import Foundation

/// Two ways to read export output, and the only two the tests need.
///
/// Separate from `ExportFixture` because reading bytes is not building a store:
/// these need no `ModelContainer` and no main actor, which is what lets
/// `ExportFormatTests` pin the wire format without touching SwiftData.
enum ExportJSON {
    /// The top-level keys **in emitted order**.
    ///
    /// Line-scanned rather than parsed, because `JSONSerialization` returns a
    /// dictionary and dictionaries have no order — the very property under
    /// test. Pretty-printed output indents top-level keys by exactly two
    /// spaces; a record's keys sit six deep inside their array, so the prefix
    /// is unambiguous. JSON strings never span lines, so no value can be
    /// mistaken for a key.
    static func topLevelKeys(in data: Data) throws -> [String] {
        try text(of: data)
            .split(separator: "\n")
            .compactMap { line in
                guard line.hasPrefix("  \"") else { return nil }
                return line.dropFirst(3).prefix { $0 != "\"" }.description
            }
    }

    /// The key set of the first element of a top-level array.
    static func recordKeys(_ array: String, in data: Data) throws -> Set<String> {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any],
            let items = object[array] as? [[String: Any]],
            let first = items.first
        else { throw ShapeError(detail: "no object in top-level array \"\(array)\"") }
        return Set(first.keys)
    }

    /// Export bytes as text.
    ///
    /// `String(bytes:encoding:)` rather than `String(decoding:as:)` because
    /// SwiftLint's `optional_data_string_conversion` rejects the latter: it
    /// substitutes replacement characters for invalid UTF-8 instead of failing,
    /// and a scan for credentials over silently-mangled text is not a scan.
    static func text(of data: Data) throws -> String {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ShapeError(detail: "export bytes are not valid UTF-8")
        }
        return text
    }

    struct ShapeError: Error { let detail: String }
}
