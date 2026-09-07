import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// The seam `SettingsModel` codes against, as four lines — which is the
/// argument for `HotkeyBinding` existing at all.
@MainActor
private final class FakeHotkeyBinding: HotkeyBinding {
    var chord: HotkeyChord = .default
    var registrationProblem: String?
    private(set) var rebindCount = 0

    func rebind(to chord: HotkeyChord) {
        self.chord = chord
        rebindCount += 1
    }
}

@MainActor
private struct Fixture {
    let model: SettingsModel
    let hotkey: FakeHotkeyBinding
    let login: FakeLoginItem
    let settings: AppSettings
    let context: ModelContext
    let payments: Project
    let hiring: Project
}

@MainActor
private func makeFixture() throws -> Fixture {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    let hotkey = FakeHotkeyBinding()
    let login = FakeLoginItem()
    let model = SettingsModel(
        settings: settings, loginItem: login, hotkey: hotkey, context: context)
    return Fixture(
        model: model, hotkey: hotkey, login: login, settings: settings, context: context,
        payments: payments, hiring: hiring)
}

// MARK: - Hotkey

@Test("recording a valid chord rebinds")
@MainActor
func recordingAValidChordRebinds() throws {
    let fixture = try makeFixture()

    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.control.rawValue)

    #expect(fixture.hotkey.rebindCount == 1)
    #expect(fixture.model.chord.displayString == "⌃K")
    #expect(fixture.model.recorderRejection == nil)
}

/// A refused chord must leave the working binding alone. Reporting the problem
/// *and* unbinding would take the user's shortcut away for a mistake.
@Test("recording a bare key changes nothing and explains why")
@MainActor
func recordingABareKeyChangesNothing() throws {
    let fixture = try makeFixture()

    fixture.model.record(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)

    #expect(fixture.hotkey.rebindCount == 0)
    #expect(fixture.model.chord == .default)
    #expect(fixture.model.recorderRejection == HotkeyChordValidator.Rejection.noModifiers.message)
}

@Test("a later valid recording clears the rejection")
@MainActor
func aValidRecordingClearsTheRejection() throws {
    let fixture = try makeFixture()
    fixture.model.record(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)
    #expect(fixture.model.recorderRejection != nil)

    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.command.rawValue)

    #expect(fixture.model.recorderRejection == nil)
}

@Test("reset restores the FR-1.1 default")
@MainActor
func resetRestoresTheDefault() throws {
    let fixture = try makeFixture()
    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.command.rawValue)

    fixture.model.resetHotkeyToDefault()

    #expect(fixture.model.chord == .default)
}

/// One copy of the problem, read through the binding rather than mirrored —
/// so a conflict raised by a rebind cannot go stale here.
@Test("the binding's registration problem is what the pane shows")
@MainActor
func theRegistrationProblemComesFromTheBinding() throws {
    let fixture = try makeFixture()
    #expect(fixture.model.hotkeyProblem == nil)

    fixture.hotkey.registrationProblem = "That shortcut is already registered."

    #expect(fixture.model.hotkeyProblem == "That shortcut is already registered.")
}

// MARK: - Launch at login

@Test("enabling launch at login registers")
@MainActor
func enablingLaunchAtLoginRegisters() throws {
    let fixture = try makeFixture()

    fixture.model.setLaunchAtLogin(true)

    #expect(fixture.model.launchesAtLogin)
    #expect(fixture.model.loginProblem == nil)
}

/// D-041's untested case, and the reason `LoginItem` stopped being a `Bool`:
/// the call returns without throwing and the app still will not launch.
@Test("a registration awaiting approval is reported rather than shown as on")
@MainActor
func approvalPendingIsReported() throws {
    let fixture = try makeFixture()
    fixture.login.statusAfterEnabling = .requiresApproval

    fixture.model.setLaunchAtLogin(true)

    #expect(!fixture.model.launchesAtLogin)
    let problem = try #require(fixture.model.loginProblem)
    #expect(problem.contains("System Settings"))
}

