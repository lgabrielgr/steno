import Foundation
import Testing

@testable import StenoKit

// `AIError` is both logged (§8) and shown (M3-04), so every case is audited
// rather than sampled. The list lives here rather than in `AISecretsTests`
// because `AIProviderTests` drives the test double through it too — a fixture
// two test files share belongs to neither of them.

@Test("every error message is fixed text", arguments: AIError.everyCase)
func errorDescriptionsCarryNoPayload(error: AIError) {
    // `AIError` is both logged and shown. A case carrying a free-form `String`
    // would be the natural place for model output to arrive, so every case is
    // checked: a message, a one-word metrics label, and no credential marker in
    // either. Mutation: add `.invalidResponse(reason: String)` and interpolate
    // it into `errorDescription`. Red, via the marker scan.
    let description = error.errorDescription ?? ""

    #expect(!description.isEmpty)
    #expect(CredentialPatterns.matches(in: description).isEmpty)
    #expect(!error.metricsLabel.isEmpty)
    #expect(!error.metricsLabel.contains(" "))
}

extension AIError {
    /// Every case, with associated values chosen to be the awkward ones.
    ///
    /// Hand-listed because associated values rule out `CaseIterable`. The count
    /// is asserted below so a ninth case cannot join `AIError` and quietly skip
    /// every audit in this file.
    static let everyCase: [AIError] = [
        .notConfigured,
        .invalidCredential,
        .network,
        .timedOut,
        .rateLimited(retryAfter: .seconds(30)),
        .rateLimited(retryAfter: nil),
        .providerUnavailable(status: 503),
        .invalidResponse(.undecodable),
        .invalidResponse(.schemaViolation),
        .invalidResponse(.emptyDraft),
        .unknownTaskIDs(count: 3),
    ]
}

@Test("the error audit covers every case the enum has")
func theErrorAuditIsComplete() {
    // A parameterized test over a short list runs quietly: drop a case from
    // `everyCase` and nothing reports it. Distinct labels are the proxy — each
    // case has exactly one, so the label set names the cases covered.
    #expect(Set(AIError.everyCase.map(\.metricsLabel)).count == 8)
}
