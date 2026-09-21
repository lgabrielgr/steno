import Foundation
import Security
import Testing

@testable import StenoKit

/// D-139: the parts of `KeychainCredentialStore` with branches in them, tested
/// without `SecItem*` ever running.
///
/// The round trip itself belongs to `make verify-keychain`, which runs the
/// signed binary against the real Keychain. What is here is what a pure test
/// can actually settle: the attributes sent, and the status codes mapped.

@Test("the lookup identifies one provider's item")
func theLookupIdentifiesOneItem() {
    let query = KeychainQuery.lookup(providerID: "anthropic")

    #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService as String] as? String == "com.lgabrielgr.steno.ai")
    #expect(query[kSecAttrAccount as String] as? String == "anthropic")
}

@Test("the item is never synchronizable")
func theItemIsNeverSynchronizable() {
    // Set rather than defaulted: iCloud Keychain would put the API key on the
    // user's other machines, and sync is cancelled (D1, §14). Leaving it to the
    // platform default would make that a platform decision rather than ours.
    #expect(
        KeychainQuery.lookup(providerID: "anthropic")[kSecAttrSynchronizable as String]
            as? Bool == false)
}

@Test("kSecAttrAccessible is absent, and that absence is the assertion")
func accessibilityIsNotPassed() {
    // §6 (v1.20) omits the attribute rather than passing it: the login keychain
    // accepts `kSecAttrAccessibleAfterFirstUnlock` and returns `errSecSuccess`
    // while doing nothing with it — probed — so a call carrying it would look
    // like it enforced a rule it does not. This test is what stops someone
    // "fixing" that by adding it back.
    let queries = [
        KeychainQuery.lookup(providerID: "anthropic"),
        KeychainQuery.insert(Data("x".utf8), providerID: "anthropic"),
        KeychainQuery.update(Data("x".utf8)),
    ]

    #expect(queries.allSatisfy { $0[kSecAttrAccessible as String] == nil })
}

@Test("insert is the lookup plus the value, so add and update address one item")
func insertIsTheLookupPlusTheValue() {
    let data = Data("payload".utf8)

    let insert = KeychainQuery.insert(data, providerID: "anthropic")

    #expect(insert[kSecValueData as String] as? Data == data)
    // Every identity attribute of the lookup is present and equal: if these
    // diverged, `SecItemAdd` would create an item `SecItemUpdate` then failed
    // to find, and the duplicate fallback would loop on a key that never saved.
    for (key, value) in KeychainQuery.lookup(providerID: "anthropic") {
        // `insert[key]` is `Any?` where `value` is `Any`, so the optional is
        // unwrapped before describing — comparing the two descriptions directly
        // compares "Optional(x)" against "x" and fails for every key, which is
        // how this test first reported a defect that was its own.
        let present = insert[key].map { String(describing: $0) }
        #expect(present == String(describing: value), "\(key)")
    }
}

@Test("update carries the value and nothing else")
func updateCarriesOnlyTheValue() {
    // An update that also restated the identity attributes would let a caller
    // move an item between providers by accident.
    let update = KeychainQuery.update(Data("payload".utf8))

    #expect(update.count == 1)
    #expect(update[kSecValueData as String] as? Data == Data("payload".utf8))
}

@Test("each mapped status becomes its own case")
func statusesMapToCases() {
    #expect(KeychainError.from(errSecDuplicateItem) == .duplicateItem)
    #expect(KeychainError.from(errSecInteractionNotAllowed) == .interactionNotAllowed)
    #expect(KeychainError.from(errSecUserCanceled) == .userCancelled)
}

@Test("an unmapped status keeps its code")
func anUnmappedStatusKeepsItsCode() {
    // -34018 is `errSecMissingEntitlement`, which is what the data-protection
    // keychain returns for an unsigned binary — the probe result behind D-134.
    // Collapsing unmapped statuses to a single case would have made that
    // diagnosis impossible to read off a failure.
    #expect(KeychainError.from(-34018) == .unexpected(-34018))
    #expect(KeychainError.from(errSecItemNotFound) == .unexpected(errSecItemNotFound))
}
