import Foundation
import Testing

@testable import StenoKit

@MainActor
private func windowModel(
    _ fixture: AutoExportFixture, panels: StubFilePanels = StubFilePanels()
) -> AutoExportWindowModel {
    AutoExportWindowModel(
        settings: fixture.settings, panels: panels, service: fixture.service())
}

@Test("the first-run sheet is owed until it has been shown")
@MainActor
func onboardingIsOwedOnce() throws {
    let fixture = try autoExportFixture()
    let model = windowModel(fixture)

    #expect(model.needsOnboarding)

    model.finishOnboarding()

    #expect(model.needsOnboarding == false)
    #expect(fixture.settings.hasSeenAutoExportOnboarding)
}

/// D-126: finishing takes the first backup in the foreground, with the user
/// present, so §10.5's promise is true from minute one rather than at the first
/// quit.
@Test("finishing onboarding writes the first backup")
@MainActor
func finishingOnboardingWritesABackup() throws {
    let fixture = try autoExportFixture()
    let model = windowModel(fixture)

    model.finishOnboarding()

    #expect(
        fixture.recorder.written
            == [fixture.folder.appendingPathComponent(ExportFilename.forDate(fixture.stamp))])
    #expect(fixture.settings.autoExportStatus.lastSuccess != nil)
}

@Test("a failure recorded by another process shows on the next launch")
@MainActor
func aPersistedFailureIsShownAtLaunch() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))

    let model = windowModel(fixture)

    #expect(model.problem == "the folder went missing")
}

/// D-123: dismissing the banner is a gesture about this window, not a claim
/// that the backup is fine. Settings and the menu bar keep saying so.
@Test("dismissing the banner hides it without clearing the stored failure")
@MainActor
func dismissingHidesWithoutClearing() throws {
    let fixture = try autoExportFixture()
    fixture.settings.autoExportStatus = AutoExportStatus(
        lastFailure: .init(failedAt: fixture.stamp, message: "the folder went missing"))
    let model = windowModel(fixture)

    model.dismissProblem()

    #expect(model.problem == nil)
    #expect(fixture.settings.autoExportStatus.problem == "the folder went missing")
}

@Test("a later failure is shown even when an identical one was dismissed")
@MainActor
func aLaterFailureIsShownAgain() throws {
    let fixture = try autoExportFixture()
    fixture.recorder.writeFailure = AutoExportFailure(detail: "gone")
    let model = windowModel(fixture)
    fixture.service().run(trigger: .quit)
    model.refresh()
    let first = try #require(model.problem)
    model.dismissProblem()

    // A success in between, then the same failure again.
    fixture.recorder.writeFailure = nil
    fixture.service().run(trigger: .quit)
    model.refresh()
    #expect(model.problem == nil)

    fixture.recorder.writeFailure = AutoExportFailure(detail: "gone")
    fixture.service().run(trigger: .quit)
    model.refresh()

    #expect(model.problem == first)
}

@Test("the banner updates when an export fails in the background")
@MainActor
func theBannerUpdatesOnNotification() throws {
    let fixture = try autoExportFixture()
    let model = windowModel(fixture)
    fixture.recorder.writeFailure = AutoExportFailure(detail: "no space left on device")

    fixture.service().run(trigger: .quit)

    #expect(model.problem?.contains("Nothing on this Mac was changed") == true)
}

@Test("choosing a folder stores it")
@MainActor
func choosingAFolderStoresIt() throws {
    let fixture = try autoExportFixture()
    let chosen = autoExportScratchDirectory()
    let panels = StubFilePanels(exportFolder: chosen)
    let model = windowModel(fixture, panels: panels)

    model.chooseFolder()

    #expect(model.folder.path == chosen.path)
    #expect(fixture.settings.autoExportFolder.path == chosen.path)
    #expect(panels.lastFolderStart?.path == fixture.folder.path)
}

@Test("cancelling the folder panel changes nothing")
@MainActor
func cancellingChangesNothing() throws {
    let fixture = try autoExportFixture()
    let model = windowModel(fixture, panels: StubFilePanels(exportFolder: nil))

    model.chooseFolder()

    #expect(model.folder.path == fixture.folder.path)
    #expect(fixture.settings.autoExportFolder.path == fixture.folder.path)
}

/// Carried finding, final review of M2.5-05: a refusal from an earlier
/// attempt must not outlive a later cancel that touched no folder.
@Test("cancelling the folder panel clears a previously-set refusal")
@MainActor
func cancellingClearsAPriorRefusal() throws {
    let fixture = try autoExportFixture()
    // In-memory containers report `/dev/null` as their configuration's URL
    // (`StenoStore.inMemory()`), so `/dev/anything` reads as inside the
    // store's own directory to `StoreFileGuard.isInsideStoreDirectory` and
    // `service.problem(withFolder:)` refuses it.
    let refused = URL(fileURLWithPath: "/dev/inside-the-store", isDirectory: true)
    let panels = StubFilePanels(exportFolder: refused)
    let model = windowModel(fixture, panels: panels)

    model.chooseFolder()
    #expect(model.folderProblem != nil)

    panels.exportFolder = nil
    model.chooseFolder()

    #expect(model.folderProblem == nil)
}
