import AppKit
import StenoKit

/// Brings the main window forward from the three states FR-1.2's "Open Main
/// Window" has to handle: closed, minimized, and on another Space — the
/// closed case provided `MainWindowView` has appeared at least once to stash
/// `reopen`.
///
/// The three need different things. Activation moves the user to the window's
/// Space; `deminiaturize` handles the Dock; and a window the user closed with
/// ⌘W has to be reopened through the scene, which only SwiftUI can do — hence
/// `reopen`, stashed by `MainWindowView` while it is on screen.
enum MainWindowReveal {
    /// The `Window` scene's id, shared by `StenoApp` and by the stashed action.
    static let sceneID = "main"

    /// Set on the `NSWindow` by `MainWindowView`, and matched here.
    ///
    /// An identifier rather than a title (localizable) or a class test (would
    /// also match `CapturePanel`).
    static let identifier = NSUserInterfaceItemIdentifier("com.lgabrielgr.steno.mainWindow")

    /// SwiftUI's `openWindow`, wrapped in a closure and captured while the
    /// window exists.
    ///
    /// A stored closure rather than an environment read at the call site: the
    /// popover's content is hosted outside the scene tree, so it has no
    /// environment to read from.
    @MainActor static var reopen: (() -> Void)?

    @MainActor
    static func reveal() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier == identifier }) {
            // Logged because this branch cannot be tested here — GUI
            // automation is unavailable — so the manual check reads a log line
            // rather than inferring which path ran.
            Log.app.info("reveal: bringing the existing main window forward")
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }

        if let reopen {
            Log.app.info("reveal: no main window found; reopening the scene")
            reopen()
        } else {
            Log.app.error(
                "reveal: no main window found and no reopen action stashed; nothing to show")
        }
    }
}
