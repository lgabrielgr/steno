import Foundation
import Testing

@testable import StenoKit

/// The sentence a notice would show.
///
/// M4-02 turned `SourceNotice.text` into `message`, which carries an optional link
/// beside the wording (D-193). Every assertion in this file is about the wording, so
/// this keeps them reading as wording; the link has its own tests.
private func sentence(for outcome: RefreshOutcome, now: Date) -> String? {
    SourceNotice.message(for: outcome, now: now)?.text
}

/// §5.2's staleness label (D-176).

private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// `cachedAt` is what the failure sentence quotes — the failed ref's *own* last
/// observation, not the outcome's global `oldestFetch`.
private func failure(
    _ error: SourceError = .network, cachedAt: Date? = nil
) -> RefreshOutcome.Failure {
    RefreshOutcome.Failure(
        connectorID: "jira", displayName: "Jira", error: error, cachedAt: cachedAt)
}

@Test("a clean pass says nothing")
func aCleanPassIsSilent() {
    let outcome = RefreshOutcome(
        attempted: 2, cached: 2, changed: 1, oldestFetch: now.addingTimeInterval(-30))

    #expect(sentence(for: outcome, now: now) == nil)
}

@Test("a failed fetch names the integration and how old the data is")
func aFailureNamesTheIntegration() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure(cachedAt: now.addingTimeInterval(-2 * 86400))])

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — using 2 days old data.")
}

@Test("a failure with nothing cached says so rather than implying stale data exists")
func aFailureWithNoCacheSaysSo() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure()], oldestFetch: nil)

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — no cached data yet.")
}

@Test("one day reads as singular")
func oneDayIsSingular() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure(cachedAt: now.addingTimeInterval(-86400 - 60))])

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — using 1 day old data.")
}

@Test("data fetched today reads as today's, not 0 days old")
func todayIsNotZeroDays() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure(cachedAt: now.addingTimeInterval(-3600))])

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — using today's data.")
}

@Test("a save failure outranks a fetch failure, because the user's retry differs")
func aSaveFailureWins() {
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure()], oldestFetch: now.addingTimeInterval(-86400),
        saveFailed: true)

    // Retrying a fetch is free; a write that was refused means the draft is built
    // on older data than the app just successfully fetched.
    #expect(
        sentence(for: outcome, now: now)
            == "Fetched updates couldn't be saved. This draft uses your last saved data.")
}

@Test("an unconfigured integration is reported when nothing failed")
func unconfiguredIsReported() {
    let outcome = RefreshOutcome(notConfigured: 2, oldestFetch: nil)

    #expect(
        sentence(for: outcome, now: now)
            == "Some references have no integration set up yet.")
}

@Test("a failed candidate read is its own sentence, not a fetch failure")
func aReadFailureIsItsOwnSentence() {
    #expect(
        sentence(for: RefreshOutcome(readFailed: true), now: now)
            == "Couldn't check your integrations for this draft.")
}

@Test("old data with nothing wrong is reported only once it is a day behind")
func quietlyOldDataIsReportedAfterADay() {
    // A ref on a done task is not in the launch pass's scope, so it can be old
    // with no failure attached. Worth saying at a day; not worth saying at an
    // hour, when the report's own window is a day wide.
    let anHour = RefreshOutcome(attempted: 0, oldestFetch: now.addingTimeInterval(-3600))
    let threeDays = RefreshOutcome(attempted: 0, oldestFetch: now.addingTimeInterval(-3 * 86400))

    #expect(sentence(for: anHour, now: now) == nil)
    #expect(sentence(for: threeDays, now: now) == "Some integration data is 3 days old.")
}

@Test("D-165: a rejected credential is not reported as a reachability problem")
func aCredentialFailureIsNotAWifiProblem() {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [
            RefreshOutcome.Failure(
                connectorID: "jira", displayName: "Jira", error: .invalidCredential,
                cachedAt: now.addingTimeInterval(-2 * 86400))
        ])

    // D-165 separates .invalidCredential from .network precisely so a bad token
    // does not send the user to check their wifi, and this sentence used to undo
    // that by labelling every failure "Couldn't reach" (Copilot, PR #42).
    let text = sentence(for: outcome, now: now)
    #expect(text == "Jira: The integration rejected the saved credential — using 2 days old data.")
    #expect(text?.contains("Couldn't reach") == false)
}

@Test("D-165: a missing reference points at the reference, not the network")
func aMissingReferenceIsNotAWifiProblem() {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [
            RefreshOutcome.Failure(
                connectorID: "jira", displayName: "Jira", error: .notFound, cachedAt: nil)
        ])

    #expect(
        sentence(for: outcome, now: now)
            == "Jira: That reference doesn't exist, or this account can't see it "
            + "— no cached data yet.")
}

