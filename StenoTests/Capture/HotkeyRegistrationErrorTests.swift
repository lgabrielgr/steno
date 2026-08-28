import Foundation
import Testing

@testable import StenoKit

@Test("each failure explains itself in words a settings pane can show")
func failuresCarryReadableMessages() {
    #expect(
        HotkeyRegistrationError.alreadyRegistered.message
            == "That shortcut is already registered.")
    #expect(
        HotkeyRegistrationError.systemRefused(-9868).message
            == "macOS refused the shortcut (error -9868).")
}

@Test("registration errors compare by case and status")
func registrationErrorsCompare() {
    #expect(HotkeyRegistrationError.systemRefused(-1) != .systemRefused(-2))
    #expect(HotkeyRegistrationError.alreadyRegistered != .systemRefused(0))
}
