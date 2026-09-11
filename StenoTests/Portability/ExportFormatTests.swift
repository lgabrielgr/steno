import Foundation
import Testing

@testable import StenoKit

/// §10.2's format, asserted without a store: key order, byte stability, the
/// date strategies, and the user agent.
///
/// These need only an `ExportDocument`, so they pin the wire format
/// independently of anything that reads SwiftData.

/// An envelope with nothing in it, built by hand.
private func emptyDocument(exportedBy: String = "steno/test (macOS)") -> ExportDocument {
    ExportDocument(
        schemaVersion: ExportDocument.currentSchemaVersion,
        exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
        exportedBy: exportedBy,
        includesCachedExternalData: false,
        projects: [], tasks: [], events: [], sourceRefs: [], reports: [])
}

@Test("§10.2: top-level keys are emitted in a fixed, alphabetical order")
func topLevelKeysAreSorted() throws {
    let data = try ExportDocument.encoder().encode(emptyDocument())

    // Alphabetical, because `.sortedKeys` is the only thing that makes the
    // order deterministic: without it the keys come out in the encoding
    // dictionary's hash order, which differs between processes. Measured —
    // two runs of this suite produced two different orders before the option
    // was set. §10.2's example order is illustrative; JSON objects are
    // unordered, so nothing that reads the file depends on it.
    #expect(
        try ExportJSON.topLevelKeys(in: data) == [
            "events", "exportedAt", "exportedBy", "includesCachedExternalData",
            "projects", "reports", "schemaVersion", "sourceRefs", "tasks",
        ])
}

@Test("the same document encodes to the same bytes twice")
func encodingIsByteStable() throws {
    #expect(
        try ExportDocument.encoder().encode(emptyDocument())
            == (try ExportDocument.encoder().encode(emptyDocument())))
}

@Test("§10.2: timestamps are written with milliseconds")
func timestampsAreWrittenWithMilliseconds() throws {
    let data = try ExportDocument.encoder().encode(emptyDocument())

    #expect(try ExportJSON.text(of: data).contains("\"2023-11-14T22:13:20.000Z\""))
}

@Test("§10.2: a hand-edited whole-second timestamp still decodes")
func wholeSecondsStillDecode() throws {
    let json = """
        {
          "schemaVersion" : 1,
          "exportedAt" : "2026-08-10T14:22:05Z",
          "exportedBy" : "steno/1.0 (macOS)",
          "includesCachedExternalData" : false,
          "projects" : [],
          "tasks" : [],
          "events" : [],
          "sourceRefs" : [],
          "reports" : []
        }
        """

    let document = try ExportDocument.decoder()
        .decode(ExportDocument.self, from: Data(json.utf8))

    // §10.2 chose JSON so a file could be inspected — and edited — before
    // import. A person who retypes a timestamp without milliseconds should not
    // produce a file the app rejects.
    #expect(document.exportedAt == Date(timeIntervalSince1970: 1_786_371_725))
}

@Test("a timestamp that is not a date at all is rejected, not defaulted")
func aMalformedTimestampIsRejected() {
    let json = """
        {
          "schemaVersion" : 1,
          "exportedAt" : "last Tuesday",
          "exportedBy" : "steno/1.0 (macOS)",
          "includesCachedExternalData" : false,
          "projects" : [],
          "tasks" : [],
          "events" : [],
          "sourceRefs" : [],
          "reports" : []
        }
        """

    #expect(throws: DecodingError.self) {
        try ExportDocument.decoder().decode(ExportDocument.self, from: Data(json.utf8))
    }
}

@Test("the user agent falls back rather than trapping on a bundle with no version")
func theUserAgentFallsBack() {
    // `Bundle(for:)` here is the test bundle, which has no
    // CFBundleShortVersionString. Reading `Bundle.main` inline instead of
    // taking a parameter would put the xctest runner's version into every
    // envelope a test asserts on — and the assertion would pass anyway.
    let agent = ExportDocument.userAgent(bundle: Bundle(for: BundleMarker.self))

    #expect(agent.hasPrefix("steno/"))
    #expect(agent.hasSuffix(" (macOS)"))
}

/// A type whose only job is to name the test bundle for `Bundle(for:)`.
private final class BundleMarker {}
