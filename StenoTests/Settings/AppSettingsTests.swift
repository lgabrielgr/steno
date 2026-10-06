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

// MARK: - §7.1's selected model (PR #37 review)

@Test("the selected model round-trips and clears")
@MainActor
func theSelectedModelRoundTrips() throws {
    let (settings, defaults) = try scratch()

    #expect(settings.aiSelectedModelID == nil)

    settings.aiSelectedModelID = "claude-test-1"
    #expect(settings.aiSelectedModelID == "claude-test-1")
    #expect(defaults.string(forKey: AppSettings.aiSelectedModelIDKey) == "claude-test-1")

    settings.aiSelectedModelID = nil
    #expect(settings.aiSelectedModelID == nil)
    // Removed rather than blanked: a key left behind with an empty value is a
    // setting `defaults read` shows as present and the app treats as absent.
    #expect(defaults.object(forKey: AppSettings.aiSelectedModelIDKey) == nil)
}

@Test("an empty model id reads as no selection")
@MainActor
func anEmptyModelIDIsNoSelection() throws {
    let (settings, defaults) = try scratch()

    // `UserDefaults` will happily store one, and a model id of "" reaches the
    // API as a 400 the user cannot explain.
    defaults.set("", forKey: AppSettings.aiSelectedModelIDKey)
    #expect(settings.aiSelectedModelID == nil)

    settings.aiSelectedModelID = ""
    #expect(defaults.object(forKey: AppSettings.aiSelectedModelIDKey) == nil)
}

// MARK: - FR-6's per-integration toggle (D-215)

@Test("an unset store has every integration enabled")
@MainActor
func anUnsetStoreEnablesEveryIntegration() throws {
    let (settings, _) = try scratch()

    // Absence is the permissive answer, which is the whole reason the key holds
    // the *disabled* set. Mutation: store the enabled set instead. Red.
    #expect(settings.disabledIntegrationIDs.isEmpty)
    #expect(settings.isIntegrationEnabled("jira"))
    #expect(settings.isIntegrationEnabled("confluence"))
    // An id nothing has ever registered is enabled too — M5-02 adds ids this
    // build has never heard of.
    #expect(settings.isIntegrationEnabled("mcp-github"))
}

@Test("disabling one integration leaves the others alone")
@MainActor
func disablingOneLeavesTheOthersAlone() throws {
    let (settings, _) = try scratch()

    settings.setIntegration("confluence", enabled: false)

    #expect(!settings.isIntegrationEnabled("confluence"))
    #expect(settings.isIntegrationEnabled("jira"))
}

@Test("re-enabling removes the key rather than storing an empty array")
@MainActor
func reEnablingRemovesTheKey() throws {
    let (settings, defaults) = try scratch()

    settings.setIntegration("jira", enabled: false)
    #expect(defaults.object(forKey: AppSettings.integrationsDisabledKey) != nil)

    settings.setIntegration("jira", enabled: true)

    // One representation of "nothing is switched off", not two.
    #expect(defaults.object(forKey: AppSettings.integrationsDisabledKey) == nil)
    #expect(settings.isIntegrationEnabled("jira"))
}

@Test("the stored value is sorted, so a rewrite that changes nothing is stable")
@MainActor
func theStoredValueIsSorted() throws {
    let (settings, defaults) = try scratch()

    settings.disabledIntegrationIDs = ["jira", "confluence", "mcp-github"]

    // A `Set`'s iteration order is its hash order and differs between
    // processes. Mutation: drop `.sorted()` in the setter — this goes red
    // across runs rather than reliably, which is why the expectation is on the
    // array and not on a round trip.
    #expect(
        defaults.stringArray(forKey: AppSettings.integrationsDisabledKey)
            == ["confluence", "jira", "mcp-github"])
}

@Test("a stored value of the wrong type reads as nothing disabled")
@MainActor
func aWrongTypedValueReadsAsEmpty() throws {
    let (settings, defaults) = try scratch()

    // What a hand-written `defaults write` can produce. It must not trap, and
    // it must not silently disable everything.
    defaults.set(42, forKey: AppSettings.integrationsDisabledKey)

    #expect(settings.disabledIntegrationIDs.isEmpty)
    #expect(settings.isIntegrationEnabled("jira"))
}

