import AppKit
import Carbon.HIToolbox
import Foundation

/// Whether a chord the user just pressed can be bound, and if not, why.
///
/// **All of the recorder's judgment lives here, in `StenoKit`.** The control
/// itself is an `NSView` with a local event monitor and cannot run in the
/// headless bundle (D-010); everything it decides can, so the only untestable
/// part left is the event plumbing.
public enum HotkeyChordValidator {
    /// Why a recorded chord was refused. Each case carries the sentence the
    /// pane shows — written for a person, the way
    /// `HotkeyRegistrationError.message` is.
    /// Conforms to `Error` because `Result`'s failure type must — not because
    /// a refused chord is an error condition. Nothing throws it.
    public enum Rejection: Error, Equatable, Sendable {
        /// A bare key with no modifiers.
        case noModifiers
        /// Shift and nothing else.
        case shiftOnly

        public var message: String {
            switch self {
            case .noModifiers:
                return "Add ⌃, ⌥ or ⌘ to make this a shortcut."
            case .shiftOnly:
                return "Shift on its own is not enough. Add ⌃, ⌥ or ⌘."
            }
        }
    }

    /// The four modifiers a chord may carry.
    ///
    /// **Masking is not cosmetic.** `NSEvent.modifierFlags` also reports
    /// `.capsLock`, `.function`, `.numericPad` and device-dependent left/right
    /// bits — an `⌥Space` pressed on a laptop can arrive with `.function` set.
    /// `HotkeyChord` compares modifiers for exact equality, both against
    /// `SystemHotkeys`' reserved table and in `Codable` round-trips, so an
    /// unmasked chord would silently never match a system shortcut and would
    /// convert to a different Carbon mask than the one the user pressed.
    static let supported: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// `Esc` cancels recording rather than binding.
    ///
    /// A consequence worth stating: no `Esc` chord is bindable at all. That is
    /// the platform norm, and `Esc` is the cancel affordance everywhere else
    /// in this app — `CaptureFieldView` and the note composer both use it.
    public static func isCancel(keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Escape)
    }

    /// Turn a recorded key press into a bindable chord.
    ///
    /// - Parameters:
    ///   - keyCode: the event's `keyCode`, a layout-independent virtual code.
    ///   - modifiers: the event's raw `modifierFlags.rawValue`, unmasked —
    ///     masking is this function's job, not its caller's.
    public static func validate(keyCode: UInt16, modifiers: UInt)
        -> Result<HotkeyChord, Rejection>
    {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers).intersection(supported)

        // A bare key bound globally is swallowed in every application, which
        // would make the user's keyboard unusable until they found this pane
        // again — and they would be typing without that key to reach it.
        guard !flags.isEmpty else { return .failure(.noModifiers) }

        // `⇧K` is not distinguishable from typing a capital K.
        guard flags != [.shift] else { return .failure(.shiftOnly) }

        return .success(HotkeyChord(keyCode: keyCode, modifiers: flags.rawValue))
    }
}
