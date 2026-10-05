import Foundation

/// §5.2's "clearly labeled as stale", as one sentence for the stand-up sheet
/// (D-176) — and, since M4-02, the one place §5.2's token wording lives (D-193).
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
/// The one thing a notice can offer to do.
///
/// **Top-level rather than nested inside `Message`**, which would be two levels of
/// nesting and is the kind of depth that makes a type hard to name at a call site.
public struct SourceNoticeAction: Sendable, Equatable {
    public let label: String
    public let url: URL

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

public enum SourceNotice {
    /// A day, for the "how old" wording. Not a calendar computation: the sentence
    /// is a warning, not a date, and `Calendar` here would make the string depend
    /// on the machine's locale and time zone for no gain the reader can see.
    private static let day: TimeInterval = 24 * 60 * 60

    /// One sentence, and at most one thing to click.
    ///
    /// **The link is why this is no longer a `String`** (D-193). §5.2 requires a
    /// 401 to carry "a direct link", and a URL rendered as text in a `Label` is not
    /// a link — the user would have to retype it, during stand-up prep, which is
    /// the moment §5.2 is written about.
    public struct Message: Sendable, Equatable {
        public let text: String

        /// Rendered beside the sentence when present. **`nil` for every sentence
        /// but the two about an expiring credential**: a banner where each
        /// complaint is also a button is a banner the user stops reading (FR-5's
        /// reasoning).
        public let action: SourceNoticeAction?

        public init(_ text: String, action: SourceNoticeAction? = nil) {
            self.text = text
            self.action = action
        }
    }

    /// What the sheet should say about `outcome`, or `nil` when there is nothing
    /// worth saying.
    ///
    /// Five facts can each produce a sentence, in priority order: a fetch that
    /// failed, a credential about to expire, an integration that is not set up, a
    /// read that failed, and data that is simply old. **Only one is shown.** A
    /// banner listing three complaints about a report the user is about to read
    /// aloud is one they will stop reading.
    ///
    /// **A failure outranks an expiry warning** (D-194): the first is already
    /// breaking, the second is a calendar. An expired-token 401 therefore wins with
    /// its own wording and its own link, which is what §5.2 asks for.
    ///
    /// A pass that fetched everything cleanly returns `nil` — silence is the
    /// correct label for data that is current.
    public static func message(for outcome: RefreshOutcome, now: Date) -> Message? {
        if outcome.saveFailed {
            return Message(
                "Fetched updates couldn't be saved. This draft uses your last saved data.")
        }

        if let failure = outcome.failures.first {
            return message(for: failure, now: now)
        }

        if let warning = outcome.credentialWarnings.first {
            return message(for: warning)
        }

        if outcome.notConfigured > 0 {
            return Message("Some references have no integration set up yet.")
        }

        if outcome.readFailed {
            return Message("Couldn't check your integrations for this draft.")
        }

        // Nothing failed, so anything still old was not in scope for this pass —
        // a ref on a done task, say. Worth saying only once it is a day behind:
        // below that, "data from 20 minutes ago" is noise about a report whose
        // window is a day wide.
        guard let age = staleness(oldestFetch: outcome.oldestFetch, now: now),
            outcome.oldestFetch.map({ now.timeIntervalSince($0) >= day }) == true
        else { return nil }
        return Message("Some integration data is \(age).")
    }

    /// The sentence for a fetch that failed.
    ///
    /// **`.credentialExpired` is composed here rather than from
    /// `errorDescription`** (D-193). The generic composition would read "Jira: Your
    /// token expired or was revoked. Create a new one — using today's data", which
    /// puts an instruction in the middle of a sentence about staleness. §5.2's
    /// requirement is that this case be unmistakable, so it gets its own shape and
    /// the link it demands.
    private static func message(for failure: RefreshOutcome.Failure, now: Date) -> Message {
        let fallbackText = fallback(for: failure, now: now)

        if failure.error == .credentialExpired {
            return Message(
                "\(failure.displayName): your token expired or was revoked — \(fallbackText).",
                action: failure.renewalURL.map {
                    SourceNoticeAction(label: "Create a new token", url: $0)
                })
        }

        if failure.error == .siteNotFound {
            // **Its own shape, for `.credentialExpired`'s reason** (D-217). Composed
            // through `cause`, the remedy landed after the staleness clause and the
            // sentence carried two em-dashes: "Jira's site address looks wrong —
            // check it in Settings — using today's data". The remedy goes last, and
            // there is no action button because the fix is a field in this app, not
            // a page on the web.
            return Message(
                "\(failure.displayName)'s site address looks wrong — \(fallbackText). "
                    + "Check it in Settings.")
        }

        return Message("\(cause(failure)) — \(fallbackText).")
    }

    /// The sentence for a credential that is about to expire (§5.2's 14-day
    /// warning, D-194).
    ///
    /// **Not a date.** "Expires 2027-03-01" asks the reader to do arithmetic in the
    /// ninety seconds before their stand-up; "expires in 9 days" is the fact they
    /// act on. The negative case is reachable — a user can ignore this for two
    /// weeks — and says something different, because by then the fetches are
    /// already failing.
    private static func message(for warning: SourceCredentialWarning) -> Message {
        let text: String
        switch warning.daysRemaining {
        case ..<0:
            text = "Your \(warning.displayName) token has expired."
        case 0:
            text = "Your \(warning.displayName) token expires today."
        case 1:
            text = "Your \(warning.displayName) token expires tomorrow."
        default:
            text = "Your \(warning.displayName) token expires in \(warning.daysRemaining) days."
        }
        return Message(
            text, action: SourceNoticeAction(label: "Create a new token", url: warning.renewalURL))
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
        case .siteNotFound:
            // Never arrives here — `message(for:now:)` gives it its own shape, the
            // way it does `.credentialExpired` — and is listed rather than defaulted
            // so that adding the *next* error case is still a compile error.
            return "\(failure.displayName)'s site address looks wrong"
        case .notConfigured, .invalidCredential, .credentialExpired, .notFound, .rateLimited,
            .unavailable, .invalidResponse:
            // The connector's name still leads, so the user knows which
            // integration to go and fix, but the sentence is the error's own.
            // `.credentialExpired` never arrives here — `message(for:now:)` gives it
            // its own shape — and is listed rather than defaulted so that adding the
            // *next* error case is still a compile error.
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
