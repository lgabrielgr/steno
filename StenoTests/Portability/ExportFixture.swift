import Foundation
import SwiftData

@testable import StenoKit

/// A store the export tests build records into, plus the two ways to look at
/// what came out.
///
/// **Two fixtures, and they are not interchangeable.** `maximal()` populates
/// every optional on every model, which is what keeps the key-allowlist test
/// honest: `encodeIfPresent` omits a `nil`, so a fixture that leaves one unset
/// makes the allowlist blind to exactly the field nobody remembered — the
/// failure it exists to catch. `realistic()` builds through the production
/// services instead, so the secrets scan runs over what the store actually
/// holds rather than over hand-assembled rows.
@MainActor
struct ExportFixture {
    let container: ModelContainer
    let context: ModelContext

    /// 2023-11-14 22:13:20 UTC, matching `ReportFixture.origin`.
    ///
    /// A whole second. Offsets used in `==` assertions stay whole or land on an
    /// eighth (`.25`, `.5`), because encoding truncates at the millisecond and
    /// most decimals are not representable as a `Double` at this magnitude — so
    /// only those round-trip *exactly* and let `ExportDocument ==` be used
    /// directly. Tests that pin ordering or tolerance deliberately use values
    /// that do **not** survive, such as `.5001` and clock-shaped dates.
    /// `nonisolated`, because `ExportFilenameTests` has no reason to hop to the
    /// main actor and these are two pure `Date` values. Without it the isolation
    /// error surfaces inside the `#expect` macro expansion rather than at the
    /// call site, which is a much harder read.
    nonisolated static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    nonisolated static func at(_ offset: TimeInterval) -> Date {
        origin.addingTimeInterval(offset)
    }

    init() throws {
        container = try StenoStore.inMemory()
        context = ModelContext(container)
    }

    /// The encoder under test, with its clock and user agent pinned.
    ///
    /// `exportedBy` is passed explicitly rather than defaulted: the test bundle
    /// is unhosted, so `Bundle.main` here is the xctest runner.
    func encoder(
        includingCachedData: Bool = false,
        nowOffset: TimeInterval = 0,
        exportedBy: String = "steno/test (macOS)"
    ) -> ExportEncoder {
        ExportEncoder(
            context: context,
            includesCachedExternalData: includingCachedData,
            now: { Self.at(nowOffset) },
            exportedBy: exportedBy)
    }

    // MARK: - Building rows

    @discardableResult
    func project(
        _ name: String, colorHex: String = "#112233", jiraKeys: [String] = [],
        sortOrder: Int = 0, cadence: ReportCadence = .daily, staleThresholdDays: Int? = nil,
        lastStandupAt: Date? = nil, archived: Bool = false,
        modifiedAt: Date = ExportFixture.origin, id: UUID = UUID()
    ) throws -> Project {
        let project = Project(
            id: id, name: name, colorHex: colorHex, jiraProjectKeys: jiraKeys,
            sortOrder: sortOrder, reportCadence: cadence,
            staleThresholdDays: staleThresholdDays, modifiedAt: modifiedAt)
        context.insert(project)
        project.lastStandupAt = lastStandupAt
        if archived { project.setArchived(true, at: modifiedAt) }
        try context.save()
        return project
    }

    /// - Parameters:
    ///   - statusAt: when the status moved, defaulting to `createdAt`. Separate
    ///     so a fixture can make `createdAt` and `statusChangedAt` differ —
    ///     equal timestamps would hide a mapping that crossed the two.
    ///   - archivedAt: when it was archived, which is what stamps `modifiedAt`.
    @discardableResult
    func task(
        _ title: String, in project: Project, status: Status = .todo,
        createdAt: Date = ExportFixture.origin, statusAt: Date? = nil,
        archived: Bool = false, archivedAt: Date? = nil
    ) throws -> TaskItem {
        let task = TaskItem(title: title, projectID: project.id, createdAt: createdAt)
        context.insert(task)
        if status != .todo { task.setStatus(status, at: statusAt ?? createdAt) }
        if archived { task.setArchived(true, at: archivedAt ?? createdAt) }
        try context.save()
        return task
    }

    @discardableResult
    func event(
        _ body: String, on task: TaskItem, at timestamp: Date = ExportFixture.origin,
        kind: EventKind = .note, payload: Data? = nil, redacted: Bool = false,
        id: UUID = UUID()
    ) throws -> Event {
        let event = Event(
            id: id, taskID: task.id, timestamp: timestamp, kind: kind, body: body,
            payload: payload)
        context.insert(event)
        if redacted { event.redact() }
        try context.save()
        return event
    }

