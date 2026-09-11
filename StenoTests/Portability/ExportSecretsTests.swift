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
    // the chord was serialized, and the assertion could not fail. A `HotkeyChord`
    // is two integers with no distinctive string form, so the sentinel is the
    // integers themselves, chosen large enough not to collide with a real key
    // code, a `sortOrder`, or a run of hex inside a UUID.
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
    #expect(!text.contains("54321"))
    #expect(!text.contains("987654321"))
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
