import Foundation

/// §10.2's envelope: the whole store as one JSON document.
///
/// **Property order is not the emitted key order** — `encoder()` sets
/// `.sortedKeys` and the file is alphabetical. Synthesized `Codable` writes
/// into a dictionary, so without that option the key order is the dictionary's
/// hash order, which differs *between processes*: two exports of an unchanged
/// store produce byte-different files. That defeats the diffability §10.2 asks
/// for and turns M2.5-05's auto-export history into churn, and no single test
/// run can see it. Measured, not assumed — see `ExportEnvelopeTests`.
///
/// The cost is that §10.2's example key order is illustrative only; the
/// document's keys are alphabetical, so `schemaVersion` is not first. JSON
/// objects are unordered by definition, so nothing that reads this file cares.
///
/// `Codable` in both directions, and deliberately: M2.5-02 decodes these exact
/// types. Two declarations of one wire format drift, and the drift is a field
/// silently lost — with sync cancelled (§10, D1) there is no second copy to
/// recover it from.
public struct ExportDocument: Codable, Equatable, Sendable {
    /// The version M2.5-02 checks before applying anything (§10.2).
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let exportedBy: String
    public let includesCachedExternalData: Bool
    public let projects: [ExportedProject]
    public let tasks: [ExportedTask]
    public let events: [ExportedEvent]
    public let sourceRefs: [ExportedSourceRef]
    public let reports: [ExportedReport]
}

extension ExportDocument {
    /// ISO-8601 at millisecond precision — `2026-08-10T09:14:02.481Z`.
    ///
    /// §10.2's example shows whole seconds, which truncates. That is not
    /// cosmetic: §10.1 resolves three of its four merge rules by comparing
    /// timestamps, so two notes typed in the same second become a tie no rule
    /// can break and their order in the log is unrecoverable. REQUIREMENTS.md
    /// v1.16 amends the example to match this.
    ///
    /// **Formatting truncates at the millisecond; it does not round.** `Date`
    /// is a `Double` of seconds, and at epoch 1.7e9 a decimal like `.481` is
    /// not representable — it is stored as `.4809999…` and emitted as `.480`.
    /// A round-trip is therefore accurate to within 1 ms and exact only when
    /// the fractional second is a dyadic value (`0`, `.125`, `.25`, `.5`, …).
    /// Measured, not assumed. M2.5-02's "the object graph is identical" means
    /// identical at that precision, and an `==` on a clock date there would
    /// fail in a way that looks like a merge bug.
    ///
    /// A `FormatStyle` rather than an `ISO8601DateFormatter`: the formatter is
    /// a non-`Sendable` class, so a shared instance is not expressible as a
    /// `static let` under Swift 6's concurrency checking, and a per-call
    /// instance is the allocation this path least wants.
    static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The same format without the fractional part, accepted on **decode only**.
    ///
    /// §10.2 chose JSON so a file could be inspected — and edited — by hand
    /// before import. A person who retypes a timestamp without milliseconds
    /// should not produce a file the app rejects. Nothing encodes through this.
    static let wholeSeconds = Date.ISO8601FormatStyle()

    /// The encoder §10.2's format rules describe.
    ///
    /// `.sortedKeys` is what makes the output deterministic at all — see the
    /// type's note. `.withoutEscapingSlashes` is not cosmetic either: without
    /// it a `SourceRef.url` exports as `https:\/\/…`, which defeats grepping
    /// the file for a link, one of the three properties §10.2 asks for by name.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractionalSeconds))
        }
        return encoder
    }

    /// The matching decoder. M2.5-02 reads files through this.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: fractionalSeconds) { return date }
            guard let date = try? Date(text, strategy: wholeSeconds) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "expected an ISO-8601 timestamp, got \"\(text)\"")
            }
            return date
        }
        return decoder
    }

    /// §10.2's `exportedBy` — `steno/0.1.0 (macOS)`.
    ///
    /// **Take the bundle as a parameter; never read `Bundle.main` inline.** The
    /// test bundle is unhosted (D-010), so `Bundle.main` there is the xctest
    /// runner: a version read at the point of use would put the runner's
    /// version into every envelope a test asserts on, and the assertion would
    /// pass anyway.
    public static func userAgent(bundle: Bundle = .main) -> String {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        return "steno/\(version ?? "unknown") (macOS)"
    }
}
