import Foundation
import Testing

@testable import StenoKit

// D-140. The ranking is the whole of §7.1's "mid-tier default" and the whole of
// its "not hardcoded", so it is tested as a pure function over inputs whose
// order disagrees with the expected order — a fixture already sorted the way
// the assertion expects proves only that `sorted(by:)` exists.

private func model(
    _ id: String,
    created: String? = nil,
    structuredOutputs: Bool? = nil
) -> AnthropicModel {
    AnthropicModel(
        id: id,
        displayName: id,
        createdAt: AnthropicWire.timestamp(created),
        supportsStructuredOutputs: structuredOutputs
    )
}

@Test("sonnet outranks everything, and the input arrives in the opposite order")
func sonnetIsTheDefault() {
    // Deliberately reversed: opus first, sonnet last. Mutation: invert
    // `familyRank`'s sonnet/haiku returns. Red.
    let ordered = ModelRanking.ordered([
        model("claude-opus-5", created: "2026-04-01T00:00:00Z"),
        model("claude-haiku-4-5", created: "2025-10-01T00:00:00Z"),
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"])
}

@Test("within a family the newest wins, and a string sort would get it wrong")
func recencyBeatsLexicographicOrder() {
    // `claude-sonnet-10` sorts *below* `claude-sonnet-5` as a string, so this
    // fails the moment ranking stops reading `created_at`. Mutation: drop the
    // date comparison and fall through to the id tiebreak. Red.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
        model("claude-sonnet-10", created: "2026-06-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-10", "claude-sonnet-5"])
}

@Test("a model that cannot do structured outputs is dropped")
func structuredOutputsAreRequired() {
    // §7.3 needs a schema-constrained response; a model that cannot give one
    // would fail every draft with a 400.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-legacy", created: "2026-01-01T00:00:00Z", structuredOutputs: false),
        model("claude-sonnet-5", created: "2025-01-01T00:00:00Z", structuredOutputs: true),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5"])
}

@Test("an unknown capabilities shape drops nothing")
func silenceIsNotRefusal() {
    // The filter is on an explicit `false` only. A vendor response that renames
    // the capability, or omits it, must cost ranking quality at most — never
    // the user's whole picker.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z", structuredOutputs: nil)
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5"])
}

@Test("a model with no timestamp still ranks, below one that has it")
func missingTimestampsAreTotallyOrdered() {
    // Order must be total, or the result depends on the sort's stability.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-b"),
        model("claude-sonnet-a"),
        model("claude-sonnet-dated", created: "2020-01-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-dated", "claude-sonnet-a", "claude-sonnet-b"])
}

@Test("the same input ranks the same way regardless of how it arrived")
func rankingIsIndependentOfInputOrder() {
    let models = [
        model("claude-haiku-4-5", created: "2025-10-01T00:00:00Z"),
        model("claude-opus-5", created: "2026-04-01T00:00:00Z"),
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
    ]

    #expect(
        ModelRanking.ordered(models).map(\.id) == ModelRanking.ordered(models.reversed()).map(\.id))
}

@Test("a timestamp with fractional seconds still parses")
func timestampsToleratePrecision() {
    // Two formatters, because `ISO8601DateFormatter` fails outright on
    // fractional seconds without the option and on their absence with it.
    #expect(AnthropicWire.timestamp("2026-01-01T00:00:00Z") != nil)
    #expect(AnthropicWire.timestamp("2026-01-01T00:00:00.123Z") != nil)
    #expect(AnthropicWire.timestamp("the first of January") == nil)
    #expect(AnthropicWire.timestamp(nil) == nil)
}

// MARK: - Decoding (the path the ranking tests above do not take)

@Test("structured_outputs is read out of the nested capabilities tree")
func capabilitiesDecodeFromTheWire() throws {
    // The tests above build `AnthropicModel` through its memberwise init, so
    // the custom `init(from:)` — where all the defensiveness lives — was never
    // exercised (PR #35 review). This is the decode path a vendor response
    // actually takes.
    let json = """
        {"data":[
          {"id":"a","display_name":"Model A","created_at":"2026-01-01T00:00:00Z",
           "capabilities":{"structured_outputs":{"supported":false}}},
          {"id":"b","display_name":"Model B",
           "capabilities":{"structured_outputs":{"supported":true}}},
          {"id":"c"},
          {"id":"d","capabilities":{"something_else":{"supported":false}}}
        ],"has_more":false}
        """

    let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(json.utf8))

    // Only an explicit `false` is a refusal; a missing or unrecognised shape
    // says nothing, and D-140 drops nothing on "nothing".
    #expect(page.data.map(\.supportsStructuredOutputs) == [false, true, nil, nil])
    // `display_name` falls back to the id rather than failing the page.
    #expect(page.data.map(\.displayName) == ["Model A", "Model B", "c", "d"])
    #expect(page.data[0].createdAt != nil)
    #expect(page.data[2].createdAt == nil)
    #expect(page.hasMore == false)
}

@Test("a model whose timestamp will not parse still decodes")
func aBadTimestampCostsRankingQualityAndNothingElse() throws {
    // Returning `nil` rather than throwing is the whole point: the model still
    // belongs in the picker, it just ranks by id within its family.
    let json = #"{"data":[{"id":"a","created_at":"yesterday"}]}"#
    let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(json.utf8))

    #expect(page.data.count == 1)
    #expect(page.data[0].createdAt == nil)
    #expect(page.hasMore == nil)
}
