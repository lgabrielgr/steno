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

        do {
            return try ExportDocument.decoder().decode(ExportDocument.self, from: data)
        } catch {
            throw ImportError.malformed(detail: detail(of: error))
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
