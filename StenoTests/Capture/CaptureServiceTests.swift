import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// `ModelContext(container)` retains its container; `container.mainContext`
/// does NOT, so a helper returning the main context leaves it dangling and the
/// next insert traps inside SwiftData. Every test in this repo uses this form.
@MainActor
private func makeContext() throws -> ModelContext {
    ModelContext(try StenoStore.inMemory())
}

/// A clock that advances a second per read.
///
/// Two captures under a frozen clock share a `createdAt`, which makes "the
/// most recently created task" undefined — and the last-used derivation is
/// exactly what these tests are asserting about.
@MainActor
private final class AdvancingClock {
    private var current: Date

    init(start: Date) { current = start }

    func next() -> Date {
        defer { current = current.addingTimeInterval(1) }
        return current
    }
}

@MainActor
@discardableResult
private func insertProject(
    _ name: String, keys: [String] = [], order: Int = 0, into context: ModelContext
) throws -> Project {
    let project = Project(
        name: name,
        colorHex: ProjectPalette.hex(forIndex: order),
        jiraProjectKeys: keys,
        sortOrder: order,
        modifiedAt: epoch
    )
    context.insert(project)
    try context.save()
    return project
}

@MainActor
@Test("a capture writes the task, its created event, and its refs")
func captureWritesEverythingOnce() throws {
    let context = try makeContext()
    let payments = try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)
    )

    #expect(task.title == "PAY-421 fix the retry handler")
    #expect(task.projectID == payments.id)
    #expect(task.createdAt == epoch)

    let events = try context.fetch(FetchDescriptor<Event>())
    #expect(events.count == 1)
    #expect(events.first?.kind == .created)
    #expect(events.first?.taskID == task.id)

    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.map(\.identifier) == ["PAY-421"])
}

@MainActor
@Test("every ref carries both the foreign key and the relationship (D-016)")
func refsAreWiredBothWays() throws {
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(
            text: "PAY-421 see https://github.com/acme/api/pull/912", preferred: nil)
    )

    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.count == 2)
    for ref in refs {
        // PersistedInvariantsTests asserts these never disagree.
        // `ExtractedRef.sourceRef(taskID:)` sets only the first.
        #expect(ref.taskID == task.id)
        #expect(ref.task?.id == task.id)
    }
}

@MainActor
@Test("text that is empty after trimming writes nothing at all")
func blankTextWritesNothing() throws {
    let context = try makeContext()
    try insertProject("Payments", into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try service.capture(text: "   \n  ", preferred: nil)

    #expect(task == nil)
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
}

@MainActor
@Test("the title is stored trimmed")
func titleIsTrimmed() throws {
    let context = try makeContext()
    try insertProject("Payments", into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(try service.capture(text: "  fix the thing  ", preferred: nil))

    #expect(task.title == "fix the thing")
}

@MainActor
@Test("a failed save leaves nothing partially written")
func failedSaveRollsBack() throws {
    struct Boom: Error {}
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], into: context)
    let service = CaptureService(context: context, now: { epoch }, save: { _ in throw Boom() })

    #expect(throws: Boom.self) {
        try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)
    }

    // Accepting a write that evaporates is worse than refusing it: the loss
    // surfaces at a stand-up weeks later (D-018, §1.1).
    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<Event>()).isEmpty)
    #expect(try context.fetch(FetchDescriptor<SourceRef>()).isEmpty)
}

@MainActor
@Test("the last-used project is the newest task's, across projects")
func lastUsedFollowsTheNewestTask() throws {
    let context = try makeContext()
    try insertProject("Payments", order: 0, into: context)
    let hiring = try insertProject("EM — Hiring", order: 1, into: context)
    let clock = AdvancingClock(start: epoch)
    let service = CaptureService(context: context, now: { clock.next() })

    try service.capture(text: "first", preferred: hiring.id)
    let second = try #require(try service.capture(text: "second", preferred: nil))

    // No key, no preference — so rung 3, and rung 3 is where `first` went.
    #expect(second.projectID == hiring.id)
}

@MainActor
@Test("last-used ignores a newer task belonging to an archived project")
func lastUsedSkipsArchivedProjects() throws {
    let context = try makeContext()
    try insertProject("Payments", order: 0, into: context)
    let design = try insertProject("Design System", order: 1, into: context)
    let hiring = try insertProject("EM — Hiring", order: 2, into: context)
    let clock = AdvancingClock(start: epoch)
    let service = CaptureService(context: context, now: { clock.next() })

    // Older capture into a project that stays live...
    try service.capture(text: "into design", preferred: design.id)
    // ...then a newer one into the project about to be archived.
    try service.capture(text: "into hiring", preferred: hiring.id)
    hiring.setArchived(true, at: epoch)
    try context.save()

    let next = try #require(try service.capture(text: "where does this land", preferred: nil))

    // **Three projects, not two, and that is what makes this test discriminate.**
    // D-021: `TaskItem` has no archived flag of its own, so the newest task row
    // still belongs to archived Hiring. The three candidate implementations
    // must give three answers, and only one of them is Design System:
    //
    //   correct           → Design System — newest task in a *live* project
    //   `fetchLimit = 1`  → Hiring, which `ProjectRouter` then rejects as not
    //                       live, falling through to rung 5 → Payments
    //   no derivation     → rung 5 → Payments
    //
    // With only two projects the correct answer collapses onto rung 5's answer
    // and the bug this test is named for passes it.
    #expect(next.projectID == design.id)
}

@MainActor
@Test("with every project archived, capture refuses and writes nothing")
func noLiveProjectRefuses() throws {
    let context = try makeContext()
    let payments = try insertProject("Payments", into: context)
    payments.setArchived(true, at: epoch)
    try context.save()
    let service = CaptureService(context: context, now: { epoch })

    #expect(throws: CaptureError.noProjectAvailable) {
        try service.capture(text: "nowhere to put this", preferred: nil)
    }

    #expect(try context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
}

@MainActor
@Test("a dismissed chip routes down the ladder instead of to the key")
func ignoringTicketKeyFallsThrough() throws {
    let context = try makeContext()
    try insertProject("Payments", keys: ["PAY"], order: 0, into: context)
    let hiring = try insertProject("EM — Hiring", order: 1, into: context)
    let service = CaptureService(context: context, now: { epoch })

    let task = try #require(
        try service.capture(
            text: "PAY-421 fix it", preferred: hiring.id, ignoringTicketKey: true)
    )

    #expect(task.projectID == hiring.id)
    // The ref is still extracted — dismissing the chip declines the routing,
    // not the reference (FR-1.5 is passive and unconditional).
    let refs = try context.fetch(FetchDescriptor<SourceRef>())
    #expect(refs.map(\.identifier) == ["PAY-421"])
}
