import SwiftUI

extension Color {
    /// Renders a `Project.colorHex` value. Falls back to black on malformed
    /// input rather than trapping — a bad colour is a cosmetic problem, and
    /// crashing the window over one would not be.
    init(projectHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
