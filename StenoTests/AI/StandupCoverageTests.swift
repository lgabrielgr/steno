import Foundation
import Testing

@testable import StenoKit

// D-156: a draft that drops the user's own words degrades; one that skips a
// task nobody said anything about does not.

private let modelID = "claude-test-1"

private func summarizer(provider: (any AIProvider)?) -> StandupSummarizer {
    StandupSummarizer(provider: provider, modelID: modelID, timeout: .seconds(20), timeZone: .gmt)
}

@Test("a draft that omits a task the user wrote notes on falls back")
func droppedWorkDegrades() async {
    let noted = DraftFixture.task(
        "the one it forgot", events: [DraftFixture.event("spent all morning on this")])
    let mentioned = DraftFixture.task(
        "the one it kept", events: [DraftFixture.event("quick fix")])
    let window = DraftFixture.window(tasks: [noted, mentioned])
    // Structurally valid and every id real, so `validated(against:)` passes it:
    // the failure is in what the draft does not say.
    let partial = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: mentioned.id, text: "shipped the quick fix")],
            today: [], blockers: []))
    let provider = StubAIProvider(draft: .success(partial))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown == StandupSummarizer.rawMarkdown(for: window))
    // The fallback carries what the draft dropped, which is the whole reason
    // this is a degradation rather than an accepted omission.
    #expect(result.markdown.contains("spent all morning on this"))
}

@Test("a task with nothing written about it may be left out")
func aQuietTaskMayBeOmitted() async {
    // The counter-case, and the reason the check is not "every task must
    // appear": `RawReportSections` itself puts a task like this under no daily
    // heading, so rejecting the draft would hand the user the rougher report
    // for being exactly as faithful as the fallback.
    let quiet = DraftFixture.task("nothing was said about this", status: .todo)
    let noted = DraftFixture.task(
        "the real work", events: [DraftFixture.event("found the race")])
    let window = DraftFixture.window(tasks: [quiet, noted])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: noted.id, text: "found the race")],
            today: [], blockers: []))
    let provider = StubAIProvider(draft: .success(draft))

    let result = await summarizer(provider: provider).summarize(window)

    #expect(result.modelUsed == modelID)
    #expect(result.markdown.contains("found the race"))
}

@Test("machine-authored events alone do not make a task unreportable")
func onlyTheUsersOwnWordsCount() async {
    // D-072's reasoning, applied here: `created` and `statusChanged` bodies are
    // strings the app wrote. A draft omitting a task whose only window activity
    // was the app's own bookkeeping has lost nothing of the user's.
    let machine = DraftFixture.task(
        "moved columns and nothing else",
        events: [
            DraftFixture.event("Task created", kind: .created),
            DraftFixture.event("To Do → In Progress", kind: .statusChanged),
        ])
    let noted = DraftFixture.task("real work", events: [DraftFixture.event("found the race")])
    let window = DraftFixture.window(tasks: [machine, noted])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: noted.id, text: "found the race")],
            today: [], blockers: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft)))
        .summarize(window)

    #expect(result.modelUsed == modelID)
}

@Test("a periodic bullet covering several tasks reports all of them")
func themedBulletsCountAsCoverage() async {
    let first = DraftFixture.task("one", events: [DraftFixture.event("did a thing")])
    let second = DraftFixture.task("two", events: [DraftFixture.event("did another")])
    let window = DraftFixture.window(.periodic, tasks: [first, second])
    // §7.3's grouping licence: one bullet, two task_ids, nothing dropped.
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [ThemedBullet(taskIDs: [first.id, second.id], text: "cleaned up retries")],
            inFlight: [], blockersAndRisks: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft)))
        .summarize(window)

    #expect(result.modelUsed == modelID, "grouping is not omission")
}

@Test("a cancelled polish is not reported as a degradation")
func cancellationIsNotADegradation() {
    // `AnthropicErrors` maps `CancellationError` to `.timedOut`, correctly —
    // that is also how the provider's own deadline fires, so the provider
    // cannot tell them apart and should not try. The caller can: it knows
    // whether *its* task was cancelled, which happens when the user closes the
    // sheet or prepares another window.
    #expect(StandupSummarizer.degradationLabel(for: .timedOut, cancelled: true) == nil)

    // A real timeout still says so, or §7.4's log stops answering the question
    // it exists for.
    #expect(StandupSummarizer.degradationLabel(for: .timedOut, cancelled: false) == "timedOut")
    #expect(StandupSummarizer.degradationLabel(for: .network, cancelled: false) == "network")
}

