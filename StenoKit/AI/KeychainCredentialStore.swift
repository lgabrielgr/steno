import Foundation
import Security

/// §8's "Keychain only", against the login keychain.
///
/// **Not the data-protection keychain, and this was measured rather than
/// assumed.** §6 names `kSecAttrAccessibleAfterFirstUnlock`, which on macOS only
/// means anything to the data-protection keychain — which requires
/// `keychain-access-groups`, a *restricted* entitlement. Probing it five ways
/// established that an ad-hoc or plainly dev-signed binary gets
/// `errSecMissingEntitlement`; that a bare `codesign` with the entitlement is
/// killed outright by amfid for having no eligible provisioning profile; and
/// that the real app target works only with `-allowProvisioningUpdates`, a live
/// Apple ID session, and a profile that expires every seven days on a free
/// Personal Team. Worse, CI's own signing shape then fails to build at all
/// ("Steno requires a provisioning profile"), taking the required
/// `build-test-lint` check with it.
///
/// REQUIREMENTS.md §6 is amended to v1.20 to say so. §6's actual requirement is
/// unchanged and met: the key is in the Keychain, and never in SwiftData,
/// `UserDefaults`, a plist, or a log.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    /// Add, then update if an item is already there.
    ///
    /// **Not delete-then-add.** If the add half of that pair failed, the user
    /// would be left with no stored key and an AI provider that silently stopped
    /// working, having asked only to change it.
    public func store(_ credential: Credential, for providerID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemAdd(
            KeychainQuery.insert(data, providerID: providerID) as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updated = SecItemUpdate(
                KeychainQuery.lookup(providerID: providerID) as CFDictionary,
                KeychainQuery.update(data) as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError.from(updated) }
        default:
            throw KeychainError.from(status)
        }
    }

    public func credential(for providerID: String) throws -> Credential? {
        var query = KeychainQuery.lookup(providerID: providerID)
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpected(status) }
            return try JSONDecoder().decode(Credential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.from(status)
        }
    }

    /// Deleting what is not there is success, not failure — the caller asked for
    /// an end state, and that end state holds.
    public func delete(for providerID: String) throws {
        let status = SecItemDelete(KeychainQuery.lookup(providerID: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }
}

/// The query dictionaries, built as pure functions so they can be asserted.
///
/// Split out because this is where the branches are, and because a test can
/// check the exact attributes without `SecItem*` ever running — which is what
/// keeps `make test` out of the developer's keychain.
enum KeychainQuery {
    static let service = "com.lgabrielgr.steno.ai"

    /// Identifies exactly one item: one credential per provider, so a second
    /// provider is a second item rather than a migration.
    ///
    /// **`kSecAttrAccessible` is absent on purpose, not by omission.** The
    /// login keychain accepts it and returns `errSecSuccess` while doing nothing
    /// with it — probed. Passing it would leave a line that looks like it
    /// enforces §6's accessibility rule and does not, which is precisely the
    /// defect shape this repo keeps rediscovering.
    ///
    /// `kSecAttrSynchronizable` is **set** rather than defaulted: iCloud
    /// Keychain would put the API key on the user's other machines, and sync is
    /// cancelled (D1, §14).
    static func lookup(providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func insert(_ data: Data, providerID: String) -> [String: Any] {
        var query = lookup(providerID: providerID)
        query[kSecValueData as String] = data
        return query
    }

    /// The attributes to change. Deliberately only the value: an update that
    /// also restated the identity attributes would let a caller move an item
    /// between providers by accident.
    static func update(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }
}

/// A Keychain failure, as something a caller can switch on.
///
/// Kept out of `AIError` on purpose: credential storage is its own layer, and
/// the AI layer's view of it is exactly two outcomes — a credential, or none.
public enum KeychainError: Error, Equatable, Sendable {
    case duplicateItem
    case interactionNotAllowed
    case userCancelled
    case unexpected(OSStatus)

    static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecDuplicateItem: return .duplicateItem
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecUserCanceled: return .userCancelled
        default: return .unexpected(status)
        }
    }
}
