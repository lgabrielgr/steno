import Foundation
import SwiftData

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
    /// **`rollback()` keeps a failed redaction off disk but does not restore
    /// the in-memory object** — the held `Event` still reports
    /// `isRedacted == true` until a fetch refreshes it. Callers must reload on
    /// the error path, or the timeline hides a note the store still has.
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