@Test("a bullet with no words is not coverage")
func aBlankBulletIsNotCoverage() async {
    // The interaction the coverage check was written without: the draft names
    // the task, so `allTaskIDs` says it is covered — and then D-152 drops the
    // blank bullet at render time and the user never sees the task at all.
    let noted = DraftFixture.task(
        "the one it blanked", events: [DraftFixture.event("spent all morning on this")])
    let other = DraftFixture.task("the real one", events: [DraftFixture.event("quick fix")])
    let window = DraftFixture.window(tasks: [noted, other])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [
                DailyBullet(taskID: noted.id, text: "   "),
                DailyBullet(taskID: other.id, text: "shipped the quick fix"),
            ],
            today: [], blockers: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft))).summarize(
        window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown.contains("spent all morning on this"))
}

@Test("a standing blocker cannot be dropped, even with nothing new said")
func anOmittedBlockerDegrades() async {
    // `GatheredTask.blockedReason` is sourced independently of the window
    // (D-069), precisely so a task blocked last week and still blocked reports
    // its reason with no in-window events at all. `RawReportSections` speaks it
    // under *Blockers*; the AI path must not silently stop.
    let blocked = DraftFixture.task(
        "waiting on infra", status: .blocked,
        blockedReason: "waiting on infra to bump the runner image")
    let other = DraftFixture.task("real work", events: [DraftFixture.event("found the race")])
    let window = DraftFixture.window(tasks: [blocked, other])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [DailyBullet(taskID: other.id, text: "found the race")],
            today: [], blockers: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft))).summarize(
        window)

    #expect(result.modelUsed == nil, "a blocker nobody mentions is the worst outcome here")
    #expect(result.markdown.contains("waiting on infra to bump the runner image"))
}

@Test("a blocker the draft does mention is accepted")
func aReportedBlockerIsFine() async {
    let blocked = DraftFixture.task(
        "waiting on infra", status: .blocked, blockedReason: "infra has not bumped the image")
    let window = DraftFixture.window(tasks: [blocked])
    let draft = StandupDraft.daily(
        DailyDraft(
            sinceLastStandup: [],
            today: [],
            blockers: [DailyBullet(taskID: blocked.id, text: "still waiting on the runner image")]))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft))).summarize(
        window)

    #expect(result.modelUsed == modelID)
}

@Test("the fallback line names the reason, not just the family")
func theFallbackLineNamesTheReason() {
    // `AIError.metricsLabel` collapses every invalidResponse reason to one word
    // — D-137's fixed vocabulary for §8's `ai` line, which stays as it is. The
    // `report` line is where someone asks why their stand-up was rough, and
    // "invalidResponse" cannot tell a hallucinated shape from a draft that
    // quietly left half the window out.
    #expect(
        StandupSummarizer.degradationLabel(
            for: .invalidResponse(.incompleteDraft), cancelled: false)
            == "invalidResponse.incompleteDraft")
    #expect(
        StandupSummarizer.degradationLabel(for: .invalidResponse(.emptyDraft), cancelled: false)
            == "invalidResponse.emptyDraft")
    // Errors without a reason keep the single word.
    #expect(StandupSummarizer.degradationLabel(for: .network, cancelled: false) == "network")
}

@Test("a blank themed bullet is not coverage either")
func aBlankThemedBulletIsNotCoverage() async {
    // The periodic twin of `aBlankBulletIsNotCoverage`. Written because the
    // mutation sweep found the daily test alone left this branch unguarded —
    // `reportedTaskIDs` has two arms and a fix applied to the one in the diff
    // is this repo's most-repeated defect.
    let noted = DraftFixture.task(
        "the one it blanked", events: [DraftFixture.event("spent all morning on this")])
    let other = DraftFixture.task("the real one", events: [DraftFixture.event("quick fix")])
    let window = DraftFixture.window(.periodic, tasks: [noted, other])
    let draft = StandupDraft.periodic(
        PeriodicDraft(
            completed: [
                ThemedBullet(taskIDs: [noted.id], text: "  \n "),
                ThemedBullet(taskIDs: [other.id], text: "shipped the quick fix"),
            ],
            inFlight: [], blockersAndRisks: []))

    let result = await summarizer(provider: StubAIProvider(draft: .success(draft))).summarize(
        window)

    #expect(result.modelUsed == nil)
    #expect(result.markdown.contains("spent all morning on this"))
}
