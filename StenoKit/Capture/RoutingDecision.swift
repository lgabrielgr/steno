import Foundation

/// A ticket key found in capture text, and the project its prefix named.
public struct KeyMatch: Equatable, Sendable {
    public let key: String
    public let projectID: UUID

    public init(key: String, projectID: UUID) {
        self.key = key
        self.projectID = projectID
    }
}

/// Where a capture is going, and which of FR-1.4's rungs decided it.
///
/// `source` is not decoration: the chip is shown for `.ticketKey` and for
/// nothing else, so the rung has to survive the call that computed it.
public struct RoutingDecision: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// FR-1.4 rung 1, carrying the key that decided it.
        case ticketKey(String)
        /// Rung 2 — the capturing surface's own context.
        case preferred
        /// Rung 3 — FR-1.4's specified default.
        case lastUsed
        /// Rung 4 — FR-6's configurable default. Unreachable until M1-08.
        case configuredDefault
        /// Rung 5 — the last resort.
        case firstProject
        /// Nowhere to route. See the design doc §4.2.
        case none
    }

    public let projectID: UUID?
    public let source: Source

    public init(projectID: UUID?, source: Source) {
        self.projectID = projectID
        self.source = source
    }
}
