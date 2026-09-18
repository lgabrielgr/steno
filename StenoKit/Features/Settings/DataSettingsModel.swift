import Foundation

/// What the Settings window's Data pane binds to (FR-6, §10.5).
///
/// Built once in `StenoApp.init` and held for the process, for
/// `SettingsModel`'s reason: the `Settings` scene's content is rebuilt freely
/// by SwiftUI, and the state behind it must not be.
@Observable
@MainActor
public final class DataSettingsModel {
    /// §10.5's opt-*out*. Writing through on `didSet` rather than computing
    /// over `AppSettings` keeps the toggle observable — a computed property
    /// reading `UserDefaults` publishes nothing, so the pane would not redraw.
    public var isEnabled: Bool {
        didSet { settings.autoExportEnabled = isEnabled }
    }

    public var exportsOnQuit: Bool {
        didSet { settings.autoExportOnQuit = exportsOnQuit }
    }

    public var exportsDaily: Bool {
        didSet { settings.autoExportDaily = exportsDaily }
    }

    public private(set) var folder: URL
    public private(set) var status: AutoExportStatus

    /// Why the folder the user just chose was refused, if it was.
    public private(set) var folderProblem: String?

    /// Set when the store could not be opened, in which case there is nothing
    /// to export. Mirrors `SettingsModel.storeFailureNote` — §13 requires a
    /// feature's degradation to ship with it, not after it.
    public var storeFailureNote: String? {
        service == nil
            ? "Steno could not open its data store, so automatic backups are unavailable."
            : nil
    }

    private let settings: AppSettings
    private let panels: any FilePanels
    private let service: AutoExportService?
    private var statusObservation: WriteObservation?

    /// - Parameter service: `nil` when the store failed to open, because
    ///   `StenoApp` builds no auto-export in that case (D-018's posture).
    public init(
        settings: AppSettings = AppSettings(),
        panels: any FilePanels = UnavailableFilePanels(),
        service: AutoExportService? = nil
    ) {
        self.settings = settings
        self.panels = panels
        self.service = service
        self.isEnabled = settings.autoExportEnabled
        self.exportsOnQuit = settings.autoExportOnQuit
        self.exportsDaily = settings.autoExportDaily
        self.folder = settings.autoExportFolder
        self.status = settings.autoExportStatus

        statusObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoAutoExportDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    /// Pick a new folder, and verify it immediately.
    ///
    /// The export that follows a successful choice is deliberate: a folder that
    /// cannot be written to should say so now, while the user is in the pane
    /// that chose it, rather than at the next quit.
    public func chooseFolder() {
        guard let chosen = panels.chooseExportFolder(startingAt: folder) else {
            // A cancel changes no folder, but it must not leave a refusal from
            // an *earlier* attempt sitting next to a folder that was never
            // touched.
            folderProblem = nil
            return
        }
        // `service == nil` only when the store failed to open (D-018); there
        // is then nothing to validate against, so the folder is stored
        // unvalidated. That is a stated decision, not `?.` silently treating
        // "no service" as "no refusal" — `run`'s own `problem(withFolder:)`
        // call re-guards before every write, so a bad folder let through here
        // is still caught there.
        if let service, let refusal = service.problem(withFolder: chosen) {
            folderProblem = refusal
            return
        }
        folderProblem = nil
        settings.autoExportFolder = chosen
        folder = chosen
        exportNow()
    }

    /// The pane's "Export now".
    public func exportNow() {
        service?.run(trigger: .manual)
        refresh()
    }

    private func refresh() {
        folder = settings.autoExportFolder
        status = settings.autoExportStatus
    }
}
