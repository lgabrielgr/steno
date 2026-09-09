import AppKit
import Foundation

/// D6's clipboard write: the report as **rich text**, with the markdown as a
/// plain-text fallback.
///
/// **Slack's composer converts `*bold*` as you type, not when you paste.** So
/// markup arriving on the clipboard stays literal, and a heading emitted as
/// `*Today*` reaches the channel as `*Today*` — which is what shipping M2-03
/// proved in use. D-073 already reached the right conclusion for bullets and
/// chose the literal `•` and `◦` characters, "because a literal bullet
/// character *is* a bullet in any paste target and does not depend on Slack's
/// composer choosing to convert a hyphen". Headings then went and depended on
/// exactly that. This type applies D-073's reasoning to emphasis: bold that is
/// actually bold, rather than characters asking the reader's client to make it
/// bold.
///
/// **Both flavours go on the pasteboard**, richest first. Anything that
/// understands RTF gets real emphasis; anything that does not gets the markdown
/// unchanged, so pasting into a plain-text field is no worse than before.
/// `StandupReport.markdownBody` keeps storing the markdown — M2-04's undo and
/// §10's export read that, and neither wants a document format.
public enum StandupClipboard {
    /// The default `copy` seam for `StandupService`. Composes the conversion
    /// with the pasteboard write so `SystemClipboard` stays a dumb wrapper and
    /// this file stays the only place that knows the dialect.
    @MainActor
    @discardableResult
    public static func write(_ markdown: String) -> Bool {
        SystemClipboard.write(markdown, rtf: rtf(from: markdown))
    }

    /// `markdown` as RTF, or `nil` if the conversion fails.
    ///
    /// `nil` rather than `throws`: a failure here costs emphasis, and
    /// `SystemClipboard` then writes the plain flavour alone. Losing bold is not
    /// worth refusing a stand-up over.
    public static func rtf(from markdown: String) -> Data? {
        let text = richText(from: markdown)
        return text.rtf(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// `markdown` with `SlackMarkdown`'s two emphasis constructs resolved into
    /// real attributes.
    ///
    /// **One rule, and it is whole-line only:** a line that is entirely wrapped
    /// in `*` becomes bold, a line entirely wrapped in `_` becomes italic, and
    /// the delimiters are dropped. Those are exactly what `SlackMarkdown`
    /// emits — a section heading and D-074's `_None_` — so this resolves the
    /// app's own markup and nothing else.
    ///
    /// **Inline emphasis inside a note body is deliberately left alone.** D-073
    /// decided that a body containing `*` or `_` is passed through verbatim
    /// rather than escaped, because "appear verbatim as the user typed them" is
    /// an acceptance criterion and correct Slack emphasis is not. Treating an
    /// interior `*` as markup here would quietly overturn that decision in the
    /// one place the user cannot see it happening. A line carrying more than one
    /// delimiter pair is therefore left plain, not guessed at.
    public static func richText(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, line) in markdown.components(separatedBy: "\n").enumerated() {
            if offset > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            }
            result.append(attributedLine(line))
        }
        return result
    }

    private static func attributedLine(_ line: String) -> NSAttributedString {
        if let inner = unwrapped(line, delimiter: "*") {
            return NSAttributedString(string: inner, attributes: [.font: boldFont])
        }
        if let inner = unwrapped(line, delimiter: "_") {
            return NSAttributedString(string: inner, attributes: [.font: italicFont])
        }
        return NSAttributedString(string: line, attributes: [.font: bodyFont])
    }

    /// `line` without its wrapping `delimiter`, or `nil` if it is not cleanly
    /// wrapped in exactly one pair.
    ///
    /// Rejects a line whose interior carries the delimiter again, so
    /// `*a* and *b*` stays plain rather than becoming one bold run spanning the
    /// words between them.
    private static func unwrapped(_ line: String, delimiter: Character) -> String? {
        guard line.count >= 3, line.first == delimiter, line.last == delimiter else { return nil }
        let inner = line.dropFirst().dropLast()
        guard !inner.contains(delimiter) else { return nil }
        return String(inner)
    }

    /// The system font at its default size, so the paste target sees ordinary
    /// body text. Slack substitutes its own font and keeps the traits, which is
    /// the whole point — the traits are what this file exists to carry.
    private static var bodyFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    private static var boldFont: NSFont { .boldSystemFont(ofSize: NSFont.systemFontSize) }

    private static var italicFont: NSFont {
        let base = bodyFont
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}
