import Foundation
import Testing

@testable import StenoKit

private struct ClassifyCase: CustomTestStringConvertible {
    let link: String
    let kind: SourceRefKind
    let identifier: String

    var testDescription: String { "\(link) → \(kind.rawValue) \(identifier)" }
}

private let classifyCases: [ClassifyCase] = [
    // Jira: any host, because a self-hosted instance is still Jira
    .init(
        link: "https://acme.atlassian.net/browse/PAY-421", kind: .jiraIssue,
        identifier: "PAY-421"),
    .init(link: "https://jira.corp.net/browse/PAY-421", kind: .jiraIssue, identifier: "PAY-421"),
    // GitHub: host-anchored, repo-qualified identifier (§3.4 v1.10, D-022)
    .init(
        link: "https://github.com/acme/api/pull/421", kind: .githubPR,
        identifier: "acme/api#421"),
    .init(
        link: "https://github.com/acme/web/pull/421", kind: .githubPR,
        identifier: "acme/web#421"),
    .init(
        link: "https://github.com/acme/api/pull/421/files#diff-abc123", kind: .githubPR,
        identifier: "acme/api#421"),
    // Confluence: both URL shapes, identifier is the numeric page ID
    .init(
        link: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook",
        kind: .confluencePage, identifier: "1712834"),
    .init(
        link: "https://acme.atlassian.net/pages/viewpage.action?pageId=1712834",
        kind: .confluencePage, identifier: "1712834"),
]

@Test("each shape maps to its kind and identifier", arguments: classifyCases)
private func classifiesByShape(testCase: ClassifyCase) throws {
    let link = try #require(URL(string: testCase.link))

    let ref = SourceURLClassifier.classify(link)

    #expect(ref.kind == testCase.kind)
    #expect(ref.identifier == testCase.identifier)
    #expect(ref.url == testCase.link)
}

private let fallbackCases: [String] = [
    // No numeric page ID to use as an identifier, so not a confluencePage
    "https://acme.atlassian.net/display/ENG/Runbook",
    "https://acme.atlassian.net/wiki/pages/overview",
    "https://acme.atlassian.net/x?pageId=",
    // Not a PR path
    "https://github.com/acme/api/tree/PAY-421-fix",
    // Right shape, wrong host — /a/b/pull/n is too generic to claim
    "https://gitlab.example.com/acme/api/pull/421",
    // /browse/ segment that is not a ticket key
    "https://shop.example.com/browse/shoes",
    "https://example.com/a/b",
]

@Test("anything unrecognised is a plain url, identified by itself", arguments: fallbackCases)
private func fallsBackToURL(raw: String) throws {
    let link = try #require(URL(string: raw))

    let ref = SourceURLClassifier.classify(link)

    #expect(ref.kind == .url)
    #expect(ref.identifier == raw)
    #expect(ref.url == raw)
}

@Test("the FR-1.5 pattern is used verbatim")
private func patternIsVerbatim() {
    #expect("PAY-421".wholeMatch(of: JiraKey.pattern) != nil)
    #expect("ABCDEFGHIJ-9".wholeMatch(of: JiraKey.pattern) != nil)
    #expect("ABCDEFGHIJK-9".wholeMatch(of: JiraKey.pattern) == nil)
    #expect("pay-421".wholeMatch(of: JiraKey.pattern) == nil)
    #expect("A-1".wholeMatch(of: JiraKey.pattern) == nil)
    // Known false positives — FR-1.5's regex is used as written (spec §7)
    #expect("UTF-8".wholeMatch(of: JiraKey.pattern) != nil)
}
