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

    /// Disarms when the control's window stops being key. Rebuilt whenever the
    /// control changes window; see `viewDidMoveToWindow`.
    private var keyWindowObservation: NotificationObservation?

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

            // A local monitor is application-wide, not view-wide. If this
            // control's window is not the one being typed into, the press is
            // not a binding gesture — so disarm and let it through rather than
            // swallowing a keystroke aimed at something else.
            //
            // Belt to `keyWindowObservation`'s braces, and the half that makes
            // the failure impossible rather than merely unlikely: the shipped
            // bug was a monitor that outlived its window and bound ⌘, — the
            // press that was meant to *open* Settings.
            guard self.window?.isKeyWindow == true else {
                self.recording = nil
                return event
            }

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

    /// Disarm when the control's window goes away — or merely stops being the
    /// one receiving keys.
    ///
    /// **`window == nil` alone is not enough, and shipping it alone was the
    /// bug.** SwiftUI's `Settings` scene keeps its window and its content view
    /// alive across a close: ⌘, reopens the same window rather than building a
    /// new one, so a control armed when the window closed never moves out of a
    /// window and this override never runs. The monitor survived, and the next
    /// keystroke anywhere in the app was swallowed and bound — reliably ⌘,
    /// itself, since that is what the user presses to get Settings back.
    ///
    /// Resigning key is the signal that actually fires: on close, on switching
    /// to the main window, and on ⌘Tab away. All three should disarm, so
    /// watching for it is not just a workaround for the close case.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        keyWindowObservation = window.map { window in
            NotificationObservation(
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recording = nil }
                })
        }
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

/// The same arrangement for a `NotificationCenter` observation.
///
/// `StenoKit`'s `WriteObservation` is this type, but it is internal to that
/// module and `Steno` cannot see it. Two five-line classes rather than making
/// one of them public: the shape is the Swift 6 rule, not shared behaviour, and
/// widening a framework's API for it would say otherwise.
private final class NotificationObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
