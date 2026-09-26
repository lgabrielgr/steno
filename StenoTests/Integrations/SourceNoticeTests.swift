import Foundation
import Testing

@testable import StenoKit

/// §5.2's staleness label (D-176).

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func failure(_ error: SourceError = .network) -> RefreshOutcome.Failure {
    RefreshOutcome.Failure(connectorID: "jira", displayName: "Jira", error: error)
}

@Test("a clean pass says nothing")
func aCleanPassIsSilent() {
    let outcome = RefreshOutcome(
        attempted: 2, cached: 2, changed: 1, oldestFetch: now.addingTimeInterval(-30))

    #expect(SourceNotice.text(for: outcome, now: now) == nil)
}

@Test("a failed fetch names the integration and how old the data is")
func aFailureNamesTheIntegration() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure()], oldestFetch: now.addingTimeInterval(-2 * 86400))

    #expect(
        SourceNotice.text(for: outcome, now: now) == "Couldn't reach Jira — using 2 days old data.")
}

@Test("a failure with nothing cached says so rather than implying stale data exists")
func aFailureWithNoCacheSaysSo() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure()], oldestFetch: nil)

    #expect(
        SourceNotice.text(for: outcome, now: now) == "Couldn't reach Jira — no cached data yet.")
}

@Test("one day reads as singular")
func oneDayIsSingular() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure()], oldestFetch: now.addingTimeInterval(-86400 - 60))

    #expect(
        SourceNotice.text(for: outcome, now: now) == "Couldn't reach Jira — using 1 day old data.")
}

@Test("data fetched today reads as today's, not 0 days old")
func todayIsNotZeroDays() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure()], oldestFetch: now.addingTimeInterval(-3600))

    #expect(
        SourceNotice.text(for: outcome, now: now) == "Couldn't reach Jira — using today's data.")
}

@Test("a save failure outranks a fetch failure, because the user's retry differs")
func aSaveFailureWins() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure()], oldestFetch: now.addingTimeInterval(-86400),
        saveFailed: true)

    // Retrying a fetch is free; a write that was refused means the draft is built
    // on older data than the app just successfully fetched.
    #expect(
        SourceNotice.text(for: outcome, now: now)
            == "Fetched updates couldn't be saved. This draft uses your last saved data.")
}

@Test("an unconfigured integration is reported when nothing failed")
func unconfiguredIsReported() {
    let outcome = RefreshOutcome(notConfigured: 2, oldestFetch: nil)

    #expect(
        SourceNotice.text(for: outcome, now: now)
            == "Some references have no integration set up yet.")
}

@Test("a failed candidate read is its own sentence, not a fetch failure")
func aReadFailureIsItsOwnSentence() {
    #expect(
        SourceNotice.text(for: RefreshOutcome(readFailed: true), now: now)
            == "Couldn't check your integrations for this draft.")
}

@Test("old data with nothing wrong is reported only once it is a day behind")
func quietlyOldDataIsReportedAfterADay() {
    // A ref on a done task is not in the launch pass's scope, so it can be old
    // with no failure attached. Worth saying at a day; not worth saying at an
    // hour, when the report's own window is a day wide.
    let anHour = RefreshOutcome(attempted: 0, oldestFetch: now.addingTimeInterval(-3600))
    let threeDays = RefreshOutcome(attempted: 0, oldestFetch: now.addingTimeInterval(-3 * 86400))

    #expect(SourceNotice.text(for: anHour, now: now) == nil)
    #expect(SourceNotice.text(for: threeDays, now: now) == "Some integration data is 3 days old.")
}
