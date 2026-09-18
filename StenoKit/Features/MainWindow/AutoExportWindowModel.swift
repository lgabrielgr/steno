import Foundation

/// What the main window shows about auto-export: the failure banner, and the
/// first-run sheet (§10.5, D-123, D-126).
///
/// **Its own type rather than three more properties on `MainWindowModel`.**
/// That model is already at SwiftLint's file-length limit, and more to the
/// point the state here is owned by a different thing: it changes when an
/// export runs, not when the store is written, and it must be readable with no
/// window on screen at all.
///
/// It holds no reference back to `MainWindowModel`, which is what lets that
/// model hold it as a `let` — the posture `importPreview` already establishes.
@Observable
@MainActor
public final class AutoExportWindowModel {
    /// The failure to show, or `nil`. Dismissed messages are filtered out here
    /// rather than cleared from the stored status: §10.5 makes silent failure
    /// unacceptable, so dismissing a banner must not be able to convince the
    /// app that the backup is fine.
    public private(set) var problem: String?

    /// Where exports go, for the sheet to show.
    public private(set) var folder: URL

    /// Why the folder the user just chose was refused, if it was.
    public private(set) var folderProblem: String?

    /// Whether the first-run sheet is still owed.
    public var needsOnboarding: Bool { !settings.hasSeenAutoExportOnboarding }

    /// The message the user dismissed, kept for this process only. A *different*
    /// failure — or the same one recurring after a success cleared it — shows
    /// again.
    private var dismissed: String?

    private let settings: AppSettings
    private let panels: any FilePanels
    private let service: AutoExportService
    private var statusObservation: WriteObservation?

    public init(settings: AppSettings, panels: any FilePanels, service: AutoExportService) {
        self.settings = settings
        self.panels = panels
        self.service = service
        self.folder = settings.autoExportFolder
        self.problem = settings.autoExportStatus.problem

        // Registered last, for `MainWindowModel`'s reason: `self` may only be
        // captured once every stored property has a value. This is how a
        // failure at quit *or* from the hourly tick reaches an open window
        // without either side knowing the other exists.
        statusObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoAutoExportDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    /// Re-read the persisted status.
    public func refresh() {
        folder = settings.autoExportFolder
        let current = settings.autoExportStatus.problem
        // A success clears `dismissed` too, so the *next* failure — even with
        // the identical message — is shown rather than silently swallowed by a
        // dismissal the user made weeks ago.
        if current == nil { dismissed = nil }
        problem = current == dismissed ? nil : current
    }

    /// Hide the banner for this process. Does not touch the stored status, so
    /// Settings and the menu bar still say the backup failed.
    public func dismissProblem() {
        dismissed = problem
        problem = nil
    }

    /// The sheet's "Choose Folder…", and the Data pane's.
    ///
    /// **A folder inside Steno's own store is refused here, while the user is
    /// looking at it** (D-125), rather than at the next quit through a banner
    /// they cannot act on without finding this control again.
    public func chooseFolder() {
        guard let chosen = panels.chooseExportFolder(startingAt: folder) else { return }
        if let refusal = service.problem(withFolder: chosen) {
            folderProblem = refusal
            return
        }
        folderProblem = nil
        settings.autoExportFolder = chosen
        folder = chosen
    }

    /// The sheet's "Done": remember that it was shown, and take the first
    /// backup.
    ///
    /// **The export runs here, in the foreground, with the user present.** It
    /// makes §10.5's promise true from minute one rather than at the first
    /// quit, and it puts any failure — a folder that cannot be created, a
    /// permission refused — in front of somebody who is still holding the
    /// context to fix it.
    public func finishOnboarding() {
        settings.hasSeenAutoExportOnboarding = true
        service.run(trigger: .manual)
        refresh()
    }
}
