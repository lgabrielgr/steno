import Foundation

/// `AnthropicProvider`'s draft path: §7.3's call, D-145's retry, and the
/// failure wrapper that keeps §8's token counts.
///
/// **Split from the main file only because SwiftLint caps a file at 400 lines**
/// — the provider crossed it once the review fixes landed. The boundary is a
/// real one even so: everything here is about turning one `StandupRequest`
/// into one validated `StandupDraft`, while the main file owns the model list,
/// the credential, and the shared plumbing.
extension AnthropicProvider {

    /// Summarize a window (§7.3), already validated against the ids the app
    /// sent.
    public func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        let started = ContinuousClock.now
        do {
            let (draft, usage) = try await attemptDraft(request)
            record(
                request,
                started: started,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                outcome: .succeeded
            )
            return draft
        } catch {
            // `DraftFailure` never escapes this method: it is unwrapped here
            // for the usage it carries, and what leaves is an `AIError`, which
            // is the contract §7.4 relies on.
            let failure = error as? DraftFailure
            let mapped = AnthropicErrors.error(forTransport: failure?.error ?? error)
            record(
                request,
                started: started,
                inputTokens: failure?.usage?.inputTokens,
                outputTokens: failure?.usage?.outputTokens,
                outcome: .failed(label: mapped.metricsLabel)
            )
            throw mapped
        }
    }
    // MARK: - The draft path

    private func attemptDraft(
        _ request: StandupRequest
    ) async throws -> (StandupDraft, AnthropicUsage?) {
        let key = try apiKey()
        let body = try AnthropicWire.messagesBody(for: request)
        let httpRequest = AnthropicWire.messagesRequest(
            baseURL: configuration.baseURL, apiKey: key, body: body)
        let transport = self.transport
        let configuration = self.configuration
        let cadence = request.cadence
        let allowed = request.allowedTaskIDs

        // Captured before the race starts, so the retry gate measures the
        // budget the caller asked for rather than the time left in a clock the
        // deadline task owns.
        let deadline = ContinuousClock.now.advanced(by: request.timeout)

        return try await withDeadline(request.timeout, throwing: AIError.timedOut) {
            var retried = false
            while true {
                do {
                    let response = try await Self.send(httpRequest, on: transport)
                    return try Self.draft(from: response.body, cadence: cadence, allowed: allowed)
                } catch let error as AIError {
                    // D-145: one retry, on 429/529/5xx only, and only when
                    // `backoff + headroom` still fits in the budget. A
                    // `retry-after` that cannot fit fails immediately with
                    // `.rateLimited` so M3-03 can say something specific,
                    // rather than after a wait it already knows is futile.
                    guard !retried,
                        let backoff = Self.backoff(for: error, configuration: configuration),
                        ContinuousClock.now.advanced(by: backoff + configuration.retryHeadroom)
                            < deadline
                    else { throw error }

                    retried = true
                    try await Task.sleep(for: backoff)
                }
            }
        }
    }

    /// How long to wait before the one permitted retry, or `nil` for a failure
    /// that must not be retried.
    private static func backoff(
        for error: AIError, configuration: Configuration
    ) -> Duration? {
        switch error {
        case .rateLimited(let retryAfter):
            return retryAfter ?? configuration.retryBackoff
        case .providerUnavailable(let status) where (500..<600).contains(status):
            // **Gated on 5xx, not on the case.** `AnthropicErrors` files every
            // non-2xx, non-4xx status here, which includes the 3xx a custom
            // transport might surface without following it — and retrying a
            // redirect means sending the same POST twice for a response that
            // will never change. D-145 permits a retry for 429, 529 and 5xx,
            // and this is that list rather than its enclosing case (PR #35
            // review).
            return configuration.retryBackoff
        default:
            // Everything else is either ours to fix (`.invalidRequest`,
            // `.invalidCredential`), already out of time (`.timedOut`), a
            // status no retry can change (3xx), or a failure a second
            // identical request cannot change.
            return nil
        }
    }

    /// An `AIError` plus the usage the response reported before it failed.
    ///
    /// **Internal to the draft path and never thrown past `generateStandup`.**
    /// A refusal, a truncation and a hallucinated id are all billed calls: the
    /// API reports `usage` and then the draft fails. D-147 says the metrics
    /// line keeps the token counts whenever the response carried them, and
    /// without this wrapper the catch has nothing to keep — it would record
    /// `nil` for the one class of failure that actually cost the user money
    /// (PR #35 review).
    ///
    /// `internal` rather than `private`, with `draft(from:cadence:allowed:)`,
    /// so that "the token counts survive the failure" is a test rather than a
    /// claim: `record` writes to the unified log and cannot be read back
    /// in-process, so the only way to assert D-147's rule is to assert the
    /// value the catch is handed.
    struct DraftFailure: Error {
        let error: AIError
        let usage: AnthropicUsage?
    }

    static func draft(
        from body: Data, cadence: ReportCadence, allowed: Set<UUID>
    ) throws -> (StandupDraft, AnthropicUsage?) {
        let response = try decode(AnthropicMessagesResponse.self, from: body)
        let usage = response.usage

        switch response.stopReason {
        case AnthropicWire.StopReason.refusal:
            // A distinct reason, not `.undecodable`: the model declined, which
            // says nothing about whether it can produce §7.3's schema.
            throw DraftFailure(error: .invalidResponse(.refused), usage: usage)
        case AnthropicWire.StopReason.maxTokens:
            // The JSON is cut off mid-object, so decoding it would report
            // `.undecodable` and blame the model for a budget the app set.
            throw DraftFailure(error: .invalidResponse(.truncated), usage: usage)
        default:
            break
        }

        guard
            let text = response.content.first(where: { $0.type == "text" })?.text,
            !text.isEmpty
        else {
            throw DraftFailure(error: .invalidResponse(.emptyDraft), usage: usage)
        }

        do {
            let draft = try StandupDraft.decode(Data(text.utf8), cadence: cadence)
            // §7.3's hallucinated-id rejection runs here, inside the provider,
            // so the next provider inherits it rather than re-deriving it
            // (D-133).
            return (try draft.validated(against: allowed), usage)
        } catch let error as AIError {
            throw DraftFailure(error: error, usage: usage)
        }
    }
}
