import AppKit
import Foundation
import Testing

@testable import StenoKit

/// A stock machine's domain: Spotlight is not in it.
///
/// A function rather than a `let` — a file-scope `[String: Any]` is not
/// `Sendable` and will not compile in Swift 6.
private func stockDomain() -> [String: Any] {
    [
        "60": [
            "enabled": true,
            "value": ["parameters": [32, 49, 262_144], "type": "standard"],
        ]
    ]
}

@Test("the default chord is free on a stock machine")
func defaultChordIsFree() {
    let reserved = SystemHotkeys.reserved(in: stockDomain())

    #expect(HotkeyConflictChecker.conflict(for: .default, against: reserved) == nil)
}

/// End-to-end for design §3.1: the fixture omits Spotlight, and ⌘Space must
/// still be reported as taken.
@Test("⌘Space conflicts with Spotlight even though the domain omits it")
func commandSpaceConflictsWithSpotlight() throws {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)

    let conflict = try #require(
        HotkeyConflictChecker.conflict(for: chord, against: reserved))

    #expect(conflict.name == "Spotlight search")
}

@Test("a chord recorded in the domain conflicts")
func recordedChordConflicts() throws {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)

    let conflict = try #require(
        HotkeyConflictChecker.conflict(for: chord, against: reserved))

    #expect(conflict.identifier == 60)
}

@Test("modifiers must match exactly, not merely overlap")
func modifiersMustMatchExactly() {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)

    // ⌃⇧Space is not ⌃Space.
    #expect(HotkeyConflictChecker.conflict(for: chord, against: reserved) == nil)
}
