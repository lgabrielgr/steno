import Foundation
import Testing

@testable import StenoKit

/// §5.2's 14-day rule (D-194).

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let day: TimeInterval = 24 * 60 * 60

@Test("§5.2: fourteen days out, the warning is due")
func fourteenDaysWarns() {
    #expect(AtlassianTokenExpiry.shouldWarn(expiresAt: now.addingTimeInterval(14 * day), now: now))
}

@Test("fifteen days out, it says nothing")
func fifteenDaysIsSilent() {
    // "Does not nag before that" is half of M4-04's acceptance criterion, and the rule
    // belongs to this type.
    #expect(
        AtlassianTokenExpiry.shouldWarn(expiresAt: now.addingTimeInterval(15 * day), now: now)
            == false)
}

@Test("the boundary is the interval, not the rounded day count")
func theBoundaryIsTheInterval() {
    // **The subtle one.** Flooring first would warn at 14.9 days, because
    // `floor(14.9) == 14` — a day early, every day, which is how a warning becomes
    // noise (FR-5). Mutation: gate `shouldWarn` on `daysRemaining` and this goes red.
    #expect(
        AtlassianTokenExpiry.shouldWarn(
            expiresAt: now.addingTimeInterval(14 * day + 1), now: now) == false)
    #expect(
        AtlassianTokenExpiry.shouldWarn(expiresAt: now.addingTimeInterval(14 * day - 1), now: now))
}

@Test("an expired token still warns")
func anExpiredTokenWarns() {
    // Reachable by ignoring the warning for two weeks, and by then the fetches are
    // already failing — so silence would be the worst possible answer.
    #expect(AtlassianTokenExpiry.shouldWarn(expiresAt: now.addingTimeInterval(-day), now: now))
}

@Test(
    "the day count is floored, so eleven hours left reads as today",
    arguments: [
        (9.0 * 24, 9),
        (24.0, 1),
        (11.0, 0),
        (0.0, 0),
        (-1.0, -1),
        (-72.0, -3),
    ])
func theDayCountIsFloored(hoursRemaining: Double, expected: Int) {
    let expiresAt = now.addingTimeInterval(hoursRemaining * 60 * 60)
    #expect(AtlassianTokenExpiry.daysRemaining(expiresAt: expiresAt, now: now) == expected)
}

@Test("a warning carries the name, the days, and the link")
func aWarningCarriesWhatTheSentenceNeeds() throws {
    let warning = try #require(
        AtlassianTokenExpiry.warning(
            displayName: "Jira", expiresAt: now.addingTimeInterval(9 * day), now: now))

    #expect(warning.displayName == "Jira")
    #expect(warning.daysRemaining == 9)
    #expect(warning.renewalURL == AtlassianTokenExpiry.renewalURL)
}

@Test("no expiry date means no warning")
func noExpiryDateMeansNoWarning() {
    #expect(AtlassianTokenExpiry.warning(displayName: "Jira", expiresAt: nil, now: now) == nil)
}

@Test("a distant expiry means no warning")
func aDistantExpiryMeansNoWarning() {
    #expect(
        AtlassianTokenExpiry.warning(
            displayName: "Jira", expiresAt: now.addingTimeInterval(200 * day), now: now) == nil)
}

@Test("§5.2's renewal link is Atlassian's token page")
func theRenewalLinkIsTheTokenPage() {
    // Confirmed reachable 2026-09-26. A constant rather than a string built at a call
    // site, so the link cannot go missing at the moment the token expires.
    #expect(
        AtlassianTokenExpiry.renewalURL.absoluteString
            == "https://id.atlassian.com/manage-profile/security/api-tokens")
}
