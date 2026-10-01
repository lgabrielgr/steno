import Foundation
import Testing

@testable import StenoKit

/// D-213: the reason a version walk stopped, and the line it logs.
///
/// **These assert prose, on purpose.** Three rounds of review on PR #44 found comments and
/// log messages describing behaviour the code no longer had — a page cap named on every
/// short walk, a harness naming one cause of three, a decision record claiming the log
/// identified the ref. Sentences drift; a test does not.

@Test("only the window's end is a complete walk")
func walkStopCompletenessIsExactlyWindowEnd() {
    #expect(ConfluenceClient.WalkStop.windowEnd.isComplete)
    #expect(ConfluenceClient.WalkStop.pageCap.isComplete == false)
    #expect(ConfluenceClient.WalkStop.repeatedCursor.isComplete == false)
    #expect(ConfluenceClient.WalkStop.unusableNext.isComplete == false)
}

@Test("each incomplete reason logs its own line, and a complete walk logs nothing")
func walkStopLinesAreDistinctAndSpecific() {
    let incomplete: [ConfluenceClient.WalkStop] = [.pageCap, .repeatedCursor, .unusableNext]
    let lines = incomplete.map(\.logLine)

    // Distinct, so a future collapse back to one message — which is the defect D-213
    // fixed — cannot pass unnoticed.
    #expect(Set(lines).count == incomplete.count)
    #expect(lines.allSatisfy { !$0.isEmpty })

    // Each names its own cause rather than borrowing another's.
    #expect(ConfluenceClient.WalkStop.pageCap.logLine.contains("page cap"))
    #expect(ConfluenceClient.WalkStop.repeatedCursor.logLine.contains("cursor did not advance"))
    #expect(ConfluenceClient.WalkStop.unusableNext.logLine.contains("no usable cursor"))
    #expect(ConfluenceClient.WalkStop.repeatedCursor.logLine.contains("page cap") == false)
    #expect(ConfluenceClient.WalkStop.unusableNext.logLine.contains("page cap") == false)

    // A complete walk has nothing to report.
    #expect(ConfluenceClient.WalkStop.windowEnd.logLine.isEmpty)
}

@Test("§8: a stop line says what happened, never which page it happened to")
func walkStopLinesCarryNoIdentifier() {
    // These reach a crash log, and a page id is the kind of identifier §8 keeps out of
    // one — the same reason `ReadOnlyTransport` withholds a URL. A decision record
    // claimed the opposite for three weeks before this test existed.
    let lines = [
        ConfluenceClient.WalkStop.pageCap.logLine,
        ConfluenceClient.WalkStop.repeatedCursor.logLine,
        ConfluenceClient.WalkStop.unusableNext.logLine,
    ]

    for line in lines {
        #expect(line.contains(ConfluenceFixture.pageID) == false)
        #expect(line.contains("for one ref"))
    }
}
