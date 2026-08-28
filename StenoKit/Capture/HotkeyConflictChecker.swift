import Foundation

/// FR-1.1's "detect and warn on conflicts".
///
/// **One class of conflict is detectable through public API, and this type
/// covers exactly that one.** System-reserved chords come from
/// `SystemHotkeys`; our own failed registration is reported by
/// `GlobalHotkeyMonitor`. A chord claimed by *another third-party
/// application* is not detectable at all — `RegisterEventHotKey` typically
/// returns `noErr` and the other application simply wins — and no amount of
/// work here changes that. Design §3 states the limit rather than implying
/// coverage this cannot provide.
public enum HotkeyConflictChecker {
    /// The reserved shortcut this chord collides with, if any.
    ///
    /// Equality is exact on key code *and* modifiers: `⌃⇧Space` is a different
    /// chord from `⌃Space`, and treating an overlap as a conflict would refuse
    /// perfectly good bindings.
    public static func conflict(for chord: HotkeyChord, against reserved: [ReservedHotkey])
        -> ReservedHotkey?
    {
        reserved.first { $0.chord == chord }
    }
}
