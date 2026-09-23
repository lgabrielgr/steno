import Foundation

/// A report and how it was produced (§7.3, §7.4).
///
/// **`modelUsed == nil` is the fallback**, and it is the only carrier of that
/// fact: `StandupReport.wasAIGenerated` is derived from it (D-151) rather than
/// set beside it, so the two cannot disagree about what the user copied.
public struct SummarizedStandup: Sendable, Equatable {
    public let markdown: String

    /// The model id that produced this, or `nil` when §7.4's raw path did.
    public let modelUsed: String?

    public init(markdown: String, modelUsed: String?) {
        self.markdown = markdown
        self.modelUsed = modelUsed
    }
}

/// §7.3's call and §7.4's degradation, in one place that cannot throw.
///
/// **`summarize` has no `throws`, and that is §7.4 expressed as a type.** "The
/// user must never arrive at a stand-up empty-handed because of a network
/// error" — so there is no error a caller could be handed, and therefore no
/// path on which a caller could forget to degrade. Every failure below returns
/// the same raw report M2-02 built for this window.
///
/// **The fallback is not the error handler.** §7.4 required the raw path be
/// built *first*, and M3-03's reading is that the draft sheet opens on it
/// (D-148): this type is what upgrades that text, not what rescues it.
public struct StandupSummarizer: Sendable {
    /// D-154: one budget for both cadences. A worst-case `daily` answer under
    /// D18's 20-task cap is roughly 3,000 tokens, and `periodic` is capped at
    /// 8–12 bullets by the prompt. Erring high costs nothing — output tokens
    /// are billed as used — while erring low makes the AI silently never work.
    public static let maxOutputTokens = 4096

    private let provider: (any AIProvider)?
    private let modelID: String?
    private let timeout: Duration
    private let timeZone: TimeZone

    /// - Parameters:
    ///   - provider: `nil` when no provider is configured at all.
    ///   - modelID: the user's selection from M3-04's picker; `nil` until they
    ///     have made one, which is every launch until M3-04 ships.
    ///   - timeout: passed in rather than read from a vendor constant — the
    ///     composition root already chooses the provider, so it supplies the
    ///     budget with it. A vendor-neutral type naming one vendor's constant
    ///     would make §7.1's neutrality true by convention rather than by
    ///     construction.
    ///   - timeZone: injected for the prompt's timestamps, so a test does not
    ///     depend on the machine's zone.
    public init(
        provider: (any AIProvider)?,
        modelID: String?,
        timeout: Duration,
        timeZone: TimeZone = .current
    ) {
        self.provider = provider
        self.modelID = modelID
        self.timeout = timeout
        self.timeZone = timeZone
    }

    /// The best report this window can produce right now.
    public func summarize(_ window: GatheredWindow) async -> SummarizedStandup {
        let fallback = SummarizedStandup(markdown: Self.rawMarkdown(for: window), modelUsed: nil)

        // No provider, no selected model, or nothing to summarize: the raw
        // report without a network call. An empty window is not an error — it
        // is three headings that each say `_None_` (D-074) — and paying for a
        // call whose only possible answer is an empty draft would be a slower
        // way to reach this same string.
        guard let provider, let modelID, !window.tasks.isEmpty else { return fallback }

        do {
            let draft = try await provider.generateStandup(
                request(for: window, modelID: modelID))
            let sections = DraftSections.build(from: draft, window: window)

            // D-152. `StandupDraft.validated(against:)` already rejected an empty
            // draft inside the provider, but it counts bullets rather than
            // content: a model answering with blank strings passes there and
            // arrives here as three empty sections.
            guard sections.contains(where: { !$0.bullets.isEmpty }) else {
                degraded(.invalidResponse(.emptyDraft))
                return fallback
            }

            return SummarizedStandup(
                markdown: SlackMarkdown.render(sections), modelUsed: modelID)
        } catch let error as AIError {
            degraded(error)
            return fallback
        } catch {
            // **An error the protocol says cannot occur.** `AIProvider`'s
            // contract is that an implementation throws `AIError` and nothing
            // else. This is one line, and without it a future provider leaking
            // a `URLError` takes the draft path down instead of roughening it —
            // which is the one outcome §7.4 exists to prevent.
            Log.report.error("the summarizer caught a non-AIError; a provider broke its contract")
            return fallback
        }
    }

    /// §7.4's raw report for this window: M2-02's two pure functions, unchanged.
    ///
    /// `static` and free of everything this type holds, so "the fallback needs
    /// no provider, no key, and no network" is visible in the signature.
    ///
    /// `public` because it is also what `StandupDraftModel` opens the sheet
    /// with when no polish is configured: one name for §7.4's raw report keeps
    /// the two paths from drifting into two spellings of the same two calls.
    public static func rawMarkdown(for window: GatheredWindow) -> String {
        SlackMarkdown.render(RawReportSections.build(from: window))
    }

    /// Everything §7.3 sends, assembled where the constraints live.
    private func request(for window: GatheredWindow, modelID: String) -> StandupRequest {
        StandupRequest(
            modelID: modelID,
            cadence: window.cadence,
            systemPrompt: StandupPrompt.system(for: window.cadence),
            userPrompt: StandupPrompt.user(for: window, timeZone: timeZone),
            outputSchema: StandupSchema.schema(for: window.cadence),
            // Every id the prompt mentions, so the provider can run §7.3's
            // hallucination check before a draft reaches anything that renders.
            allowedTaskIDs: Set(window.tasks.map(\.id)),
            maxOutputTokens: Self.maxOutputTokens,
            timeout: timeout
        )
    }

    /// Why this report is the rough one.
    ///
    /// **`Log.report`, not `Log.aiLayer`.** This is a decision the report path
    /// made, not a measurement of an AI call — §8 gives the `ai` category to
    /// `AIMetricsLog.record` as its only emitter, and the provider has already
    /// written this call's metrics line there.
    ///
    /// Carries `metricsLabel` and nothing else: it is a word from a fixed
    /// vocabulary, and no `AIError` case holds free-form text precisely so that
    /// logging one cannot leak a stand-up (§8).
    private func degraded(_ error: AIError) {
        Log.report.info(
            "standup fell back to the raw report: \(error.metricsLabel, privacy: .public)")
    }
}
