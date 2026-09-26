import Foundation

/// §5.2's "clearly labeled as stale", as one sentence for the stand-up sheet
/// (D-176).
///
/// **App-side only.** `SlackMarkdown`'s output, the clipboard, and
/// `StandupReport.markdownBody` are untouched: the label exists so the user knows
/// how much to trust the draft before reading it aloud, and the audience of a
/// stand-up does not need fetch timestamps. A line injected into the markdown
/// would travel to Slack on most reports, because the launch pass runs on a
/// 30-minute rule.
///
/// Pure, and given `now` rather than reading a clock, so every wording is
/// assertable without waiting.
public enum SourceNotice {
    /// A day, for the "how old" wording. Not a calendar computation: the sentence
    /// is a warning, not a date, and `Calendar` here would make the string depend
    /// on the machine's locale and time zone for no gain the reader can see.
    private static let day: TimeInterval = 24 * 60 * 60

    /// What the sheet should say about `outcome`, or `nil` when there is nothing
    /// worth saying.
    ///
    /// Three facts can each produce a sentence, in priority order: a fetch that
    /// failed, an integration that is not set up, and data that is simply old.
    /// **Only one is shown.** A banner listing three complaints about a report the
    /// user is about to read aloud is one they will stop reading; the failure is
    /// the most actionable of the three, so it wins.
    ///
    /// A pass that fetched everything cleanly returns `nil` — silence is the
    /// correct label for data that is current.
    public static func text(for outcome: RefreshOutcome, now: Date) -> String? {
        if outcome.saveFailed {
            return "Fetched updates couldn't be saved. This draft uses your last saved data."
        }

        if let failure = outcome.failures.first {
            return "\(cause(failure)) — \(fallback(for: failure, now: now))."
        }

        if outcome.notConfigured > 0 {
            return "Some references have no integration set up yet."
        }

        if outcome.readFailed {
            return "Couldn't check your integrations for this draft."
        }

        // Nothing failed, so anything still old was not in scope for this pass —
        // a ref on a done task, say. Worth saying only once it is a day behind:
        // below that, "data from 20 minutes ago" is noise about a report whose
        // window is a day wide.
        guard let age = staleness(oldestFetch: outcome.oldestFetch, now: now),
            outcome.oldestFetch.map({ now.timeIntervalSince($0) >= day }) == true
        else { return nil }
        return "Some integration data is \(age)."
    }

    /// What went wrong with `failure`, in the user's terms.
    ///
    /// **Switches on the error rather than saying "couldn't reach" for all of
    /// them.** D-165 separates `.invalidCredential` and `.notFound` from `.network`
    /// precisely so a bad credential or a mistyped ticket key does not send the
    /// user to check their wifi — and then this sentence undid that by labelling
    /// every failure a reachability problem. `SourceError.errorDescription` already
    /// carries the actionable wording; only the two genuinely-unreachable cases
    /// get the connector's name attached, because that is when naming it helps.
    /// Raised by Copilot in review of PR #42.
    private static func cause(_ failure: RefreshOutcome.Failure) -> String {
        switch failure.error {
        case .network, .timedOut:
            return "Couldn't reach \(failure.displayName)"
        case .notConfigured, .invalidCredential, .notFound, .rateLimited, .unavailable,
            .invalidResponse:
            // The connector's name still leads, so the user knows which
            // integration to go and fix, but the sentence is the error's own.
            let detail = failure.error.errorDescription ?? "Something went wrong"
            return "\(failure.displayName): \(detail.trimmingSuffix("."))"
        }
    }

    /// What the draft falls back on for the ref that failed.
    ///
    /// Reads `failure.cachedAt`, not the outcome's `oldestFetch`: the second is the
    /// minimum across every ref in scope, so attributing it to the connector that
    /// failed can state something false — see `RefreshOutcome.Failure.cachedAt`.
    private static func fallback(for failure: RefreshOutcome.Failure, now: Date) -> String {
        staleness(oldestFetch: failure.cachedAt, now: now)
            .map { "using \($0) data" } ?? "no cached data yet"
    }

    /// "2 days old", "today's", or `nil` when nothing has ever been fetched.
    private static func staleness(oldestFetch: Date?, now: Date) -> String? {
        guard let oldestFetch else { return nil }
        let days = Int(now.timeIntervalSince(oldestFetch) / day)
        switch days {
        case ..<1: return "today's"
        case 1: return "1 day old"
        default: return "\(days) days old"
        }
    }
}

extension String {
    /// `self` without a trailing period, so one can be added by the sentence that
    /// composes it without producing "…data..".
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
