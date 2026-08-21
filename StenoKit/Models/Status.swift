/// Task status — the fixed four (REQUIREMENTS.md §3.2, D11).
///
/// There is deliberately no `custom` case and no associated value: §2.1 rules
/// out custom statuses and workflow engines, and an enum that cannot express
/// one is a cheaper guarantee than a rule someone has to remember.
public enum Status: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress
    case blocked
    case done
}
