import Foundation

@testable import StenoKit

/// Record values for the merge tests, built directly rather than through a
/// store.
///
/// `StoreMerge` is pure, so its tests need no `ModelContainer` at all — which is
/// the whole reason §10.6's three algebraic properties can be stated as
/// comparisons between values. `ExportFixture` builds through SwiftData and
/// stays where it is; this is its counterpart on the other side of the wire.
///
/// **Ids are fixed, not random.** Every exported array's total order ends in
/// `id.uuidString` (D-092), so random ids would make the sorted output of a
/// merge differ run to run — and a commutativity assertion would then be
/// flaky in a way that looks like a merge bug.
enum MergeFixture {
    /// 2023-11-14 22:13:20 UTC, matching `ExportFixture.origin`.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// **Offsets here are deliberately not eighths of a second.** The wire
    /// format quantizes to the millisecond, and the merge compares timestamps;
    /// values that survive encoding exactly would hide the asymmetry
    /// `MergedStore.wireNormalized` exists to remove.
    static func at(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    /// A stable uuid, ordered by its argument so the sorted output of a merge is
    /// predictable when a test needs to index into it.
    static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))
            ?? UUID()
    }

    static func project(
        _ number: Int, name: String = "Payments", colorHex: String = "#112233",
        jiraKeys: [String] = [], archived: Bool = false, sortOrder: Int = 0,
        lastStandupAt: Date? = nil, cadence: ReportCadence = .daily,
        staleThresholdDays: Int? = nil, modifiedAt: Date = MergeFixture.origin
    ) -> ExportedProject {
        ExportedProject(
            id: id(number), name: name, colorHex: colorHex, jiraProjectKeys: jiraKeys,
            isArchived: archived, sortOrder: sortOrder, lastStandupAt: lastStandupAt,
            reportCadence: cadence, staleThresholdDays: staleThresholdDays,
            modifiedAt: modifiedAt)
    }

    static func task(
        _ number: Int, title: String = "Fix the retry handler", project: Int = 1,
        status: Status = .todo, createdAt: Date = MergeFixture.origin,
        statusChangedAt: Date? = nil, completedAt: Date? = nil, archived: Bool = false,
        modifiedAt: Date = MergeFixture.origin
    ) -> ExportedTask {
        ExportedTask(
            id: id(number), title: title, projectID: id(project), status: status,
            createdAt: createdAt, statusChangedAt: statusChangedAt ?? createdAt,
            completedAt: completedAt, isArchived: archived, modifiedAt: modifiedAt)
    }

    static func event(
        _ number: Int, task: Int = 2, at when: Date = MergeFixture.origin,
        kind: EventKind = .note, body: String = "repro'd the race", payload: Data? = nil,
        redacted: Bool = false
    ) -> ExportedEvent {
        ExportedEvent(
            id: id(number), taskID: id(task), timestamp: when, kind: kind, body: body,
            payload: payload, isRedacted: redacted)
    }

    /// A `statusChanged` event with a body `StatusTransition` can read back.
    static func transition(
        _ number: Int, task: Int = 2, from: Status, into: Status, at when: Date
    ) -> ExportedEvent {
        event(
            number, task: task, at: when, kind: .statusChanged,
            body: StatusTransition(from: from, into: into).eventBody)
    }

    static func ref(
        _ number: Int, task: Int = 2, kind: SourceRefKind = .jiraIssue,
        identifier: String = "PAY-421", url: String? = nil, lastFetchedAt: Date? = nil,
        cachedSummary: String? = nil
    ) -> ExportedSourceRef {
        ExportedSourceRef(
            id: id(number), taskID: id(task), kind: kind, identifier: identifier, url: url,
            lastFetchedAt: lastFetchedAt, cachedSummary: cachedSummary)
    }

    static func report(
        _ number: Int, project: Int = 1, generatedAt: Date = MergeFixture.origin,
        windowStart: Date = MergeFixture.origin, windowEnd: Date = MergeFixture.origin,
        body: String = "*Yesterday*\n- shipped it", wasAIGenerated: Bool = false,
        modelUsed: String? = nil, undone: Bool = false
    ) -> ExportedReport {
        ExportedReport(
            id: id(number), projectID: id(project), generatedAt: generatedAt,
            windowStart: windowStart, windowEnd: windowEnd, markdownBody: body,
            wasAIGenerated: wasAIGenerated, modelUsed: modelUsed, isUndone: undone)
    }

    /// A store at wire precision, which is the only state a merge ever sees.
    ///
    /// Both sides go through this. Skipping it on one side reintroduces exactly
    /// the sub-millisecond asymmetry that makes `merge(A,B)` stop equalling
    /// `merge(B,A)`, and the test would then be asserting the bug.
    static func store(
        projects: [ExportedProject] = [], tasks: [ExportedTask] = [],
        events: [ExportedEvent] = [], refs: [ExportedSourceRef] = [],
        reports: [ExportedReport] = []
    ) throws -> MergedStore {
        try MergedStore(
            projects: projects, tasks: tasks, events: events, sourceRefs: refs,
            reports: reports
        ).wireNormalized()
    }
}
