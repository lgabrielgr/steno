import AppKit
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
