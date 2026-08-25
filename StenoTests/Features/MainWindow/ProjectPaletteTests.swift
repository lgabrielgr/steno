import Testing

@testable import StenoKit

@Test("the palette cycles rather than trapping past its end")
func paletteCycles() {
    let count = ProjectPalette.hexes.count

    #expect(ProjectPalette.hex(forIndex: count) == ProjectPalette.hex(forIndex: 0))
    #expect(!ProjectPalette.hex(forIndex: 99).isEmpty)
}

@Test("consecutive projects get distinguishable colours")
func consecutiveColoursDiffer() {
    #expect(ProjectPalette.hex(forIndex: 0) != ProjectPalette.hex(forIndex: 1))
}

@Test("every palette entry is a six-digit hex colour")
func paletteEntriesAreWellFormed() {
    for hex in ProjectPalette.hexes {
        #expect(hex.count == 7)
        #expect(hex.hasPrefix("#"))
        // The length and prefix checks alone let something like "#3B82FG"
        // through. `Color(projectHex:)` lives in the app target and is
        // untestable here, so this is the only guard the palette's hex
        // strings get — it must actually parse as hex, not just look like it.
        #expect(UInt64(hex.dropFirst(), radix: 16) != nil)
    }
}
