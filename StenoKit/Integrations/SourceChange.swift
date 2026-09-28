import Foundation

/// One discrete change a connector found, with the id that makes it
/// de-duplicable (D-186).
///
/// **The id is why this is not a `String`.** §5.2's `since` window is asked with
/// a deliberate overlap (D-185), so every pass re-reads items it has already
/// reported, and something must drop them. That something is
/// `SourceRefreshService`, which compares ids against what the event log says it
/// has already written — so the id has to survive the trip from the wire into a
/// payload and back.
public struct SourceChange: Sendable, Equatable {
    /// Stable within its ref and across launches: a Jira changelog `history.id`,
    /// a `comment.id`, a remote link's `id`.
    ///
    /// **Not a hash of `text`.** A comment edited after being reported would
    /// arrive as a new change, and a status flipped from In Review back to In
    /// Progress and forward again would collide with its own earlier entry.
    public let id: String

    /// What §3.3's event body says. Prose for a human, assembled by the
    /// connector, which is the only party that knows how to say it.
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Something about a connector's credential the user should know before it
/// breaks (§5.2's 14-day warning).
///
/// **A value the source layer owns, not a sentence.** `SourceNotice` composes the
/// wording, so the connector reports a fact and the one place that knows how the
/// stand-up sheet speaks does the phrasing (D-194). It also keeps the draft model
/// free of any notion of what Atlassian is.
public struct SourceCredentialWarning: Sendable, Equatable {
    /// The connector's `displayName`, so the sentence can name what to go and fix.
    public let displayName: String

    /// Days until the credential expires. **Negative once it already has**, which
    /// is a state the user can reach by ignoring the warning for two weeks, and
    /// the sentence says something different then.
    public let daysRemaining: Int

    /// Where the user goes to fix it.
    public let renewalURL: URL

    public init(displayName: String, daysRemaining: Int, renewalURL: URL) {
        self.displayName = displayName
        self.daysRemaining = daysRemaining
        self.renewalURL = renewalURL
    }
}
