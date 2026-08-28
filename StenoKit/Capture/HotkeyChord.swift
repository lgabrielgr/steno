import AppKit
import Carbon.HIToolbox
import Foundation

/// One global keyboard chord: a virtual key code plus its modifiers.
///
/// **Modifiers are stored in the Cocoa encoding** — `NSEvent.ModifierFlags`
/// raw values — and converted to Carbon only at the registration call. Two
/// reasons. It is what `com.apple.symbolichotkeys` speaks, so
/// `HotkeyConflictChecker` compares like with like; and it is what a key
/// recorder control in M1-08 will hand over. The two layouts are unrelated
/// (design §3.2), so a single canonical form with one conversion point is the
/// difference between a chord that binds correctly and one that binds to
/// something else.
public struct HotkeyChord: Equatable, Hashable, Codable, Sendable {
    /// A virtual key code — `kVK_Space` and friends, layout-independent.
    public let keyCode: UInt16

    /// `NSEvent.ModifierFlags.rawValue`, not a Carbon mask.
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// FR-1.1's default. Verified free of system shortcuts on the development
    /// machine — the only Space chords macOS claims there are `⌃Space` and
    /// `⌃⌥Space`, both input-source switching — so a fresh install does not
    /// open on a conflict warning.
    public static let `default` = HotkeyChord(
        keyCode: UInt16(kVK_Space),
        modifiers: NSEvent.ModifierFlags.option.rawValue
    )

    /// The Carbon mask `RegisterEventHotKey` expects.
    public var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// For M1-08's rebinding pane and for conflict messages.
    ///
    /// Modifier order is macOS's own — `⌃⌥⇧⌘` — so a chord reads the way the
    /// same chord reads in a system menu.
    public var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// Covers the keys the default chord and the conflict table actually use.
    ///
    /// A table rather than a `switch`: twelve cases put the function over
    /// SwiftLint's `cyclomatic_complexity` threshold of 10, which `--strict`
    /// makes a build failure. It is also the better shape — this is data.
    private static let keyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_DownArrow: "↓",
        kVK_UpArrow: "↑",
        kVK_ANSI_3: "3",
        kVK_ANSI_4: "4",
        kVK_ANSI_5: "5",
        kVK_ANSI_D: "D",
        kVK_ANSI_Slash: "/",
    ]

    /// An unmapped code degrades to a readable label rather than to empty
    /// text: a rebinding pane showing a bare `⌘` is worse than one showing
    /// `⌘Key 200`.
    static func keyName(for keyCode: UInt16) -> String {
        keyNames[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
