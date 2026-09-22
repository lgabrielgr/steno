import Foundation

/// §7.1's shipped provider: auth, budgets, retries, and error mapping.
///
/// **Transport and nothing else.** The prompt, the two schemas and §7.4's
/// fallback are M3-03's; the picker and the key field are M3-04's. What this
/// type owes them is the ordered model list (D-140), a timeout the fallback can
/// wait on (D-144), and the guarantee that every failure arrives as an
/// `AIError` — §7.4 cannot degrade on an error type it has never heard of.
///
/// **No signature here mentions an `AnthropicWire` type**, which is §7.1's
/// acceptance criterion: callers see only M3-01's neutral types.
///
/// A `struct` rather than an `actor`: nothing here is mutable, so there is no
/// state to protect, and `AIProvider: Sendable` (D-131) is satisfied by the
/// stored `Sendable` dependencies.
public struct AnthropicProvider: AIProvider {
    /// The numbers D-144 decided, in one place so M3-03 can read them and a
    /// test can shrink them.
    public struct Configuration: Sendable {
        public var baseURL: URL

        /// D-144: the tighter budget for `availableModels` and
        /// `testConnection`. A user who clicked "Test connection" is watching,
        /// and a fast honest `.network` beats a slow correct one.
        public var settingsTimeout: Duration

        /// Used when a retryable failure named no interval of its own.
        public var retryBackoff: Duration

        /// How much budget beyond the backoff a retry must have to be worth
        /// starting. A retry certain to be cancelled mid-flight is a slower
        /// failure, not a second chance.
        public var retryHeadroom: Duration

        public init(
            baseURL: URL,
            settingsTimeout: Duration,
            retryBackoff: Duration,
            retryHeadroom: Duration
        ) {
            self.baseURL = baseURL
            self.settingsTimeout = settingsTimeout
            self.retryBackoff = retryBackoff
            self.retryHeadroom = retryHeadroom
        }

        public static let standard = Configuration(
            // Force-unwrapped, and safe: the argument is a literal, so this
            // either works on every launch or on none, and a test would catch
            // it before a user could.
            baseURL: URL(string: "https://api.anthropic.com")!,
            settingsTimeout: .seconds(10),
            retryBackoff: .seconds(1),
            retryHeadroom: .seconds(2)
        )
    }

    /// D-144's draft budget: the wall clock M3-03 puts in
    /// `StandupRequest.timeout`, covering attempt, backoff and retry.
    ///
    /// **A published constant rather than a field on `Configuration`**, because
    /// the provider does not choose it — M3-01 put `timeout` on the request and
    /// left it without a default so that "a task that never made a network
    /// call" could not pre-empt this decision. A field here would be one
    /// nothing reads, which is a bug filed against whoever next tries to change
    /// it and finds the value ignored.
    ///
    /// Twenty seconds because a stand-up draft is not streamed (§7, M3-02's
    /// out-of-scope list) and a Sonnet-class summarization lands in 5–15s:
    /// twelve would cut off a legitimate periodic window, and thirty is most of
    /// the time the user has before they speak.
    public static let recommendedDraftTimeout: Duration = .seconds(20)

    /// Keys the Keychain item (`CredentialStore`), so it is stable across
    /// launches and must not be renamed.
    public let id = "anthropic"

    public let displayName = "Anthropic"

