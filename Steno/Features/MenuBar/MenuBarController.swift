import AppKit
import StenoKit
import SwiftData
import SwiftUI

/// Owns the status item, the popover, and the model behind it.
///
/// **Built once, at launch, and kept resident**, for the reason
/// `QuickCaptureController` gives: building an `NSHostingController` and
/// running a fetch inside the *first* click of every launch puts the cost on
/// the click that matters most and is hardest to measure. What an open
/// actually costs is `prepareForShow()` — two fetches and a chip refresh.
@MainActor
final class MenuBarController: NSObject {
    private let model: MenuBarModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// When the popover last *began* closing, however it was closed.
    ///
    /// The start, not the finish: a close animates, and the timestamp has to
    /// be recorded before the mouse-up that follows the dismissing mouse-down
    /// or the guard it feeds is inert. See `toggle()`.
    private var lastCloseAt: Date = .distantPast

    /// The observation's token, kept because it is the only handle by which
    /// the registration could ever be removed. Nothing removes it today: the
    /// controller is built once in `StenoApp.init` and lives for the process.
    private var closeObservation: (any NSObjectProtocol)?

    init(container: ModelContainer) {
        // `container.mainContext`, matching what `MainWindowView` and
        // `QuickCaptureModel` read, so a write here and the window's own
        // fetches agree without relying on cross-context visibility.
        model = MenuBarModel(context: container.mainContext)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "Steno")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        // `.transient` is what dismisses the popover on a click outside, with
        // no delegate. The one piece of bookkeeping it costs is `lastCloseAt`
        // below: that dismissal does not run through `hide()`, so `toggle()`
        // would otherwise have no way to know it happened.
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: MenuBarPopoverView(
                model: model,
                onDismiss: { [weak self] in self?.hide() },
                onOpenMainWindow: { [weak self] in
                    // Close first, so the window does not arrive behind a
                    // popover that is about to dismiss itself.
                    self?.hide()
                    MainWindowReveal.reveal()
                }
            ))
        // Lets the popover take its height from the content, so an empty list
        // and a list of six are both sized correctly and neither scrolls.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        // `willClose`, not `didClose`. Every close lands in both — `hide()`,
        // `Esc`, a successful capture, and the `.transient` dismissal AppKit
        // performs on its own — but `didClose` is posted after the close
        // *completes*, and `popover.animates` defaults to `true`. The fade can
        // outlast the mouse-up that follows the dismissing mouse-down, which
        // would leave `lastCloseAt` unset at exactly the moment `toggle()`
        // reads it, making the guard inert. `willClose` is posted when the
        // close begins, so the stamp is already down by then. If a re-open is
        // still seen by hand, `popover.animates = false` is the next lever.
        closeObservation = NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification, object: popover, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastCloseAt = Date() }
        }
    }

    /// Clicking the icon closes an open popover and opens a closed one.
    ///
    /// **The timestamp is not paranoia.** A `.transient` popover closes on a
    /// mouse-*down* outside itself, the status button is outside it, and
    /// `NSStatusBarButton` sends its action on mouse-*up* — so if AppKit does
    /// not swallow that mouse-down, the popover is already closing by the time
    /// this runs and `isShown` alone would re-open it, making the icon look
    /// dead. Whether AppKit swallows it is undocumented and has varied by
    /// release; this guard is correct under both behaviours, because if the
    /// click *is* swallowed the action never fires at all. It cannot be
    /// exercised without a window server (D-010).
    @objc private func toggle() {
        if popover.isShown || Date().timeIntervalSince(lastCloseAt) < 0.2 {
            hide()
        } else {
            show()
        }
    }

    /// §1.1 makes this path P0 and §13 requires it measured. Read with the
    /// `log show --signpost` recipe in `Log.captureSignposter`.
    private func show() {
        guard let button = statusItem.button else { return }
        let interval = Log.captureSignposter.beginInterval("popoverShow")
        defer { Log.captureSignposter.endInterval("popoverShow", interval) }

        // Before the show, not after: the field must not render one frame with
        // a stale chip. `QuickCaptureController.show` orders it the same way.
        model.prepareForShow()

        // `NSApp.activate`, which `CapturePanel` deliberately refuses. The two
        // surfaces are opposites (D-038): the panel appears over the app the
        // user is working in, while the menu bar is reached by leaving it — so
        // activation is what lets the popover's window become key and receive
        // the typing, without which §1.1's ~3-second budget would be spent on
        // a second click into the field.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `NSApp.activate` above completes asynchronously and AppKit can hand
        // key to another Steno window as the app activates, so the popover is
        // not guaranteed to be key here. `makeKey()` asserts it, so the field
        // SwiftUI focuses in `CaptureFieldView`'s `.onAppear` is the one that
        // receives typing. Whether the popover would become key unaided needs
        // a window server to settle; manual check 2 is what settles it.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func hide() {
        popover.performClose(nil)
    }
}
