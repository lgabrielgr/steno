import Foundation
import Testing

@testable import StenoKit

private let windowStart = Date(timeIntervalSince1970: 0)
private let windowEnd = Date(timeIntervalSince1970: 86_400)

private func report() -> StandupReport {
    StandupReport(
        projectID: UUID(),
        generatedAt: windowEnd,
        windowStart: windowStart,
        windowEnd: windowEnd,
        markdownBody: "*Since last stand-up*\n- Fixed the retry-handler race",
        wasAIGenerated: true,
        modelUsed: "claude-opus-5"
    )
}

@Test("§3.5: a report carries its window and provenance")
func standupReportInitialState() {
    let subject = report()
    #expect(subject.windowStart == windowStart)
    #expect(subject.windowEnd == windowEnd)
    #expect(subject.wasAIGenerated)
    #expect(subject.modelUsed == "claude-opus-5")
    #expect(!subject.isUndone)
}

// FR-4.1: undo restores the previous lastStandupAt by reading it from the
// report's windowStart, so the row has to survive being undone.
@Test("FR-4.1: markUndone retains the row and its window")
func markUndoneRetainsTheRow() {
    let subject = report()

    subject.markUndone()

    #expect(subject.isUndone)
    #expect(subject.windowStart == windowStart)
    #expect(subject.markdownBody.contains("retry-handler race"))
}

@Test("§7.4: a fallback report records that no model was used")
func fallbackReportHasNoModel() {
    let subject = StandupReport(
        projectID: UUID(),
        generatedAt: windowEnd,
        windowStart: windowStart,
        windowEnd: windowEnd,
        markdownBody: "- Fixed the retry-handler race",
        wasAIGenerated: false
    )

    #expect(!subject.wasAIGenerated)
    #expect(subject.modelUsed == nil)
}
