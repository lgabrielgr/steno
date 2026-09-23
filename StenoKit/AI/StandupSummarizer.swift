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

            // A draft that simply left work out is a worse failure than one
            // that arrived malformed, because nothing about it looks wrong.
            let dropped = Self.unreportedWork(in: window, draft: draft)
            guard dropped == 0 else {
                degraded(.invalidResponse(.incompleteDraft))
                return fallback
            }

            return SummarizedStandup(
                markdown: SlackMarkdown.render(sections), modelUsed: modelID)
        } catch let error as AIError {
            // **A cancelled polish is not a degradation** (PR #37 review). The
            // user closed the sheet or prepared another window; the result is
            // discarded either way. `AnthropicErrors` maps `CancellationError`
            // to `.timedOut` — correctly, because that is also how the
            // provider's own deadline fires — so without this check an ordinary
            // dismiss writes "fell back: timedOut" into the log someone reads
            // to find out why their report was rough, and tells them their
            // provider is slow when they cancelled it themselves.
            degraded(error, cancelled: Task.isCancelled)
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

    /// How many tasks the user wrote notes on that the draft never mentions.
    ///
    /// **Not "every task in the window must appear."** That reading is stricter
    /// than the fallback it would degrade to: `RawReportSections` records its
    /// own accepted gap — a task now `.todo` whose only window event is a status
    /// change appears under no daily heading — so requiring full coverage would
    /// reject drafts for omitting exactly what M2-02 omits, and hand the user
    /// the rougher report for being more faithful.
    ///
    /// What is never sanctioned is dropping words the user actually wrote. §7.3
    /// says a task too thin to summarize gets its raw note rather than padding;
    /// it nowhere permits silence. So the test is authored events: if the user
    /// typed something about a task inside the window and no bullet mentions
    /// that task, the draft lost work, and §7.4's report — which does carry it —
    /// is better.
    ///
    /// Counts rather than names them: §8 keeps task identity out of the log.
    static func unreportedWork(in window: GatheredWindow, draft: StandupDraft) -> Int {
        // `DraftSections.reportedTaskIDs`, not `draft.allTaskIDs`: the latter
        // counts a task named by a bullet with no words in it, which D-152 then
        // drops at render time (PR #37 review).
        let reported = DraftSections.reportedTaskIDs(in: draft)
        return window.tasks.filter { !reported.contains($0.id) && carriesUserWords($0) }.count
    }

    /// Whether omitting this task would lose something the user actually said.
    ///
    /// **Two carriers, not one.** Authored events are the obvious half. The
    /// other is `blockedReason`, which `GatheredTask` sources *independently of
    /// the window* — deliberately, so that "a task blocked last week, still
    /// blocked, with nothing new said since" still reports its reason, which is
    /// exactly the case where `events` is empty (D-069). `RawReportSections`
    /// puts every currently-blocked task under *Blockers* with that reason, so
    /// without this clause an AI draft could drop a standing blocker and be
    /// marked successful while the fallback it replaced would have spoken it
    /// (PR #37 review).
    ///
    /// A blocker nobody mentions is the worst thing this product can do to a
    /// stand-up.
    private static func carriesUserWords(_ task: GatheredTask) -> Bool {
        task.blockedReason != nil || task.events.contains { $0.kind.isUserAuthored }
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
    private func degraded(_ error: AIError, cancelled: Bool = false) {
        guard let label = Self.degradationLabel(for: error, cancelled: cancelled) else { return }
        Log.report.info("standup fell back to the raw report: \(label, privacy: .public)")
    }

    /// What the fallback line should say, or `nil` when there is nothing to say.
    ///
    /// **Split out so the rule is a test rather than a claim** — D-147's
    /// reasoning: `Log.report` writes to the unified log and cannot be read back
    /// in-process, so a test of the emitter could only check that it did not
    /// crash. This is the decision the emitter makes.
    static func degradationLabel(for error: AIError, cancelled: Bool) -> String? {
        guard !cancelled else { return nil }
        // The family, then the reason where there is one. §8's `ai` line keeps
        // D-137's single word; this is the `report` line, and "invalidResponse"
        // alone cannot tell a hallucinated shape from a draft that quietly left
        // half the window out (PR #37 review).
        guard case .invalidResponse(let reason) = error else { return error.metricsLabel }
        return "\(error.metricsLabel).\(reason.label)"
    }
}
