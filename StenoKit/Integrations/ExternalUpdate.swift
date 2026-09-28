import Foundation

/// What a found change says on an `Event` (§3.3, D-169).
///
/// Pure, and its own type, so "when is an event due" is one testable expression
/// rather than a condition spread through `SourceRefreshService`'s apply loop.
public enum ExternalUpdateBody {
    /// The body for one fetch, or `nil` when there is nothing to report.
    ///
    /// **The first observation of a ref is an event** (D-169). §3.3 says
    /// `externalUpdate` is appended when a fetch "finds a change", and read
    /// strictly the first fetch finds none — but external state reaches a report
    /// only through these events (D-168), so suppressing the first one leaves the
    /// first stand-up after enabling an integration with nothing from it, which
    /// reads as a broken integration.
    ///
    /// Later fetches speak only when `changes` is non-empty. That is what keeps
    /// the log free of rows saying a ticket has not moved.
    ///
    /// Blank strings are dropped on both paths: a connector answering with
    /// whitespace has said nothing, and `"PAY-421: "` in a stand-up is worse
    /// than silence (D-152's rule, one layer down).
    public static func text(
        identifier: String,
        summary: String,
        changes: [SourceChange],
        isFirstObservation: Bool
    ) -> String? {
        if isFirstObservation {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(identifier): \(trimmed)"
        }

        let stated =
            changes
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return stated.isEmpty ? nil : "\(identifier): \(stated.joined(separator: "; "))"
    }
}

/// §3.3's `payload` for an `externalUpdate` event: "JSON blob for structured
/// external data".
///
/// Nothing reads it yet. It is written because the body is prose assembled for a
/// human — a later feature that wants the discrete changes, the resource's
/// canonical URL, or the connector's own fetch timestamp cannot recover them
/// from that sentence, and an event is append-only, so a payload not written now
/// is not recoverable later either.
struct ExternalUpdatePayload: Codable, Equatable {
    let refID: UUID
    let kind: SourceRefKind
    let identifier: String
    let changes: [String]
    let url: String?

    /// The connector's own timestamp, kept here rather than on the row (D-171).
    let fetchedAt: Date

    /// **The watermark, and the reason M4-02 needed no schema change** (D-184).
    ///
    /// The newest item timestamp this event reported. `SourceRefreshService` reads
    /// it back from the newest payloads for a ref and computes the next `since`
    /// from it, so the window is anchored on what the source confirmed it served
    /// rather than on our own clock — which is the defect D-183 left open.
    ///
    /// **Why here rather than on `SourceRef`**: a row field would need a §3.4
    /// amendment, a §10.1 merge rule, and a §10.2 decision about export — and
    /// cached external data is excluded from an export by default, so a
    /// row-based watermark would reset on the machine you import onto and report
    /// a ticket's whole recent history as news. Events always export. §10.1
    /// already says a field recomputable from the log should be.
    ///
    /// Optional because a payload written before M4-02 carries none, and because
    /// a connector may have no anchor to report.
    let watermark: Date?

    /// Stable source ids of the items reported in *this* event — the dedup key
    /// (D-186). Optional for the reason `watermark` is.
    let changeIDs: [String]?

    /// The complete set of state-item ids observed at this fetch, **not a delta**
    /// (D-187). Remote links carry no timestamp, so "what is new" is this set
    /// minus the previous one, and that only works if the whole set is recorded
    /// every time.
    let presentIDs: [String]?

    /// `true` when the fetch that wrote this event stopped short of its whole window, which makes
    /// `watermark` a floor rather than a high-water mark (D-184, revised in review round 6).
    ///
    /// Written as `nil` rather than `false` in the ordinary case, so a payload's bytes are
    /// unchanged for every fetch that read its whole window — §10.2 keeps `Event.payload`
    /// byte-exact, and a key that appears on every row is a key in every diff.
    let windowCapped: Bool?

    /// **Written out rather than synthesized, so the three M4-02 fields can
    /// default.** They are optional because a payload written before M4-02 carries
    /// none; making every call site say `watermark: nil` would spread that fact over
    /// the tests instead of keeping it here.
    init(
        refID: UUID,
        kind: SourceRefKind,
        identifier: String,
        changes: [String],
        url: String?,
        fetchedAt: Date,
        watermark: Date? = nil,
        changeIDs: [String]? = nil,
        presentIDs: [String]? = nil,
        windowCapped: Bool? = nil
    ) {
        self.refID = refID
        self.kind = kind
        self.identifier = identifier
        self.changes = changes
        self.url = url
        self.fetchedAt = fetchedAt
        self.watermark = watermark
        self.changeIDs = changeIDs
        self.presentIDs = presentIDs
        self.windowCapped = windowCapped
    }

    /// **`.sortedKeys`, and it is load-bearing** (D-174). `Event.payload` is
    /// exported as base64 and `ExportRecords` keeps it byte-exact by design;
    /// Swift's `Codable` emits keys in an internal dictionary order that differs
    /// between processes, so without this two exports of an unchanged store are
    /// byte-different files. That is the defect v1.16 and D-090 already fixed
    /// once at the envelope level. `StandupReportedPayload` gets away with a bare
    /// encoder because it has one key; this has six.
    ///
    /// **`.iso8601` for the same reason it is not the default.** `Date`'s default
    /// strategy is a `Double` of seconds since 2001, which round-trips but is
    /// unreadable in a diff of the one file §10.2 promises is diffable.
    ///
    /// `nil` rather than `throws`: a payload that cannot be encoded must not
    /// abort a pass whose cache write is fine, following
    /// `StandupReportedPayload.encoded()`. The cost of a missing payload is a
    /// diagnostic, not a report.
    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    /// Decode a payload written by `encoded()`. `nil` for a row that carries
    /// none, which is every event of every other kind.
    static func decoded(from data: Data?) -> Self? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }
}
