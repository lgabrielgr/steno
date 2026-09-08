import Testing

@testable import StenoKit

/// One realistic window, rendered under both cadences.
///
/// Covers all four statuses, a task with two ticket keys' worth of structure, a
/// task with no keys, machine-authored events that must not appear, a quiet
/// blocked task whose reason lives outside the window (D-069), and a `.todo`
/// task the two cadences file differently.
private func goldenTasks() -> [GatheredTask] {
    [
        SectionInput.task(
            "Flaky auth test on checkout", status: .done, ticketKeys: ["PAY-412"],
            events: [
                SectionInput.event("Task created", kind: .created),
                SectionInput.event("was a race in TokenRefresher, not the test"),
                SectionInput.event("To Do → In Progress", kind: .statusChanged),
                SectionInput.event("PR merged after review"),
            ]),
        SectionInput.task(
            "Bump pg driver to 15.4", status: .done,
            events: [SectionInput.event("In Progress → Done", kind: .statusChanged)]),
        SectionInput.task(
            "Rate limiter tuning", status: .inProgress, ticketKeys: ["PAY-388"],
            events: [SectionInput.event("dropped the window to 30s")]),
        SectionInput.task(
            "Spike: cache warming", status: .todo,
            events: [SectionInput.event("read the redis docs, not obviously worth it")]),
        // The reason is present both as an in-window event and on
        // blockedReason, which is what StatusService.addBlockedReason actually
        // produces for a task blocked since the last stand-up. The expected
        // output below says it exactly once; that it did not change when this
        // event was added is the assertion.
        SectionInput.task(
            "Webhook replay", status: .blocked, ticketKeys: ["PAY-401"],
            blockedReason: "waiting on infra for the DLQ credentials",
            events: [
                SectionInput.event(
                    "waiting on infra for the DLQ credentials", kind: .blockedReason)
            ]),
    ]
}

private func goldenMarkdown(_ cadence: ReportCadence) -> String {
    SlackMarkdown.render(
        RawReportSections.build(from: SectionInput.window(cadence, goldenTasks())))
}

@Test("FR-4 + D6: a daily window renders its whole report")
func aDailyWindowRendersItsGoldenMarkdown() {
    // Rate limiter tuning appears twice — with its note above, and as a bare
    // title under Today. That is the daily mapping's whole claim.
    #expect(
        goldenMarkdown(.daily) == """
            *Since last stand-up*
            • Flaky auth test on checkout (PAY-412)
                ◦ was a race in TokenRefresher, not the test
                ◦ PR merged after review
            • Bump pg driver to 15.4
            • Rate limiter tuning (PAY-388)
                ◦ dropped the window to 30s
            • Spike: cache warming
                ◦ read the redis docs, not obviously worth it

            *Today*
            • Rate limiter tuning (PAY-388)

            *Blockers*
            • Webhook replay (PAY-401)
                ◦ waiting on infra for the DLQ credentials
            """)
}

@Test("D17 + D6: the same window renders differently under periodic cadence")
func aPeriodicWindowRendersItsGoldenMarkdown() {
    // Same tasks, same words, different filing: nothing appears twice, and the
    // todo spike sits under In flight rather than alongside completed work.
    #expect(
        goldenMarkdown(.periodic) == """
            *Completed*
            • Flaky auth test on checkout (PAY-412)
                ◦ was a race in TokenRefresher, not the test
                ◦ PR merged after review
            • Bump pg driver to 15.4

            *In flight*
            • Rate limiter tuning (PAY-388)
                ◦ dropped the window to 30s
            • Spike: cache warming
                ◦ read the redis docs, not obviously worth it

            *Blockers & risks*
            • Webhook replay (PAY-401)
                ◦ waiting on infra for the DLQ credentials
            """)
}

@Test("D17: the two cadences do not merely rename each other's headings")
func theTwoCadencesDisagreeOnMoreThanTitles() {
    // Stripping the headings leaves different documents, so a future
    // "simplification" that maps periodic onto daily's sections fails here
    // rather than passing both golden tests with swapped titles.
    let bulletsOnly = { (markdown: String) in
        markdown.split(separator: "\n").filter { !$0.hasPrefix("*") }
    }

    #expect(bulletsOnly(goldenMarkdown(.daily)) != bulletsOnly(goldenMarkdown(.periodic)))
}
