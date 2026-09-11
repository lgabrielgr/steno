import Foundation

/// Bytes to a document, with §10.2's version gate in front of the full decode.
enum ImportReader {
    /// Just enough of the envelope to answer "can this build read it at all?".
    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// - Throws: `ImportError.malformed` or `.unsupportedSchemaVersion`. Nothing
    ///   here touches a `ModelContext`, which is the strongest form of §10.4's
    ///   "a malformed file leaves the store untouched" — not a rollback, but an
    ///   absence of any write.
    static func read(_ data: Data) throws -> ExportDocument {
        // **The version is checked before the full decode, deliberately.** A
        // file written by a newer Steno may carry keys and enum cases this build
        // cannot represent, and decoding it first would refuse it with a
        // field-level complaint — "unknown key `integrations`" — where §10.2 asks
        // for a clear message about the version.
        let probe: VersionProbe
        do {
            probe = try JSONDecoder().decode(VersionProbe.self, from: data)
        } catch {
            // Truncated files land here: a file cut in half is not "an unknown
            // version", and saying so would send the user looking for an update
            // that does not exist.
            throw ImportError.malformed(detail: detail(of: error))
        }

        guard probe.schemaVersion == ExportDocument.currentSchemaVersion else {
            throw ImportError.unsupportedSchemaVersion(
                found: probe.schemaVersion, supported: ExportDocument.currentSchemaVersion)
        }

        let document: ExportDocument
        do {
            document = try ExportDocument.decoder().decode(ExportDocument.self, from: data)
        } catch {
            throw ImportError.malformed(detail: detail(of: error))
        }

        try validateShape(of: document)
        return document
    }

    /// Structural checks the `Codable` decode cannot make.
    ///
    /// **Both of these were process-terminating or silently lossy before.** The
    /// merge indexes records by `id` and the applier pairs the two cached ref
    /// fields; a hand-edited file that breaks either assumption reached code
    /// that had no way to refuse it. §10.4 requires a clean rejection, and a
    /// trap is not one.
    private static func validateShape(of document: ExportDocument) throws {
        try requireUniqueIDs(document.projects.map(\.id), in: "projects")
        try requireUniqueIDs(document.tasks.map(\.id), in: "tasks")
        try requireUniqueIDs(document.events.map(\.id), in: "events")
        try requireUniqueIDs(document.sourceRefs.map(\.id), in: "sourceRefs")
        try requireUniqueIDs(document.reports.map(\.id), in: "reports")

        // §10.2 writes `lastFetchedAt` and `cachedSummary` together or omits
        // both, and `SourceRef.recordFetch` cannot produce any other state. A
        // summary with no timestamp was previously accepted and then dropped on
        // the floor, because the applier only records a fetch when it has a date
        // to record it at — data loss with no message.
        for ref in document.sourceRefs where ref.cachedSummary != nil && ref.lastFetchedAt == nil {
            throw ImportError.malformed(
                detail:
                    "The reference to \(ref.identifier) has a cached summary but no fetch time; "
                    + "§10.2 writes those two together or not at all.")
        }
    }

    private static func requireUniqueIDs(_ ids: [UUID], in array: String) throws {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            throw ImportError.malformed(
                detail: "Two records in \(array) share the id \(id).")
        }
    }

    /// A `DecodingError` rendered as something a person can act on.
    ///
    /// The coding path is carried because §10.2 chose a format people edit by
    /// hand: "events[47].timestamp" is what turns a refusal into a fix.
    private static func detail(of error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decoding {
        case .dataCorrupted(let context):
            return described(context, fallback: "The file isn't valid JSON.")
        case .keyNotFound(let key, let context):
            return described(context, fallback: "A required field is missing: \(key.stringValue).")
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return described(context, fallback: "A field has the wrong type.")
        @unknown default:
            return "The file could not be read."
        }
    }

    private static func described(_ context: DecodingError.Context, fallback: String) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let location = path.isEmpty ? "" : " (at \(path))"
        let reason = context.debugDescription.isEmpty ? fallback : context.debugDescription
        return reason + location
    }
}
