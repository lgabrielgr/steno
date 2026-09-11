import Foundation
import Testing

@testable import StenoKit

/// §10.3: no credential reaches the export file.
///
/// §8 keeps secrets in Keychain and the encoder serializes SwiftData, so the
/// guarantee is structural — which is exactly why the scan alone proves
/// nothing. It passes on an empty store. It passes if the scanner matches
/// nothing, ever. **The positive control is the test**; the negative direction
/// is the claim it licenses.

@Test(
    "the scanner recognises every pattern it claims to",
    arguments: CredentialPatterns.all)
func theScannerFlagsAKnownCredential(pattern: CredentialPattern) {
    // Shaped like the real thing: a credential smuggled into a note body,
    // inside a plausible export. If this test stops failing to find something,
    // the negative test below is no longer evidence of anything.
    let leaked = """
        {
          "events" : [
            { "body" : "token is \(pattern.marker)0123456789abcdef", "kind" : "note" }
          ]
        }
        """

    // The **name** is asserted, not merely that something matched. `isEmpty`
    // would pass for a scanner that ignored every marker and matched only the
    // shared hexadecimal suffix — all eight cases green, and the pattern this
    // case exists for never exercised. Exactly one marker appears in `leaked`,
    // so exactly one name may come back.
    #expect(CredentialPatterns.matches(in: leaked) == [pattern.name])
}

@Test("the scanner's inventory is populated and covers the markers §10.3 names")
func theScannerInventoryIsPopulated() {
    // A parameterized test over an empty collection runs **zero** cases and
    // reports success, so emptying `CredentialPatterns.all` would silently turn
    // the positive control above into nothing at all — and the negative scan
    // below it into a test that cannot fail. This assertion is the one that
    // cannot disappear with the data it describes.
    #expect(CredentialPatterns.all.count == 8)
    #expect(
        Set(CredentialPatterns.all.map(\.marker)) == [
            "sk-ant-", "sk-proj-", "ATATT", "ghp_", "xoxb-", "xoxp-", "AKIA", "Bearer ",
        ])
}

@Test("ordinary stand-up prose is not mistaken for a credential")
func ordinaryProseIsNotFlagged() {
    let innocent = """
        {
          "events" : [
            { "body" : "repro'd the race in the retry handler", "kind" : "note" },
            { "body" : "IN-PROGRESS → BLOCKED", "kind" : "statusChanged" }
          ]
        }
        """

    #expect(CredentialPatterns.matches(in: innocent).isEmpty)
}

@MainActor
@Test("§10.3: a real export of a real store contains no credential pattern")
func theExportContainsNoCredentials() throws {
    let fixture = try ExportFixture()
    try fixture.realistic()

    let text = try ExportJSON.text(of: try fixture.encoder(includingCachedData: true).encode())

    // The store here was built through CaptureService, StatusService,
    // NoteService and the Copy path, not assembled by hand, so this asserts
    // over what the app actually writes.
    #expect(CredentialPatterns.matches(in: text).isEmpty)
}

@MainActor
@Test("§10.3: the export carries no UserDefaults-backed setting — O-9")
func settingsAreNotExported() throws {
    let suiteName = "steno.export.o9.tests"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    // `removeSuite(named:)` only drops a suite from `UserDefaults.standard`'s
    // search list, and this one was never added to it — so it would leave the
    // sentinels on disk under a fixed suite name, for every later run and every
    // other test to find. The persistent domain is what actually clears.
    defer { suite.removePersistentDomain(forName: suiteName) }
    let settings = AppSettings(defaults: suite)

    // **Sentinels, not arbitrary values.** Asserting only that the two literal
    // key names are absent proves very little: an export that serialized the
    // same settings under different keys, or in another representation, would
    // pass. These two values are distinctive enough that their presence
    // anywhere in the file is unambiguous.
    let sentinelProjectID = try #require(
        UUID(uuidString: "DEADBEEF-0000-4000-8000-00000000FEED"))
    settings.defaultProjectID = sentinelProjectID

    // The chord needs a sentinel of its own, and it has to be a *value* rather
    // than an encoding. Comparing against `JSONEncoder().encode(chord)` — which
    // is what this did first — can never match: that encoder is compact and the
    // export is `.prettyPrinted`, so the literal string is absent whether or not
    // the chord was serialized, and the assertion could not fail.
    //
    // A `HotkeyChord` is two integers with no distinctive string form, so the
    // sentinel is the integers. **Matched as whole tokens, not as substrings**:
    // every decimal digit is also a hex digit, so a bare `contains("54321")`
    // could match inside a random UUID the fixture emitted and fail a correct
    // export. A UUID's groups are 8-4-4-4-12 characters, none of which can be a
    // dash-delimited `54321`, so a word-boundary match cannot collide with one
    // while still matching a real leak like `"keyCode" : 54321`.
    let sentinelChord = HotkeyChord(keyCode: 54_321, modifiers: 987_654_321)
    settings.hotkeyChord = sentinelChord

    let fixture = try ExportFixture()
    try fixture.realistic()
    let data = try fixture.encoder().encode()
    let text = try ExportJSON.text(of: data)

    // O-9, decided no: a defaultProjectID can name a project the target machine
    // does not have, and a chord free on one Mac may collide on another. §10's
    // export carries domain data only.
    #expect(!text.contains(sentinelProjectID.uuidString))
    #expect(text.range(of: "\\b54321\\b", options: .regularExpression) == nil)
    #expect(text.range(of: "\\b987654321\\b", options: .regularExpression) == nil)
    #expect(!text.contains("hotkeyChord"))
    #expect(!text.contains("defaultProjectID"))
    #expect(!text.contains(AppSettings.hotkeyChordKey))
    #expect(!text.contains(AppSettings.defaultProjectIDKey))

    // The structural half, which is what forecloses "exported under some other
    // name": the envelope has exactly nine keys, so a settings array has
    // nowhere to appear. Mutation-tested by adding a tenth.
    #expect(try ExportJSON.topLevelKeys(in: data).count == 9)

    // **What this test cannot prove, stated rather than implied.** The
    // sentinels are written to a scratch suite, because §9.4 forbids a headless
    // test from writing the developer's real preferences — so an encoder that
    // read `UserDefaults.standard` directly would never see them and would pass
    // here. What actually forecloses that is the type: `ExportEncoder.init`
    // takes no `AppSettings` and the file imports no `UserDefaults`, which the
    // compiler enforces and no test can. This asserts the observable half.
}
