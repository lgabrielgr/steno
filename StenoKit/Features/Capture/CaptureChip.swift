import Foundation

/// FR-1.4's dismissible inline chip, as facts rather than as a view.
///
/// Carries the project's name and colour so the rendering surface needs no
/// store access of its own (D-019), and so all three surfaces show the same
/// thing without each deciding what to display.
public struct CaptureChip: Equatable, Sendable {
    /// The ticket key that caused the routing, e.g. `"PAY-421"`.
    public let key: String
    public let projectID: UUID
    public let projectName: String
    public let colorHex: String

    public init(key: String, projectID: UUID, projectName: String, colorHex: String) {
        self.key = key
        self.projectID = projectID
        self.projectName = projectName
        self.colorHex = colorHex
    }
}
