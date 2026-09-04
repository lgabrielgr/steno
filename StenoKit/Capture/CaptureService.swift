import Foundation
import SwiftData

/// Why a capture could not be written.
public enum CaptureError: Error, Equatable {
    /// Every project is archived, so there is nowhere to route.
    ///
    /// The one state in which capture refuses text — see the design doc §4.2
    /// and ARCHITECTURE §3's "capture never blocks" row, whose single
    /// documented exception this is.
    case noProjectAvailable
}

/// D15's "one code path": the whole of turning typed text into a persisted
/// task, shared verbatim by the main window (M1-02), the floating hotkey
/// window (M1-03) and the menu bar popover (M1-04).
///
/// `@MainActor` because `ModelContext` is not `Sendable`. `now` and `save` are
/// injected for the same reasons `MainWindowModel` injects them: a testable
/// clock, and a save that can be made to fail on demand — a real
/// `ModelContext` cannot.
@MainActor
public struct CaptureService {
    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void

    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.now = now
        self.save = save
    }

    /// Capture `text` as a task.
    ///
    /// Returns `nil` for text that is empty after trimming — a no-op rather
    /// than an error, because a surface committing an untouched field is not a
    /// failure worth reporting to the user.
    ///
    /// Throws `CaptureError.noProjectAvailable` when there is nowhere to
    /// route, and rethrows a save failure after rolling the context back.
    ///
    /// - Parameters:
    ///   - preferred: the surface's own context. The main window passes its
    ///     sidebar selection; the hotkey window and popover pass `nil`.
    ///   - defaultProjectID: FR-6's configured default. `nil` until M1-08.
    ///   - ignoringTicketKey: the user dismissed the chip, so skip rung 1.
    @discardableResult
    public func capture(
        text: String,
        preferred: UUID?,
        defaultProjectID: UUID? = nil,
        ignoringTicketKey: Bool = false
    ) throws -> TaskItem? {
        let interval = Log.captureSignposter.beginInterval("capture")
        defer { Log.captureSignposter.endInterval("capture", interval) }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let projects = try liveProjects()
        let lastUsed = try lastUsedProjectID(among: projects)
        let decision = ProjectRouter.route(
            text: trimmed,
            projects: projects,
            preferred: preferred,
            lastUsed: lastUsed,
            defaultProjectID: defaultProjectID,
            ignoringTicketKey: ignoringTicketKey
        )
        guard let projectID = decision.projectID else { throw CaptureError.noProjectAvailable }

        // FR-1.5, the full M1-01 path, run once. Unlike routing's scan this
        // one wants each reference exactly once, links and keys reconciled.
        let extracted = ReferenceExtractor.extract(from: trimmed)
        let stamp = now()

        let task = TaskItem(title: trimmed, projectID: projectID, createdAt: stamp)
        context.insert(task)

        // §3.3's EventKind table: `created` is written when a task is created.
        // A task without one is a hole in the append-only log — M2-01's
        // gathering would skip it and M2.5-02's merge would reason from it.
        context.insert(
            Event(taskID: task.id, timestamp: stamp, kind: .created, body: "Task created")
        )

        for ref in extracted {
            let stored = ref.sourceRef(taskID: task.id)
            context.insert(stored)
            // `sourceRef(taskID:)` sets the foreign key only. D-016 keeps both
            // the key and the relationship, and PersistedInvariantsTests
            // asserts they never disagree.
            stored.task = task
        }

        // `SourceRef.newRefs(from:existing:)` is deliberately NOT called here.
        // For a brand-new task `existing` is empty, and `extract` has already
        // deduped by `(kind, identifier)` — which is `SourceRef.DedupKey`
        // minus a `taskID` that is constant across one pass — so it is
        // provably a no-op. M1-06's note path is its real first caller.

        do {
            // Both of these act on the whole context, not just this capture.
            // `save` commits anything else already pending in it, and
            // `rollback` discards anything else pending. That is safe today
            // because the only caller passes `mainContext` and
            // `MainWindowModel.perform` never leaves changes pending across a
            // call — but it is an assumption, and M1-06's note path is the
            // first thing likely to break it.
            try save(context)
        } catch {
            // Without this the objects sit in the context, the next reload
            // finds them, and the window shows a task that is not on disk
            // (D-018).
            context.rollback()
            throw error
        }

        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed. `queue: nil` on
        // the observing side keeps delivery synchronous on this actor, which
        // is what lets the tests assert a count rather than wait for one.
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
        return task
    }

    private func liveProjects() throws -> [Project] {
        try context.fetch(
            FetchDescriptor<Project>(
                predicate: #Predicate { !$0.isArchived },
                sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
            )
        )
    }

    /// FR-1.4's "last-used project", derived rather than stored.
    ///
    /// No new field, no `UserDefaults` key, no settings row: it is the project
    /// of the most recently created task. It therefore cannot drift from
    /// reality, every surface agrees by construction, and it round-trips
    /// through §10's export for free because it is not a separate fact.
    ///
    /// **Not `fetchLimit = 1`.** `TaskItem` *does* have its own `isArchived`,
    /// and the predicate below uses it — but that is not the flag that matters
    /// here. D-021: a task row does not encode whether its **project** is
    /// archived. "A project's tasks disappear when it archives" is an emergent
    /// property of one in-memory join, not a stored fact, and no predicate on
    /// `TaskItem` can express it. So limiting the fetch returns the newest
    /// unarchived task, which may still belong to an archived project, and
    /// routes the capture somewhere the user cannot see it. The join has to
    /// happen after the fetch — hence read all, then `live.contains`. D18 caps
    /// the dataset under 20 live tasks, so that costs nothing.
    private func lastUsedProjectID(among projects: [Project]) throws -> UUID? {
        let live = Set(projects.map(\.id))
        guard !live.isEmpty else { return nil }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let newest = try context.fetch(descriptor)
        return newest.first { live.contains($0.projectID) }?.projectID
    }
}

this is not valid swift
