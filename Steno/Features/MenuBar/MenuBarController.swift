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
        // no delegate and no bookkeeping here.
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
    }

    @objc private func toggle() {
        if popover.isShown {
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
        // activation is what gets the field first responder without a second
        // click, which §1.1 requires.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `CaptureFieldView` takes focus in `.onAppear`, and that only lands
        // if the popover's window is key by then.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func hide() {
        popover.performClose(nil)
    }
}
