import Foundation

/// What the model sent back, in §7.3's two shapes and no vendor's (§7.1).
///
/// **The cadence tag is not decoration.** §7.3 is explicit that `daily` and
/// `periodic` "are not cosmetic variants of each other — the sections differ,
/// and so does the cardinality of the task reference". A daily bullet covers
/// one task; a periodic bullet may theme several together, which is what
/// licenses the grouping §7.3 mandates for long windows.
///
/// **Not `[ReportSection]`.** Returning the type `RawReportSections` already
/// produces would let M3-03 hand the result straight to `SlackMarkdown` — at
/// the cost of putting §7.3's section names and D17's cadence wording inside
/// the vendor layer, where every future provider would re-implement them.
/// `ReportSection`'s own doc comment anticipated this split; these are the
/// "schema-validated AI bullets" it names.
public enum StandupDraft: Sendable, Equatable {
    case daily(DailyDraft)
    case periodic(PeriodicDraft)
}

/// §7.3's `daily` schema: one bullet per task, three DSU sections.
public struct DailyDraft: Sendable, Equatable, Codable {
    public let sinceLastStandup: [DailyBullet]
    public let today: [DailyBullet]
    public let blockers: [DailyBullet]

    private enum CodingKeys: String, CodingKey {
        case sinceLastStandup = "since_last_standup"
        case today
        case blockers
    }

    public init(sinceLastStandup: [DailyBullet], today: [DailyBullet], blockers: [DailyBullet]) {
        self.sinceLastStandup = sinceLastStandup
        self.today = today
        self.blockers = blockers
    }
}

/// §7.3's `periodic` schema: themed bullets that may each span several tasks.
public struct PeriodicDraft: Sendable, Equatable, Codable {
    public let completed: [ThemedBullet]
    public let inFlight: [ThemedBullet]
    public let blockersAndRisks: [ThemedBullet]

    private enum CodingKeys: String, CodingKey {
        case completed
        case inFlight = "in_flight"
        case blockersAndRisks = "blockers_and_risks"
    }

    public init(
        completed: [ThemedBullet],
        inFlight: [ThemedBullet],
        blockersAndRisks: [ThemedBullet]
    ) {
        self.completed = completed
        self.inFlight = inFlight
        self.blockersAndRisks = blockersAndRisks
    }
}

/// One task's line (§7.3, `daily`).
public struct DailyBullet: Sendable, Equatable, Codable {
    public let taskID: UUID
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case text
    }

    public init(taskID: UUID, text: String) {
        self.taskID = taskID
        self.text = text
    }
}

/// One themed line, covering one or more tasks (§7.3, `periodic`).
///
/// `taskIDs` plural is what lets the app link a merged bullet back to every
/// task it covers. §7.3: "A `daily` bullet that tried to do this would be a
/// bug."
public struct ThemedBullet: Sendable, Equatable, Codable {
    public let taskIDs: [UUID]
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case taskIDs = "task_ids"
        case text
    }

    public init(taskIDs: [UUID], text: String) {
        self.taskIDs = taskIDs
        self.text = text
    }
}

extension StandupDraft {
    /// Every task id this draft refers to, across all three of its sections.
    public var allTaskIDs: Set<UUID> {
        switch self {
        case .daily(let draft):
            let bullets = draft.sinceLastStandup + draft.today + draft.blockers
            return Set(bullets.map(\.taskID))
        case .periodic(let draft):
            let bullets = draft.completed + draft.inFlight + draft.blockersAndRisks
            return Set(bullets.flatMap(\.taskIDs))
        }
    }

    /// No bullets in any section.
    ///
    /// Not the same as "no task ids": a bullet with an empty `task_ids` array is
    /// still a bullet the model wrote, and losing it silently would be worse
    /// than surfacing it.
    public var isEmpty: Bool {
        switch self {
        case .daily(let draft):
            return draft.sinceLastStandup.isEmpty && draft.today.isEmpty && draft.blockers.isEmpty
        case .periodic(let draft):
            return draft.completed.isEmpty && draft.inFlight.isEmpty
                && draft.blockersAndRisks.isEmpty
        }
    }

    /// §7.3's loud failure, run before any caller sees a draft.
    ///
    /// "Both schemas must reject a `task_id` the app didn't send — a
    /// hallucinated ID is the clearest possible signal the model invented a
    /// fact, and it should fail loudly into the §7.4 fallback rather than
    /// render."
    ///
    /// **This lives here, and the provider calls it, rather than living in
    /// M3-03.** Both placements work for the provider that exists; only this one
    /// works for the provider that doesn't yet, because a rule the caller
    /// applies is a rule the next provider can ship without and nothing fails.
    public func validated(against allowed: Set<UUID>) throws -> StandupDraft {
        guard !isEmpty else {
            throw AIError.invalidResponse(.emptyDraft)
        }
        let unknown = allTaskIDs.subtracting(allowed)
        guard unknown.isEmpty else {
            throw AIError.unknownTaskIDs(count: unknown.count)
        }
        return self
    }

    /// Decode §7.3's JSON into the shape `cadence` selects.
    ///
    /// Decoding lives here rather than in each provider so that the wire names
    /// are written once. The `DecodingError` split is meaningful: JSON that
    /// isn't JSON is a different fault from JSON that doesn't match the schema
    /// the request supplied, and M3-02 reports them differently.
    public static func decode(_ data: Data, cadence: ReportCadence) throws -> StandupDraft {
        // "Is this JSON at all?" asked separately, rather than inferred from
        // which `DecodingError` came back. `dataCorrupted` is thrown both for
        // bytes that are not JSON *and* for JSON carrying a malformed UUID —
        // so switching on the error kind would file a hallucinated `task_id`
        // format under `.undecodable` and tell M3-03 the provider returned
        // garbage when it returned well-formed JSON that broke the schema.
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw AIError.invalidResponse(.undecodable)
        }

        do {
            switch cadence {
            case .daily:
                return .daily(try JSONDecoder().decode(DailyDraft.self, from: data))
            case .periodic:
                return .periodic(try JSONDecoder().decode(PeriodicDraft.self, from: data))
            }
        } catch is DecodingError {
            throw AIError.invalidResponse(.schemaViolation)
        }
    }
}
