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
    let suite = try #require(UserDefaults(suiteName: "steno.export.o9.tests"))
    defer { UserDefaults.standard.removeSuite(named: "steno.export.o9.tests") }
    let settings = AppSettings(defaults: suite)
    settings.hotkeyChord = HotkeyChord.default
    settings.defaultProjectID = UUID()

    let fixture = try ExportFixture()
    try fixture.realistic()
    let text = try ExportJSON.text(of: try fixture.encoder().encode())

    // O-9, decided no: a defaultProjectID can name a project the target machine
    // does not have, and a chord free on one Mac may collide on another. §10's
    // export carries domain data only.
    #expect(!text.contains("hotkeyChord"))
    #expect(!text.contains("defaultProjectID"))
    #expect(!text.contains(AppSettings.hotkeyChordKey))
    #expect(!text.contains(AppSettings.defaultProjectIDKey))
}
