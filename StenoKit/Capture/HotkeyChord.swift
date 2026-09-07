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

    /// Every key a chord can name.
    ///
    /// **Grown for M1-08's recorder.** Until then this covered only the
    /// default chord and `SystemHotkeys`' conflict table — eleven codes, with
    /// everything else degrading to `"Key 200"`. That degradation is right as
    /// a fallback and wrong as the answer for a chord the user has just
    /// pressed, and a recorder can emit any code on the keyboard. Extending
    /// the table is what this type's shape was chosen for: **this is data, not
    /// logic** — add a row rather than a special case in `keyName(for:)`.
    ///
    /// A table rather than a `switch` because a `switch` of this size is far
    /// past SwiftLint's `cyclomatic_complexity` threshold of 10, which
    /// `--strict` makes a build failure.
    ///
    /// `Dictionary(uniqueKeysWithValues:)` rather than a dictionary literal:
    /// both trap on a duplicate key, but this one type-checks in reasonable
    /// time at eighty entries where the literal does not. The trap is the
    /// point — a duplicated row is a mistake, and `HotkeyChordTests` reaches
    /// this table so the trap fires in the suite rather than in the app.
    ///
    /// **The names are ANSI-layout names.** On a non-ANSI layout a key can
    /// display under its ANSI name. The *stored* chord is unaffected —
    /// `keyCode` is a layout-independent virtual key code — so this is a
    /// labelling imprecision, not a binding bug. Resolving names through
    /// `UCKeyTranslate` would fix it and would make the result depend on the
    /// machine running the suite, which §9.4 rules out.
    private static let keyNames: [Int: String] = {
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        let digits: [(Int, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        let punctuation: [(Int, String)] = [
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"),
            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
        ]
        // Symbols where macOS's own menus use one, words where they do not.
        let specials: [(Int, String)] = [
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"),
            (kVK_ForwardDelete, "⌦"), (kVK_Escape, "⎋"), (kVK_Home, "↖"), (kVK_End, "↘"),
            (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"), (kVK_Help, "Help"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"),
            (kVK_DownArrow, "↓"),
        ]
        let functionKeys: [(Int, String)] = [
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
            (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
            (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"),
            (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"),
            (kVK_F19, "F19"), (kVK_F20, "F20"),
        ]
        return Dictionary(
            uniqueKeysWithValues: letters + digits + punctuation + specials + functionKeys)
    }()

    /// Every key code the table names, for the test that guards it.
    static var namedKeyCodes: [UInt16] { keyNames.keys.map { UInt16($0) } }

    /// An unmapped code degrades to a readable label rather than to empty
    /// text: a rebinding pane showing a bare `⌘` is worse than one showing
    /// `⌘Key 200`.
    static func keyName(for keyCode: UInt16) -> String {
        keyNames[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