@Test("a timeout keeps the reachability wording")
func aTimeoutIsAReachabilityProblem() {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [
            RefreshOutcome.Failure(
                connectorID: "jira", displayName: "Jira", error: .timedOut,
                cachedAt: now.addingTimeInterval(-3600))
        ])

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — using today's data.")
}

@Test("the age quoted is the failed ref's own, not the window's oldest")
func theAgeBelongsToTheFailedRef() {
    // An uncached Jira ref fails while an unrelated Confluence ref holds a
    // two-day-old cache. Reading the outcome's global oldestFetch would tell the
    // user Jira is using two-day-old data, when Jira has none at all (Copilot,
    // PR #42).
    let outcome = RefreshOutcome(
        attempted: 2, cached: 1,
        failures: [
            RefreshOutcome.Failure(
                connectorID: "jira", displayName: "Jira", error: .network, cachedAt: nil)
        ],
        oldestFetch: now.addingTimeInterval(-2 * 86400))

    #expect(
        sentence(for: outcome, now: now) == "Couldn't reach Jira — no cached data yet.")
}

// MARK: - §5.2's token wording (D-193, D-194)

/// A failure carrying the renewal link, as the service stamps it.
private func expiredFailure(cachedAt: Date? = nil) -> RefreshOutcome.Failure {
    RefreshOutcome.Failure(
        connectorID: "jira", displayName: "Jira", error: .credentialExpired, cachedAt: cachedAt,
        renewalURL: AtlassianTokenExpiry.renewalURL)
}

private func expiryWarning(daysRemaining: Int) -> SourceCredentialWarning {
    SourceCredentialWarning(
        displayName: "Jira", daysRemaining: daysRemaining,
        renewalURL: AtlassianTokenExpiry.renewalURL)
}

@Test("§5.2: a 401 says the token expired and never mentions the network")
func aFourOhOneNamesTheToken() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [expiredFailure()])
    let message = try #require(SourceNotice.message(for: outcome, now: RefreshFixture.origin))

    #expect(message.text == "Jira: your token expired or was revoked — no cached data yet.")
    // The words §5.2 forbids here, checked directly: "a silent 401 during stand-up prep
    // is the worst possible time to debug auth", and sending the user to their wifi
    // settings is how that time gets spent.
    #expect(message.text.contains("reach") == false)
    #expect(message.text.contains("connection") == false)
}

@Test("§5.2: the 401 sentence carries a direct link")
func aFourOhOneCarriesALink() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [expiredFailure()])
    let action = try #require(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.action)

    #expect(action.label == "Create a new token")
    #expect(action.url == AtlassianTokenExpiry.renewalURL)
}

@Test("the 401 sentence still says what the draft fell back on")
func aFourOhOneStillNamesTheFallback() throws {
    let twoDaysAgo = RefreshFixture.origin.addingTimeInterval(-2 * 24 * 60 * 60)
    let outcome = RefreshOutcome(attempted: 1, failures: [expiredFailure(cachedAt: twoDaysAgo)])

    #expect(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.text
            == "Jira: your token expired or was revoked — using 2 days old data.")
}

@Test("a connector with no renewal page gets the sentence without a link")
func aConnectorWithoutARenewalPageGetsNoLink() throws {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [
            RefreshOutcome.Failure(
                connectorID: "x", displayName: "Something", error: .credentialExpired)
        ])
    let message = try #require(SourceNotice.message(for: outcome, now: RefreshFixture.origin))

    #expect(message.text.contains("expired or was revoked"))
    #expect(message.action == nil)
}

@Test(
    "§5.2: the expiry warning counts down in days",
    arguments: [
        (9, "Your Jira token expires in 9 days."),
        (1, "Your Jira token expires tomorrow."),
        (0, "Your Jira token expires today."),
        (-1, "Your Jira token has expired."),
    ])
func theExpiryWarningCountsDown(daysRemaining: Int, expected: String) throws {
    let outcome = RefreshOutcome(credentialWarnings: [expiryWarning(daysRemaining: daysRemaining)])
    let message = try #require(SourceNotice.message(for: outcome, now: RefreshFixture.origin))

    #expect(message.text == expected)
    #expect(message.action?.url == AtlassianTokenExpiry.renewalURL)
}

@Test("D-194: a fetch that is already failing outranks a token that expires on Friday")
func afailureOutranksTheExpiryWarning() throws {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [
            RefreshOutcome.Failure(connectorID: "jira", displayName: "Jira", error: .network)
        ],
        credentialWarnings: [expiryWarning(daysRemaining: 9)])

    // One sentence only, and the actionable one wins: the first is breaking now, the
    // second is a calendar.
    #expect(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.text
            == "Couldn't reach Jira — no cached data yet.")
}

