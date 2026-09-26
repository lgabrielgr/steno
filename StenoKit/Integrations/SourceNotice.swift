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
            let age = staleness(oldestFetch: outcome.oldestFetch, now: now)
            let reach = "Couldn't reach \(failure.displayName)"
            return age.map { "\(reach) — using \($0) data." } ?? "\(reach) — no cached data yet."
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
