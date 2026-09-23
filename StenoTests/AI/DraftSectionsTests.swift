import Foundation
import Testing

@testable import StenoKit

/// Turning §7.3's validated bullets into the sections M2-02 already renders.

@Test("a daily draft becomes the same three headings the raw path uses")
func dailySectionsMatchTheRawPath() {
    let task = DraftFixture.task("anything")
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: task.id, text: "found the race")],
            today: [DailyBullet(taskID: task.id, text: "still on it")],
            blockers: []))

    let sections = DraftSections.build(from: draft, window: window)

    // Compared against `ReportHeadings` rather than against
    // `RawReportSections`' output: two paths that drifted the same way would
    // still agree with each other.
    #expect(sections.map(\.title) == ReportHeadings.ordered(for: .daily))
    #expect(sections.map(\.title) == RawReportSections.build(from: window).map(\.title))
    #expect(sections[0].bullets.map(\.text) == ["found the race"])
    #expect(sections[1].bullets.map(\.text) == ["still on it"])
    #expect(sections[2].bullets.isEmpty)
    // One line per bullet: `ReportBullet.details`' default is what an AI bullet
    // uses, and a detail line here would be something the model did not write.
    #expect(sections[0].bullets.allSatisfy { $0.details.isEmpty })
}

@Test("a periodic draft becomes the periodic headings, in the order returned")
func periodicSectionsKeepTheModelsOrder() {
    let first = DraftFixture.task("one")
    let second = DraftFixture.task("two")
    let window = DraftFixture.window(.periodic, tasks: [first, second])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [
                ThemedBullet(taskIDs: [second.id], text: "second"),
                ThemedBullet(taskIDs: [first.id], text: "first"),
            ],
            inFlight: [], blockersAndRisks: []))

    let sections = DraftSections.build(from: draft, window: window)

    #expect(sections.map(\.title) == ReportHeadings.ordered(for: .periodic))
    // The model's order, not the window's: a themed bullet has no task order to
    // inherit, and re-sorting would break the narrative it grouped them into.
    #expect(sections[0].bullets.map(\.text) == ["second", "first"])
}

// MARK: - D-150, the ticket keys

@Test("a key the model dropped is re-attached in the raw path's format")
func aDroppedKeyIsReattached() {
    let task = DraftFixture.task("auth", keys: ["STENO-12", "STENO-19"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: task.id, text: "fixed the flaky auth test")],
            today: [], blockers: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "fixed the flaky auth test (STENO-12, STENO-19)")
}

@Test("a key the model kept is not appended twice, whatever its case")
func aKeptKeyIsNotDuplicated() {
    let task = DraftFixture.task("auth", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [
                DailyBullet(taskID: task.id, text: "landed STENO-12 behind a flag"),
                DailyBullet(taskID: task.id, text: "landed steno-12 behind a flag"),
            ],
            today: [], blockers: []))

    let texts = DraftSections.build(from: draft, window: window)[0].bullets.map(\.text)
    #expect(texts[0] == "landed STENO-12 behind a flag")
    // Preserved badly is still preserved: a second copy would read worse than
    // the imperfect original.
    #expect(texts[1] == "landed steno-12 behind a flag")
}

@Test("a themed bullet gathers every task's keys, deduped, first occurrence first")
func themedKeysAreGatheredAndDeduped() {
    let first = DraftFixture.task("one", keys: ["STENO-12", "STENO-30"])
    let second = DraftFixture.task("two", keys: ["STENO-12", "STENO-44"])
    let window = DraftFixture.window(.periodic, tasks: [first, second])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [ThemedBullet(taskIDs: [first.id, second.id], text: "cleaned up retries")],
            inFlight: [], blockersAndRisks: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "cleaned up retries (STENO-12, STENO-30, STENO-44)")
}

@Test("a task id the window does not hold contributes no keys and no crash")
func anUnknownIDIsInert() {
    let task = DraftFixture.task("known", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    // Unreachable through a provider — `StandupDraft.validated(against:)` runs
    // first — but this type must not be the thing that traps if it ever is.
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: UUID(), text: "from nowhere")],
            today: [], blockers: []))

    let text = DraftSections.build(from: draft, window: window)[0].bullets.first?.text
    #expect(text == "from nowhere")
}

// MARK: - D-152, blank bullets

@Test("a bullet with no words is dropped, keys and all")
func blankBulletsAreDropped() {
    let task = DraftFixture.task("auth", keys: ["STENO-12"])
    let window = DraftFixture.window(tasks: [task])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [
                DailyBullet(taskID: task.id, text: "   \n  "),
                DailyBullet(taskID: task.id, text: "a real sentence"),
            ],
            today: [DailyBullet(taskID: task.id, text: "")],
            blockers: []))

    let sections = DraftSections.build(from: draft, window: window)

    // Without the drop these render as `• (STENO-12)` and `• ` — a bullet the
    // user reads aloud that says nothing at all.
    #expect(sections[0].bullets.map(\.text) == ["a real sentence (STENO-12)"])
    #expect(sections[1].bullets.isEmpty)
}

@Test("a bullet with words and no task ids is kept")
func anUnattributedBulletSurvives() {
    let window = DraftFixture.window(.periodic, tasks: [DraftFixture.task("one")])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [ThemedBullet(taskIDs: [], text: "tidied up the CI config")],
            inFlight: [], blockersAndRisks: []))

    // `StandupDraft.isEmpty`'s own doc comment: "a bullet with an empty
    // `task_ids` array is still a bullet the model wrote, and losing it
    // silently would be worse than surfacing it." D-152 narrows nothing there.
    #expect(
        DraftSections.build(from: draft, window: window)[0].bullets.map(\.text)
            == ["tidied up the CI config"])
}
