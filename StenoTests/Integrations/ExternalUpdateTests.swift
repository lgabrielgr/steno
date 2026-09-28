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
        changes: .texts("moved to In Review", "2 new comments"), isFirstObservation: false)

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
            identifier: "PAY-421", summary: "In Review", changes: .texts("", "  "),
            isFirstObservation: false) == nil)
    // A blank among real changes is dropped without taking the event with it.
    #expect(
        ExternalUpdateBody.text(
            identifier: "PAY-421", summary: "In Review", changes: .texts("", "reopened"),
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

// MARK: - The watermark fields (D-184)

@Test("the payload round-trips with its watermark, change ids and link set")
func thePayloadRoundTripsWithItsWatermark() throws {
    let payload = ExternalUpdatePayload(
        refID: refID, kind: .jiraIssue, identifier: "PAY-421", changes: ["moved to In Review"],
        url: nil, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        watermark: Date(timeIntervalSince1970: 1_699_999_000),
        changeIDs: ["10001#status", "9001"], presentIDs: ["L1"])

    let decoded = try #require(ExternalUpdatePayload.decoded(from: payload.encoded()))

    #expect(decoded == payload)
    #expect(decoded.watermark == Date(timeIntervalSince1970: 1_699_999_000))
    #expect(decoded.changeIDs == ["10001#status", "9001"])
    #expect(decoded.presentIDs == ["L1"])
}

@Test("a payload written before M4-02 still decodes, with no watermark")
func apreM4PayloadStillDecodes() throws {
    // The reason all three fields are optional: rows already in a user's store carry
    // none of them, and a decode that failed would make every earlier `externalUpdate`
    // unreadable — which is a resume point that never resumes.
    let json = """
        {"changes":["reopened"],"fetchedAt":"2023-11-14T22:13:20Z",\
        "identifier":"PAY-421","kind":"jiraIssue",\
        "refID":"0BC7A3A0-0000-4000-8000-000000000001"}
        """
    let decoded = try #require(ExternalUpdatePayload.decoded(from: Data(json.utf8)))

    #expect(decoded.watermark == nil)
    #expect(decoded.changeIDs == nil)
    #expect(decoded.presentIDs == nil)
}

@Test("every declared property reaches the JSON when it has a value")
func everyDeclaredPropertyIsEncoded() throws {
    // **A `Mirror`, not a list of keys.** An optional encoded with `encodeIfPresent`
    // omits its key when nil, which is intended — but it also means a *new* field can be
    // added and silently never written, and a hand-kept list of expected keys is exactly
    // the thing that stops being updated. This walks the declarations instead.
    let payload = ExternalUpdatePayload(
        refID: refID, kind: .jiraIssue, identifier: "PAY-421", changes: ["reopened"],
        url: "https://example.atlassian.net/browse/PAY-421",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        watermark: Date(timeIntervalSince1970: 1_699_999_000),
        changeIDs: ["c1"], presentIDs: ["L1"], windowCapped: true)

    let encoded = try #require(payload.encoded())
    let json = try #require(String(data: encoded, encoding: .utf8))

    for child in Mirror(reflecting: payload).children {
        let name = try #require(child.label)
        #expect(json.contains("\"\(name)\""), "\(name) never reached the payload JSON")
    }
}

@Test("the sorted-key order still holds with the new fields in place")
func thesortedOrderHoldsWithTheNewFields() throws {
    // D-174 again, now that there are nine keys: `Event.payload` is exported as base64
    // and kept byte-exact, so an unchanged store must re-export identically.
    let payload = ExternalUpdatePayload(
        refID: refID, kind: .jiraIssue, identifier: "PAY-421", changes: [], url: nil,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        watermark: Date(timeIntervalSince1970: 1_699_999_000),
        changeIDs: ["c1"], presentIDs: ["L1"])

    let encoded = try #require(payload.encoded())
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(
        json == """
            {"changeIDs":["c1"],"changes":[],"fetchedAt":"2023-11-14T22:13:20Z",\
            "identifier":"PAY-421","kind":"jiraIssue","presentIDs":["L1"],\
            "refID":"0BC7A3A0-0000-4000-8000-000000000001",\
            "watermark":"2023-11-14T21:56:40Z"}
            """)
}
