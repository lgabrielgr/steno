import Foundation

/// Scans text for the external references it mentions (REQUIREMENTS.md FR-1.5).
///
/// Pure: no I/O, no store, no clock, no configuration. Extraction is passive
/// and silent — there is no `@project`, no `#tag`, and no command grammar of
/// any kind, because the user explicitly declined one (FR-1.5, §1.1).
///
/// The parameter is `text`, not `title`: FR-1.5 runs extraction over task
/// titles *and* note bodies, and M1-06 calls this same entry point.
public enum ReferenceExtractor {
    private struct LinkSpan {
        let range: Range<String.Index>
        let link: URL
    }

    /// `NSDataDetector` is `Sendable`, so this needs no isolation. Built with
    /// `try?` rather than `try!`, which `make lint --strict` rejects; a test
    /// asserts it is non-nil, so a silent total failure cannot ship.
    static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func extract(from text: String) -> [ExtractedRef] {
        guard !text.isEmpty else { return [] }
        let spans = linkSpans(in: text)
        var found: [(start: String.Index, ref: ExtractedRef)] = spans.compactMap { span in
            guard isRefBearing(span.link) else { return nil }
            return (span.range.lowerBound, SourceURLClassifier.classify(span.link))
        }
        // A key overlapping a link is part of that link. This is what turns a
        // browse URL into one ref instead of two, and what stops a slug like
        // /reports/AWS-2024/q3 from manufacturing a ticket that never existed.
        for match in text.matches(of: JiraKey.pattern) {
            guard !spans.contains(where: { $0.range.overlaps(match.range) }) else { continue }
            found.append(
                (
                    match.range.lowerBound,
                    ExtractedRef(kind: .jiraIssue, identifier: String(text[match.range]))
                ))
        }
        found.sort { $0.start < $1.start }
        return merged(found.map(\.ref))
    }

    /// **Every** link the detector recognised, whatever its scheme.
    ///
    /// The `http(s)` filter belongs to `isRefBearing`, not here: a span this
    /// function dropped would be invisible to the overlap rule, and the key
    /// regex would read straight through it — `ping PAY-421@example.com` would
    /// yield a phantom ticket out of the interior of an email address.
    private static func linkSpans(in text: String) -> [LinkSpan] {
        guard let detector else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var spans: [LinkSpan] = []
        for match in detector.matches(in: text, range: whole) {
            guard let link = match.url, let range = Range(match.range, in: text) else { continue }
            spans.append(LinkSpan(range: range, link: link))
        }
        return spans
    }

    /// Only an `http(s)` link becomes a ref. The detector synthesises a
    /// `mailto:` link from a bare email address, and an email address is not a
    /// `SourceRef`; the same goes for `file:` and `ftp:`. Such a span still
    /// suppresses the keys inside it — see `linkSpans`.
    private static func isRefBearing(_ link: URL) -> Bool {
        guard let scheme = link.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Dedup within one pass, first occurrence winning the position.
    ///
    /// `url` is filled from the first occurrence that *has* one, so
    /// "PAY-421 — see <browse URL>" keeps the link. Taking the first
    /// occurrence wholesale would hand M4 a ref with nothing to fetch.
    ///
    /// Dedup *across* saves is not this function's job: `SourceRef.newRefs`
    /// does that, and M1-02 calls it with what the store already holds.
    private static func merged(_ refs: [ExtractedRef]) -> [ExtractedRef] {
        var order: [ExtractedRef.DedupKey] = []
        var byKey: [ExtractedRef.DedupKey: ExtractedRef] = [:]
        for ref in refs {
            guard let existing = byKey[ref.dedupKey] else {
                byKey[ref.dedupKey] = ref
                order.append(ref.dedupKey)
                continue
            }
            if existing.url == nil, ref.url != nil {
                byKey[ref.dedupKey] = ExtractedRef(
                    kind: existing.kind, identifier: existing.identifier, url: ref.url)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