    private let transport: any HTTPTransport
    private let credentials: any CredentialStore
    private let configuration: Configuration

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentials: any CredentialStore,
        configuration: Configuration = .standard
    ) {
        self.transport = transport
        self.credentials = credentials
        self.configuration = configuration
    }

    // MARK: - AIProvider

    /// Every model this key may use, ordered (D-140): element zero is the
    /// recommended default.
    public func availableModels() async throws -> [AIModel] {
        let key = try apiKey()
        let transport = self.transport
        let baseURL = configuration.baseURL

        // **The catch is not redundant with `send`'s.** Cancelling the *caller*
        // cancels this deadline's child tasks, and `Task.sleep` then throws a
        // bare `CancellationError` straight out of the group — past every
        // mapping inside it. `generateStandup` already had a catch-all for the
        // same reason; a mapping applied to one of two sibling paths is the
        // defect this repo keeps re-learning (PR #35 review).
        do {
            return try await Self.fetchModels(
                transport: transport,
                baseURL: baseURL,
                key: key,
                timeout: configuration.settingsTimeout
            )
        } catch {
            throw AnthropicErrors.error(forTransport: error)
        }
    }

    private static func fetchModels(
        transport: any HTTPTransport,
        baseURL: URL,
        key: String,
        timeout: Duration
    ) async throws -> [AIModel] {
        try await withDeadline(timeout) {
            var collected: [AnthropicModel] = []
            var cursor: String?

            // A bound rather than `while true`. Every termination condition
            // below depends on a field the vendor controls, and a page that
            // reports `has_more` forever would otherwise spin until the
            // deadline — burning the user's budget instead of answering.
            for _ in 0..<Self.maximumModelPages {
                let request = AnthropicWire.modelsRequest(
                    baseURL: baseURL, apiKey: key, after: cursor)
                let response = try await Self.send(request, on: transport)
                let page = try Self.decode(AnthropicModelsPage.self, from: response.body)
                collected.append(contentsOf: page.data)

                // Three ways to stop: the API said there is no more, it named
                // no cursor, or it named the cursor we just used.
                guard page.hasMore == true, let last = page.lastID, last != cursor else { break }
                cursor = last
            }

            return ModelRanking.ordered(collected)
        }
    }

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

    /// Verify the stored credential (§7.1).
    ///
    /// The model list is the cheapest call that separates a rejected key (401,
    /// `.invalidCredential`) from an unreachable host (`.network`), and it
    /// inherits this type's whole mapping rather than re-deriving it.
    public func testConnection() async throws {
        _ = try await availableModels()
    }

    // MARK: - The draft path

    private static let maximumModelPages = 20

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

        return try await withDeadline(request.timeout) {
            var retried = false
            while true {
                do {
                    let response = try await Self.send(httpRequest, on: transport)
                    return try Self.draft(from: response.body, cadence: cadence, allowed: allowed)
                } catch let error as AIError {
                    // D-144: one retry, on 429/529/5xx only, and only when
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
            // will never change. D-144 permits a retry for 429, 529 and 5xx,
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
    /// API reports `usage` and then the draft fails. D-146 says the metrics
    /// line keeps the token counts whenever the response carried them, and
    /// without this wrapper the catch has nothing to keep — it would record
    /// `nil` for the one class of failure that actually cost the user money
    /// (PR #35 review).
    ///
    /// `internal` rather than `private`, with `draft(from:cadence:allowed:)`,
    /// so that "the token counts survive the failure" is a test rather than a
    /// claim: `record` writes to the unified log and cannot be read back
    /// in-process, so the only way to assert D-146's rule is to assert the
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

    // MARK: - Plumbing

    private static func send(
        _ request: HTTPRequest, on transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AnthropicErrors.error(forTransport: error)
        }

        if let failure = AnthropicErrors.error(
            forStatus: response.status, headers: response.headers)
        {
            throw failure
        }
        return response
    }

    /// Decode a wire type, reporting anything unreadable as `.undecodable`.
    ///
    /// The `DecodingError` is dropped rather than described: its message quotes
    /// the coding path and, for a type mismatch, the value that failed — which
    /// on the draft path is the user's stand-up (§8, D-132).
    private static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw AIError.invalidResponse(.undecodable)
        }
    }

    /// The stored API key, or `.notConfigured` (§7.4's "is not configured").
    ///
    /// `.oauth` resolves to `.notConfigured` too: §7.2 ships the API key path
    /// only, and a token this provider cannot send is indistinguishable, from
    /// the user's side, from no credential at all.
    private func apiKey() throws -> String {
        let stored: Credential?
        do {
            stored = try credentials.credential(for: id)
        } catch {
            // A Keychain read that fails is reported as "not configured"
            // rather than surfaced: there is no `AIError` case for it, and
            // every remedy the user has — re-enter the key — is the same one
            // `.notConfigured` already asks for.
            throw AIError.notConfigured
        }

        guard case .apiKey(let key) = stored, !key.isEmpty else {
            throw AIError.notConfigured
        }
        return key
    }

    /// §8's one metrics line, emitted for a draft and for nothing else (D-146).
    private func record(
        _ request: StandupRequest,
        started: ContinuousClock.Instant,
        inputTokens: Int?,
        outputTokens: Int?,
        outcome: AIRequestMetrics.Outcome
    ) {
        AIMetricsLog.record(
            AIRequestMetrics(
                providerID: id,
                modelID: request.modelID,
                latency: started.duration(to: ContinuousClock.now),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                outcome: outcome
            )
        )
    }
}
