import AppKit
import Foundation
import Testing

@testable import StenoKit

@MainActor
private func scratch() throws -> (AppSettings, UserDefaults) {
    // `try #require`, never `!` — `force_unwrapping` is an enabled opt-in rule
    // and `--strict` promotes it to a build failure.
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return (AppSettings(defaults: defaults), defaults)
}

@Test("an unset store reports both settings as absent")
@MainActor
func anUnsetStoreReportsAbsent() throws {
    let (settings, _) = try scratch()

    #expect(settings.hotkeyChord == nil)
    #expect(settings.defaultProjectID == nil)
}

@Test("the hotkey chord round-trips")
@MainActor
func theChordRoundTrips() throws {
    let (settings, _) = try scratch()
    let chord = HotkeyChord(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue)

    settings.hotkeyChord = chord

    #expect(settings.hotkeyChord == chord)
}

@Test("the default project round-trips")
@MainActor
func theDefaultProjectRoundTrips() throws {
    let (settings, _) = try scratch()
    let projectID = UUID()

    settings.defaultProjectID = projectID

    #expect(settings.defaultProjectID == projectID)
}

@Test("clearing the default project removes it")
@MainActor
func clearingTheDefaultProjectRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.defaultProjectID = UUID()

    settings.defaultProjectID = nil

    #expect(settings.defaultProjectID == nil)
    #expect(defaults.string(forKey: AppSettings.defaultProjectIDKey) == nil)
}

/// The read must not trap on a value it did not write. `UserDefaults` is a
/// shared, user-editable store — `defaults write` is a supported thing for a
/// person to do — so a force-unwrapped `UUID(uuidString:)` here is a crash on
/// launch that no test of the happy path would ever find.
@Test("an unparseable default project reads as absent")
@MainActor
func anUnparseableDefaultProjectReadsAsAbsent() throws {
    let (settings, defaults) = try scratch()
    defaults.set("not-a-uuid", forKey: AppSettings.defaultProjectIDKey)

    #expect(settings.defaultProjectID == nil)
}

/// The posture M1-03 established for the chord and this type keeps: report a
/// bad value as absent, leave the bytes alone. The caller falls back to
/// `HotkeyChord.default` and the pane can still show what is really stored.
@Test("an undecodable chord reads as absent without being erased")
@MainActor
func anUndecodableChordIsNotErased() throws {
    let (settings, defaults) = try scratch()
    defaults.set(Data([0x01, 0x02]), forKey: AppSettings.hotkeyChordKey)

    #expect(settings.hotkeyChord == nil)
    #expect(defaults.data(forKey: AppSettings.hotkeyChordKey) == Data([0x01, 0x02]))
}