/// The likely failure on a development machine: a debug build run out of
/// `.build/` is a relocated bundle and `SMAppService` refuses it (D-041).
/// Reporting the thrown error verbatim is what tells a manual check "this
/// build cannot register" apart from "this feature is broken".
@Test("a thrown registration failure is reported and the toggle stays off")
@MainActor
func aThrownRegistrationFailureIsReported() throws {
    struct Denied: LocalizedError {
        var errorDescription: String? { "the bundle has moved" }
    }
    let fixture = try makeFixture()
    fixture.login.failure = Denied()

    fixture.model.setLaunchAtLogin(true)

    #expect(!fixture.model.launchesAtLogin)
    let problem = try #require(fixture.model.loginProblem)
    #expect(problem.contains("the bundle has moved"))
}

@Test("a successful disable clears an earlier problem")
@MainActor
func aSuccessfulDisableClearsTheProblem() throws {
    let fixture = try makeFixture()
    fixture.login.statusAfterEnabling = .requiresApproval
    fixture.model.setLaunchAtLogin(true)
    #expect(fixture.model.loginProblem != nil)

    fixture.login.statusAfterEnabling = .enabled
    fixture.model.setLaunchAtLogin(false)

    #expect(fixture.model.loginProblem == nil)
    #expect(!fixture.model.launchesAtLogin)
}

// MARK: - Default project

@Test("the picker lists live projects and persists a choice")
@MainActor
func theDefaultProjectPersists() throws {
    let fixture = try makeFixture()
    #expect(fixture.model.projects.count == 2)

    fixture.model.setDefaultProject(fixture.hiring.id)

    #expect(fixture.model.resolvedDefaultProjectID == fixture.hiring.id)
    #expect(fixture.settings.defaultProjectID == fixture.hiring.id)
}

/// Archiving the chosen project must not silently discard the setting:
/// unarchiving it restores the choice. The picker shows "None" meanwhile,
/// which is what `resolvedDefaultProjectID` is for.
///
/// **This posts `.stenoDidWrite` by hand, so it proves the observer and
/// nothing about who calls it.** That gap shipped: nothing posted it for
/// project writes, and the picker kept resolving to an archived project
/// (D-060). `ProjectWriteNotificationTests` archives through the real path
/// and is the test that would have caught it — keep both.
@Test("a default whose project is archived resolves to none without being erased")
@MainActor
func anArchivedDefaultResolvesToNone() throws {
    let fixture = try makeFixture()
    fixture.model.setDefaultProject(fixture.hiring.id)

    fixture.hiring.setArchived(true, at: epoch)
    try fixture.context.save()
    NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

    #expect(fixture.model.resolvedDefaultProjectID == nil)
    #expect(fixture.model.defaultProjectID == fixture.hiring.id)
    #expect(fixture.settings.defaultProjectID == fixture.hiring.id)
}

/// A project created in the main window while Settings is open reaches the
/// picker through `.stenoDidWrite`, without either type knowing the other.
/// Hand-posted, with the caveat above: the end-to-end version is
/// `creatingReachesTheSettingsPicker`.
@Test("a project created elsewhere appears in the picker")
@MainActor
func aProjectCreatedElsewhereAppears() throws {
    let fixture = try makeFixture()

    fixture.context.insert(
        Project(
            name: "Platform", colorHex: "#10B981", jiraProjectKeys: ["PLAT"],
            sortOrder: 2, modifiedAt: epoch))
    try fixture.context.save()
    NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

    #expect(fixture.model.projects.count == 3)
}

// MARK: - Degradation

/// §13: a feature's degradation ships with it. With no store there is no panel
/// to bind a chord to and no project list — but launch at login has no store
/// dependency and must keep working.
@Test("with no store the pane degrades but launch at login still works")
@MainActor
func withNoStoreLaunchAtLoginStillWorks() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let login = FakeLoginItem()
    let model = SettingsModel(
        settings: AppSettings(defaults: defaults), loginItem: login, hotkey: nil, context: nil)

    #expect(model.storeFailureNote != nil)
    #expect(model.projects.isEmpty)
    #expect(model.chord == .default)

    model.setLaunchAtLogin(true)

    #expect(model.launchesAtLogin)
    #expect(model.loginProblem == nil)
}
