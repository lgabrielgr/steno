import AppKit
import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut macOS has already claimed.
public struct ReservedHotkey: Equatable, Sendable {
    /// The `AppleSymbolicHotKeys` id, kept so a conflict message can name the
    /// shortcut and a future setting could point the user at the right pane.
    public let identifier: Int
    public let name: String
    public let chord: HotkeyChord

    public init(identifier: Int, name: String, chord: HotkeyChord) {
        self.identifier = identifier
        self.name = name
        self.chord = chord
    }
}

/// macOS's own shortcuts, resolved from the `com.apple.symbolichotkeys`
/// defaults domain.
///
/// **The domain records deviations, not state.** This is the whole reason this
/// type is more than a plist read. On a stock machine Spotlight (64), Finder
/// search (65), Mission Control (32) and application windows (33) are absent
/// from the domain *entirely* and are live at their defaults; other ids appear
/// as a bare `{"enabled": true}` with no `value` key, meaning "on, at a chord
/// this file does not record". A resolver that trusts the plist alone reports
/// `⌘Space` as free — which is the single likeliest conflict any user of
/// FR-1.1 will ever attempt. Design §3.1.
public enum SystemHotkeys {
    public static let domainName = "com.apple.symbolichotkeys"
    public static let defaultsKey = "AppleSymbolicHotKeys"

    /// The chords macOS ships enabled, for the ids a capture hotkey could
    /// plausibly collide with.
    ///
    /// This is **data, not logic** — extend it if a gap turns up rather than
    /// adding special cases to `reserved(in:)`.
    static let systemDefaults: [Int: ReservedHotkey] = {
        func entry(
            _ identifier: Int, _ name: String, _ code: Int,
            _ flags: NSEvent.ModifierFlags
        ) -> (Int, ReservedHotkey) {
            (
                identifier,
                ReservedHotkey(
                    identifier: identifier, name: name,
                    chord: HotkeyChord(keyCode: UInt16(code), modifiers: flags.rawValue))
            )
        }
        return Dictionary(
            uniqueKeysWithValues: [
                entry(32, "Mission Control", kVK_UpArrow, [.control]),
                entry(33, "Application windows", kVK_DownArrow, [.control]),
                entry(52, "Turn Dock hiding on/off", kVK_ANSI_D, [.option, .command]),
                entry(60, "Select previous input source", kVK_Space, [.control]),
                entry(61, "Select next input source", kVK_Space, [.control, .option]),
                entry(64, "Spotlight search", kVK_Space, [.command]),
                entry(65, "Finder search window", kVK_Space, [.option, .command]),
                entry(79, "Move left a space", kVK_LeftArrow, [.control]),
                entry(81, "Move right a space", kVK_RightArrow, [.control]),
                entry(98, "Show Help menu", kVK_ANSI_Slash, [.shift, .command]),
                entry(28, "Screenshot to file", kVK_ANSI_3, [.shift, .command]),
                entry(30, "Screenshot region to file", kVK_ANSI_4, [.shift, .command]),
                entry(184, "Screenshot and recording options", kVK_ANSI_5, [.shift, .command]),
            ])
    }()

    /// Every chord macOS currently claims.
    ///
    /// The domain is a parameter rather than read internally so the whole
    /// resolution is testable against fixtures with no dependency on the
    /// machine running the suite (§9.4).
    public static func reserved(in domain: [String: Any]) -> [ReservedHotkey] {
        var found: [ReservedHotkey] = []
        var seen: Set<Int> = []

        for (rawIdentifier, rawEntry) in domain {
            guard let identifier = Int(rawIdentifier),
                let entry = rawEntry as? [String: Any]
            else { continue }
            seen.insert(identifier)

            // Absent `enabled` means off: macOS writes the key when it writes
            // the entry, so an entry without one is not a live shortcut.
            guard (entry["enabled"] as? Bool) ?? false else { continue }

            if let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Int],
                parameters.count >= 3
            {
                // parameters = (ascii, keyCode, cocoaModifierMask).
                found.append(
                    ReservedHotkey(
                        identifier: identifier,
                        name: systemDefaults[identifier]?.name ?? "System shortcut \(identifier)",
                        chord: HotkeyChord(
                            keyCode: UInt16(truncatingIfNeeded: parameters[1]),
                            modifiers: UInt(bitPattern: parameters[2]))))
            } else if let fallback = systemDefaults[identifier] {
                // Enabled, but the chord is not recorded here.
                found.append(fallback)
            }
        }

        // The ids the domain never mentions, which are live at their defaults.
        for (identifier, fallback) in systemDefaults where !seen.contains(identifier) {
            found.append(fallback)
        }
        return found
    }

    /// The running machine's domain. Unsandboxed (see `Steno.entitlements`),
    /// so this reads the user's real preferences.
    public static func systemDomain() -> [String: Any] {
        UserDefaults(suiteName: domainName)?.dictionary(forKey: defaultsKey) ?? [:]
    }
}
