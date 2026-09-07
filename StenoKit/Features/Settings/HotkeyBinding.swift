import Foundation

/// What Settings needs from whatever owns the global hotkey.
///
/// **Three members, deliberately.** `SettingsModel` could hold a
/// `QuickCaptureModel` directly — both are view models in the same module —
/// but then the Settings layer would depend on the capture panel's state, its
/// project list and its capture field, none of which it has any business
/// knowing about. This is the seam, and it is narrow enough that a test double
/// is four lines.
///
/// `QuickCaptureModel` conforms with no additional code: it already has all
/// three.
@MainActor
public protocol HotkeyBinding: AnyObject {
    /// The chord currently bound.
    var chord: HotkeyChord { get }

    /// A conflict or registration failure, in words, or `nil`.
    var registrationProblem: String? { get }

    /// Bind a different chord, taking effect immediately.
    func rebind(to chord: HotkeyChord)
}
