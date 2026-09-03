import Foundation
import SwiftData

/// What an attempted correction did (FR-2).
///
/// Four cases rather than a `Bool` because the UI's response differs in each:
/// expiry keeps the user's draft and offers to append it, `notCorrectable` is a
/// programming error the UI should never have offered, and `unchanged` is a
/// no-op worth no message at all.
public enum CorrectionOutcome: Equatable, Sendable {
    /// The original was redacted and a replacement appended.
    case corrected
    /// Blank, or byte-identical to the original. Nothing was written.
    case unchanged
    /// Past FR-2's window. Nothing was written; the caller still holds the text.
    case windowExpired
    /// Not a user-authored kind, or already redacted. Nothing was written.
    case notCorrectable
}

/// The one path for notes and their correction (FR-2, §3.3).
///
/// A sibling of `StatusService`, not an extension of it: `addBlockedReason`
/// guards on `task.status == .blocked`, but correcting a blocked reason three
/// minutes after the task unblocked must still work. Same rows, different rule.
///
/// Shaped like `StatusService` and `CaptureService`, for their reasons:
/// `@MainActor` because `ModelContext` is not `Sendable`; `now` injected so
/// timestamps are assertable; `save` injected because a real `ModelContext`
/// cannot be made to fail on demand, and the rollback is the path that most
/// needs a test.
///
/// **Correction is redact-and-reappend, never mutation.** `Event`'s fields are
/// all `private(set)`, so the shorter path is a compile error rather than a
/// convention — see `correct(_:to:on:)`.
@MainActor
public struct NoteService {
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

    /// FR-2: append a `note` event carrying `text`.
    ///
    /// Returns `nil` for text that is empty after trimming — a no-op rather
    /// than an error, matching `CaptureService.capture`: a surface committing
    /// an untouched field is not a failure worth reporting.
    ///
    /// **Does not stamp `task.modifiedAt`.** `TaskItem.setStatus` already
    /// declines to, on the grounds that status is derived from the event log;
    /// a note is the same kind of fact. Stamping it would let a task that only
    /// gained a note outrank, in §10.1's "later `modifiedAt` wins" merge, a
    /// task whose title was genuinely edited on another Mac.
    @discardableResult
    public func addNote(_ text: String, to task: TaskItem) throws -> Event? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let event = Event(taskID: task.id, timestamp: now(), kind: .note, body: trimmed)
        context.insert(event)
        insertNewRefs(from: trimmed, on: task)
        try commit()
        return event
    }

    /// FR-2's grace-period "edit", which is not an edit.
    ///
    /// Redacts `event` and appends a **new** row carrying the corrected body,
    /// the **original's timestamp**, and the **original's kind**.
    ///
    /// The timestamp is FR-2's own requirement: it keeps the note where the
    /// user expects it in the timeline instead of jumping to the top
    /// mid-correction. It also means the window does not restart — eligibility
    /// measures from `event.timestamp`, so no chain of corrections reaches past
    /// five minutes from the first write.
    ///
    /// **The kind is a deliberate widening of FR-2**, which says "a new `note`
    /// event" because it predates `blockedReason` being correctable. Hard-coding
    /// `.note` would relabel a corrected blocked reason, changing what §3.3 says
    /// the row means and what M2-02 renders it under.
    public func correct(
        _ event: Event, to text: String, on task: TaskItem
    ) throws -> CorrectionOutcome {
        // The replacement is filed under `event.taskID` while extracted refs
        // are attached to `task`, so a mismatched pair would split one
        // correction across two tasks — the event on one, its `SourceRef`s on
        // the other. Unreachable through the only caller, which draws the
        // event from the selected task's own timeline; this makes it
        // unreachable through any caller.
        guard event.taskID == task.id else { return .notCorrectable }
        guard event.kind.isUserAuthored, !event.isRedacted else { return .notCorrectable }
        guard
            NoteCorrection.isCorrectable(
                kind: event.kind, timestamp: event.timestamp, isRedacted: event.isRedacted,
                at: now())
        else { return .windowExpired }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied correction is **not** silently converted into a redaction.
        // Making the destructive, one-way operation the outcome of clearing a
        // text field is exactly the surprise `Event` has no `unredact()` to
        // recover from.
        guard !trimmed.isEmpty, trimmed != event.body else { return .unchanged }

        event.redact()
        context.insert(
            Event(
                taskID: event.taskID, timestamp: event.timestamp, kind: event.kind, body: trimmed))
        insertNewRefs(from: trimmed, on: task)
        try commit()
        return .corrected
    }

    /// §3.3's soft delete: hide the event, retain the row.
    ///
    /// Returns whether it wrote. `false` rather than a throw for an ineligible
    /// event matches `StatusService.setStatus`'s no-op contract — nothing
    /// written, nothing for the caller to reload.
    @discardableResult
    public func redact(_ event: Event) throws -> Bool {
        guard event.kind.isUserAuthored, !event.isRedacted else { return false }
        event.redact()
        try commit()
        return true
    }

    /// FR-1.5 over a note body, deduped against what the task already has.
    ///
    /// `SourceRef.newRefs(from:existing:)`'s first real caller — its doc
    /// comment has said so since M0-03. Unlike `CaptureService`, the task here
    /// is not new, so `existing` is genuinely non-empty and the dedup is doing
    /// work rather than being provably a no-op.
    private func insertNewRefs(from text: String, on task: TaskItem) {
        let candidates = ReferenceExtractor.extract(from: text).map {
            $0.sourceRef(taskID: task.id)
        }
        for ref in SourceRef.newRefs(from: candidates, existing: task.sourceRefs ?? []) {
            context.insert(ref)
            // `sourceRef(taskID:)` sets the foreign key only. D-016 keeps both
            // the key and the relationship, and `PersistedInvariantsTests`
            // asserts they never disagree.
            ref.task = task
        }
    }

    /// Save, roll back on failure, and tell the other surfaces.
    ///
    /// **What a held object reports after a failed `rollback()` is not
    /// something this codebase controls, and no test here asserts it.**
    /// Measured twice, two different ways, on two contradictory but each
    /// internally deterministic answers — depending on what else was running
    /// in the same test process, not on anything `NoteService` does. The
    /// stored value is always correctly rolled back; a fresh fetch is
    /// trustworthy. The held object is not, in either direction reliably.
    /// Callers must reload on every failure path for exactly that reason:
    /// there is no answer to trust, so none is assumed.
    private func commit() throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed.
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
    }
}
