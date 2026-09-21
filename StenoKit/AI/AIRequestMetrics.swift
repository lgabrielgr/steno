import Foundation

/// What §8 permits recording about an AI call: "token counts, latency, model".
///
/// **There is no field here that could hold a prompt or a draft**, and that is
/// the design. §8's rule — metadata yes, "never full payloads by default" — is
/// enforced by the shape of the type rather than by a convention each provider
/// has to remember, so a test can assert it by inspection.
public struct AIRequestMetrics: Sendable, Equatable {
    public let providerID: String
    public let modelID: String
    public let latency: Duration

    /// `nil` where the provider reported no usage — a failure before the call
    /// completed, typically.
    public let inputTokens: Int?
    public let outputTokens: Int?

    public let outcome: Outcome

    /// Success, or an `AIError.metricsLabel`.
    ///
    /// A label rather than the `AIError` itself: `rateLimited` carries a
    /// `Duration` and `providerUnavailable` a status code, and a metrics line
    /// that interpolated the error whole would print them into a field meant to
    /// be one word from a fixed vocabulary.
    public enum Outcome: Sendable, Equatable {
        /// Spelled out because SwiftLint rejects a two-character case name.
        /// The *logged* label stays `ok`: a log line is read in bulk.
        case succeeded
        case failed(label: String)
    }

    public init(
        providerID: String,
        modelID: String,
        latency: Duration,
        inputTokens: Int?,
        outputTokens: Int?,
        outcome: Outcome
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.latency = latency
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.outcome = outcome
    }
}

/// The one place an AI call is logged (§8).
///
/// **One emitter with one call site, rather than a `Logger` and a doc comment
/// listing what may be logged.** A category plus a written rule makes §8 a
/// convention every future provider must remember, with nothing failing when one
/// forgets; a single `record` leaves no seam to invent a log line through.
///
/// **No payload-logging path exists anywhere in this codebase** — not behind
/// `#if DEBUG`, not behind a defaults key. That opt-in is the literal reading of
/// §8's "by default", and it writes the user's stand-up into the unified log,
/// where `log show` retrieves it long afterwards. M3-03 can add one if working
/// on §7.3's prompt genuinely demands it.
public enum AIMetricsLog {
    public static func record(_ metrics: AIRequestMetrics) {
        // One `.public` interpolation of a line built in full, rather than six
        // interpolations of six values. `Logger` redacts non-literal strings by
        // default, so a model id logged without the annotation arrives as
        // `<private>` — a failure invisible in review and visible only in
        // `log show`, which would defeat §8's metadata requirement while looking
        // like it satisfied it. One annotation is one place to get that right.
        Log.aiLayer.info("\(line(for: metrics), privacy: .public)")
    }

    /// The exact text `record` emits.
    ///
    /// **Split out so §8 can be asserted rather than asserted *about*.** A
    /// `Logger` call cannot be read back in-process, so a test of `record`
    /// alone could only check that it did not crash. This is the string, and
    /// `AISecretsTests` pins it character for character — which is what makes
    /// "no payload is ever logged" a test that fails when someone adds one.
    static func line(for metrics: AIRequestMetrics) -> String {
        let outcome: String
        switch metrics.outcome {
        case .succeeded: outcome = "ok"
        case .failed(let label): outcome = label
        }

        return "ai provider=\(metrics.providerID) model=\(metrics.modelID) "
            + "ms=\(metrics.latency.milliseconds) "
            + "in=\(describe(metrics.inputTokens)) out=\(describe(metrics.outputTokens)) "
            + "outcome=\(outcome)"
    }

    /// `-` rather than `nil` or `0`: a provider that reported no usage and one
    /// that reported zero tokens are different facts, and zero is a number
    /// someone will eventually sum.
    private static func describe(_ tokens: Int?) -> String {
        tokens.map(String.init) ?? "-"
    }
}

extension Duration {
    /// Whole milliseconds, for a log line and for nothing else.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
