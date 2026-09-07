import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

private struct SaveFailure: Error {}

/// A binding that records nothing. Present only so `SettingsModel` is built in
/// the shape the app builds it — with a store *and* a hotkey — rather than in
/// the degraded shape `hotkey: nil` produces.
@MainActor
private final class InertHotkeyBinding: HotkeyBinding {
    var chord: HotkeyChord = .default
    var registrationProblem: String?
    func rebind(to chord: HotkeyChord) { self.chord = chord }
}

@MainActor
private struct Pair {
    let window: MainWindowModel
    let settings: SettingsModel
    let appSettings: AppSettings
    let context: ModelContext
}

/// Both models over one context, as `StenoApp` builds them: `SettingsModel`
/// gets `container.mainContext` and `MainWindowView` builds its model over the
/// same one.
@MainActor
private func makePair() throws -> Pair {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let window = MainWindowModel(context: context, now: { origin })
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let appSettings = AppSettings(defaults: defaults)
    let settings = SettingsModel(
        settings: appSettings, loginItem: FakeLoginItem(),
        hotkey: InertHotkeyBinding(), context: context)
    return Pair(window: window, settings: settings, appSettings: appSettings, context: context)
}

/// The bug this file exists for: project writes went through
/// `MainWindowModel.perform`, which did not post `.stenoDidWrite`, so the
/// Settings picker kept offering — and kept resolving to — a project the user
/// had archived.
///
/// **No `NotificationCenter.post` here, deliberately.** The two tests in
/// `SettingsModelTests` that cover the same ground post it by hand, which
/// proves the observer works and cannot detect that nothing calls it. This one
/// archives through the real path.
@MainActor
@Test("archiving a project in the main window clears it from the Settings picker")
func archivingReachesTheSettingsPicker() throws {
    let pair = try makePair()
    pair.window.createProject(named: "Payments")
    let payments = try #require(pair.window.projects.first)
    pair.settings.setDefaultProject(payments.id)
    #expect(pair.settings.resolvedDefaultProjectID == payments.id)

    pair.window.archive(projectID: payments.id)

    #expect(pair.settings.projects.isEmpty)
    #expect(pair.settings.resolvedDefaultProjectID == nil)
    // §3.1 archives rather than deletes, so the stored choice is kept: an
    // unarchived project gets its setting back.
    #expect(pair.appSettings.defaultProjectID == payments.id)
}

@MainActor
@Test("a project created in the main window appears in the Settings picker")
func creatingReachesTheSettingsPicker() throws {
    let pair = try makePair()

    pair.window.createProject(named: "Hiring")

    #expect(pair.settings.projects.map(\.name) == ["Hiring"])
}

@MainActor
@Test("renaming a project in the main window reaches the Settings picker")
func renamingReachesTheSettingsPicker() throws {
    let pair = try makePair()
    pair.window.createProject(named: "Payments")
    let payments = try #require(pair.window.projects.first)

    pair.window.updateProject(id: payments.id, name: "Payments Platform", jiraKeys: "PAY")

    #expect(pair.settings.projects.map(\.name) == ["Payments Platform"])
}

@MainActor
@Test("a successful project write posts .stenoDidWrite exactly once")
func aProjectWritePostsOnce() throws {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let model = MainWindowModel(context: context, now: { origin })
    let counter = WriteCounter()

    model.createProject(named: "Payments")

    #expect(counter.posts == 1)
}

/// The write-side twin of D-018's rollback rule: a save that failed changed
/// nothing, so telling every other surface to refetch would be announcing a
/// write that did not happen.
@MainActor
@Test("a failed project write posts nothing")
func aFailedProjectWritePostsNothing() throws {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    let model = MainWindowModel(
        context: context, now: { origin }, save: { _ in throw SaveFailure() })
    let counter = WriteCounter()

    model.createProject(named: "Payments")

    #expect(counter.posts == 0)
    #expect(model.lastError != nil)
}
