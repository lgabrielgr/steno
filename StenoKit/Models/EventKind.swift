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