    @discardableResult
    func ref(
        _ identifier: String, on task: TaskItem, kind: SourceRefKind = .jiraIssue,
        url: String? = nil, cachedSummary: String? = nil, lastFetchedAt: Date? = nil
    ) throws -> SourceRef {
        let ref = SourceRef(taskID: task.id, kind: kind, identifier: identifier, url: url)
        context.insert(ref)
        ref.task = task
        if let lastFetchedAt { ref.recordFetch(summary: cachedSummary, at: lastFetchedAt) }
        try context.save()
        return ref
    }

    @discardableResult
    func report(
        for project: Project, generatedAt: Date = ExportFixture.origin,
        windowStart: Date = ExportFixture.origin, windowEnd: Date = ExportFixture.origin,
        body: String = "*Yesterday*\n- shipped it", wasAIGenerated: Bool = false,
        modelUsed: String? = nil, undone: Bool = false
    ) throws -> StandupReport {
        let report = StandupReport(
            projectID: project.id, generatedAt: generatedAt, windowStart: windowStart,
            windowEnd: windowEnd, markdownBody: body, wasAIGenerated: wasAIGenerated,
            modelUsed: modelUsed)
        context.insert(report)
        if undone { report.markUndone() }
        try context.save()
        return report
    }

    // MARK: - The two whole-store fixtures

    /// One of every record, with **every optional populated** and every date
    /// distinct.
    ///
    /// The populated optionals are what keep `ExportCompletenessTests`' key
    /// allowlist honest: `encodeIfPresent` omits a `nil`, so an unset optional
    /// here would make the allowlist blind to that exact field. The distinct
    /// dates are what let the value-mapping test see a crossed wire —
    /// `completedAt` and `statusChangedAt` are the one unavoidable pair, since
    /// `TaskItem.setStatus` writes both from one argument.
    func maximal() throws -> Maximal {
        let project = try self.project(
            "Payments Platform", colorHex: "#AABBCC", jiraKeys: ["PAY", "BILL"],
            sortOrder: 7, cadence: .periodic, staleThresholdDays: 10,
            lastStandupAt: Self.at(3600), archived: true, modifiedAt: Self.at(1800))
        let task = try self.task(
            "Fix the retry handler", in: project, status: .done,
            createdAt: Self.at(60), statusAt: Self.at(120),
            archived: true, archivedAt: Self.at(180))
        let event = try self.event(
            "Waiting on infra to provision staging", on: task, at: Self.at(240),
            kind: .blockedReason, payload: Data("{\"ticket\":\"PAY-421\"}".utf8),
            redacted: true)
        let ref = try self.ref(
            "acme/api#421", on: task, kind: .githubPR,
            url: "https://github.com/acme/api/pull/421",
            cachedSummary: "In review, 2 comments", lastFetchedAt: Self.at(300))
        let report = try self.report(
            for: project, generatedAt: Self.at(420), windowStart: Self.at(360),
            windowEnd: Self.at(400), body: "*Yesterday*\n- fixed the retry handler",
            wasAIGenerated: true, modelUsed: "claude-opus-5", undone: true)
        return Maximal(project: project, task: task, event: event, ref: ref, report: report)
    }

    struct Maximal {
        let project: Project
        let task: TaskItem
        let event: Event
        let ref: SourceRef
        let report: StandupReport
    }

    /// A store built the way the app builds one — through the services.
    ///
    /// The secrets scan runs over this rather than over `maximal()`: a
    /// hand-assembled store proves what the test author typed, while this holds
    /// what capture, status, notes and Copy actually write.
    func realistic() throws {
        try StenoStore.seedDefaultProjectIfEmpty(in: context)
        guard let project = try context.fetch(FetchDescriptor<Project>()).first else {
            throw ExportJSON.ShapeError(detail: "the seed left no project")
        }
        let capture = CaptureService(context: context, now: { Self.at(60) })
        guard
            let task = try capture.capture(
                text: "PAY-421 fix the retry handler", preferred: project.id)
        else { throw ExportJSON.ShapeError(detail: "capture produced no task") }

        _ = try StatusService(context: context, now: { Self.at(120) })
            .setStatus(.inProgress, on: task)
        _ = try NoteService(context: context, now: { Self.at(180) })
            .addNote("repro'd the race in the retry handler", to: task)

        let window = try ReportGatherer(context: context, now: { Self.at(240) })
            .gather(for: project)
        _ = try StandupService(
            context: context, now: { Self.at(300) }, copy: { _ in true }
        ).commit("*Yesterday*\n- fixed PAY-421", of: window, for: project)
    }
}
