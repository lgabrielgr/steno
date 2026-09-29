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

    /// D-195's limit. Defined by `AtlassianText` now, so both connectors bound their
    /// free text at the same length.
    static let limit = AtlassianText.limit

    /// `node` as plain text, collapsed and truncated.
    ///
    /// Empty for a `nil` node or a document with no text in it — an image-only
    /// comment, say — which the caller treats as "no gist", not as a failure.
    static func plainText(_ node: ADFNode?, limit: Int = limit) -> String {
        guard let node else { return "" }
        // The collapse-and-truncate rules live in `AtlassianText` now: Confluence's
        // version messages are free text from the same kind of box and need both, and a
        // private copy here is how one caller got them and the other did not (D-202).
        return AtlassianText.gist(fragments(node).joined(), limit: limit)
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
}
