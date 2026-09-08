import Foundation
import SwiftData

@testable import StenoKit

/// A store with two projects, for the gatherer's tests.
///
/// Holds the `ModelContainer` as well as the context, because the purity gates
/// need a **second** `ModelContext` over the same container: a refetch on the
/// context that did the reading returns the object already held, so it would
/// pass even against a mutation. The independent context is what makes those
/// assertions real reads of the store.
@MainActor
struct ReportFixture {
    let container: ModelContainer
    let context: ModelContext
    let alpha: Project
    let beta: Project

    /// 2023-11-14 22:13:20 UTC. A fixed instant, so every window is arithmetic
    /// the reader can check by hand.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        container = try StenoStore.inMemory()
        context = ModelContext(container)
        alpha = Project(name: "Alpha", colorHex: "#112233", modifiedAt: Self.origin)
        beta = Project(name: "Beta", colorHex: "#445566", modifiedAt: Self.origin)
        context.insert(alpha)
        context.insert(beta)
        try context.save()
    }

    @discardableResult
    func task(
        _ title: String, in project: Project, status: Status = .todo,
        createdAt: Date = ReportFixture.origin, archived: Bool = false
    ) throws -> TaskItem {
        let item = TaskItem(title: title, projectID: project.id, createdAt: createdAt)
        context.insert(item)
        if status != .todo { item.setStatus(status, at: createdAt) }
        if archived { item.setArchived(true, at: createdAt) }
        try context.save()
        return item
    }

    @discardableResult
    func event(
        _ body: String, on task: TaskItem, at offset: TimeInterval,
        kind: EventKind = .note, redacted: Bool = false
    ) throws -> Event {
        let event = Event(
            taskID: task.id, timestamp: Self.origin.addingTimeInterval(offset),
            kind: kind, body: body)
        context.insert(event)
        if redacted { event.redact() }
        try context.save()
        return event
    }

    @discardableResult
    func jiraRef(_ key: String, on task: TaskItem) throws -> SourceRef {
        let ref = SourceRef(taskID: task.id, kind: .jiraIssue, identifier: key)
        context.insert(ref)
        ref.task = task
        try context.save()
        return ref
    }

    /// Set a project's last stand-up **and commit it**.
    ///
    /// A method rather than a bare assignment at each call site because
    /// `lastStandupAt` is a plain `var` (§10.1 gives it its own merge rule, so
    /// it must not stamp `modifiedAt`), which makes an uncommitted assignment
    /// easy to write and invisible afterwards. It leaves `context.hasChanges`
    /// true, which silently defeats the purity gate that asserts the gatherer
    /// left nothing pending.
    func setLastStandup(_ date: Date?, on project: Project) throws {
        project.lastStandupAt = date
        try context.save()
    }

    /// The gatherer under test, with its clock pinned to `origin + offset`.
    func gatherer(nowOffset: TimeInterval) -> ReportGatherer {
        ReportGatherer(context: context, now: { Self.origin.addingTimeInterval(nowOffset) })
    }

    /// Read `project` back through a context that has never seen it, so the
    /// value comes from the store rather than from an object already in memory.
    func reloadThroughASecondContext(_ project: Project) throws -> Project? {
        let fresh = ModelContext(container)
        let id = project.id
        return try fresh.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id }))
            .first
    }
}
