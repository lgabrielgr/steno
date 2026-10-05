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
    ///
    /// `nonisolated` because the doubles read it at file scope: this type is
    /// `@MainActor` for its store, and an immutable `Date` needs none of that.
    nonisolated static let origin = Date(timeIntervalSince1970: 1_700_000_000)

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
    /// - Parameter url: §3.4's optional link. Defaulted to none; a test that needs a
    ///   ref the connectors route by *host* — a site change orphaning a cached ref —
    ///   passes one.
    func ref(
        _ identifier: String, on task: TaskItem, kind: SourceRefKind = .jiraIssue,
        url: String? = nil, fetched: Date? = nil, summary: String? = nil
    ) throws -> SourceRef {
        let ref = SourceRef(taskID: task.id, kind: kind, identifier: identifier, url: url)
        context.insert(ref)
        ref.task = task
        if let fetched { ref.recordFetch(summary: summary, at: fetched) }
        try context.save()
        return ref
    }

    /// Record that a ref has already been reported, the way a pass does (D-184).
    ///
    /// **An `externalUpdate` event with a payload, not just a `lastFetchedAt`.** Since
    /// M4-02 the next `since` comes from the log rather than from the row, so a
    /// fixture that set only the row's timestamp would set up a ref the service
    /// correctly treats as never reported — which is how a test about `since` starts
    /// passing for the wrong reason.
    ///
    /// - Parameters:
    ///   - watermark: the newest item timestamp that observation reported. The next
    ///     `since` is this less `ResumePoint.overlap`.
    ///   - changeIDs: ids the log will say were already reported, for dedup tests.
    ///   - presentIDs: the recorded state set, for the link set-difference tests.
    ///     `nil` records no set at all, which is what a pre-M4-02 payload looks like.
    @discardableResult
    func observed(
        _ ref: SourceRef, watermark: Date, at stamp: Date? = nil,
        changes: [String] = [], changeIDs: [String] = [], presentIDs: [String]? = nil
    ) throws -> Event {
        let event = Event(
            taskID: ref.taskID, timestamp: stamp ?? watermark, kind: .externalUpdate,
            body: "\(ref.identifier): recorded by the fixture",
            payload: ExternalUpdatePayload(
                refID: ref.id, kind: ref.kind, identifier: ref.identifier, changes: changes,
                url: nil, fetchedAt: watermark, watermark: watermark, changeIDs: changeIDs,
                presentIDs: presentIDs
            ).encoded())
        context.insert(event)
        try context.save()
        return event
    }

    /// What `since` a ref with this watermark produces (D-185).
    ///
    /// Spelled here once so the tests read as "the watermark, less the overlap" rather
    /// than repeating an arithmetic expression that could drift from the constant.
    nonisolated static func since(after watermark: Date) -> Date {
        watermark.addingTimeInterval(-ResumePoint.overlap)
    }

    /// The service under test.
    ///
    /// Millisecond budgets by default: an eight-second hang in `make test` is how
    /// a suite stops being run.
    /// - Parameter gate: a **fresh** gate by default, so one test's pass never
    ///   queues behind another's — the production default is the shared instance
    ///   (D-183). A test that wants two services serialized against each other
    ///   passes one gate to both.
    /// - Parameter disabled: connector ids FR-6's toggle has switched off (D-216).
    ///   Defaulted to none, so every existing caller is unchanged.
    func service(
        connectors: [any SourceConnector],
        disabled: Set<String> = [],
        nowOffset: TimeInterval = 0,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        readEvents: @escaping (ModelContext, UUID) throws -> [Event] = {
            try $0.fetch(EventQueries.allEvents(forTaskID: $1))
        },
        perFetch: Duration = .milliseconds(200),
        budget: Duration = .milliseconds(400),
        gate: SourceRefreshGate = SourceRefreshGate()
    ) -> SourceRefreshService {
        SourceRefreshService(
            context: context,
            registry: SourceRegistry(
                connectors: connectors, isEnabled: { !disabled.contains($0) }),
            now: { Self.origin.addingTimeInterval(nowOffset) }, save: save,
            readEvents: readEvents, perFetch: perFetch, budget: budget, gate: gate)
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

extension [SourceChange] {
    /// Text-only changes, with ids derived from the text.
    ///
    /// **Test sugar, and only for assertions that are about wording.** `SourceChange`
    /// carries an id because de-duplication depends on it (D-186); a test about the
    /// event *body* does not care what the id is, and spelling one out at every call
    /// site would bury the sentence being asserted. Tests about dedup name their ids
    /// explicitly.
    static func texts(_ values: String...) -> [SourceChange] {
        values.map { SourceChange(id: $0, text: $0) }
    }
}
