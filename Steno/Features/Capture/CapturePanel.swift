import AppKit
import SwiftUI

/// The floating capture window.
///
/// **`.nonactivatingPanel`, and shown without `NSApp.activate`.** This is the
/// whole of the design's focus story. The panel becomes key and receives
/// typing, while at the `NSWorkspace` level the user's own application never
/// stops being frontmost — so dismissing has nothing to restore and there is
/// no restore step to get wrong. The task file makes returning focus part of
/// the 3-second budget rather than polish (§1.1); this meets it by never
/// taking focus away.
///
/// The rejected alternative was to activate and then restore
/// `NSWorkspace.shared.frontmostApplication`: the menu bar swaps, the Dock
/// icon marks active, and the restore is an asynchronous cross-process call
/// that can lose a race. Do not "simplify" toward it.
///
/// `.canJoinAllSpaces` with `.fullScreenAuxiliary` is what puts the panel over
/// another application's full-screen space.
final class CapturePanel: NSPanel {
    /// Required: a panel that cannot become key cannot receive typing, and a
    /// capture field that needs a click has already failed FR-1.1.
    override var canBecomeKey: Bool { true }

    /// Never main — being main is what would make Steno the active
    /// application and take the user out of their own.
    override var canBecomeMain: Bool { false }

    init(root: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        // The panel must survive the app not being active — it is shown while
        // another application is frontmost, which is the normal case.
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: root)
    }

    /// Slightly above centre, where a Spotlight-style panel is expected and
    /// where it does not cover what the user is looking at.
    func positionForCapture() {
        guard let screen = NSScreen.main else { return center() }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY + visible.height * 0.15
            ))
    }
}
