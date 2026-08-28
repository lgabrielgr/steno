import AppKit
import StenoKit
import SwiftData
import SwiftUI

/// Owns the hotkey, the panel, and the model behind it.
///
/// **Built once, at launch, and kept resident** (design §4.2). Building lazily
/// would put `NSPanel` creation, `NSHostingView` instantiation and a SwiftData
/// fetch inside the *first* press of every launch — the press §1.1 most cares
/// about, and the hardest one to measure. One panel resident for the process
/// lifetime is not a cost worth that.
@MainActor
final class QuickCaptureController {
    private let model: QuickCaptureModel
    private let panel: CapturePanel
    private var isShowing = false

    init(container: ModelContainer) {
        // `container.mainContext`, matching what `MainWindowView` reads, so a
        // capture from the panel and the window's own fetches agree without
        // relying on cross-context visibility.
        let model = QuickCaptureModel(
            context: container.mainContext,
            monitor: CarbonHotkeyMonitor()
        )
        self.model = model

        // Built here so the field and its chip are live before the first
        // press, not constructed during it.
        panel = CapturePanel(
            root: CaptureFieldView(
                field: model.field,
                onDismiss: { [weak model] in
                    // Esc: an explicit discard, so the draft goes too.
                    model?.field.reset()
                    NotificationCenter.default.post(name: .capturePanelShouldHide, object: nil)
                },
                style: .bar
            )
        )
        panel.delegate = PanelDelegate.shared
    }

    func start() {
        model.start { [weak self] in self?.toggle() }

        // Esc (via the panel content's `onDismiss`) and losing key focus (via
        // `PanelDelegate`) both post `.capturePanelShouldHide`, and this is
        // where that lands. Toggling the chord while the panel is open does
        // not go through the notification: `toggle()` already holds `self`
        // and calls `hide()` directly.
        NotificationCenter.default.addObserver(
            forName: .capturePanelShouldHide, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// Pressing the chord while the panel is open dismisses it — the platform
    /// idiom, and FR-1.1 does not specify otherwise. The draft survives,
    /// because a fumbled chord is not a decision to discard (design §8.1).
    private func toggle() {
        // Not a ternary: SwiftLint's `void_function_in_ternary` rejects
        // `isShowing ? hide() : show()` and `--strict` fails the build on it.
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        // §1.1 makes this path P0 and §13 requires it measured. Read with:
        //   /usr/bin/log show --last 5m --signpost --predicate \
        //     'subsystem == "com.lgabrielgr.steno" AND category == "capture"'
        let interval = Log.captureSignposter.beginInterval("hotkeyShow")
        defer { Log.captureSignposter.endInterval("hotkeyShow", interval) }

        model.prepareForShow()
        panel.positionForCapture()
        // No `NSApp.activate`. See `CapturePanel`.
        panel.makeKeyAndOrderFront(nil)
        isShowing = true
    }

    private func hide() {
        panel.orderOut(nil)
        isShowing = false
    }
}

extension Notification.Name {
    /// Raised by the panel's content and by its delegate; the controller owns
    /// the actual `orderOut` so there is one place that knows the panel is up.
    static let capturePanelShouldHide = Notification.Name(
        "com.lgabrielgr.steno.capturePanelShouldHide")
}

/// Hides the panel when it stops being key.
///
/// **Hides without resetting** (design §8.1). The user clicked away
/// mid-thought; the next press restores their draft. The alternative —
/// Spotlight's discard-on-blur — throws away typed capture text, which
/// `CaptureFieldView`'s own comment calls the single worst thing a capture
/// tool can do. `Esc` remains the way to actually discard.
@MainActor
private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()

    func windowDidResignKey(_ notification: Notification) {
        NotificationCenter.default.post(name: .capturePanelShouldHide, object: nil)
    }
}
