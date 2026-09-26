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

    /// Whether this kind's body belongs in a report the user reads aloud.
    ///
    /// **`externalUpdate` is reportable but not user-authored, which is why this
    /// is a second property rather than a wider `isUserAuthored`** (D-180). The
    /// two predicates answer different questions and are read by different
    /// layers: FR-2's correction and redaction scope asks "did the user type
    /// this", and an integration's sentence must never become editable as though
    /// they had. Widening the first to serve the report would have made a Jira
    /// comment correctable.
    ///
    /// `created` and `statusChanged` stay out, per D-072: their bodies are
    /// `"Task created"` and `"In Progress → Done"`, machine-authored strings the
    /// user would otherwise read to their team, and a task's status is already
    /// expressed by which section it appears in. `standupReported` cannot reach a
    /// window at all (D-066).
    ///
    /// Read by `RawReportSections` for §7.4's fallback and by
    /// `StandupSummarizer.unreportedWork` for the coverage rule, so the two paths
    /// cannot disagree about what a report owes the user.
    ///
    /// Exhaustive for the reason above.
    public var isReportable: Bool {
        switch self {
        case .note, .blockedReason, .externalUpdate:
            true
        case .created, .statusChanged, .standupReported:
            false
        }
    }
}
