import Foundation

@testable import StenoKit

/// The store every automated test uses (D-134).
///
/// `make test` never touches the real Keychain: not because it cannot — the
/// login keychain works ad-hoc signed, which was probed — but because a suite
/// that wrote into the developer's login keychain would leave items behind on
/// every run, and §9.4 already holds the same line for `UserDefaults`. The real
/// store's round trip belongs to `make verify-keychain`.
///
/// `@unchecked Sendable` with a lock, rather than an actor: `CredentialStore`'s
/// methods are synchronous, so an actor could not conform.
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Credential] = [:]
    private var failure: (any Error)?

    init(failing failure: (any Error)? = nil) {
        self.failure = failure
    }

    func store(_ credential: Credential, for providerID: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            items[providerID] = credential
        }
    }

    func credential(for providerID: String) throws -> Credential? {
        try lock.withLock {
            if let failure { throw failure }
            return items[providerID]
        }
    }

    func delete(for providerID: String) throws {
        try lock.withLock {
            if let failure { throw failure }
            items.removeValue(forKey: providerID)
        }
    }

    /// What is actually held, for a test that wants to look rather than ask.
    var contents: [String: Credential] {
        lock.withLock { items }
    }
}
