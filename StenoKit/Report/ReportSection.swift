/// One heading and its bullets, as a report is structured before it is
/// formatted (§7.3, D6).
///
/// **This type is §7.3's split expressed as an interface.** "The app renders
/// markdown from whichever structure came back. Never ask the model to format
/// the final Slack text — formatting is the app's job, and separating them
/// makes output stable." `RawReportSections` produces these from a gathered
/// window with no AI involved; M3-03 produces them from schema-validated AI
/// bullets. Both hand them to the same `SlackMarkdown.render`.
///
/// A `GatheredWindow -> String` renderer would have left M3-03 with nothing to
/// reuse: at the point it renders it holds bullets, not a window, so it would
/// have had to duplicate the emitter or fabricate a window to feed it.
public struct ReportSection: Sendable, Equatable {
    /// The heading, already in its cadence's wording (FR-4, D17).
    public let title: String

    /// May be empty. `SlackMarkdown` renders an empty section rather than
    /// dropping it — "no blockers" is a sentence people say at stand-ups.
    public let bullets: [ReportBullet]

    public init(title: String, bullets: [ReportBullet]) {
        self.title = title
        self.bullets = bullets
    }
}

/// One task's line, plus the user's own words beneath it.
public struct ReportBullet: Sendable, Equatable {
    /// The task line: its title, plus any ticket keys.
    public let text: String

    /// Verbatim user-authored lines beneath `text`, oldest first.
    ///
    /// **Named `details`, not `notes`,** because a blocked task's first detail
    /// is its `blockedReason`, which §3.3 lists as a separate kind from `note`.
    ///
    /// **May be empty, and that is not a defect.** A task moved to `done` with
    /// nothing written about it has nothing to say — D-072 excludes the
    /// machine-authored `created` and `statusChanged` bodies — and D-068
    /// already admits quiet in-progress tasks for the same reason.
    ///
    /// Defaulted because M3-03 builds these from AI bullets, which carry one
    /// line of text and no children.
    public let details: [String]

    public init(text: String, details: [String] = []) {
        self.text = text
        self.details = details
    }
}
