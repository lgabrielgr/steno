import Foundation
import Testing

@testable import StenoKit

/// §7.2's credential enum, and the two things that keep `.oauth` from rotting.

@Test(
    "both cases survive a round trip through a store",
    arguments: [
        Credential.apiKey("fixture-key-value"),
        Credential.oauth(
            TokenSet(
                accessToken: "access", refreshToken: "refresh",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000))),
    ])
func bothCasesRoundTrip(credential: Credential) throws {
    // **This is why the store serializes the enum rather than a bare string.**
    // §7.2 requires `.oauth` to exist so a subscription flow can be added
    // without a refactor, and nothing constructs it in production — so without
    // this it would be a declaration nobody has ever executed, which on this
    // project is a bug filed against a later task.
    let store = InMemoryCredentialStore()

    try store.store(credential, for: "anthropic")

    #expect(try store.credential(for: "anthropic") == credential)
}

@Test("the stored format is spelled out, not left to the compiler")
func theStoredFormatIsStable() throws {
    // The Keychain item holds these bytes. Swift's synthesized enum encoding is
    // a compiler implementation detail, and a stored credential that stops
    // decoding because a toolchain changed its mind is a user who silently
    // loses their API key — so the shape is pinned here.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    let encoded = try encoder.encode(Credential.apiKey("abc"))

    let json = try #require(String(bytes: encoded, encoding: .utf8))
    #expect(json == #"{"apiKey":"abc","kind":"apiKey"}"#)
}

@Test("a credential written by this version decodes in the next one")
func theStoredFormatDecodes() throws {
    // The other direction of the same guarantee: bytes as written above must
    // come back. A test that only round-trips through the current encoder
    // passes even if both halves change together.
    let stored = Data(#"{"apiKey":"abc","kind":"apiKey"}"#.utf8)

    #expect(try JSONDecoder().decode(Credential.self, from: stored) == .apiKey("abc"))
}

@Test("§7.2: Settings may offer the API key and nothing else")
func onlyTheAPIKeyIsSelectable() {
    // The rule §7.2 states as prose — "surface API key as the only enabled
    // option in Settings v1" — asserted a milestone before M3-04's picker
    // exists. M3-04 renders `userSelectable`; a picker built from `allCases`
    // would offer a sign-in flow that cannot work.
    #expect(CredentialKind.userSelectable == [.apiKey])
    #expect(CredentialKind.allCases == [.apiKey, .oauth])
}

@Test("absence is nil, not an error")
func anUnsetCredentialIsNil() throws {
    // The first-launch state, and what becomes `AIError.notConfigured` one
    // layer up. A store that threw here would make "no key yet" indistinguishable
    // from "the Keychain is broken".
    #expect(try InMemoryCredentialStore().credential(for: "anthropic") == nil)
}
