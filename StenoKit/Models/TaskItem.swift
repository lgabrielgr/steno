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

    public func rename(to newTitle: String, at date: Date) {
        title = newTitle
        modifiedAt = date
    }

    public func move(toProject newProjectID: UUID, at date: Date) {
        projectID = newProjectID
        modifiedAt = date
    }

    public func setArchived(_ archived: Bool, at date: Date) {
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
    /// `ModelContext` that M0-04 owns. M1-05's status service is the sanctioned
    /// caller and appends it. A transition that skips its event is a real bug
    /// that surfaces much later as an inexplicable revert after an import
    /// (§10.1) — so call the service, not this, once M1-05 exists.
    ///
    /// Does not stamp `modifiedAt`: status is derived from the event log at
    /// merge time, so it has no claim on the timestamp that arbitrates `title`.
    public func setStatus(_ new: Status, at date: Date) {
        guard new != status else { return }
        status = new
        statusChangedAt = date
        completedAt = (new == .done) ? date : nil
    }
}
