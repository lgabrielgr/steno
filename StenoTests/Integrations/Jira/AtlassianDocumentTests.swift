import Foundation
import Testing

@testable import StenoKit

/// D-195: ADF, flattened to something a stand-up can say out loud.

private func node(_ value: [String: Any]) throws -> ADFNode {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(ADFNode.self, from: data)
}

@Test("a paragraph becomes its text")
func aParagraphBecomesItsText() throws {
    let body = try node(JiraFixture.adf("Could you add the migration plan?"))
    #expect(AtlassianDocument.plainText(body) == "Could you add the migration plan?")
}

@Test("two paragraphs are separated, not run together")
func twoParagraphsAreSeparated() throws {
    let body = try node([
        "type": "doc",
        "content": [
            ["type": "paragraph", "content": [["type": "text", "text": "Ship it."]]],
            ["type": "paragraph", "content": [["type": "text", "text": "Then tell Ana."]]],
        ],
    ])
    // Mutation: drop the block separator and this becomes "Ship it.Then tell Ana."
    #expect(AtlassianDocument.plainText(body) == "Ship it. Then tell Ana.")
}

@Test("a mention reads as the author typed it")
func aMentionReadsAsTyped() throws {
    let body = try node([
        "type": "doc",
        "content": [
            [
                "type": "paragraph",
                "content": [
                    ["type": "mention", "attrs": ["id": "557058:abc", "text": "@Leo"]],
                    ["type": "text", "text": " can you review?"],
                ],
            ]
        ],
    ])
    // The rendered form, not the account id: `557058:abc` in a stand-up is noise.
    #expect(AtlassianDocument.plainText(body) == "@Leo can you review?")
}

@Test("an inline card contributes its URL, which is often the PR")
func anInlineCardContributesItsURL() throws {
    let body = try node([
        "type": "doc",
        "content": [
            [
                "type": "paragraph",
                "content": [
                    ["type": "text", "text": "see "],
                    [
                        "type": "inlineCard",
                        "attrs": ["url": "https://github.com/acme/api/pull/421"],
                    ],
                ],
            ]
        ],
    ])
    #expect(
        AtlassianDocument.plainText(body) == "see https://github.com/acme/api/pull/421")
}

@Test("a hard break is a space")
func aHardBreakIsASpace() throws {
    let body = try node([
        "type": "doc",
        "content": [
            [
                "type": "paragraph",
                "content": [
                    ["type": "text", "text": "one"],
                    ["type": "hardBreak"],
                    ["type": "text", "text": "two"],
                ],
            ]
        ],
    ])
    #expect(AtlassianDocument.plainText(body) == "one two")
}

@Test("a nested list keeps its items in order")
func aNestedListKeepsOrder() throws {
    let body = try node([
        "type": "doc",
        "content": [
            [
                "type": "bulletList",
                "content": [
                    [
                        "type": "listItem",
                        "content": [
                            ["type": "paragraph", "content": [["type": "text", "text": "first"]]]
                        ],
                    ],
                    [
                        "type": "listItem",
                        "content": [
                            ["type": "paragraph", "content": [["type": "text", "text": "second"]]]
                        ],
                    ],
                ],
            ]
        ],
    ])
    #expect(AtlassianDocument.plainText(body) == "first second")
}

@Test("an unknown node type contributes its children rather than failing")
func anUnknownNodeRecurses() throws {
    // ADF grows. A node type added next year must cost a fragment of a sentence, not a
    // `.invalidResponse` for a ticket the user can see in their browser.
    let body = try node([
        "type": "doc",
        "content": [
            [
                "type": "somethingAtlassianAddedIn2027",
                "content": [["type": "text", "text": "still readable"]],
            ]
        ],
    ])
    #expect(AtlassianDocument.plainText(body) == "still readable")
}

@Test("a document with no text at all is empty, not a failure")
func anImageOnlyDocumentIsEmpty() throws {
    let body = try node([
        "type": "doc",
        "content": [
            ["type": "mediaSingle", "content": [["type": "media", "attrs": ["id": "x"]]]]
        ],
    ])
    // The caller reads this as "no gist" and says "comment from Ana" instead.
    #expect(AtlassianDocument.plainText(body).isEmpty)
}

@Test("a nil body is empty")
func aNilBodyIsEmpty() {
    #expect(AtlassianDocument.plainText(nil).isEmpty)
}

@Test("whitespace is collapsed")
func whitespaceIsCollapsed() throws {
    let body = try node(JiraFixture.adf("  lots   of\n\n space  "))
    #expect(AtlassianDocument.plainText(body) == "lots of space")
}

@Test("a long comment is cut on a word boundary")
func aLongCommentIsCutOnAWordBoundary() throws {
    let body = try node(JiraFixture.adf(String(repeating: "alpha beta ", count: 40)))
    let text = AtlassianDocument.plainText(body, limit: 24)

    #expect(text.count <= 24)
    #expect(text.hasSuffix("…"))
    // The boundary, not the middle of a word: "alpha bet…" reads as a bug.
    #expect(text == "alpha beta alpha beta…")
}

@Test("a single word longer than the limit is cut anyway")
func oneLongWordIsStillCut() throws {
    let body = try node(JiraFixture.adf(String(repeating: "x", count: 50)))
    let text = AtlassianDocument.plainText(body, limit: 10)
    // No boundary to cut on, so the hard cut is what is left — better than returning
    // fifty characters from a function whose caller asked for ten.
    #expect(text.count <= 10)
    #expect(text.hasSuffix("…"))
}

@Test("text shorter than the limit is untouched")
func shortTextIsUntouched() throws {
    let body = try node(JiraFixture.adf("short"))
    #expect(AtlassianDocument.plainText(body, limit: 200) == "short")
}
