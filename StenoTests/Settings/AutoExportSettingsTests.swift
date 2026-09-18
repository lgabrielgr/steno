import Foundation
import Testing

@testable import StenoKit

@MainActor
private func scratchSettings() throws -> (AppSettings, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return (AppSettings(defaults: defaults), defaults)
}

/// §10.5's "auto-export should default to ON", asserted on a store that has
/// never been written.
///
/// **The whole point is the `?? true`.** `UserDefaults.bool(forKey:)` answers
/// `false` for an absent key, which would turn the opt-*out* into an opt-in on
/// every fresh install — silently, in the direction nobody notices, because a
/// backup that never runs looks exactly like one with nothing to do.
@Test("a fresh install has auto-export on, both triggers on, and a folder")
@MainActor
func aFreshInstallHasAutoExportOn() throws {
    let (settings, _) = try scratchSettings()

    #expect(settings.autoExportEnabled)
    #expect(settings.autoExportOnQuit)
    #expect(settings.autoExportDaily)
    #expect(settings.autoExportFolder == AppSettings.defaultAutoExportFolder)
    #expect(settings.autoExportStatus == AutoExportStatus())
    #expect(settings.hasSeenAutoExportOnboarding == false)
}

/// D-120: the default folder is deliberately outside every TCC-protected
/// location, so an unattended write — at quit, with nobody present — cannot
/// raise a permission prompt.
@Test("the default folder is ~/Steno Backups, not inside Documents")
@MainActor
func theDefaultFolderIsOutsideProtectedLocations() {
    let folder = AppSettings.defaultAutoExportFolder
    let home = FileManager.default.homeDirectoryForCurrentUser

    #expect(folder == home.appendingPathComponent("Steno Backups", isDirectory: true))
    for protected in ["Documents", "Desktop", "Downloads"] {
        #expect(!folder.path.hasPrefix(home.appendingPathComponent(protected).path))
    }
}

@Test("turning a trigger off is remembered, and does not read back as the default")
@MainActor
func anExplicitFalseSurvives() throws {
    let (settings, _) = try scratchSettings()

    settings.autoExportEnabled = false
    settings.autoExportOnQuit = false
    settings.autoExportDaily = false

    #expect(settings.autoExportEnabled == false)
    #expect(settings.autoExportOnQuit == false)
    #expect(settings.autoExportDaily == false)
}

@Test("the folder round-trips")
@MainActor
func theFolderRoundTrips() throws {
    let (settings, _) = try scratchSettings()
    let folder = URL(fileURLWithPath: "/Users/someone/Dropbox/Steno", isDirectory: true)

    settings.autoExportFolder = folder

    #expect(settings.autoExportFolder.path == folder.path)
}

@Test("the status round-trips, success and failure alike")
@MainActor
func theStatusRoundTrips() throws {
    let (settings, _) = try scratchSettings()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let status = AutoExportStatus(
        lastSuccess: .init(writtenAt: stamp, path: "/tmp/steno-export-2023-11-14.json"),
        lastFailure: .init(failedAt: stamp, message: "the folder went missing"))

    settings.autoExportStatus = status

    #expect(settings.autoExportStatus == status)
    #expect(settings.autoExportStatus.problem == "the folder went missing")
}

/// `UserDefaults` is user-editable — `defaults write` is a supported thing for
/// a person to do — so an unreadable value must read as absent rather than
/// crash, and the bytes must stay on disk.
@Test("an undecodable status reads as empty and is not overwritten")
@MainActor
func anUndecodableStatusReadsAsEmpty() throws {
    let (settings, defaults) = try scratchSettings()
    defaults.set(Data("not json".utf8), forKey: AppSettings.autoExportStatusKey)

    #expect(settings.autoExportStatus == AutoExportStatus())
    #expect(defaults.data(forKey: AppSettings.autoExportStatusKey) == Data("not json".utf8))
}
