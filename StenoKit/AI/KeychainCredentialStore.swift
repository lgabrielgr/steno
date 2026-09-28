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
    /// This store's Keychain service. The Atlassian credential uses its own
    /// (D-189): one namespace must not mean two things.
    static let service = "com.lgabrielgr.steno.ai"

    public init() {}

    /// Add, then update if an item is already there.
    ///
    /// **Not delete-then-add.** If the add half of that pair failed, the user
    /// would be left with no stored key and an AI provider that silently stopped
    /// working, having asked only to change it.
    public func store(_ credential: Credential, for providerID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let status = SecItemAdd(
            KeychainQuery.insert(data, service: Self.service, account: providerID) as CFDictionary,
            nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updated = SecItemUpdate(
                KeychainQuery.lookup(service: Self.service, account: providerID) as CFDictionary,
                KeychainQuery.update(data) as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError.from(updated) }
        default:
            throw KeychainError.from(status)
        }
    }

    public func credential(for providerID: String) throws -> Credential? {
        var query = KeychainQuery.lookup(service: Self.service, account: providerID)
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
        let status = SecItemDelete(
            KeychainQuery.lookup(service: Self.service, account: providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.from(status)
        }
    }
}
