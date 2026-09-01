import Foundation

/// One row of the menu bar popover's in-progress list.
///
/// A value rather than the `TaskItem` itself, so what the popover shows —
/// title, project, colour and status together — is asserted in the headless
/// bundle instead of being re-derived inside a view that D-010 puts beyond it.
public struct MenuBarRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let status: Status
    public let projectName: String
    public let colorHex: String
}
