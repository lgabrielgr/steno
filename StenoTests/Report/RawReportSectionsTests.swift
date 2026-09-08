import Testing

@testable import StenoKit

// MARK: - Daily

@Test("FR-4 daily: an in-progress task with notes appears under two headings")
func dailyListsAProgressedInProgressTaskTwice() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Flaky auth test", status: .inProgress,
                    events: [SectionInput.event("was a race in TokenRefresher")])
            ]))

    // The whole point of the two-test membership rule: it says what happened
    // under one heading and what is happening under the other, never both.
    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Flaky auth test", details: ["was a race in TokenRefresher"])])
    #expect(
        SectionInput.section("Today", of: sections) == [ReportBullet(text: "Flaky auth test")])
}

@Test("FR-4 daily: a blocked task's notes go above, its reason under Blockers")
func dailyBlockersCarryTheReasonAndNotTheNotes() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [SectionInput.event("raised INFRA-9")])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["raised INFRA-9"])])
    #expect(
        SectionInput.section("Blockers", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["waiting on infra"])])
}

@Test("FR-4 daily: a task finished with no notes is still reported as completed")
func dailyReportsADoneTaskThatCarriesOnlyAStatusChange() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Bump pg driver", status: .done,
                    events: [SectionInput.event("In Progress → Done", kind: .statusChanged)])
            ]))

    // The defect this exists for: with membership tested on activity alone,
    // the statusChanged filter empties the task's details and it then matches
    // no daily heading at all — the most reportable thing that happened,
    // silently absent.
    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Bump pg driver")])
}

@Test("A task moved back to todo with nothing written appears under no daily heading")
func dailyOmitsAQuietTodoTask() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Rate limiter", status: .todo,
                    events: [SectionInput.event("In Progress → To Do", kind: .statusChanged)])
            ]))

    // The accepted gap, asserted so it stays a decision rather than becoming a
    // surprise. A bare title under "Since last stand-up" would assert progress
    // that did not happen.
    #expect(sections.map(\.bullets.count) == [0, 0, 0])
}

@Test("A reason captured inside the window is said once, not twice")
func dailyDoesNotRepeatAnInWindowBlockedReason() {
    // The common case, not an exotic one: StatusService.addBlockedReason
    // stamps now(), so a task blocked since the last stand-up has its reason
    // event *inside* the window as well as on GatheredTask.blockedReason.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [
                        SectionInput.event("raised INFRA-9"),
                        SectionInput.event("waiting on infra", kind: .blockedReason),
                    ])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["raised INFRA-9"])])
    #expect(
        SectionInput.section("Blockers", of: sections)
            == [ReportBullet(text: "Webhook replay", details: ["waiting on infra"])])
}

@Test("A reason from a block that has since lifted is still the user's words")
func anUnblockedTaskKeepsItsFormerBlockedReason() {
    // D-069 leaves GatheredTask.blockedReason nil for anything not currently
    // blocked, so this event is the only carrier of what the user wrote. It
    // must survive, or the report loses words the user typed.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task(
                    "Webhook replay", status: .inProgress,
                    events: [
                        SectionInput.event("was waiting on infra", kind: .blockedReason),
                        SectionInput.event("creds arrived, unblocked"),
                    ])
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)
            == [
                ReportBullet(
                    text: "Webhook replay",
                    details: ["was waiting on infra", "creds arrived, unblocked"])
            ])
}

// MARK: - Periodic

@Test("D17 periodic: every task lands in exactly one section")
func periodicIsAPartition() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .periodic,
            [
                SectionInput.task("Done thing", status: .done),
                SectionInput.task("Doing thing", status: .inProgress),
                SectionInput.task("Blocked thing", status: .blocked),
                SectionInput.task(
                    "Todo thing", status: .todo, events: [SectionInput.event("started poking")]),
            ]))

    // Counted across all sections rather than per-section, so a task rendered
    // twice fails here — which is the property that separates periodic's
    // mapping from daily's.
    #expect(sections.map(\.bullets.count).reduce(0, +) == 4)
    #expect(SectionInput.section("Completed", of: sections)?.map(\.text) == ["Done thing"])
    #expect(
        SectionInput.section("In flight", of: sections)?.map(\.text)
            == ["Doing thing", "Todo thing"])
    #expect(
        SectionInput.section("Blockers & risks", of: sections)?.map(\.text) == ["Blocked thing"])
}

@Test("D17 periodic: a blocked task's reason comes before its notes")
func periodicBlockersCarryReasonThenNotes() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .periodic,
            [
                SectionInput.task(
                    "Webhook replay", status: .blocked, blockedReason: "waiting on infra",
                    events: [
                        SectionInput.event("raised INFRA-9"),
                        SectionInput.event("waiting on infra", kind: .blockedReason),
                    ])
            ]))

    // Periodic has no second section for the notes to live in, so losing them
    // here would lose the user's words outright — and the in-window reason
    // event must not make the bullet say "waiting on infra" twice.
    #expect(
        SectionInput.section("Blockers & risks", of: sections)
            == [
                ReportBullet(
                    text: "Webhook replay", details: ["waiting on infra", "raised INFRA-9"])
            ])
}

// MARK: - Shared rules

/// One row of the machine-authored-event table.
///
/// Private, so the `@Test` function taking it must be private too — a
/// non-private function with a private parameter type does not compile.
private struct KindCase: Sendable {
    let label: String
    let cadence: ReportCadence
    let heading: String
}

@Test(
    "D-072: machine-authored events never become bullets",
    arguments: [
        KindCase(label: "daily", cadence: .daily, heading: "Since last stand-up"),
        KindCase(label: "periodic", cadence: .periodic, heading: "Completed"),
    ])
private func structuralEventsProduceNoDetails(kind: KindCase) {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            kind.cadence,
            [
                SectionInput.task(
                    "Ship it", status: .done,
                    events: [
                        SectionInput.event("Task created", kind: .created),
                        SectionInput.event("To Do → In Progress", kind: .statusChanged),
                        SectionInput.event("found the leak", kind: .note),
                        SectionInput.event("In Progress → Done", kind: .statusChanged),
                    ])
            ]))

    #expect(
        SectionInput.section(kind.heading, of: sections)?.first?.details == ["found the leak"],
        "\(kind.label): only the user's own words belong in a spoken stand-up")
}

@Test("An empty window still renders every heading", arguments: ReportCadence.allCases)
func anEmptyWindowStillProducesThreeSections(cadence: ReportCadence) {
    let sections = RawReportSections.build(from: SectionInput.window(cadence, []))

    #expect(sections.count == 3)
    #expect(sections.map(\.bullets.count) == [0, 0, 0])
}

@Test("FR-1.5: every ticket key on a task survives into its bullet")
func ticketKeysAreAppendedAndJoined() {
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task("Two keys", status: .done, ticketKeys: ["PAY-388", "PAY-412"]),
                SectionInput.task("No keys", status: .done),
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)?.map(\.text)
            == ["Two keys (PAY-388, PAY-412)", "No keys"])
}

@Test("The gatherer's task order is preserved, not re-sorted")
func taskOrderIsInherited() {
    // Deliberately not alphabetical and not sorted by status, so a renderer
    // that sorted by either would produce a different order and fail. Running
    // the renderer twice would prove nothing about this.
    let sections = RawReportSections.build(
        from: SectionInput.window(
            .daily,
            [
                SectionInput.task("zebra", status: .done),
                SectionInput.task("apple", status: .done),
                SectionInput.task("mango", status: .done),
            ]))

    #expect(
        SectionInput.section("Since last stand-up", of: sections)?.map(\.text)
            == ["zebra", "apple", "mango"])
}
