import Foundation

/// Atlassian Document Format, flattened to something a stand-up can say out loud
/// (D-195).
///
/// **Why flatten at all.** REST v3 returns comment bodies as ADF JSON. The
/// alternatives were reporting only "a new comment", which sends the user to a
/// browser mid-stand-up, and asking for `expand=renderedBody`, which returns HTML —
/// strictly more parsing to recover text this document already holds structurally.
///
/// Pure, with no clock and no network, so every node shape is a table test.
enum AtlassianDocument {
    /// How much of a comment reaches the event body.
    ///
    /// A gist, not the comment: the event body is one line of a stand-up draft, and
    /// §3.3's log is not a copy of Jira. Truncation is on a word boundary, because a
    /// sentence cut mid-word reads as a bug rather than as a summary.
    static let limit = 200

    /// `node` as plain text, collapsed and truncated.
    ///
    /// Empty for a `nil` node or a document with no text in it — an image-only
    /// comment, say — which the caller treats as "no gist", not as a failure.
    static func plainText(_ node: ADFNode?, limit: Int = limit) -> String {
        guard let node else { return "" }
        let collapsed = collapse(fragments(node).joined())
        return truncate(collapsed, to: limit)
    }

    /// The text fragments of one node, in reading order.
    ///
    /// Inline nodes contribute their own text; block nodes contribute their children
    /// followed by a space, which is what keeps two paragraphs from becoming one
    /// run-together word. `collapse` tidies the resulting whitespace, so this
    /// function never has to decide whether a separator is needed twice.
    private static func fragments(_ node: ADFNode) -> [String] {
        switch node.type {
        case "text":
            return [node.text ?? ""]
        case "hardBreak":
            return [" "]
        case "mention":
            // The rendered form, `@Ana`, which is what the author typed and what the
            // reader recognises. An account id would be useless in a stand-up.
            return [node.attrs?.text ?? ""]
        case "emoji":
            return [node.attrs?.text ?? node.attrs?.shortName ?? ""]
        case "inlineCard":
            // Often the PR link the stand-up is about.
            return [node.attrs?.url ?? ""]
        default:
            // **Unknown nodes recurse rather than fail** (D-195). ADF grows; a node
            // type added next year must cost a fragment, not a `.invalidResponse` for
            // a ticket the user can see in their browser.
            let children = (node.content ?? []).flatMap(fragments)
            return children.isEmpty ? [] : children + [" "]
        }
    }

    /// Runs of whitespace to single spaces, trimmed.
    private static func collapse(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `value` at most `limit` characters, cut on a word boundary with an ellipsis.
    ///
    /// The ellipsis is one character and counts toward the limit, so the result never
    /// exceeds what the caller asked for.
    private static func truncate(_ value: String, to limit: Int) -> String {
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
