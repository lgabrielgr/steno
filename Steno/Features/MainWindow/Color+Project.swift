import SwiftUI

extension Color {
    /// Renders a `Project.colorHex` value. Falls back to black on malformed
    /// input rather than trapping — a bad colour is a cosmetic problem, and
    /// crashing the window over one would not be.
    init(projectHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        // Exactly six digits, or black. Parsing alone is not enough: "#FFF" is
        // valid hex and would otherwise read as 0x000FFF and render blue rather
        // than the white the shorthand implies, and an eight-digit value would
        // silently drop its high byte. Import is where arbitrary values arrive
        // (§10.1), so this has to reject rather than reinterpret.
        let value = digits.count == 6 ? (UInt64(digits, radix: 16) ?? 0) : 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
