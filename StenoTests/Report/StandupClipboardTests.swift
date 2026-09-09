import AppKit
import Foundation
import Testing

@testable import StenoKit

/// D6: what actually reaches Slack. `SlackMarkdown`'s `*bold*` does not convert
/// on paste, so emphasis has to be real before it leaves the app.

/// Whether the run covering `substring` is bold / italic.
///
/// Finds the range in the rendered plain text rather than assuming an offset, so
/// a change to the surrounding layout cannot turn these into assertions about
/// the wrong characters.
@MainActor
private func traits(
    of substring: String, in text: NSAttributedString
) -> NSFontDescriptor.SymbolicTraits? {
    guard let found = text.string.range(of: substring) else { return nil }
    let offset = text.string.distance(from: text.string.startIndex, to: found.lowerBound)
    let font = text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    return font?.fontDescriptor.symbolicTraits
}

@MainActor
@Test("a heading line becomes really bold, and loses its asterisks")
func headingBecomesBold() {
    let text = StandupClipboard.richText(from: "*Since last stand-up*")

    // The asterisks must be GONE, not merely decorated — they are what Slack
    // was showing literally.
    #expect(text.string == "Since last stand-up")
    #expect(traits(of: "Since last stand-up", in: text)?.contains(.bold) == true)
}

@MainActor
@Test("D-074's `_None_` becomes really italic, and loses its underscores")
func noneBecomesItalic() {
    let text = StandupClipboard.richText(from: "_None_")

    #expect(text.string == "None")
    #expect(traits(of: "None", in: text)?.contains(.italic) == true)
}

@MainActor
@Test("a bullet line is unchanged, and its literal bullet character survives")
func bulletLineIsPlain() {
    let text = StandupClipboard.richText(from: "• Fix flaky auth test (ENG-4)")

    // D-073 chose `•` precisely because it needs no conversion. Nothing here
    // may undo that.
    #expect(text.string == "• Fix flaky auth test (ENG-4)")
    #expect(traits(of: "Fix flaky", in: text)?.contains(.bold) == false)
}

@MainActor
@Test("D-073 holds: a note's own asterisks stay verbatim and are not emphasis")
func inlineAsterisksAreNotMarkup() {
    // The user typed this. D-073 passes `*` and `_` through unescaped because
    // "appear verbatim as the user typed them" is an acceptance criterion;
    // treating an interior delimiter as markup here would overturn that in the
    // one place the user cannot see it happen.
    let body = "    ◦ the *args splat broke, see _internal_helper"
    let text = StandupClipboard.richText(from: body)

    #expect(text.string == body, "every character the user typed survives")
    #expect(traits(of: "args", in: text)?.contains(.italic) == false)
}

@MainActor
@Test("a line carrying two emphasis pairs is left plain rather than guessed at")
func ambiguousLineIsLeftPlain() {
    // `*a* and *b*` wrapped naively would become one bold run spanning "and".
    let line = "*a* and *b*"
    let text = StandupClipboard.richText(from: line)

    #expect(text.string == line)
    #expect(traits(of: "and", in: text)?.contains(.bold) == false)
}

@MainActor
@Test("a bare delimiter pair is not treated as emphasis")
func emptyEmphasisIsPlain() {
    // Unreachable from `SlackMarkdown` — a section always has a title — but the
    // guard is what keeps `dropFirst().dropLast()` from running on two
    // characters.
    #expect(StandupClipboard.richText(from: "**").string == "**")
    #expect(StandupClipboard.richText(from: "*").string == "*")
}

@MainActor
@Test("a whole report keeps its line structure, with only the headings emphasised")
func wholeReportRoundTrips() {
    let markdown = """
        *Since last stand-up*
        • Fix flaky auth test (ENG-4)
            ◦ found the race in setUp

        *Blockers*
        _None_
        """

    let text = StandupClipboard.richText(from: markdown)

    // Structure preserved: same number of lines, blank line intact, bullets and
    // their indentation untouched.
    #expect(text.string.components(separatedBy: "\n").count == 6)
    #expect(text.string.contains("    ◦ found the race in setUp"))
    #expect(text.string.contains("\n\n"), "the blank line between sections survives")
    // Emphasis resolved, delimiters gone.
    #expect(!text.string.contains("*"))
    #expect(!text.string.contains("_"))
    #expect(traits(of: "Blockers", in: text)?.contains(.bold) == true)
    #expect(traits(of: "None", in: text)?.contains(.italic) == true)
    #expect(traits(of: "found the race", in: text)?.contains(.bold) == false)
}

@MainActor
@Test("the RTF flavour is produced and carries the bold run back out")
func rtfRoundTrips() throws {
    let data = try #require(StandupClipboard.rtf(from: "*Today*\n• Ship it"))
    #expect(!data.isEmpty)

    // Decode it the way a paste target would, rather than trusting that
    // generating bytes means generating *correct* bytes.
    let decoded = try #require(
        NSAttributedString(rtf: data, documentAttributes: nil))
    #expect(decoded.string.hasPrefix("Today"))
    #expect(!decoded.string.contains("*"))
    let font = decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
}

@MainActor
@Test("an empty draft produces empty rich text rather than failing")
func emptyDraftIsHandled() {
    #expect(StandupClipboard.richText(from: "").string.isEmpty)
}
