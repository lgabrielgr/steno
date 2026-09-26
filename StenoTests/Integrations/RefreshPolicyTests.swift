import Foundation
import Testing

@testable import StenoKit

/// §5.5's "older than 30 minutes" rule, as arithmetic.

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func snapshot(_ identifier: String, fetched: Date?) -> SourceRefSnapshot {
    SourceRefSnapshot(
        refID: UUID(), kind: .jiraIssue, identifier: identifier, lastFetchedAt: fetched)
}

@Test("a ref never fetched is always due")
func neverFetchedIsDue() {
    let due = RefreshPolicy.due(
        [snapshot("PAY-1", fetched: nil)], now: origin, olderThan: .seconds(1800))

    #expect(due.map(\.identifier) == ["PAY-1"])
}

@Test("§5.5: fetched longer ago than the staleness window is due, sooner is not")
func theStalenessWindowSplitsRefs() {
    let refs = [
        snapshot("stale", fetched: origin.addingTimeInterval(-1801)),
        snapshot("fresh", fetched: origin.addingTimeInterval(-1799)),
    ]

    let due = RefreshPolicy.due(refs, now: origin, olderThan: .seconds(1800))

    // Both directions in one assertion: naming only the survivor would pass
    // against a policy that returned everything.
    #expect(due.map(\.identifier) == ["stale"])
}

@Test("the boundary is strict: exactly the staleness window old is not due")
func theBoundaryIsStrict() {
    let due = RefreshPolicy.due(
        [snapshot("PAY-1", fetched: origin.addingTimeInterval(-1800))],
        now: origin, olderThan: .seconds(1800))

    #expect(due.isEmpty)
}

@Test("§5.5's launch window is 30 minutes")
func theLaunchWindowIsThirtyMinutes() {
    #expect(RefreshPolicy.launchStaleness == .seconds(1800))
}

@Test("a sub-second staleness window is not truncated to zero")
func subSecondWindowsSurvive() {
    // The millisecond budgets every service test uses depend on this: a
    // `Duration.seconds` accessor that dropped the attosecond term would make
    // `.milliseconds(50)` behave as zero, and every ref would look due.
    let refs = [
        snapshot("stale", fetched: origin.addingTimeInterval(-0.100)),
        snapshot("fresh", fetched: origin.addingTimeInterval(-0.010)),
    ]

    let due = RefreshPolicy.due(refs, now: origin, olderThan: .milliseconds(50))

    #expect(due.map(\.identifier) == ["stale"])
}
