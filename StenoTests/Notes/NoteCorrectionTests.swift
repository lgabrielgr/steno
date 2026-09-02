import Foundation
import Testing

@testable import StenoKit

private let origin = Date(timeIntervalSince1970: 1_000_000)

@Test("only the kinds the user typed are correctable", arguments: EventKind.allCases)
func onlyUserAuthoredKindsAreCorrectable(kind: EventKind) {
    let correctable = NoteCorrection.isCorrectable(
        kind: kind, timestamp: origin, isRedacted: false, at: origin)
    #expect(correctable == (kind == .note || kind == .blockedReason))
}

@Test("the window is open before five minutes and closed at five minutes")
func theWindowClosesAtFiveMinutes() {
    func correctable(after seconds: TimeInterval) -> Bool {
        NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin, isRedacted: false,
            at: origin.addingTimeInterval(seconds))
    }
    #expect(correctable(after: 0))
    #expect(correctable(after: 299))
    // Half-open: exactly five minutes is already too late.
    #expect(!correctable(after: 300))
    #expect(!correctable(after: 301))
}

@Test("a redacted event is never correctable")
func aRedactedEventIsNeverCorrectable() {
    #expect(
        !NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin, isRedacted: true, at: origin))
}

@Test("an event stamped in the future stays correctable")
func aFutureEventStaysCorrectable() {
    // Clock jitter, or a §10 import from a Mac running fast. Rejecting a
    // negative age would make such a note permanently uncorrectable, which is
    // both likelier and worse than letting it be corrected early.
    #expect(
        NoteCorrection.isCorrectable(
            kind: .note, timestamp: origin.addingTimeInterval(1), isRedacted: false, at: origin))
}
