import Foundation

/// §7.1's mid-tier default, chosen from a list that is fetched rather than
/// compiled in (D-141).
///
/// §7.1 sets two rules that pull against each other: the list "must be fetched
/// at runtime … not hardcoded", and the default should be "a mid-tier model …
/// this is not a reasoning-heavy workload, and cost per stand-up should stay
/// negligible." The wire response carries `id`, `display_name`, `created_at`,
/// `max_input_tokens`, `max_tokens` and a `capabilities` tree — no tier and no
/// pricing. Nothing on the wire distinguishes mid-tier from top-tier.
///
/// **So the list is returned ordered, and element zero is the default.** No
/// model id is compiled in as the source of the picker's contents, and a
/// `claude-sonnet-6` is preferred the day it appears, with no release. What is
/// compiled in is a preference among *family words*, which is the honest
/// description of what §7.1 asks for: it names a tier, and the tier is not on
/// the wire.
///
/// **Ranking runs on the wire records, not on `AIModel`.** `AIModel` is two
/// fields by D-129's reasoning and carries no `created_at`, and sorting ids as
/// strings puts `claude-sonnet-10` below `claude-sonnet-5`.
enum ModelRanking {
    /// Rank, filter, and map one fetched page-set into what §7.1's picker shows.
    ///
    /// **Deduplicated by id, because paging can hand the same model twice.**
    /// The provider's loop appends a page before it can know the page repeats —
    /// so if the API ignores `after_id`, or simply returns overlapping pages as
    /// cursor schemes are allowed to, the picker would offer the same model
    /// twice. The cursor guard upstream stops the *loop*; it cannot un-append
    /// what it has already collected (PR #35 review).
    ///
    /// First occurrence wins, and it is taken before the sort, so "first" means
    /// the earlier page rather than something the ordering decided.
    static func ordered(_ models: [AnthropicModel]) -> [AIModel] {
        var seen: Set<String> = []
        return
            models
            .filter { $0.supportsStructuredOutputs != false }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: precedes)
            .map { AIModel(id: $0.id, displayName: $0.displayName) }
    }

    /// 0 for sonnet, 1 for haiku, 2 for everything else.
    ///
    /// Haiku ranks *above* the rest rather than below: the fallback from "no
    /// sonnet exists" should move toward §7.1's cost sentence, not away from
    /// it. Summarizing a factual log is the workload Haiku is for.
    static func familyRank(_ identifier: String) -> Int {
        let lowered = identifier.lowercased()
        if lowered.contains("sonnet") { return 0 }
        if lowered.contains("haiku") { return 1 }
        return 2
    }

    /// `(familyRank, createdAt descending, id ascending)`.
    ///
    /// The id tiebreak makes the order total, so the result does not depend on
    /// the sort's stability when two models share a timestamp — or, more often
    /// in practice, when neither carries one.
    private static func precedes(_ lhs: AnthropicModel, _ rhs: AnthropicModel) -> Bool {
        let lhsRank = familyRank(lhs.id)
        let rhsRank = familyRank(rhs.id)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        switch (lhs.createdAt, rhs.createdAt) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            // A model that reported a timestamp outranks one that did not: the
            // API sends `created_at` for everything it currently serves, so a
            // missing one means a shape this module did not recognise.
            return true
        case (.none, .some):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}
