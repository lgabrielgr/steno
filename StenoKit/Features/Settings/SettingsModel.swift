import Foundation
import SwiftData

/// What the Settings window's Capture pane binds to.
///
/// **Everything the pane decides lives here, in `StenoKit`.** ARCHITECTURE §2
/// rule 2 puts view models between views and the store on testability grounds,
/// and `@AppStorage` in the pane would have put FR-6's state in `Steno/`, where
/// the headless bundle cannot reach it — a mistake each of the four later panes
/// would then have inherited.
///
/// **Built once in `StenoApp.init` and held for the process,** the posture
/// `QuickCaptureController` and `MenuBarController` already establish. The
/// `Settings` scene's content is rebuilt freely by SwiftUI; the state behind it
/// is not.
///
/// Every dependency is injected and nothing is constructed internally, so the
/// whole type is exercisable with fakes and a scratch defaults suite (§9.4).
@Observable
@MainActor
public final class SettingsModel {
    // MARK: Hotkey

    /// The chord currently bound, and any conflict or registration failure —
    /// both read straight from the binding rather than mirrored, so there is
    /// one copy of each.
    public var chord: HotkeyChord { hotkey?.chord ?? .default }
    public var hotkeyProblem: String? { hotkey?.registrationProblem }

    /// Why the last recorded chord was refused, if it was. Cleared by the next
    /// successful recording.
    public private(set) var recorderRejection: String?

    // MARK: Launch at login

    public private(set) var loginStatus: LoginItemStatus
    public private(set) var loginProblem: String?

    /// What the toggle shows. Derived from the status macOS reports, never
    /// from the fact that a call returned — see `LoginItemStatus`.
    public var launchesAtLogin: Bool { loginStatus == .enabled }

    // MARK: Default project

    /// Live, non-archived projects, for the picker.
    public private(set) var projects: [Project] = []

    /// The stored default. `nil` when unset.
    public private(set) var defaultProjectID: UUID?

    /// What the picker should show selected.
    ///
    /// A stored default whose project has been archived or deleted resolves to
    /// `nil` here, so the picker reads "None" rather than showing an empty row
    /// — **but the stored value is left alone**, so unarchiving the project
    /// restores the setting. That is the posture M1-03 took with an
    /// undecodable chord, and it is why `AppSettings` does no validation.
    public var resolvedDefaultProjectID: UUID? {
        guard let defaultProjectID,
            projects.contains(where: { $0.id == defaultProjectID })
        else { return nil }
        return defaultProjectID
    }

    // MARK: Availability

    /// Set when the store could not be opened, in which case there is no
    /// capture panel to bind a chord to and no project list to choose from.
    ///
    /// Launch at login is unaffected and stays live — it has no store
    /// dependency, and §13 requires a feature's degradation to ship with it
    /// rather than after it.
    public var storeFailureNote: String? {
        hotkey == nil
            ? "Steno could not open its data store, so the shortcut and the default project are unavailable."
            : nil
    }

    private let settings: AppSettings
    private let loginItem: any LoginItem
    private let hotkey: (any HotkeyBinding)?
    private let context: ModelContext?
    private var writeObservation: WriteObservation?

    /// - Parameters:
    ///   - hotkey: `nil` when the store failed to open, because `StenoApp`
    ///     builds no `QuickCaptureController` in that case (D-018).
    ///   - context: `nil` for the same reason.
    public init(
        settings: AppSettings = AppSettings(),
        loginItem: any LoginItem = SystemLoginItem(),
        hotkey: (any HotkeyBinding)? = nil,
        context: ModelContext? = nil
    ) {
        self.settings = settings
        self.loginItem = loginItem
        self.hotkey = hotkey
        self.context = context
        self.loginStatus = loginItem.status
        self.defaultProjectID = settings.defaultProjectID
        reloadProjects()

        // Registered last: `self` may only be captured once every stored
        // property has a value. A project created — or archived — in the main
        // window while Settings is open reaches the picker through this,
        // without either type knowing the other exists: the same route M1-03
        // and M1-04 use.
        //
        // That holds only because `MainWindowModel.perform` posts the
        // notification for project writes. It did not until D-060, and this
        // observer silently covered nothing: see `WriteNotifications`.
        writeObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadProjects() }
            })
    }

    // MARK: - Hotkey

    /// Bind a chord the recorder produced.
    ///
    /// Validation happens here rather than in the recorder so the rules are
    /// testable without a window server. A rejected chord changes nothing —
    /// the old binding stays live while the message explains why.
    public func record(keyCode: UInt16, modifiers: UInt) {
        switch HotkeyChordValidator.validate(keyCode: keyCode, modifiers: modifiers) {
        case .success(let recorded):
            recorderRejection = nil
            hotkey?.rebind(to: recorded)
        case .failure(let rejection):
            recorderRejection = rejection.message
        }
    }

    /// Restore FR-1.1's `⌥Space`.
    public func resetHotkeyToDefault() {
        recorderRejection = nil
        hotkey?.rebind(to: .default)
    }

    // MARK: - Launch at login

    /// Register or unregister, then report what macOS actually says.
    ///
    /// **The status is re-read rather than assumed from the call returning.**
    /// `register()` can succeed into `.requiresApproval`, and a toggle that
    /// trusted the call would show "on" for an app that will not launch.
    public func setLaunchAtLogin(_ enabled: Bool) {
        loginProblem = nil
        do {
            if enabled {
                try loginItem.enable()
            } else {
                try loginItem.disable()
            }
        } catch {
            // Verbatim, not a generic message. On a development machine the
            // likely failure is a relocated bundle run out of `.build/`, and
            // saying so is what tells a manual check "this build cannot
            // register" apart from "this feature is broken" (D-041).
            loginProblem = "macOS refused: \(error.localizedDescription)"
        }

        loginStatus = loginItem.status
        if loginProblem == nil {
            loginProblem = note(for: loginStatus, afterEnabling: enabled)
        }
    }

    /// The sentence a status deserves once the call itself did not throw.
    private func note(for status: LoginItemStatus, afterEnabling enabled: Bool) -> String? {
        switch status {
        case .requiresApproval:
            return
                "Steno is registered, but macOS needs you to approve it in System Settings › General › Login Items."
        case .notFound:
            return "macOS could not find Steno to register. Move it to Applications and try again."
        case .notRegistered where enabled:
            return "macOS did not register Steno for launch at login."
        case .enabled, .notRegistered:
            return nil
        }
    }

    // MARK: - Default project

    public func setDefaultProject(_ projectID: UUID?) {
        defaultProjectID = projectID
        settings.defaultProjectID = projectID
    }

    /// Refetch the picker's options.
    ///
    /// A failure leaves the list empty and is logged rather than surfaced: an
    /// empty picker offering only "None" is a legible degradation, and
    /// Settings is not a place to report a store problem the main window is
    /// already reporting.
    private func reloadProjects() {
        guard let context else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        do {
            projects = try context.fetch(descriptor)
        } catch {
            projects = []
            Log.app.error(
                "could not load projects for Settings: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
