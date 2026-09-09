import Foundation
import OSLog
import SwiftData

/// What one Copy did (FR-4 step 7).
///
/// **Two channels, because the two failures need different responses.** A
/// thrown error means the transaction rolled back: nothing happened, and
/// retrying is safe. `didReachClipboard == false` means everything happened
/// except the clipboard, and retrying would report the window a second time.
/// Collapsing them into one `Bool` would leave the UI unable to tell the user
/// which of those they are looking at.
public struct StandupCommit {
    /// The persisted row. M2-04 undoes *this* report.
    public let report: StandupReport

    /// Whether the markdown actually reached the pasteboard.
    public let didReachClipboard: Bool
}

/// FR-4 step 7's Copy: the one place the stand-up clock advances.
///
/// A sibling of `NoteService` and `StatusService` and shaped like them —
/// `@MainActor` because `ModelContext` is not `Sendable`, `now` injected so
/// timestamps are assertable, `save` injected because a real `ModelContext`
/// cannot be made to fail on demand and the rollback is the path that most
/// needs a test — plus one seam they do not have, the clipboard.
///
/// **Deliberately not part of `ReportGatherer`.** That type has no `save` and
/// no `commit()`, and D-065 records that absence as the design: FR-4 requires
/// generating a preview to be free of side effects "so the user can peek
/// without corrupting their window". Every write in FR-4's flow lives here, so
/// the two halves of that guarantee are two types rather than two code paths in
/// one.
@MainActor
public struct StandupService {
    private let context: ModelContext
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void
    private let copy: (String) -> Bool

    public init(
        context: ModelContext,
        now: @escaping () -> Date = Date.init,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        copy: @escaping (String) -> Bool = StandupClipboard.write
    ) {
        self.context = context
        self.now = now
        self.save = save
        self.copy = copy
    }

    /// Commit `body` as `project`'s stand-up for `window`, then copy it.
    ///
    /// All four of FR-4 step 7's effects, or none of them. Steps 2–5 below are
    /// inserts and one field write into a single `ModelContext`, committed by a
    /// single `save` — so "a failure partway must not leave `lastStandupAt`
    /// advanced with no report persisted" is a property of the transaction
    /// boundary rather than of careful ordering. The rejected alternative was
    /// four saves with compensating writes, which cannot satisfy it at all: the
    /// compensation for an appended `Event` is a delete, and §3.3 forbids that
    /// outright.
    ///
    /// **`throws` covers two failures, and a refused clipboard is not one of
    /// them.** The save can fail, and the `window`/`project` guard below can
    /// refuse the call before anything is written; both leave the store
    /// untouched, so a caller that catches either one can retry safely. A
    /// clipboard refusal happens *after* the transaction has committed and
    /// cannot be retried without double-reporting, so it is reported through
    /// `StandupCommit.didReachClipboard` instead — see below.
    ///
    /// **`body` is the caller's text, not a re-render of `window`.** FR-4 step 6
    /// makes the draft editable and §7.3's whole philosophy is that the user's
    /// phrasing wins, so the edited string is what reaches both the clipboard
    /// and `markdownBody`.
    public func commit(
        _ body: String, of window: GatheredWindow, for project: Project
    ) throws -> StandupCommit {
        // 1. The pair must describe the same project. `NoteService.correct`
        //    guards its own pair for this reason: a mismatch would advance one
        //    project's clock against another project's window, which is exactly
        //    what D16 forbids. Unreachable through the only caller: `copyStandup()`
        //    resolves the project *from* `window.projectID`, so the pair it passes
        //    cannot disagree by construction. Retained anyway — the guard is one
        //    line, and it is what stops a future caller that reads a live
        //    selection (as `copyStandup()` itself once did) from advancing one
        //    project's clock against another's window.
        guard window.projectID == project.id else {
            throw StandupError.windowBelongsToAnotherProject
        }

        // 2. One stamp, used for the report and every event it appends. Two
        //    `now()` calls would let a report and its own events disagree about
        //    when the stand-up happened.
        let stamp = now()

        let report = StandupReport(
            projectID: project.id,
            generatedAt: stamp,
            windowStart: window.start,
            windowEnd: window.end,
            markdownBody: body,
            wasAIGenerated: false
        )
        context.insert(report)

        // 3. One event per task the window reported on — **not** per task named
        //    in `body`. The user may have edited a bullet out of the draft, and
        //    recovering task identity from Slack `mrkdwn` is not merely hard but
        //    ill-defined: D6's output carries no identifiers. The window is the
        //    machine-readable record of what was reported on; the text is the
        //    user's phrasing of it.
        let payload = StandupReportedPayload(reportID: report.id).encoded()
        for task in window.tasks {
            context.insert(
                Event(
                    taskID: task.id,
                    timestamp: stamp,
                    // §3.3's own example body for this kind. Not invented here,
                    // and not the report text: D-066 keeps `standupReported`
                    // out of every future window, so this string is read in the
                    // timeline and nowhere else.
                    kind: .standupReported,
                    body: "Reported to standup",
                    payload: payload
                ))
        }

        // 4. The clock advances to the window's **end**, not to `now` (D-076).
        //    FR-4 step 7 says "now", but the window was computed at generate
        //    time: a note captured between generating and copying would fall
        //    into no report at all — neither this draft nor the next window.
        //    REQUIREMENTS v1.15 amends step 7 to match this line.
        project.lastStandupAt = window.end

        // 5. One save for all of it. On failure the context returns to where it
        //    started and the caller is told nothing happened.
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }

        // 6. After the save, never before: an observer that reloads must not
        //    read a context whose write has not landed (D-019).
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

        // 7. The clipboard last. If the save had failed the user would have
        //    nothing on the clipboard and a draft still on screen — they retry,
        //    and nothing was lost. Copying first would hand them text to read
        //    aloud at a stand-up the app has no record of, with no signal that
        //    the record is missing.
        //
        //    This failing after a successful save cannot be rolled back: the
        //    compensation is deleting an `Event`, which §3.3 forbids. So it is
        //    reported rather than reversed, and M2-04's undo is the recovery.
        let didReachClipboard = copy(body)
        if !didReachClipboard {
            Log.app.error("the stand-up was recorded but the clipboard refused the write")
        }

        return StandupCommit(report: report, didReachClipboard: didReachClipboard)
    }
}

/// Why a Copy was refused before it wrote anything.
public enum StandupError: Error, Equatable {
    /// The window and the project disagree — see `commit`'s first guard.
    case windowBelongsToAnotherProject
}
