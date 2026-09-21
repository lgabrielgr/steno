import Foundation
import SwiftData
import Testing

@testable import StenoKit

// §8: "Tokens and API keys in Keychain only. Never in SwiftData,
// `UserDefaults`, plists, or logs."
//
// **Three assertions, one per destination that rule names**, each written so
// that the obvious way to break §8 turns it red. The mutation for each is in
// its doc comment and was run before this was committed — a test that cannot
// fail has been shipped on this project before, four at once.
//
// The scanner is `CredentialPatterns`, already used by §10.3's export audit.
// A second set of markers here would be a second thing to keep current.

// MARK: - SwiftData

@Test("no persisted model has a property that could hold a credential")
func noModelPropertyLooksLikeACredential() {
    // Mutation: add `var apiKey: String = ""` to any `@Model` type. Red.
    let schema = Schema(StenoStore.models())
    let names = schema.entities.flatMap { entity in
        entity.properties.map { "\(entity.name).\($0.name)" }
    }

    #expect(names.allSatisfy { !looksLikeACredential($0) }, "\(names)")

    // Without this, emptying `StenoStore.models()` would leave the assertion
    // above vacuously true — `allSatisfy` on an empty collection is `true`.
    #expect(schema.entities.count == 5)
    #expect(names.count > 20)
}

// MARK: - UserDefaults and plists

@Test("no setting is named like a credential")
func noSettingsKeyLooksLikeACredential() {
    // `UserDefaults` *is* the plist, so this covers both destinations §8 names.
    // Mutation: add an `apiKey` entry to `AppSettings.allKeys`. Red.
    #expect(AppSettings.allKeys.allSatisfy { !looksLikeACredential($0) }, "\(AppSettings.allKeys)")

    // The count is what stops this being a test that passes by matching
    // nothing: a new key must be listed in `allKeys`, and listing it moves this
    // number. Same guard `CredentialPatterns.all` carries for the same reason.
    #expect(AppSettings.allKeys.count == 8)
    #expect(Set(AppSettings.allKeys).count == AppSettings.allKeys.count)
}

@Test("the credential never reaches UserDefaults")
func storingACredentialTouchesNoDefaults() {
    // **An earlier version of this test could not fail.** It created a scratch
    // suite, ran a credential through `InMemoryCredentialStore`, and asserted
    // the scratch suite was empty — which it was going to be no matter what any
    // production code did, because nothing under test had ever heard of that
    // suite. Four such tests have shipped on this project before.
    //
    // This one runs the real harness path and looks where a leak would actually
    // land. Mutation: add `UserDefaults.standard.set(key, forKey: "x")` to
    // `KeychainSelftest.run`. Red.
    let store = InMemoryCredentialStore()

    _ = KeychainSelftest.run(store: store, out: { _ in })

    // Read-only, and narrow: the sentinel, not a key census, so a test running
    // beside this one cannot make it flake.
    //
    // **If you run that mutation, clean up after it.** The write lands in the
    // xctest tool's own domain and survives the run, so this test then fails on
    // an unmutated tree until you clear it:
    //
    //     defaults delete com.apple.dt.xctest.tool <key>
    //
    // That persistence is the test working — a leaked credential does not
    // evaporate when the process exits — but it will look like a broken suite.
    let values = UserDefaults.standard.dictionaryRepresentation().values
    let leaked = values.filter { String(describing: $0).contains("selftest-") }
    #expect(leaked.isEmpty, "\(leaked)")
}

// MARK: - Logs

@Test("the metrics line is exactly six fields, and none of them is a payload")
func theMetricsLineCarriesOnlyMetadata() {
    // Pinned character for character. Mutation: interpolate anything else into
    // `AIMetricsLog.line(for:)`. Red.
    let metrics = AIRequestMetrics(
        providerID: "anthropic",
        modelID: "a-model-id",
        latency: .milliseconds(1234),
        inputTokens: 900,
        outputTokens: 120,
        outcome: .succeeded)

    #expect(
        AIMetricsLog.line(for: metrics)
            == "ai provider=anthropic model=a-model-id ms=1234 in=900 out=120 outcome=ok")
}

@Test("a provider that reported no usage is distinguishable from one that reported zero")
func absentTokenCountsAreNotZero() {
    let metrics = AIRequestMetrics(
        providerID: "anthropic",
        modelID: "a-model-id",
        latency: .zero,
        inputTokens: nil,
        outputTokens: nil,
        outcome: .failed(label: AIError.timedOut.metricsLabel))

    #expect(
        AIMetricsLog.line(for: metrics)
            == "ai provider=anthropic model=a-model-id ms=0 in=- out=- outcome=timedOut")
}

@Test("AIRequestMetrics declares no field that could hold task text")
func metricsDeclaresOnlyMetadataFields() {
    // Mutation: add `let prompt: String` to `AIRequestMetrics`. Red.
    //
    // `Mirror` over an instance rather than a name check on the line above,
    // because a field can exist, carry a payload, and simply not be logged
    // yet — which is how the next task inherits a loaded gun.
    let metrics = AIRequestMetrics(
        providerID: "anthropic", modelID: "m", latency: .zero,
        inputTokens: nil, outputTokens: nil, outcome: .succeeded)

    let fields = Mirror(reflecting: metrics).children.compactMap(\.label)

    #expect(
        fields == ["providerID", "modelID", "latency", "inputTokens", "outputTokens", "outcome"])
}

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

// MARK: - Shared

/// Deliberately broader than `CredentialPatterns`, which matches *values*.
/// This matches *names*, which is the failure §8 is guarding here: a field
/// called `apiKey` is a problem before it ever holds a real key.
/// **Bare "key" is deliberately not a marker.** It matches `hotkeyChord`,
/// `jiraProjectKeys` and `dedupKey` — three legitimate domain terms in this
/// codebase — and a matcher that needs three suppressions on day one is one
/// whose fourth suppression hides a real finding. What is left catches the
/// names a credential actually arrives under.
private func looksLikeACredential(_ name: String) -> Bool {
    let lowered = name.lowercased()
    let markers = ["apikey", "api_key", "accesstoken", "token", "secret", "credential", "password"]
    return markers.contains { lowered.contains($0) }
}
