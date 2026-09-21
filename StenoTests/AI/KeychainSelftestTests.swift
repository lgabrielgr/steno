import Foundation
import Testing

@testable import StenoKit

/// The harness's *sequence*, tested against the double.
///
/// `make verify-keychain` runs this same logic against the real Keychain on a
/// signed build; what a unit test can settle is that the sequence is right and
/// that it reports honestly — a harness that printed PASS for a store which
/// silently dropped the write would be worse than no harness at all.

@Test("a working store passes, and leaves nothing behind")
func aWorkingStorePasses() {
    var lines: [String] = []
    let store = InMemoryCredentialStore()

    let code = KeychainSelftest.run(store: store, out: { lines.append($0) })

    #expect(code == 0)
    #expect(lines.last?.contains("PASS") == true)
    // The harness cleans up after itself: a developer running `make
    // verify-keychain` must not accumulate an item per run.
    #expect(store.contents.isEmpty)
}

@Test("a store that fails is reported, not announced as a pass")
func aFailingStoreFails() {
    var lines: [String] = []
    let store = InMemoryCredentialStore(failing: KeychainError.interactionNotAllowed)

    let code = KeychainSelftest.run(store: store, out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.last?.contains("FAIL") == true)
}

@Test("the harness never prints the credential it stored")
func theHarnessNeverPrintsTheCredential() {
    // It stores a value and reads it back, so the value passes through this
    // code — and a failure message that dumped it would write an API-key-shaped
    // string to a terminal and its scrollback. §8 governs this output as much
    // as it governs the log.
    var lines: [String] = []
    let store = ForgetfulCredentialStore()

    let code = KeychainSelftest.run(store: store, out: { lines.append($0) })

    #expect(code == 1)
    #expect(lines.joined().contains("selftest-") == false, "\(lines.joined())")
}

@Test("the second write is what proves an overwrite works")
func theSecondWriteIsAnOverwrite() {
    // The sequence exists to exercise D-135's `errSecDuplicateItem` ->
    // `SecItemUpdate` fallback, whose failure mode is a user who changes their
    // API key and silently keeps using the old one. A harness that stored once
    // would never reach it.
    let store = CountingCredentialStore()

    _ = KeychainSelftest.run(store: store, out: { _ in })

    #expect(store.writes == 2)
}

@Test("a failure partway through still leaves nothing behind")
func aFailedRunCleansUpAfterItself() {
    // The finding this covers (Copilot, PR #33): the explicit delete sits at the
    // end of the sequence, so a mismatch on the first read-back used to return
    // early and strand a credential-shaped item in the real Keychain — the one
    // place it must not accumulate, and at the moment someone is investigating.
    //
    // Mutation: drop the `defer` in `KeychainSelftest.run`. Red.
    let store = MisreadingCredentialStore()

    let code = KeychainSelftest.run(store: store, out: { _ in })

    #expect(code == 1)
    #expect(store.contents.isEmpty, "\(store.contents)")
}

/// Stores faithfully and reads back something else — a Keychain that fails the
/// harness *after* the first write has landed, which is the path that leaked.
private final class MisreadingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [String: Credential] = [:]

    func store(_ credential: Credential, for providerID: String) throws {
        lock.withLock { held[providerID] = credential }
    }

    func credential(for providerID: String) throws -> Credential? {
        lock.withLock { held[providerID] == nil ? nil : .apiKey("something-else") }
    }

    func delete(for providerID: String) throws {
        lock.withLock { held.removeValue(forKey: providerID) }
    }

    var contents: [String: Credential] {
        lock.withLock { held }
    }
}

/// Accepts writes and returns nothing — the shape of a Keychain that reports
/// success while dropping the item.
private final class ForgetfulCredentialStore: CredentialStore, @unchecked Sendable {
    func store(_ credential: Credential, for providerID: String) throws {}
    func credential(for providerID: String) throws -> Credential? { nil }
    func delete(for providerID: String) throws {}
}

private final class CountingCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Credential?
    private(set) var writes = 0

    func store(_ credential: Credential, for providerID: String) throws {
        lock.withLock {
            held = credential
            writes += 1
        }
    }

    func credential(for providerID: String) throws -> Credential? {
        lock.withLock { held }
    }

    func delete(for providerID: String) throws {
        lock.withLock { held = nil }
    }
}
