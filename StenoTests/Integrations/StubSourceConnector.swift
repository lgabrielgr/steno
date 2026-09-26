import Foundation

@testable import StenoKit

/// A scripted `SourceConnector` (§9.4: every external call sits behind a
/// protocol with a test double).
///
/// Nothing fake ships — this lives in the test bundle, the way `StubAIProvider`
/// does. It is the only conformance to `SourceConnector` that exists until
/// M4-02, which is what lets the whole source layer be exercised with networking
/// denied.
///
/// `final class` rather than a struct because the recorder mutates: the tests
/// need to assert *what was asked for*, in particular the `since` each fetch was
/// handed, which is the only externally visible evidence that refresh policy
/// lives in the service rather than in the connector.
final class StubSourceConnector: SourceConnector, @unchecked Sendable {
    /// What one identifier's fetch does.
    enum Script: Sendable {
        case success(SourceUpdate)
        case failure(SourceError)
        /// Suspends until cancelled, for the per-fetch deadline and the pass
        /// budget. `Task.sleep` rather than a lock: it is cancellable, so the
        /// deadline resolves rather than the thread blocking — which is what
        /// `Deadline.swift` records as the difference between a late answer and a
        /// leaked request.
        case hang
    }

    let id: String
    let displayName: String
    let isConfigured: Bool

    /// Which kinds this connector claims. `nil` claims every kind.
    private let kinds: Set<SourceRefKind>?

    /// Per-identifier scripts. An identifier with no entry uses `fallback`.
    private let scripts: [String: Script]
    private let fallback: Script

    /// **Locked, because the service fetches four refs at once.** The first
    /// version appended to a plain array from every concurrent fetch, and a record
    /// was lost — which showed up as a test asserting that a ref had never been
    /// fetched when it had. An unsynchronized recorder does not merely race: it
    /// makes the double lie about what the code under test did.
    private let lock = NSLock()
    private var recorded: [(identifier: String, since: Date?)] = []
    private var connectionCalls = 0

    /// Every `(identifier, since)` this connector was asked for.
    ///
    /// **Order is not meaningful** — fetches run concurrently — so assertions look
    /// entries up rather than comparing whole sequences, unless exactly one fetch
    /// was expected.
    var asked: [(identifier: String, since: Date?)] { lock.withLock { recorded } }

    var testConnectionCalls: Int { lock.withLock { connectionCalls } }

    init(
        id: String = "stub",
        displayName: String = "Stub",
        isConfigured: Bool = true,
        kinds: Set<SourceRefKind>? = nil,
        scripts: [String: Script] = [:],
        fallback: Script = .success(
            SourceUpdate(summary: "stub state", changes: [], url: nil, fetchedAt: .distantPast))
    ) {
        self.id = id
        self.displayName = displayName
        self.isConfigured = isConfigured
        self.kinds = kinds
        self.scripts = scripts
        self.fallback = fallback
    }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        kinds.map { $0.contains(ref.kind) } ?? true
    }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        lock.withLock { recorded.append((ref.identifier, since)) }
        switch scripts[ref.identifier] ?? fallback {
        case .success(let update):
            return update
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(60))
            throw SourceError.timedOut
        }
    }

    func testConnection() async throws {
        lock.withLock { connectionCalls += 1 }
        guard isConfigured else { throw SourceError.notConfigured }
    }
}

/// The acceptance criterion's "connector that always throws" (§5.5).
///
/// Its own type rather than a `StubSourceConnector` with a failing fallback: the
/// criterion is a statement about the whole layer, and a test that reads
/// `AlwaysFailingConnector()` says what it is verifying without the reader
/// decoding a script.
struct AlwaysFailingConnector: SourceConnector {
    let id = "always-failing"
    let displayName = "Always Failing"
    let isConfigured = true
    let error: SourceError

    /// Which kinds it claims. **Not defaulted to "everything" by accident:** a
    /// greedy double registered first shadows every other connector, which is how
    /// the "one failure does not stop the others" test first passed for the wrong
    /// reason — both refs went to this connector and the working one was never
    /// asked.
    private let kinds: Set<SourceRefKind>?

    init(error: SourceError = .network, kinds: Set<SourceRefKind>? = nil) {
        self.error = error
        self.kinds = kinds
    }

    func canHandle(_ ref: SourceRefSnapshot) -> Bool {
        kinds.map { $0.contains(ref.kind) } ?? true
    }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        throw error
    }

    func testConnection() async throws { throw error }
}

/// A connector that breaks the protocol's error contract, for the guard that
/// catches it.
struct ContractBreakingConnector: SourceConnector {
    let id = "contract-breaking"
    let displayName = "Contract Breaking"
    let isConfigured = true

    /// Not a `SourceError` — the whole point.
    struct Leaked: Error {}

    func canHandle(_ ref: SourceRefSnapshot) -> Bool { true }

    func fetch(_ ref: SourceRefSnapshot, since: Date?) async throws -> SourceUpdate {
        throw Leaked()
    }

    func testConnection() async throws { throw Leaked() }
}

extension SourceUpdate {
    /// A fetch result with `changes`, for the common case.
    static func stub(
        summary: String = "In Review",
        changes: [String] = [],
        url: URL? = nil,
        fetchedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SourceUpdate {
        SourceUpdate(summary: summary, changes: changes, url: url, fetchedAt: fetchedAt)
    }
}
