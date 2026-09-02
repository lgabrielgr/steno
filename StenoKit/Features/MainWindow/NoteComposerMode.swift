import Foundation

/// What the detail pane's composer is currently doing.
///
/// One value rather than a `Bool` plus an optional id, for `ActiveSheet`'s
/// reason: "correcting, but no event" and "adding, but an event" are both
/// unrepresentable here.
public enum NoteComposerMode: Equatable, Sendable {
    /// A new note. `⌘↩` appends.
    case adding
    /// FR-2's grace-period correction of an existing event.
    case correcting(eventID: UUID)
}