@Test("the expiry warning outranks not-configured and staleness")
func theExpiryWarningOutranksTheQuieterSentences() throws {
    let outcome = RefreshOutcome(
        notConfigured: 2,
        credentialWarnings: [expiryWarning(daysRemaining: 3)],
        oldestFetch: RefreshFixture.origin.addingTimeInterval(-5 * 24 * 60 * 60))

    #expect(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.text
            == "Your Jira token expires in 3 days.")
}

@Test("a save failure still outranks everything, including the token")
func aSaveFailureOutranksTheToken() throws {
    let outcome = RefreshOutcome(
        credentialWarnings: [expiryWarning(daysRemaining: 1)], saveFailed: true)
    #expect(
        SourceNotice.message(for: outcome, now: RefreshFixture.origin)?.text
            == "Fetched updates couldn't be saved. This draft uses your last saved data.")
}

@Test("a clean pass with a distant expiry says nothing at all")
func acleanPassWithNoWarningIsSilent() {
    // Silence is the correct label for data that is current — and a banner that fires
    // on every draft is one the user stops reading (FR-5).
    #expect(
        SourceNotice.message(
            for: RefreshOutcome(attempted: 2, cached: 2, oldestFetch: RefreshFixture.origin),
            now: RefreshFixture.origin) == nil)
}

// MARK: - D-216's silence, and D-217's sentence

@Test("D-216: a pass that only skipped disabled integrations says nothing")
func aDisabledIntegrationIsSilent() {
    // **The whole reason `.disabled` is its own dispatch case.** Folded into
    // `notConfigured`, this outcome would say "Some references have no
    // integration set up yet" — false, and an instruction the user already
    // declined by switching it off.
    //
    // Mutation: add a `disabled > 0` branch to `SourceNotice.message`. Red.
    #expect(sentence(for: RefreshOutcome(disabled: 3, oldestFetch: nil), now: now) == nil)
}

@Test("D-216: a disabled count does not suppress a real complaint about something else")
func disabledDoesNotMaskAnUnconfiguredIntegration() {
    // Silence about one integration must not become silence about the pass. The
    // enabled-but-unconfigured one still has a sentence.
    let outcome = RefreshOutcome(notConfigured: 1, disabled: 2, oldestFetch: nil)

    #expect(
        sentence(for: outcome, now: now) == "Some references have no integration set up yet.")
}

@Test("D-217: a wrong site address is its own sentence, pointing at Settings")
func aWrongSiteAddressPointsAtSettings() {
    let outcome = RefreshOutcome(
        attempted: 1,
        failures: [failure(.siteNotFound, cachedAt: now.addingTimeInterval(-2 * 86400))])

    // One em-dash, and the remedy last. Composed through `cause` this read
    // "Jira's site address looks wrong — check it in Settings — using 2 days old
    // data", which is why the case has its own shape.
    #expect(
        sentence(for: outcome, now: now)
            == "Jira isn't being served from your configured site — using 2 days old data. "
            + "Check the site address in Settings.")
}

@Test("D-217: a wrong site address does not read as a connection problem")
func aWrongSiteIsNotAConnectionProblem() {
    let site = RefreshOutcome(attempted: 1, failures: [failure(.siteNotFound)])
    let network = RefreshOutcome(attempted: 1, failures: [failure(.network)])

    // Mutation: group `.siteNotFound` with `.network` in `cause`. Red.
    #expect(sentence(for: site, now: now) != sentence(for: network, now: now))
    #expect(sentence(for: network, now: now)?.contains("Couldn\'t reach Jira") == true)
    #expect(sentence(for: site, now: now)?.contains("Couldn\'t reach") == false)
}

@Test("D-217: a wrong site address with no cache says so without inventing an age")
func aWrongSiteWithNoCacheNamesNoAge() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.siteNotFound)])

    #expect(
        sentence(for: outcome, now: now)
            == "Jira isn\'t being served from your configured site — no cached data yet. "
            + "Check the site address in Settings.")
}

@Test("D-194 still holds: a failure outranks an expiry warning for the new case too")
func aSiteFailureOutranksTheExpiryWarning() {
    let warning = SourceCredentialWarning(
        displayName: "Jira", daysRemaining: 9,
        renewalURL: AtlassianTokenExpiry.renewalURL)
    let outcome = RefreshOutcome(
        attempted: 1, failures: [failure(.siteNotFound)], credentialWarnings: [warning])

    #expect(sentence(for: outcome, now: now)?.contains("configured site") == true)
}