@Test("disabling is idempotent")
@MainActor
func disablingIsIdempotent() throws {
    let (settings, defaults) = try scratch()

    settings.setIntegration("jira", enabled: false)
    settings.setIntegration("jira", enabled: false)

    #expect(defaults.stringArray(forKey: AppSettings.integrationsDisabledKey) == ["jira"])
}

// MARK: - §5.5's scheduled refresh (M4-05)

/// **Absence means enabled**, which `UserDefaults.bool(forKey:)` cannot say. §5.5
/// states the schedule as policy rather than as an option, and the inverse spelling
/// would make a fresh install's schedule inert in the one direction nobody notices: a
/// pass that never fires looks exactly like one with nothing to fetch.
@Test("a fresh install has the schedule on, at 08:00, never run")
@MainActor
func aFreshInstallIsScheduledAtEight() throws {
    let (settings, _) = try scratch()

    #expect(settings.scheduledRefreshEnabled)
    #expect(settings.scheduledRefreshTime == .eightAM)
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("the schedule's three settings round-trip")
@MainActor
func theScheduleRoundTrips() throws {
    let (settings, _) = try scratch()
    let dispatchedAt = Date(timeIntervalSince1970: 1_792_000_000)
    let quarterPastSix = try #require(TimeOfDay(hour: 6, minute: 15))

    settings.scheduledRefreshEnabled = false
    settings.scheduledRefreshTime = quarterPastSix
    settings.scheduledRefreshLastRun = dispatchedAt

    #expect(settings.scheduledRefreshEnabled == false)
    #expect(settings.scheduledRefreshTime == quarterPastSix)
    #expect(settings.scheduledRefreshLastRun == dispatchedAt)
}

/// Midnight is a legitimate setting, which is why the getter reads `object(forKey:)`
/// rather than `integer(forKey:)` — the latter answers `0` for an absent key, so
/// midnight and "unset" would be the same value and the 08:00 default would be
/// unreachable for anyone who ever chose 00:00.
@Test("midnight is a real setting, not an absent one")
@MainActor
func midnightIsARealSetting() throws {
    let (settings, _) = try scratch()
    let midnight = try #require(TimeOfDay(minutesSinceMidnight: 0))

    settings.scheduledRefreshTime = midnight

    #expect(settings.scheduledRefreshTime == midnight)
}

@Test("an out-of-range stored time reads as the default")
@MainActor
func anOutOfRangeTimeReadsAsTheDefault() throws {
    let (settings, defaults) = try scratch()

    // What a hand-written `defaults write` can produce. It must not trap, and it must
    // not schedule a refresh at a time the user never chose.
    defaults.set(99 * 60, forKey: AppSettings.scheduledRefreshTimeKey)

    #expect(settings.scheduledRefreshTime == .eightAM)
}

@Test("a stored time of the wrong type reads as the default")
@MainActor
func aWrongTypedTimeReadsAsTheDefault() throws {
    let (settings, defaults) = try scratch()

    defaults.set("eight o'clock", forKey: AppSettings.scheduledRefreshTimeKey)

    #expect(settings.scheduledRefreshTime == .eightAM)
}

@Test("clearing the last run removes it")
@MainActor
func clearingTheLastRunRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.scheduledRefreshLastRun = Date()

    settings.scheduledRefreshLastRun = nil

    #expect(settings.scheduledRefreshLastRun == nil)
    #expect(defaults.object(forKey: AppSettings.scheduledRefreshLastRunKey) == nil)
}

@Test("the unattended credential rejection round-trips")
@MainActor
func theRejectionRoundTrips() throws {
    let (settings, _) = try scratch()
    let rejection = CredentialRejection(
        displayName: "Jira", at: Date(timeIntervalSince1970: 1_792_000_000))

    settings.scheduledRefreshRejection = rejection

    #expect(settings.scheduledRefreshRejection == rejection)
}

@Test("an unreadable stored rejection reads as none")
@MainActor
func anUnreadableRejectionReadsAsNone() throws {
    let (settings, defaults) = try scratch()

    defaults.set("not json", forKey: AppSettings.scheduledRefreshRejectionKey)

    #expect(settings.scheduledRefreshRejection == nil)
}

@Test("clearing the rejection removes it")
@MainActor
func clearingTheRejectionRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.scheduledRefreshRejection = CredentialRejection(displayName: "Jira", at: Date())

    settings.scheduledRefreshRejection = nil

    #expect(settings.scheduledRefreshRejection == nil)
    #expect(defaults.object(forKey: AppSettings.scheduledRefreshRejectionKey) == nil)
}
