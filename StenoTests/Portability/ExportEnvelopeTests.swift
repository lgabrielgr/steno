import Foundation
import Testing

@testable import StenoKit

/// §10.2's envelope: the four scalar fields, the key order, and the empty store.

@MainActor
@Test("§10.2: the envelope carries schemaVersion, the clock, and the user agent")
func theEnvelopeCarriesItsScalars() throws {
    let fixture = try ExportFixture()

    let document = try fixture.encoder(nowOffset: 90, exportedBy: "steno/9.9.9 (macOS)")
        .snapshot()

    #expect(document.schemaVersion == 1)
    #expect(document.exportedAt == ExportFixture.at(90))
    #expect(document.exportedBy == "steno/9.9.9 (macOS)")
    #expect(document.includesCachedExternalData == false)
}

@MainActor
@Test("an empty store exports five empty arrays, not an error")
func anEmptyStoreExportsEmptyArrays() throws {
    let fixture = try ExportFixture()

    let data = try fixture.encoder().encode()
    let document = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    // M2.5-05 auto-exports on quit and defaults ON, so this is the first file a
    // new machine writes. It has to decode cleanly rather than be something
    // M2.5-02 later rejects.
    #expect(document.projects.isEmpty)
    #expect(document.tasks.isEmpty)
    #expect(document.events.isEmpty)
    #expect(document.sourceRefs.isEmpty)
    #expect(document.reports.isEmpty)
    #expect(document.schemaVersion == 1)
}

@MainActor
@Test("the exported JSON is indented and does not escape slashes in URLs")
func theOutputIsReadable() throws {
    let fixture = try ExportFixture()
    let project = try fixture.project("Payments")
    let task = try fixture.task("ship it", in: project)
    try fixture.ref("PAY-421", on: task, url: "https://acme.atlassian.net/browse/PAY-421")

    let text = try ExportJSON.text(of: try fixture.encoder().encode())

    #expect(text.contains("\n  \"schemaVersion\" : 1"))
    // Without `.withoutEscapingSlashes` this reads https:\/\/acme…, which
    // defeats grepping the file for a link — one of §10.2's three stated goals.
    #expect(text.contains("https://acme.atlassian.net/browse/PAY-421"))
    #expect(!text.contains("\\/"))
}
