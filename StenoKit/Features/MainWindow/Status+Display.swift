extension Status {
    /// FR-3's spelling, used for group headers and the detail pane.
    ///
    /// In `StenoKit` rather than in a view so the strings are assertable, and
    /// so M1-04's popover and M1-05's status control cannot invent a second
    /// spelling of the same four statuses.
    public var displayName: String {
        switch self {
        case .todo: "TODO"
        case .inProgress: "IN-PROGRESS"
        case .blocked: "BLOCKED"
        case .done: "DONE"
        }
    }
}
