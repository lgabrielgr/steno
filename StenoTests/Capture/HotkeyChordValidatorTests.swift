import AppKit
import Carbon.HIToolbox
import Testing

@testable import StenoKit

@Test("a chord with a real modifier is accepted")
func aModifiedChordIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.option.rawValue)

    let chord = try #require(try? result.get())
    #expect(chord.keyCode == UInt16(kVK_ANSI_K))
    #expect(chord.displayString == "⌥K")
}

/// FR-1.1's own default must survive its validator.
@Test("the default chord is accepted")
func theDefaultChordIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: HotkeyChord.default.keyCode, modifiers: HotkeyChord.default.modifiers)

    #expect((try? result.get()) == HotkeyChord.default)
}

/// A bare key bound system-wide is swallowed in every application — including
/// whatever the user would type to get back to this pane and undo it.
@Test("a bare key is refused")
func aBareKeyIsRefused() {
    let result = HotkeyChordValidator.validate(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)

    #expect(result == .failure(.noModifiers))
}

@Test("shift alone is refused")
func shiftAloneIsRefused() {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.shift.rawValue)

    #expect(result == .failure(.shiftOnly))
}

@Test("shift with a real modifier is accepted")
func shiftWithARealModifierIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K),
        modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)

    let chord = try #require(try? result.get())
    #expect(chord.displayString == "⇧⌘K")
}

/// The defect this masking exists to prevent is silent. `NSEvent` reports
/// `.function` on a laptop's arrow and function keys and `.capsLock` whenever
/// caps lock is on; `HotkeyChord` compares modifiers for exact equality, both
/// against `SystemHotkeys`' reserved table and across a `Codable` round-trip.
/// An unmasked chord therefore never matches a system shortcut — so FR-1.1's
/// conflict warning would simply stop firing — and converts to a Carbon mask
/// the user did not press.
@Test("device and lock flags are stripped")
func extraneousFlagsAreStripped() throws {
    let noisy = NSEvent.ModifierFlags([.option, .function, .capsLock, .numericPad])

    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_Space), modifiers: noisy.rawValue)

    #expect((try? result.get()) == HotkeyChord.default)
}

@Test("escape cancels rather than binding")
func escapeCancels() {
    #expect(HotkeyChordValidator.isCancel(keyCode: UInt16(kVK_Escape)))
    #expect(!HotkeyChordValidator.isCancel(keyCode: UInt16(kVK_Space)))
}
