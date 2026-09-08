/// D6: "Text formatted for copy → paste into Slack." The one place that
/// decision lives.
///
/// **Slack's `mrkdwn` has no heading syntax.** `## Since last stand-up` pastes
/// into Slack as a literal `##`, so a heading is `*bold*` alone on its line.
/// Bullets are the literal characters `•` and `◦` rather than `-`, because a
/// literal bullet character *is* a bullet in any paste target and does not
/// depend on Slack's composer choosing to convert a hyphen.
///
/// Takes `[ReportSection]` rather than a `GatheredWindow` so M3-03 can render
/// AI-authored bullets through this same function (§7.3: "Never ask the model
/// to format the final Slack text — formatting is the app's job, and
/// separating them makes output stable").
public enum SlackMarkdown {
    /// Two spaces short of the `◦`, so a wrapped detail hangs under its text.
    private static let continuationIndent = "      "

    /// The rendered report: sections in order, one blank line between them, no
    /// trailing newline.
    public static func render(_ sections: [ReportSection]) -> String {
        sections.map(block).joined(separator: "\n\n")
    }

    /// One heading and its bullets.
    ///
    /// **An empty section renders `_None_` rather than being dropped** (D-074).
    /// "No blockers" is a sentence people say at stand-ups, and dropping the
    /// heading throws away information the user wants to speak. It also means
    /// an empty *window* is not a special case at all — it is three headings
    /// that each say `_None_` — so the "honest and usable, not a crash or a
    /// blank string" criterion is met with no branch existing to get wrong.
    private static func block(_ section: ReportSection) -> String {
        let body =
            section.bullets.isEmpty
            ? ["_None_"]
            : section.bullets.flatMap(lines)
        return (["*\(section.title)*"] + body).joined(separator: "\n")
    }

    /// One bullet: its task line, then a `◦` line per detail.
    private static func lines(_ bullet: ReportBullet) -> [String] {
        ["• \(bullet.text)"] + bullet.details.flatMap(detail)
    }

    /// One detail, which may be several lines on screen.
    ///
    /// **`NoteService.addNote` trims only *outer* whitespace and
    /// `NoteComposerView` is a `TextEditor`, so a body can carry interior
    /// newlines.** Emitted naïvely, a note's second line would appear as an
    /// orphan outside any bullet, silently breaking the structure of a document
    /// the user is about to read aloud.
    ///
    /// The first line follows `◦ `; the rest hang beneath it. Every character
    /// the user typed survives — only leading indentation is added, which is
    /// layout, not editing.
    ///
    /// An interior blank line is emitted bare rather than as six spaces, so
    /// nothing persisted into `StandupReport.markdownBody` carries trailing
    /// whitespace.
    ///
    /// **Nothing is escaped, deliberately.** A body containing `*` or `_` will
    /// render with unintended emphasis in Slack. Backslash-escaping it would
    /// put characters on screen the user never typed — visible in M2-03's
    /// *editable* draft and persisted verbatim into `markdownBody` — and "appear
    /// verbatim as the user typed them" is an acceptance criterion of this
    /// task, where correct Slack emphasis is not. When the two conflict,
    /// verbatim wins.
    private static func detail(_ body: String) -> [String] {
        let split = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = split.first else { return [] }
        return ["    ◦ \(first)"]
            + split.dropFirst().map { $0.isEmpty ? "" : continuationIndent + $0 }
    }
}
