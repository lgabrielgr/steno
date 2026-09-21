import Foundation

/// Where an AI provider's credential lives (§8: "Keychain only").
///
/// **A protocol, so that `make test` never writes into the developer's login
/// keychain.** §9.4 already requires tests to use a scratch `UserDefaults`
/// suite rather than real preferences; the same hygiene applies here, and every
/// test that needs *a* store rather than *the* store uses
/// `InMemoryCredentialStore`. The real store's own round trip is covered by
/// `make verify-keychain`, which runs the signed binary.
///
/// Absence is `nil`, not an error: a user who has not set a key yet is the
/// ordinary first-launch state, and it is what becomes `AIError.notConfigured`
/// one layer up.
public protocol CredentialStore: Sendable {
    func store(_ credential: Credential, for providerID: String) throws
    func credential(for providerID: String) throws -> Credential?
    func delete(for providerID: String) throws
}
