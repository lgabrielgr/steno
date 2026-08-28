import AppKit
import Foundation
import Testing

@testable import StenoKit

private let commandSpace = HotkeyChord(
    keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
private let controlSpace = HotkeyChord(
    keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)

/// Shaped exactly like the real domain: an id with a recorded `value`, an id
/// enabled with no `value` at all, a disabled id, and — critically — no entry
/// for Spotlight.
///
/// A function, not a `let`. A file-scope `let` of type `[String: Any]` is a
/// **compile error** in Swift 6 — the type is not `Sendable`, so it cannot be
/// a global. Verified, not guessed.
private func realisticDomain() -> [String: Any] {
    [
        "60": [
            "enabled": true,
            "value": ["parameters": [32, 49, 262_144], "type": "standard"],
        ],
        "79": ["enabled": true],
        "65": ["enabled": false],
    ]
}

@Test("a recorded value is used as the reserved chord")
func recordedValueIsUsed() throws {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let entry = try #require(reserved.first { $0.identifier == 60 })

    #expect(entry.chord == controlSpace)
}

@Test("an id enabled with no recorded value falls back to the default table")
func enabledWithoutValueUsesDefaultTable() throws {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let entry = try #require(reserved.first { $0.identifier == 79 })

    // ⌃← — the domain says only that it is on, never what it is bound to.
    #expect(entry.chord.keyCode == 123)
    #expect(entry.chord.modifiers == NSEvent.ModifierFlags.control.rawValue)
}

/// The regression test for design §3.1. Spotlight is absent from the fixture,
/// exactly as it is absent from a stock machine's real domain — and is
/// nonetheless live at ⌘Space. A resolver that reads only the plist reports
/// the likeliest conflict a user can hit as free.
@Test("an id absent from the domain is still reserved at its default chord")
func absentIDIsStillReserved() throws {
    #expect(realisticDomain()["64"] == nil)

    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let spotlight = try #require(reserved.first { $0.identifier == 64 })

    #expect(spotlight.chord == commandSpace)
    #expect(spotlight.name == "Spotlight search")
}

@Test("an explicitly disabled id is not reserved")
func disabledIDIsNotReserved() {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())

    #expect(!reserved.contains { $0.identifier == 65 })
}

@Test("malformed entries are skipped rather than crashing")
func malformedEntriesAreSkipped() {
    let domain: [String: Any] = [
        "not-a-number": ["enabled": true],
        "60": "not-a-dictionary",
        "61": ["enabled": true, "value": ["parameters": [32]]],
    ]

    let reserved = SystemHotkeys.reserved(in: domain)

    // 61 is enabled but its parameters are too short, so it resolves from the
    // default table; the other two contribute nothing.
    #expect(reserved.contains { $0.identifier == 61 })
    #expect(!reserved.contains { $0.identifier == 60 && $0.chord.keyCode == 0 })
}
