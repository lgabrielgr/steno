import Foundation
import Testing

@testable import StenoKit

/// `SourceError`'s two vocabularies (D-165), the way `AIErrorTests` covers
/// `AIError`'s.

/// Every case, so both switches below are exercised exhaustively. A case added
/// without a line here still fails to compile inside `SourceError` itself — both
/// switches are exhaustive — but a *wrong* label compiles fine, which is what
/// these tests are for.
private let everyCase: [SourceError] = [
    .notConfigured,
    .invalidCredential,
    .notFound,
    .network,
    .timedOut,
    .rateLimited(retryAfter: nil),
    .unavailable(status: 503),
    .invalidResponse,
]

@Test("every case has its own metrics label")
func labelsAreDistinct() {
    let labels = everyCase.map(\.metricsLabel)

    // Distinct, so a copy-pasted label cannot make two failures indistinguishable
    // in the log someone reads to find out why a report was stale.
    #expect(Set(labels).count == labels.count)
    #expect(!labels.contains { $0.isEmpty })
}

@Test("§8: no label or message carries an associated value")
func labelsCarryNoPayload() {
    // D-165's property: a `SourceError` is always safe to log. A label derived
    // from `String(describing:)` would print `retryAfter` and a status code into a
    // field that is supposed to be one word.
    #expect(SourceError.rateLimited(retryAfter: .seconds(30)).metricsLabel == "rateLimited")
    #expect(SourceError.unavailable(status: 503).metricsLabel == "unavailable")
    #expect(SourceError.unavailable(status: 503).errorDescription?.contains("503") == false)
    #expect(
        SourceError.rateLimited(retryAfter: .seconds(30)).errorDescription?.contains("30")
            == false)
}

@Test("every case explains itself to the user")
func everyCaseHasAMessage() {
    for error in everyCase {
        let message = error.errorDescription ?? ""
        #expect(!message.isEmpty, "\(error.metricsLabel) has no message")
        // The banner puts these in front of someone about to read a stand-up out
        // loud, so a message has to be a sentence rather than the case's name.
        //
        // **Not "the message must not contain the label"**, which was the first
        // attempt: `.unavailable`'s message says "unavailable" because that is the
        // ordinary English word for it, and the test failed on correct copy.
        #expect(message != error.metricsLabel)
        #expect(message.contains(" "), "\(error.metricsLabel)'s message is one word")
        #expect(message.hasSuffix("."), "\(error.metricsLabel)'s message is not a sentence")
    }
}

@Test("the retry-after interval is part of the value, not the label")
func rateLimitedCarriesItsInterval() {
    // Carried because M4-02 needs it and §5.5's best-effort pass may want to
    // respect it; kept out of the label for the reason above.
    guard case .rateLimited(let retryAfter) = SourceError.rateLimited(retryAfter: .seconds(30))
    else {
        Issue.record("expected .rateLimited")
        return
    }
    #expect(retryAfter == .seconds(30))
}
