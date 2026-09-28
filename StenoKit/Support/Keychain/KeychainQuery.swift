import Foundation
import Security

/// The Keychain query dictionaries, built as pure functions so they can be
/// asserted.
///
/// **Neutral ground, not the AI layer** (D-189). This started life inside
/// `KeychainCredentialStore.swift`, which is `AI/`; §13 forbids the source layer
/// depending on the AI layer, so M4-02's Atlassian credential could not have
/// reached it there. Both credential stores now build their queries here and
/// neither layer knows about the other.
///
/// Split out originally because this is where the branches are, and because a
/// test can check the exact attributes without `SecItem*` ever running — which is
/// what keeps `make test` out of the developer's keychain.
enum KeychainQuery {
    /// Identifies exactly one item: one credential per `(service, account)`, so a
    /// second provider — or a second integration — is a second item rather than a
    /// migration.
    ///
    /// **`service` is a parameter rather than a constant** (D-189). It was
    /// `com.lgabrielgr.steno.ai` for every caller when the AI provider was the
    /// only caller; the Atlassian credential is not an AI credential, and putting
    /// it under that service name would make one namespace mean two things.
    ///
    /// **`kSecAttrAccessible` is absent on purpose, not by omission.** The login
    /// keychain accepts it and returns `errSecSuccess` while doing nothing with it
    /// — probed. Passing it would leave a line that looks like it enforces §6's
    /// accessibility rule and does not, which is precisely the defect shape this
    /// repo keeps rediscovering.
    ///
    /// `kSecAttrSynchronizable` is **set** rather than defaulted: iCloud Keychain
    /// would put the secret on the user's other machines, and sync is cancelled
    /// (D1, §14).
    static func lookup(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func insert(_ data: Data, service: String, account: String) -> [String: Any] {
        var query = lookup(service: service, account: account)
        query[kSecValueData as String] = data
        return query
    }

    /// The attributes to change. Deliberately only the value: an update that also
    /// restated the identity attributes would let a caller move an item between
    /// accounts by accident.
    static func update(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }
}
