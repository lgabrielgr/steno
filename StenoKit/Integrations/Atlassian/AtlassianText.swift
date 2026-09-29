import Foundation

/// Free text from a source, made safe to put in an event body (D-195, D-202).
///
/// **Two rules, and both are about the stand-up sheet rather than about Atlassian.**
/// A `SourceChange.text` becomes one line of a report a user reads aloud: a newline in
/// it silently becomes two lines, one of which has lost its subject, and an unbounded
/// one turns a stand-up into a paste of somebody's release notes.
///
/// Extracted from `AtlassianDocument`, which applied both to Jira comment bodies and
/// kept them private — so Confluence version messages, which are free text from the
/// same kind of box, arrived with neither. That is the shape D-202 exists to prevent,
/// found by asking which inputs the spec implies and no test covered.
enum AtlassianText {
    /// D-195's limit: enough to recognise what was said, short enough to read out.
    static let limit = 200

    /// `value` with its whitespace collapsed and its length bounded.
    static func gist(_ value: String, limit: Int = limit) -> String {
        truncate(collapse(value), to: limit)
    }

    /// Every run of whitespace — including newlines and tabs — becomes one space.
    static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `value` at most `limit` characters, cut on a word boundary with an ellipsis.
    ///
    /// The ellipsis is one character and counts toward the limit, so the result never
    /// exceeds it.
    static func truncate(_ value: String, to limit: Int) -> String {
        guard value.count > limit, limit > 1 else {
            return value.count > limit ? String(value.prefix(limit)) : value
        }

        let head = value.prefix(limit - 1)
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        let word = head[head.startIndex..<lastSpace]
        // A single word longer than the limit has no boundary to cut on, so the hard
        // cut is what is left.
        return word.isEmpty ? head + "…" : word + "…"
    }
}
