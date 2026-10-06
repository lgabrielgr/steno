import Foundation
import Testing

@testable import StenoKit

private let moment = Date(timeIntervalSince1970: 1_792_000_000)

private func failure(_ error: SourceError, connector: String = "jira") -> RefreshOutcome.Failure {
    RefreshOutcome.Failure(
        connectorID: connector, displayName: connector == "jira" ? "Jira" : "Confluence",
        error: error)
}

// MARK: - What counts as a rejection

@Test("an expired credential is recorded, naming the connector")
func anExpiredCredentialIsRecorded() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.credentialExpired)])

    let rejection = try #require(CredentialRejection.from(outcome, at: moment))

    #expect(rejection.displayName == "Jira")
    #expect(rejection.discoveredAt == moment)
}

@Test("a rejected credential is recorded")
func aRejectedCredentialIsRecorded() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.invalidCredential)])

    #expect(try #require(CredentialRejection.from(outcome, at: moment)).displayName == "Jira")
}

/// **The list of errors that are *not* evidence about the token**, and the reason this is a
/// table rather than one case: a warning that fires on an unreachable network is one the
/// user learns to ignore, which is FR-5's reasoning applied to the credential.
@Test("a failure that says nothing about the token records nothing")
func anUnrelatedFailureRecordsNothing() {
    for error in [
        SourceError.network, .timedOut, .siteNotFound, .notConfigured, .notFound,
        .invalidResponse, .rateLimited(retryAfter: nil), .unavailable(status: 503),
    ] {
        let outcome = RefreshOutcome(attempted: 1, failures: [failure(error)])

        #expect(
            CredentialRejection.from(outcome, at: moment) == nil,
            "\(error) must not be read as a credential rejection")
    }
}

/// Both Atlassian connectors share one credential (§5.3), so a pass that fails both has
/// found one broken token. The first failure wins rather than two records being kept.
@Test("two connectors sharing one credential record one rejection")
func twoConnectorsRecordOneRejection() throws {
    let outcome = RefreshOutcome(
        attempted: 2,
        failures: [
            failure(.credentialExpired), failure(.invalidCredential, connector: "confluence"),
        ])

    #expect(try #require(CredentialRejection.from(outcome, at: moment)).displayName == "Jira")
}

// MARK: - What clears one

@Test("a pass that reached a source and was not refused clears the record")
func aSuccessfulPassClears() {
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(attempted: 3, cached: 3)))
}

/// **The case that makes this correct.** A pass with nothing due is the normal case — most
/// ticks attempt nothing — so clearing on one would erase the warning within five minutes of
/// recording it. D-163's rule in the form this needs: an empty failure list is not evidence
/// of success.
@Test("a pass that attempted nothing clears nothing")
func anEmptyPassClearsNothing() {
    #expect(CredentialRejection.isCleared(by: .idle) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(notConfigured: 2)) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(disabled: 2)) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(readFailed: true)) == false)
}

@Test("a pass still being refused does not clear the record")
func aRefusedPassDoesNotClear() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.credentialExpired)])

    #expect(CredentialRejection.isCleared(by: outcome) == false)
}

/// A network failure neither records nor clears: the token is no more suspect than before,
/// and no less. Both halves asserted together, because the pair is the behaviour.
@Test("a network failure leaves an existing record exactly as it was")
func aNetworkFailureLeavesItAlone() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.network)])

    #expect(CredentialRejection.from(outcome, at: moment) == nil)
    #expect(CredentialRejection.isCleared(by: outcome) == false)
}
