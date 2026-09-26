import Foundation
import Testing

@testable import StenoKit

/// §3.3's `externalUpdate` body and payload.

@Test("D-169: the first observation of a ref reports its summary")
func theFirstObservationSpeaks() {
    let body = ExternalUpdateBody.text(
        identifier: "PAY-421", summary: "In Review, assigned to Dana", changes: [],
        isFirstObservation: true)

    #expect(body == "PAY-421: In Review, assigned to Dana")
}

@Test("a later fetch with no changes says nothing")
func noChangesIsSilent() {
    let body = ExternalUpdateBody.text(
        identifier: "PAY-421", summary: "In Review", changes: [], isFirstObservation: false)

    #expect(body == nil)
}

@Test("§3.3: a later fetch reports its changes, not its summary")
func changesAreWhatGetsReported() {
    let body = ExternalUpdateBody.text(
        identifier: "PAY-421", summary: "In Review",
        changes: ["moved to In Review", "2 new comments"], isFirstObservation: false)

    // The summary is deliberately absent: §3.3's example body is the change
    // ("PAY-421 moved to In Review; 2 new comments"), and a bullet restating
    // current state on every fetch is what makes a log unreadable.
    #expect(body == "PAY-421: moved to In Review; 2 new comments")
}

@Test("blank content is dropped on both paths")
func blankContentSaysNothing() {
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "   ", changes: [], isFirstObservation: true) == nil)
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "In Review", changes: ["", "  "],
            isFirstObservation: false) == nil)
    // A blank among real changes is dropped without taking the event with it.
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "In Review", changes: ["", "reopened"],
            isFirstObservation: false) == "PAY-421: reopened")
}

/// A fixed id, so the byte assertion below is a constant a reader can check.
private let refID = UUID(uuidString: "0BC7A3A0-0000-4000-8000-000000000001") ?? UUID()

@Test("the payload round-trips")
func thePayloadRoundTrips() throws {
    let payload = ExternalUpdatePayload(
        refID: refID,
        kind: .jiraIssue, identifier: "PAY-421", changes: ["moved to In Review"],
        url: "https://example.atlassian.net/browse/PAY-421",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let decoded = try #require(ExternalUpdatePayload.decoded(from: payload.encoded()))

    #expect(decoded == payload)
}

@Test("D-174: the payload's keys are sorted, so an unchanged store re-exports byte-identically")
func thePayloadsKeysAreSorted() throws {
    // **The fixture is built so this test can fail.** `Codable` emits keys in a
    // per-process hash order, so an assertion that merely round-tripped would
    // pass with `.sortedKeys` removed. Asserting the exact bytes fails whenever
    // the order is anything but sorted — which is nearly every run — and the
    // declaration order here (refID, kind, identifier, changes, url, fetchedAt)
    // is not the sorted order (changes, fetchedAt, identifier, kind, refID, url),
    // so a formatter that preserved declaration order also fails.
    let payload = ExternalUpdatePayload(
        refID: refID,
        kind: .jiraIssue, identifier: "PAY-421", changes: ["reopened"],
        url: "https://example.atlassian.net/browse/PAY-421",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let encoded = try #require(payload.encoded())
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(
        json == """
            {"changes":["reopened"],"fetchedAt":"2023-11-14T22:13:20Z",\
            "identifier":"PAY-421","kind":"jiraIssue",\
            "refID":"0BC7A3A0-0000-4000-8000-000000000001",\
            "url":"https:\\/\\/example.atlassian.net\\/browse\\/PAY-421"}
            """)
}

@Test("a row carrying no payload decodes to nil rather than throwing")
func anAbsentPayloadIsNil() {
    #expect(ExternalUpdatePayload.decoded(from: nil) == nil)
    #expect(ExternalUpdatePayload.decoded(from: Data("not json".utf8)) == nil)
}
