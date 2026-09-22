import Foundation

/// §7.1's shipped provider: auth, budgets, retries, and error mapping.
///
/// **Transport and nothing else.** The prompt, the two schemas and §7.4's
/// fallback are M3-03's; the picker and the key field are M3-04's. What this
/// type owes them is the ordered model list (D-141), a timeout the fallback can
/// wait on (D-145), and the guarantee that every failure arrives as an
/// `AIError` — §7.4 cannot degrade on an error type it has never heard of.
///
/// **No signature here mentions an `AnthropicWire` type**, which is §7.1's
/// acceptance criterion: callers see only M3-01's neutral types.
///
/// A `struct` rather than an `actor`: nothing here is mutable, so there is no
/// state to protect, and `AIProvider: Sendable` (D-131) is satisfied by the
/// stored `Sendable` dependencies.
public struct AnthropicProvider: AIProvider {
    /// The numbers D-145 decided, in one place so M3-03 can read them and a
    /// test can shrink them.
    public struct Configuration: Sendable {
        public var baseURL: URL

        /// D-145: the tighter budget for `availableModels` and
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

    /// D-145's draft budget: the wall clock M3-03 puts in
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

    let transport: any HTTPTransport
    let credentials: any CredentialStore
    let configuration: Configuration

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

    /// Every model this key may use, ordered (D-141): element zero is the
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

            // **No page cap, and the deadline is the bound — but only because
            // the loop checks cancellation.** An earlier version stopped after
            // twenty pages, which turned a vendor that kept saying `has_more`
            // into a *silently truncated* list: a picker missing the user's
            // model, reported as success (PR #35 review).
            //
            // Removing the cap is only safe with the check below. Nothing else
            // in this loop suspends in a way that throws on cancellation — an
            // actor hop does not — so without it the deadline fires, the group
            // waits for a child that never notices, and the whole call hangs.
            // That is the same cooperative-cancellation trap `HTTPTransport`'s
            // doc comment warns implementers about, and this loop was quietly
            // an instance of it. A test that pages forever found it.
            while true {
                try Task.checkCancellation()

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

    /// Verify the stored credential (§7.1).
    ///
    /// The model list is the cheapest call that separates a rejected key (401,
    /// `.invalidCredential`) from an unreachable host (`.network`), and it
    /// inherits this type's whole mapping rather than re-deriving it.
    public func testConnection() async throws {
        _ = try await availableModels()
    }

    // MARK: - Plumbing

    static func send(
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
    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
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
    func apiKey() throws -> String {
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

    /// §8's one metrics line, emitted for a draft and for nothing else (D-147).
    func record(
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
