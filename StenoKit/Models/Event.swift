import Foundation
import SwiftData

/// An immutable record of something that happened to a task
/// (REQUIREMENTS.md §3.3, D10).
///
/// **This type is the append-only invariant expressed as API.** Every stored
/// property is `private(set)`, so the initialiser is the only place any field
/// but `isRedacted` is ever written, and `redact()` is the only mutator.
/// Swift enforces this: a `private(set)` setter is unreachable from any other
/// file, including elsewhere in StenoKit.
///
/// A feature that appears to need an event mutated actually needs a new event
/// or a redaction (§13). Do not add a setter here.
///
/// **This closes mutation, not deletion.** §3.3 forbids deleting an event as
/// firmly as editing one, and nothing in this file prevents it:
/// `ModelContext.delete(_:)` is available on any `PersistentModel`, and no
/// amount of `private(set)` reaches it. The guard has to live where deletes are
/// issued, so closing this seam belongs to whoever owns the context (M0-04).
/// Until it does, a delete is a real bug that silently destroys the log every
/// summary is derived from.
///
/// The link to the task is `taskID` alone — no relationship, deliberately, and
/// asymmetrically with `SourceRef`. §3.2's field table lists `sourceRefs` and
/// lists no `events`; see the M0-03 design doc §1.2 before "restoring
/// symmetry".
@Model
public final class Event {
    public private(set) var id: UUID = UUID()
    public private(set) var taskID: UUID = UUID()
    public private(set) var timestamp: Date = Date.now
    public private(set) var kind: EventKind = EventKind.note
    public private(set) var body: String = ""
    public private(set) var payload: Data?
    public private(set) var isRedacted: Bool = false

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        timestamp: Date,
        kind: EventKind,
        body: String,
        payload: Data? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
        self.payload = payload
    }

    /// Hide this event from summaries while retaining the row (§3.3).
    ///
    /// One-way by design: there is no `unredact()`. Nothing in the spec
    /// reverses a redaction — FR-4.1's undo redacts `standupReported` events
    /// and is not itself undoable, and note correction is specified as
    /// redact-and-reappend. A reversible setter can be added by the task that
    /// needs one; it could not easily be taken away.
    func redact() {
        isRedacted = true
    }
}
