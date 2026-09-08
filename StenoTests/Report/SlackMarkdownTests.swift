import Testing

@testable import StenoKit

@Test("D6: a heading is bold mrkdwn, because Slack has no heading syntax")
func aSectionRendersItsTitleInBold() {
    let markdown = SlackMarkdown.render([
        ReportSection(title: "Today", bullets: [ReportBullet(text: "Rate limiter (PAY-388)")])
    ])

    // Asserted as the whole string rather than with `contains`, so a stray
    // leading blank line or trailing newline fails here.
    #expect(markdown == "*Today*\n• Rate limiter (PAY-388)")
}

@Test("A detail hangs under its bullet")
func detailsRenderAsIndentedSubBullets() {
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Since last stand-up",
            bullets: [
                ReportBullet(text: "Flaky auth test", details: ["was a race", "PR merged"])
            ])
    ])

    #expect(
        markdown == """
            *Since last stand-up*
            • Flaky auth test
                ◦ was a race
                ◦ PR merged
            """)
}

@Test("D-074: an empty section says so rather than disappearing")
func anEmptySectionRendersNone() {
    let markdown = SlackMarkdown.render([ReportSection(title: "Blockers", bullets: [])])

    // "No blockers" is a sentence people say at stand-ups; dropping the
    // heading throws away something the user wants to speak.
    #expect(markdown == "*Blockers*\n_None_")
}

@Test("An empty window is three headings, not a blank string")
func anEmptyWindowRendersHonestly() {
    // Literal sections rather than a window, so this file tests emission and
    // nothing else. That RawReportSections yields three empty sections from an
    // empty window is asserted where that mapping lives.
    let markdown = SlackMarkdown.render([
        ReportSection(title: "Since last stand-up", bullets: []),
        ReportSection(title: "Today", bullets: []),
        ReportSection(title: "Blockers", bullets: []),
    ])

    #expect(
        markdown == """
            *Since last stand-up*
            _None_

            *Today*
            _None_

            *Blockers*
            _None_
            """)
}

@Test("A multi-line note keeps every line, hanging under the first")
func aMultiLineDetailIndentsItsContinuationLines() {
    // NoteService trims only outer whitespace and NoteComposerView is a
    // TextEditor, so this body is reachable from the UI. Rendered naïvely the
    // second line would escape its bullet entirely.
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Today",
            bullets: [ReportBullet(text: "Migration", details: ["step one\nstep two"])])
    ])

    #expect(
        markdown == """
            *Today*
            • Migration
                ◦ step one
                  step two
            """)
}

@Test("A blank line inside a note carries no trailing whitespace")
func anInteriorBlankLineIsEmittedBare() {
    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Today",
            bullets: [ReportBullet(text: "Migration", details: ["one\n\ntwo"])])
    ])

    // The middle line must be empty, not six spaces — this text is persisted
    // into StandupReport.markdownBody.
    #expect(
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) == [
            "*Today*", "• Migration", "    ◦ one", "", "      two",
        ])
}

@Test("§7.3 verbatim: nothing in a body is escaped or rewritten")
func bodiesAreEmittedVerbatim() {
    // Every class of string §7.3 names: a ticket key, a function name, an
    // error string, and mrkdwn metacharacters the user typed on purpose.
    let body = "fixed the flaky auth test in TokenRefresher.refresh(): `EOF *before* _end_`"

    let markdown = SlackMarkdown.render([
        ReportSection(
            title: "Since last stand-up",
            bullets: [ReportBullet(text: "Auth (PAY-412)", details: [body])])
    ])

    #expect(markdown.hasSuffix("    ◦ " + body))
}

@Test("Sections are separated by exactly one blank line")
func sectionsAreJoinedByASingleBlankLine() {
    let markdown = SlackMarkdown.render([
        ReportSection(title: "One", bullets: [ReportBullet(text: "a")]),
        ReportSection(title: "Two", bullets: [ReportBullet(text: "b")]),
    ])

    #expect(markdown == "*One*\n• a\n\n*Two*\n• b")
    #expect(!markdown.hasSuffix("\n"))
}
