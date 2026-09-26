import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// A store with one project, tasks, and refs, for the refresh service's tests.
///
/// Holds the container as well as the context because the write assertions need a
/// **second** `ModelContext`: a refetch on the context that did the writing
/// returns the objects already held, so "the event landed" would pass even
/// against a rollback. `ReportFixture` records the same reason.
///
/// **Refs are created the way `CaptureService` creates them** — `taskID` *and*
/// the relationship, per D-016 — because the production shape is what the service
/// reads. A fixture that set only one of the two would pass a test against an
/// implementation that read the other.
@MainActor
struct RefreshFixture {
    let container: ModelContainer
    let context: ModelContext
    let project: Project

    /// 2023-11-14 22:13:20 UTC. A fixed instant, so every staleness window is
    /// arithmetic the reader can check by hand.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        container = try StenoStore.inMemory()
        context = ModelContext(container)
        project = Project(name: "Payments", colorHex: "#112233", modifiedAt: Self.origin)
        context.insert(project)
        try context.save()
    }

    @discardableResult
    func task(
        _ title: String, status: Status = .inProgress, archived: Bool = false
    ) throws -> TaskItem {
        let item = TaskItem(title: title, projectID: project.id, createdAt: Self.origin)
        context.insert(item)
        if status != .todo { item.setStatus(status, at: Self.origin) }
        if archived { item.setArchived(true, at: Self.origin) }
        try context.save()
        return item
    }

    @discardableResult
    func ref(
        _ identifier: String, on task: TaskItem, kind: SourceRefKind = .jiraIssue,
        fetched: Date? = nil, summary: String? = nil
    ) throws -> SourceRef {
        let ref = SourceRef(taskID: task.id, kind: kind, identifier: identifier)
        context.insert(ref)
        ref.task = task
        if let fetched { ref.recordFetch(summary: summary, at: fetched) }
        try context.save()
        return ref
    }

    /// The service under test.
    ///
    /// Millisecond budgets by default: an eight-second hang in `make test` is how
    /// a suite stops being run.
    /// - Parameter gate: a **fresh** gate by default, so one test's pass never
    ///   queues behind another's — the production default is the shared instance
    ///   (D-183). A test that wants two services serialized against each other
    ///   passes one gate to both.
    func service(
        connectors: [any SourceConnector],
        nowOffset: TimeInterval = 0,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        perFetch: Duration = .milliseconds(200),
        budget: Duration = .milliseconds(400),
        gate: SourceRefreshGate = SourceRefreshGate()
    ) -> SourceRefreshService {
        SourceRefreshService(
            context: context, registry: SourceRegistry(connectors: connectors),
            now: { Self.origin.addingTimeInterval(nowOffset) }, save: save,
            perFetch: perFetch, budget: budget, gate: gate)
    }

    // MARK: - Independent reads

    /// A second context over the same container, so a read is a real read.
    private func freshContext() -> ModelContext { ModelContext(container) }

    func eventsInStore(kind: EventKind? = nil) throws -> [Event] {
        let events = try freshContext().fetch(
            FetchDescriptor<Event>(sortBy: [SortDescriptor(\.timestamp, order: .forward)]))
        guard let kind else { return events }
        // Filtered in memory: an `EventKind` inside a `#Predicate` does not
        // compile in either spelling (`EventQueries` records this).
        return events.filter { $0.kind == kind }
    }

    func refInStore(_ identifier: String) throws -> SourceRef? {
        try freshContext().fetch(FetchDescriptor<SourceRef>())
            .first { $0.identifier == identifier }
    }

    func taskInStore(_ title: String) throws -> TaskItem? {
        try freshContext().fetch(FetchDescriptor<TaskItem>()).first { $0.title == title }
    }
}

/// A `save` that throws on demand, for the rollback path.
///
/// A real `ModelContext` cannot be made to fail its save, which is why every
/// writing service in this codebase injects one.
@MainActor
final class FailingSave {
    private(set) var attempts = 0
    var shouldFail: Bool

    init(shouldFail: Bool = true) {
        self.shouldFail = shouldFail
    }

    struct Refused: Error {}

    func save(_ context: ModelContext) throws {
        attempts += 1
        if shouldFail { throw Refused() }
        try context.save()
    }
}
