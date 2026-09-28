import Foundation

@testable import StenoKit

/// A connector that actually honours `since`, so the window can be tested.
///
/// **`StubSourceConnector` cannot show D-183's defect**, and that is the whole reason
/// this type exists: it answers with whatever it was scripted regardless of the
/// window, so a pass asking the *wrong* `since` still gets the same changes back and
/// every assertion passes. A test written against it would confirm that the plumbing
/// runs, not that the window is right.
///
/// This one holds timestamped items and returns the ones inside the window, the way
/// `JiraChangeSet` does — including D-188's rule that a `nil` since reports no changes
/// at all and only establishes the anchor.
final class WindowedConnector: SourceConnector, @unchecked Sendable {
    struct Item: Sendable {
        let id: String
        let text: String

        /// When the *source* says this happened — not when we fetched it.
        let stamp: Date
    }

    let id = "windowed"
    let displayName = "Windowed"
    let isConfigured: Bool
    let credentialWarning: SourceCredentialWarning?
    let credentialRenewalURL: URL?

    private let summary: String
    private let items: [Item]
    private let present: [SourceChange]
    private let kinds: Set<SourceRefKind>?

    /// Reports a capped window with this floor, for the two-pass resume regression.
    private let cappedFloor: Date?

    private let lock = NSLock()
    private var recorded: [Date?] = []

    /// Every `since` this connector was handed, in call order.
    var asked: [Date?] { lock.withLock { recorded } }

    init(
        summary: String = "In Review",
        items: [Item] = [],
        present: [SourceChange] = [],
        isConfigured: Bool = true,
        credentialWarning: SourceCredentialWarning? = nil,
        credentialRenewalURL: URL? = nil,
        kinds: Set<SourceRefKind>? = [.jiraIssue],
        cappedFloor: Date? = nil
    ) {
        self.summary = summary
        self.items = items
        self.present = present
        self.isConfigured = isConfigured
        self.credentialWarning = credentialWarning
        self.credentialRenewalURL = credentialRenewalURL
        self.kinds = kinds
        self.cappedFloor = cappedFloor
    }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        kinds.map { $0.contains(ref.kind) } ?? true
    }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        lock.withLock { recorded.append(since) }

        // `>=`, not `>`: `since` is the watermark less the overlap, and an item landing
        // exactly on that boundary is inside the window. A `nil` since returns
        // everything, because the service is what suppresses a first observation's body
        // (D-188) — a connector that filtered here too would leave those ids
        // unrecorded and the next pass would report them as news.
        let window = since ?? .distantPast
        let changes = items.filter { $0.stamp >= window }
            .map { SourceChange(id: $0.id, text: $0.text) }

        return SourceUpdate(
            summary: summary,
            changes: changes,
            url: nil,
            fetchedAt: RefreshFixture.origin,
            present: present,
            // Over every item, reported or not (D-184) — or the floor, when this connector is
            // standing in for a walk that stopped at its page cap.
            watermark: cappedFloor ?? items.map(\.stamp).max(),
            isWindowCapped: cappedFloor != nil)
    }

    func testConnection() async throws {
        guard isConfigured else { throw SourceError.notConfigured }
    }
}
