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
    /// §10.2's example showed whole seconds before this task amended it, which
    /// truncates. That is not cosmetic: §10.1 resolves three of its four merge
    /// rules by comparing timestamps, so two notes typed in the same second
    /// become a tie no rule can break and their order in the log is
    /// unrecoverable. REQUIREMENTS.md v1.16 carries the fractional example.
    ///
    /// **This style truncates at the millisecond.** `Date` is a `Double` of
    /// seconds, and at epoch 1.7e9 a decimal like `.481` is not representable —
    /// it is stored as `.4809999…`, which this style emits as `.480`. Nothing
    /// formats through it directly for that reason; every emitted timestamp
    /// goes through `wireString`, which corrects it to round-to-nearest.
    ///
    /// A `FormatStyle` rather than an `ISO8601DateFormatter`: the formatter is
    /// a non-`Sendable` class, so a shared instance is not expressible as a
    /// `static let` under Swift 6's concurrency checking, and a per-call
    /// instance is the allocation this path least wants.
    static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Half a millisecond, added before formatting so that truncation becomes
    /// round-to-nearest. Not a tunable — `wireString` is the only caller.
    private static let halfMillisecond: TimeInterval = 0.0005

    /// **The single implementation of what the file says an instant is.**
    ///
    /// Every emitted timestamp and every sort key goes through here, and that
    /// is not tidiness: D-092 records what happened the last time truncation
    /// had two implementations — they disagreed in the third decimal place at
    /// `.999`, and only a test written to compare them found it. Rounding makes
    /// that boundary live again, since `…20.9995` now carries to `…21.000`.
    ///
    /// **It rounds, and the half-millisecond is what makes it round.** The
    /// obvious reading — that truncation is harmless because the error is under
    /// a millisecond — misses the property M2.5-02 actually needs, which is
    /// that the format be a *fixed point*. It was not: parsing `…20.481Z` gives
    /// a `Double` of `.4809999…`, which truncates back out as `…20.480Z`. So a
    /// value moved every time it crossed a file. Measured over every
    /// millisecond value at four epochs from 2020 to 2033: **496 of 1000
    /// unstable** under truncation, walking backwards up to 2 ms over at most
    /// two hops before sticking; **0 of 4000** unstable once rounded, and 0 of
    /// 50000 for clock-shaped dates. Two things rested on that fixed point —
    /// §10.6's "importing the same file twice changes nothing", and §10.2's
    /// promise that two exports of an unchanged store are byte-identical, which
    /// is what makes M2.5-05's auto-export a history rather than churn.
    ///
    /// A round-trip is therefore accurate to within 0.5 ms in either direction,
    /// and **exact** only when the fractional second is an **eighth** — `0`,
    /// `.125`, `.25`, `.375`, `.5`, `.625`, `.75`, `.875` — the only values both
    /// exactly representable in binary and exactly expressible in three
    /// decimals. Not every dyadic value: `.0625` is dyadic and still emits
    /// `.062`, because the added half-millisecond lands just below `.063` at
    /// this magnitude. Behaviour at an exact half-millisecond input is
    /// deterministic but not predictable by arithmetic, which is why the
    /// stability figures above were measured rather than derived.
    ///
    /// M2.5-02's "the object graph is identical" means identical at this
    /// precision; an `==` on a clock date there fails in a way that looks like
    /// a merge bug. See D-091 and D-101.
    static func wireString(_ date: Date) -> String {
        date.addingTimeInterval(halfMillisecond).formatted(fractionalSeconds)
    }

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
            try container.encode(wireString(date))
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
