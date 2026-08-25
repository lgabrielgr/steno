import Foundation

/// Turns one link into the reference it points at (REQUIREMENTS.md §3.4).
///
/// Classification is by **path shape, not hostname**: a self-hosted
/// `jira.corp.net/browse/PAY-421` is as much a Jira issue as an Atlassian
/// one, and the extractor cannot read the user's configured hosts without
/// ceasing to be the pure function FR-1.5 requires. GitHub is the single host
/// check, because `/<a>/<b>/pull/<n>` alone is too generic to claim.
public enum SourceURLClassifier {
    /// Always returns a ref: an unrecognised link is a `.url`, identified by
    /// itself. Order matters only in that the fallback comes last.
    public static func classify(_ link: URL) -> ExtractedRef {
        let absolute = link.absoluteString
        let segments = link.pathComponents.filter { $0 != "/" }
        if let identifier = jiraKeyPath(segments) {
            return ExtractedRef(kind: .jiraIssue, identifier: identifier, url: absolute)
        }
        if let identifier = githubPullRequest(link, segments) {
            return ExtractedRef(kind: .githubPR, identifier: identifier, url: absolute)
        }
        if let identifier = confluencePageID(link, segments) {
            return ExtractedRef(kind: .confluencePage, identifier: identifier, url: absolute)
        }
        return ExtractedRef(kind: .url, identifier: absolute, url: absolute)
    }

    /// A non-empty all-ASCII-digit string, or nil. Both Confluence forms and
    /// the PR number funnel through this so "empty is not a number" is decided
    /// once.
    ///
    /// ASCII is checked explicitly because `isNumber` covers the whole Unicode
    /// Number category, and both callers reach decoded text: `pathComponents`
    /// percent-decodes, so `/pages/%C2%BD/` yields `½`, and `queryItems`
    /// decodes `?pageId=١٢٣`. Either would classify as a page whose ID no
    /// connector could ever fetch.
    private static func digits(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return value
    }

    private static func jiraKeyPath(_ segments: [String]) -> String? {
        guard let index = segments.firstIndex(of: "browse"), index + 1 < segments.count else {
            return nil
        }
        let candidate = segments[index + 1]
        guard candidate.wholeMatch(of: JiraKey.pattern) != nil else { return nil }
        return candidate
    }

    /// Repo-qualified per §3.4 (v1.10, D-022): a bare PR number collides
    /// across repositories under the `(taskID, kind, identifier)` dedup rule.
    /// Trailing segments (`/files`, a fragment) are ignored, so the same PR
    /// linked at different depths yields one identifier.
    private static func githubPullRequest(_ link: URL, _ segments: [String]) -> String? {
        let host = link.host()?.lowercased()
        guard host == "github.com" || host == "www.github.com" else { return nil }
        guard segments.count >= 4, segments[2] == "pull" else { return nil }
        guard let number = digits(segments[3]) else { return nil }
        return "\(segments[0])/\(segments[1])#\(number)"
    }

    /// A page with no numeric ID (the legacy `/display/SPACE/Title` form)
    /// deliberately returns nil and falls back to `.url`: §3.4 says the
    /// identifier *is* the page ID, and M4-03 needs one to fetch.
    ///
    /// **Known false positives, accepted deliberately:** no host check, so any
    /// `?pageId=<digits>` or `/pages/<digits>/` URL is claimed —
    /// `https://example.com/pages/12/34` becomes `.confluencePage "12"`. That
    /// is the price of classifying by shape rather than hostname, which is
    /// what lets a self-hosted wiki work at all; the cost is one stray ref
    /// card, and FR-1.4 routes on nothing this produces.
    private static func confluencePageID(_ link: URL, _ segments: [String]) -> String? {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryValue = items.first { $0.name == "pageId" }?.value
        if let pageID = digits(queryValue) {
            return pageID
        }
        guard let index = segments.firstIndex(of: "pages"), index + 1 < segments.count else {
            return nil
        }
        return digits(segments[index + 1])
    }
}
