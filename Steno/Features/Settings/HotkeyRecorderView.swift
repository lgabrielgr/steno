import AppKit
import Carbon.HIToolbox
import StenoKit
import SwiftUI

/// The click-then-press control that captures a chord.
///
/// **All of its judgment is elsewhere.** `HotkeyChordValidator` decides what a
/// recorded press means and `SettingsModel.record` acts on it; this type is
/// only the event plumbing, which is the part D-010 puts beyond the headless
/// bundle. Keeping the split that sharp is what makes "a bare key is refused"
/// a unit test rather than a manual check.
struct HotkeyRecorderView: NSViewRepresentable {
    /// The current chord, as `HotkeyChord.displayString` renders it.
    let display: String

    /// Raw `keyCode` and unmasked `modifierFlags.rawValue`. Masking is the
    /// validator's job — see `HotkeyChordValidator.supported`.
    let onRecord: (UInt16, UInt) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderControl {
        let control = HotkeyRecorderControl()
        control.onRecord = onRecord
        control.display = display
        return control
    }

    func updateNSView(_ nsView: HotkeyRecorderControl, context: Context) {
        nsView.onRecord = onRecord
        nsView.display = display
    }
}

/// A button that, while armed, swallows the next key press and reports it.
///
/// **A *local* monitor, not a global one.** Recording only needs events
/// delivered to this application, and a global monitor would require
/// Accessibility permission — the dependency `CarbonHotkeyMonitor`'s own
/// documentation explains M1-03 avoided, and the reason Steno ships no
/// permissions UI. If recording ever raises a permission prompt, that is a
/// defect here, not a step to add to onboarding.
final class HotkeyRecorderControl: NSButton {
    var onRecord: ((UInt16, UInt) -> Void)?

    var display: String = "" {
        didSet { refreshTitle() }
    }

    /// Holds the monitor while armed. Assigning `nil` removes it, because the
    /// token's `deinit` is what calls `NSEvent.removeMonitor`.
    private var recording: LocalMonitorToken? {
        didSet { refreshTitle() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HotkeyRecorderControl is created in code, never from a nib")
    }

    private func refreshTitle() {
        title = recording == nil ? display : "Press a shortcut…"
    }

    @objc private func toggleRecording() {
        guard recording == nil else {
            recording = nil
            return
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording != nil else { return event }

            // `Esc` cancels rather than binding — so no `Esc` chord is
            // bindable at all, which is the platform norm and matches every
            // other `Esc` in this app.
            if HotkeyChordValidator.isCancel(keyCode: event.keyCode) {
                self.recording = nil
                return nil
            }

            self.onRecord?(event.keyCode, event.modifierFlags.rawValue)
            self.recording = nil

            // Swallowed: the press was a binding gesture, and letting it
            // through would also type into whatever has focus behind us.
            return nil
        }
        recording = monitor.map(LocalMonitorToken.init)
    }

    /// Disarm when the control leaves the screen, so a Settings window closed
    /// mid-recording does not leave a monitor swallowing every key press.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { recording = nil }
    }
}

/// Removes a local event monitor when its owner releases it.
///
/// The `WriteObservation` pattern, for the same Swift 6 reason: the `deinit`
/// of a `@MainActor` class is nonisolated and may not touch isolated stored
/// properties, so the monitor is held by a plain object whose own `deinit`
/// touches nothing isolated.
private final class LocalMonitorToken {
    private let monitor: Any

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    deinit {
        NSEvent.removeMonitor(monitor)
    }
}
