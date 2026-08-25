import Foundation
import Testing

@testable import StenoKit

@Test("the adapter carries every field onto the SwiftData model")
func adapterCarriesFields() {
    let taskID = UUID()
    let extracted = ExtractedRef(
        kind: .githubPR, identifier: "acme/api#421",
        url: "https://github.com/acme/api/pull/421")

    let ref = extracted.sourceRef(taskID: taskID)

    #expect(ref.taskID == taskID)
    #expect(ref.kind == .githubPR)
    #expect(ref.identifier == "acme/api#421")
    #expect(ref.url == "https://github.com/acme/api/pull/421")
}

@Test("url defaults to nil, for a bare key with no link to attach")
func urlDefaultsToNil() {
    let extracted = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")

    #expect(extracted.url == nil)
    #expect(extracted.sourceRef(taskID: UUID()).url == nil)
}

@Test("dedupKey ignores url, so the same ref found twice collapses")
func dedupKeyIgnoresURL() {
    let bare = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")
    let linked = ExtractedRef(
        kind: .jiraIssue, identifier: "PAY-421",
        url: "https://acme.atlassian.net/browse/PAY-421")

    #expect(bare.dedupKey == linked.dedupKey)
    #expect(bare != linked)
}

@Test("dedupKey separates the same identifier under different kinds")
func dedupKeySeparatesKinds() {
    let issue = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")
    let link = ExtractedRef(kind: .url, identifier: "PAY-421")

    #expect(issue.dedupKey != link.dedupKey)
}
