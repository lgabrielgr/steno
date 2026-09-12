import Foundation
import SwiftData

/// A single line of work (REQUIREMENTS.md §3.2).
///
/// Named `TaskItem`, not `Task`, because `Task` shadows `_Concurrency.Task` in
/// every file that can see it, and this app runs async integration fetches from
/// M4 onward (§3.2). Only the Swift identifier changed: prose, UI copy, the
/// export key `"tasks"`, and the `taskID` field name all still say "task".
///
/// `status` here is a **cache**, not the truth. The truth is the newest
/// `statusChanged` event — which is why M2.5-02's merge derives status from the
/// log rather than copying this field.
@Model
public final class TaskItem {
    public private(set) var id: UUID = UUID()
    public private(set) var title: String = ""
    public private(set) var projectID: UUID = UUID()
    public private(set) var status: Status = Status.todo
    public private(set) var createdAt: Date = Date.now
    public private(set) var statusChangedAt: Date = Date.now
    public private(set) var completedAt: Date?

    /// The task's external references (§3.2, D-016).
    ///
    /// `SourceRef.taskID` is the authoritative link — export, import, and
    /// M2.5-02's merge read it, not this array. Appending here rewires
    /// `ref.task` through the inverse but leaves `ref.taskID` alone, so keep
    /// the two in step; see the coherence test in `PersistedInvariantsTests`.
    @Relationship(inverse: \SourceRef.task)
    public var sourceRefs: [SourceRef]? = []

    public private(set) var isArchived: Bool = false

    /// Last mutation of a field whose import conflict rule is
    /// "later `modifiedAt` wins" (§10.1).
    ///
    /// Deliberately **not** stamped by `setStatus` — see that method.
    public private(set) var modifiedAt: Date = Date.now

    public init(id: UUID = UUID(), title: String, projectID: UUID, createdAt: Date) {
        self.id = id
        self.title = title
        self.projectID = projectID
        self.createdAt = createdAt
        self.statusChangedAt = createdAt
        self.modifiedAt = createdAt
    }

    func rename(to newTitle: String, at date: Date) {
        title = newTitle
        modifiedAt = date
    }

    func move(toProject newProjectID: UUID, at date: Date) {
        projectID = newProjectID
        modifiedAt = date
    }

    func setArchived(_ archived: Bool, at date: Date) {
        isArchived = archived
        modifiedAt = date
    }

    /// Move the task to `new`, maintaining `statusChangedAt` and `completedAt`
    /// (§3.2). Any status may move to any other; there is no workflow.
    ///
    /// **Setting the status a task already has is a complete no-op.** §3.2 does
    /// not cover that case; it is decided here. Re-stamping would let a
    /// redundant call reset a completed task's completion time, and would hand
    /// M1-05 a `statusChanged` event describing a transition that never
    /// happened — which then flows into a stand-up report as work that did not
    /// occur.
    ///
    /// **This does not append the `statusChanged` event**, which needs a
    /// `ModelContext`. `StatusService` is the only sanctioned caller and
    /// appends it there. As of M1-05 this method is `internal`, so the app
    /// target cannot reach it at all — the rule is enforced by the compiler
    /// rather than by this comment (D-033).
    ///
    /// Does not stamp `modifiedAt`: status is derived from the event log at
    /// merge time, so it has no claim on the timestamp that arbitrates `title`.
    func setStatus(_ new: Status, at date: Date) {
        guard new != status else { return }
        status = new
        statusChangedAt = date
        completedAt = (new == .done) ? date : nil
    }
}

extension TaskItem {
    /// Overwrite every field from an imported record — see
    /// `Project.applyImported` for why this bypasses the stamping mutators.
    ///
    /// `setStatus` is bypassed for a second reason of its own: it guards
    /// `new != status` and derives `completedAt` from the transition it is
    /// making. The merge has already derived all three fields together from the
    /// newest `statusChanged` event in the log (§10.1), and routing them back
    /// through the guard would drop a resolution that only *looks* like a no-op —
    /// same status, different `statusChangedAt`.
    ///
    /// **`createdAt` is deliberately not written here**, and the reasoning that
    /// said it should be was wrong. It argued that the merge refuses a file
    /// whose two sides disagree on it, so writing it is a no-op — but the merge
    /// compares the *wire-normalized* local snapshot, while the row itself holds
    /// full precision. Writing the record's value back therefore quantized a
    /// live task's creation time whenever some unrelated field (a title, an
    /// archive flag) made the row writable. An inserted task gets `createdAt`
    /// from `init`; an existing one keeps the instant it was actually created.
    func applyImported(_ record: ExportedTask) {
        title = record.title
        projectID = record.projectID
        status = record.status
        // Preserved when the wire instant already agrees: `applyEvents` skips an
        // unchanged `statusChanged` event, so rewriting this cache would leave it
        // quantized and no longer equal to the event it is derived from — an
        // invariant `PersistedInvariantsTests` asserts.
        statusChangedAt = ExportDocument.canonical(
            record.statusChangedAt, keeping: statusChangedAt)
        completedAt = ExportDocument.canonical(record.completedAt, keeping: completedAt)
        isArchived = record.isArchived
        modifiedAt = record.modifiedAt
    }
}
