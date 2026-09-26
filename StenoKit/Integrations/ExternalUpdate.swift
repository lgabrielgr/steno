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
        changes: [String],
        isFirstObservation: Bool
    ) -> String? {
        if isFirstObservation {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(identifier): \(trimmed)"
        }

        let stated =
            changes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
