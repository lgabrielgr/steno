/// What an `Event` records (REQUIREMENTS.md §3.3).
public enum EventKind: String, Codable, CaseIterable, Sendable {
    /// Task was created.
    case created
    /// User added progress.
    case note
    /// Status transition.
    case statusChanged
    /// Optional note on why a task is blocked.
    case blockedReason
    /// An integration fetch found a change.
    case externalUpdate
    /// A report was generated and copied.
    case standupReported
}

extension EventKind {
    /// Whether the user typed this event's body themselves.
    ///
    /// The one place FR-2's correction and redaction scope is decided: the
    /// service, the timeline, and the tests all read this rather than each
    /// spelling out a pair of cases.
    ///
    /// Exhaustive, with no `default`, so a kind added later is a compile error
    /// here rather than a silent `false`.
    public var isUserAuthored: Bool {
        switch self {
        case .note, .blockedReason:
            true
        case .created, .statusChanged, .externalUpdate, .standupReported:
            false
        }
    }
}
