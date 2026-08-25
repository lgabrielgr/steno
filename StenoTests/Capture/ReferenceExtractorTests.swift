import Foundation
import Testing

@testable import StenoKit

private struct ExtractCase: CustomTestStringConvertible {
    let name: String
    let text: String
    let expected: [ExtractedRef]

    var testDescription: String { name }
}

private let browseURL = "https://acme.atlassian.net/browse/PAY-421"

private let extractCases: [ExtractCase] = [
    .init(
        name: "a bare key",
        text: "PAY-421",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(
        name: "a key inside a sentence",
        text: "Fixed the retry bug in PAY-421 this morning",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(
        name: "multiple keys in one line, in text order",
        text: "PAY-421 and INFRA-7 both landed",
        expected: [
            .init(kind: .jiraIssue, identifier: "PAY-421"),
            .init(kind: .jiraIssue, identifier: "INFRA-7"),
        ]),
    .init(
        name: "a key at string start and a key at string end",
        text: "PAY-421 is blocked by INFRA-7",
        expected: [
            .init(kind: .jiraIssue, identifier: "PAY-421"),
            .init(kind: .jiraIssue, identifier: "INFRA-7"),
        ]),
    .init(name: "a lowercase key does not match", text: "pay-421 is not a key", expected: []),
    .init(
        name: "a hyphenated non-key word does not match",
        text: "a well-known trade-off, state-of-the-art",
        expected: []),
    .init(
        name: "a bare URL",
        text: "notes at https://example.com/a/b",
        expected: [
            .init(kind: .url, identifier: "https://example.com/a/b", url: "https://example.com/a/b")
        ]),
    .init(
        name: "a GitHub PR URL",
        text: "https://github.com/acme/api/pull/421",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "https://github.com/acme/api/pull/421")
        ]),
    .init(
        name: "a Confluence URL",
        text: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook",
        expected: [
            .init(
                kind: .confluencePage, identifier: "1712834",
                url: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook")
        ]),
    .init(
        name: "a browse URL and its bare key yield one ref carrying the link",
        text: "Fixed PAY-421, see \(browseURL)",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421", url: browseURL)]),
    .init(
        name: "a key inside another host's URL is part of that URL, not a ticket",
        text: "https://github.com/acme/api/tree/PAY-421-fix",
        expected: [
            .init(
                kind: .url, identifier: "https://github.com/acme/api/tree/PAY-421-fix",
                url: "https://github.com/acme/api/tree/PAY-421-fix")
        ]),
    .init(
        name: "a slug shaped like a key does not become a phantom ticket",
        text: "See https://ex.com/reports/AWS-2024/q3",
        expected: [
            .init(
                kind: .url, identifier: "https://ex.com/reports/AWS-2024/q3",
                url: "https://ex.com/reports/AWS-2024/q3")
        ]),
    .init(
        name: "the same key twice yields one ref",
        text: "PAY-421 blocked, still PAY-421",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(name: "an email address is not a reference", text: "ping bob@example.com", expected: []),
    .init(
        name: "a scheme-less PR URL still classifies",
        text: "see github.com/acme/api/pull/421 please",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "http://github.com/acme/api/pull/421")
        ]),
    .init(
        name: "two PRs with the same number in different repos stay two refs",
        text: "https://github.com/acme/api/pull/421 and https://github.com/acme/web/pull/421",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "https://github.com/acme/api/pull/421"),
            .init(
                kind: .githubPR, identifier: "acme/web#421",
                url: "https://github.com/acme/web/pull/421"),
        ]),
    .init(
        name: "a bare key followed by its link keeps the link",
        text: "PAY-421 — see \(browseURL)",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421", url: browseURL)]),
    .init(
        name: "trailing punctuation is not part of the URL",
        text: "see https://example.com/a/b.",
        expected: [
            .init(kind: .url, identifier: "https://example.com/a/b", url: "https://example.com/a/b")
        ]),
    .init(
        name: "a 10-character prefix matches", text: "ABCDEFGHIJ-9 matches",
        expected: [
            .init(kind: .jiraIssue, identifier: "ABCDEFGHIJ-9")
        ]),
    .init(name: "an 11-character prefix does not", text: "ABCDEFGHIJK-9 does not", expected: []),
    .init(name: "empty input", text: "", expected: []),
    .init(name: "whitespace-only input", text: "   \n  ", expected: []),
]

@Test("FR-1.5 extraction", arguments: extractCases)
private func extracts(testCase: ExtractCase) {
    #expect(ReferenceExtractor.extract(from: testCase.text) == testCase.expected)
}

@Test("keys and URLs interleave in first-occurrence order")
private func ordersByFirstOccurrence() {
    let text = "PAY-421 then https://example.com/a then INFRA-7"

    let refs = ReferenceExtractor.extract(from: text)

    #expect(refs.map(\.identifier) == ["PAY-421", "https://example.com/a", "INFRA-7"])
}

@Test("extraction is pure: the same input gives the same output")
private func isPure() {
    let text = "PAY-421 and \(browseURL) and https://github.com/acme/api/pull/421"

    #expect(ReferenceExtractor.extract(from: text) == ReferenceExtractor.extract(from: text))
}

@Test("the link detector is available, so URL refs are not silently lost")
private func detectorIsAvailable() {
    #expect(ReferenceExtractor.detector != nil)
}
