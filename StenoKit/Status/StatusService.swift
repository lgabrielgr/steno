import Foundation
import SwiftData

/// The one path for changing a task's status (§3.2, §3.3, D-033).
///
/// Every transition appends exactly one `statusChanged` event. A transition
/// that skips its event is not cosmetic: §3.3 makes the log the source of
/// truth, and M2.5-02's merge *derives* `TaskItem.status` from the newest
/// `statusChanged` event — so a silent transition reverts after an import,
/// months later, for no visible reason.
///
/// Shaped like `CaptureService`, for its reasons: `@MainActor` because
/// `ModelContext` is not `Sendable`; `now` injected so timestamps are
/// assertable; `save` injected because a real `ModelContext` cannot be made to
/// fail on demand, and the rollback is the path that most needs a test.
///
/// **On a failed save the store is untouched, but a caller's held reference is
/// not restored.** Measured, not assumed: `context.rollback()` discards the
/// inserted event and prevents the mutation from ever being persisted, yet the
/// in-memory object keeps the rejected value until the context is fetched
/// again — a fetch refreshes that same instance. Callers that hold a task must
/// refetch after a failure; `MainWindowModel` does, by calling `reload()`.
@MainActor
public struct StatusService {
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

    /// Move `task` to `new`, appending the `statusChanged` event §3.3 requires.
    ///
    /// Returns whether a transition actually happened. Setting the status a
    /// task already has writes **nothing** — no event, no save, no post — and
    /// returns `false`: `TaskItem.setStatus` no-ops on it, and an event for it
    /// would describe a transition that never occurred, which M2-02 would then
    /// render into a stand-up as work that did not happen.
    ///
    /// Rethrows a save failure after rolling the context back. Without that
    /// the mutation would be committed by the next unrelated save (D-018).
    @discardableResult
    public func setStatus(_ new: Status, on task: TaskItem) throws -> Bool {
        // Read before the mutation. Reading `task.status` afterwards compiles
        // and yields `"BLOCKED → BLOCKED"` in a log that has no correction path.
        let transition = StatusTransition(from: task.status, into: new)
        guard transition.from != transition.into else { return false }

        let stamp = now()
        task.setStatus(new, at: stamp)
        context.insert(
            Event(
                taskID: task.id, timestamp: stamp, kind: .statusChanged,
                body: transition.eventBody))

        try commit()
        return true
    }

    /// §3.3's optional `blockedReason`, appended after the transition rather
    /// than as part of it (D-036).
    ///
    /// Writes nothing and returns `false` when the task is not currently
    /// blocked, or when `text` is empty after trimming. `TextEntrySheet` is
    /// what actually keeps Esc free of empty events — Esc calls `dismiss()`
    /// without ever calling `onCommit`, and the confirm button disables itself
    /// on empty input — so this guard is belt-and-braces behind that, not the
    /// mechanism itself.
    @discardableResult
    public func addBlockedReason(_ text: String, to task: TaskItem) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.status == .blocked, !trimmed.isEmpty else { return false }

        context.insert(
            Event(taskID: task.id, timestamp: now(), kind: .blockedReason, body: trimmed))
        try commit()
        return true
    }

    /// Save, roll back on failure, and tell the other surfaces.
    private func commit() throws {
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed. Synchronous
        // delivery on this actor is what lets tests assert a count rather than
        // wait for one.
        NotificationCenter.default.post(name: .stenoDidWrite, object: nil)
    }
}
