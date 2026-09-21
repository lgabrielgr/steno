import Foundation

/// Everything a provider needs to produce a draft, and nothing about how (§7.1).
///
/// **The prompt and the schema are built upstream and carried here.** M3-03
/// owns §7.3's prompt constraints — never introduce a fact, preserve ticket keys
/// verbatim, do not elevate register, 8–12 bullets for a long `periodic` window
/// — and this is how they reach a provider that knows only HTTP, auth, retries
/// and error mapping. A provider that composed its own prompt would mean every
/// future provider re-derived those constraints, and the one that got them
/// wrong would inflate the user's language in front of their team.
public struct StandupRequest: Sendable, Equatable {
    /// A model id from `availableModels()`, sent back verbatim.
    public let modelID: String

    /// D17's cadence, which selects both the schema and the `StandupDraft` case.
    public let cadence: ReportCadence

    public let systemPrompt: String
    public let userPrompt: String

    /// The JSON Schema the provider constrains the response to (§7.3).
    public let outputSchema: AIOutputSchema

    /// Every task id the prompt actually mentions, for §7.3's rejection rule.
    ///
    /// Carried on the request rather than kept by the caller so that
    /// `StandupDraft.validated(against:)` can run inside the provider, before a
    /// hallucinated id reaches anything that renders.
    public let allowedTaskIDs: Set<UUID>

    public let maxOutputTokens: Int

    /// **No default, deliberately.** M3-02 decides the budget — "if the API is
    /// slow, the user is standing in a meeting" — and a default here would
    /// quietly pre-empt that decision with a number chosen by a task that never
    /// made a network call.
    public let timeout: Duration

    public init(
        modelID: String,
        cadence: ReportCadence,
        systemPrompt: String,
        userPrompt: String,
        outputSchema: AIOutputSchema,
        allowedTaskIDs: Set<UUID>,
        maxOutputTokens: Int,
        timeout: Duration
    ) {
        self.modelID = modelID
        self.cadence = cadence
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.outputSchema = outputSchema
        self.allowedTaskIDs = allowedTaskIDs
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
    }
}

/// A JSON Schema document, as bytes (§7.3's structured outputs).
///
/// **Opaque on purpose.** Nothing in M3-01 through M3-04 inspects a schema;
/// they transmit it, and each provider maps it onto whatever structured-output
/// mechanism it has. A typed `JSONValue` tree would be machinery with no
/// reader, and would have to be kept in step with `StandupDraft` by hand.
public struct AIOutputSchema: Sendable, Equatable {
    /// The schema's name, where a provider's API wants one.
    public let name: String

    /// The schema document itself.
    public let json: Data

    public init(name: String, json: Data) {
        self.name = name
        self.json = json
    }
}
