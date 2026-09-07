import AppKit
import Carbon.HIToolbox
import Foundation
import Testing

@testable import StenoKit

@Test("the default chord is ⌥Space")
func defaultChordIsOptionSpace() {
    #expect(HotkeyChord.default.keyCode == 49)
    #expect(HotkeyChord.default.modifiers == NSEvent.ModifierFlags.option.rawValue)
    #expect(HotkeyChord.default.displayString == "⌥Space")
}

/// The two encodings are unrelated bit layouts, and confusing them binds the
/// user to a chord other than the one they chose. See design §3.2.
@Test(
    "Cocoa modifier flags convert to their Carbon equivalents",
    arguments: [
        (NSEvent.ModifierFlags.shift, UInt32(512)),
        (NSEvent.ModifierFlags.control, UInt32(4096)),
        (NSEvent.ModifierFlags.option, UInt32(2048)),
        (NSEvent.ModifierFlags.command, UInt32(256)),
    ])
func cocoaModifiersConvertToCarbon(flags: NSEvent.ModifierFlags, carbon: UInt32) {
    let chord = HotkeyChord(keyCode: 49, modifiers: flags.rawValue)
    #expect(chord.carbonModifiers == carbon)
}

@Test("combined modifiers convert as a union")
func combinedModifiersConvert() {
    let chord = HotkeyChord(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)

    #expect(chord.carbonModifiers == UInt32(4096 | 2048))
    #expect(chord.displayString == "⌃⌥Space")
}

@Test("a chord round-trips through Codable")
func chordRoundTripsThroughCodable() throws {
    let encoded = try JSONEncoder().encode(HotkeyChord.default)
    let decoded = try JSONDecoder().decode(HotkeyChord.self, from: encoded)

    #expect(decoded == HotkeyChord.default)
}

@Test("an unmapped key code degrades to a readable label rather than empty text")
func unmappedKeyCodeDegrades() {
    let chord = HotkeyChord(keyCode: 200, modifiers: NSEvent.ModifierFlags.command.rawValue)

    #expect(chord.displayString == "⌘Key 200")
}

/// The table M1-08's recorder made load-bearing.
///
/// Two properties, and both can break silently. A dropped row degrades that
/// key to `"Key 40"` in the pane the user just pressed it in; a duplicated
/// name makes two different chords read identically, so a conflict message
/// names a shortcut the user cannot find. Constructing `keyNames` also traps
/// on a duplicate *key*, so reaching the table at all is part of the check.
@Test("every named key code renders as itself, uniquely")
func namedKeyCodesRenderUniquely() {
    let names = HotkeyChord.namedKeyCodes.map { HotkeyChord.keyName(for: $0) }

    #expect(!names.isEmpty)
    for name in names {
        #expect(!name.isEmpty)
        #expect(!name.hasPrefix("Key "), "\(name) fell through to the unmapped fallback")
    }
    #expect(Set(names).count == names.count, "two key codes share a name")
}

/// The recorder can emit any code on the keyboard, and the letters and digits
/// are what a person actually picks.
@Test("the keys a person would choose all have names")
func theOrdinaryKeysAreNamed() {
    let named = Set(HotkeyChord.namedKeyCodes)
    for letter in [kVK_ANSI_A, kVK_ANSI_K, kVK_ANSI_Z] {
        #expect(named.contains(UInt16(letter)))
    }
    for digit in [kVK_ANSI_0, kVK_ANSI_9] {
        #expect(named.contains(UInt16(digit)))
    }
    #expect(named.contains(UInt16(kVK_F1)))
    #expect(named.contains(UInt16(kVK_Tab)))
}
