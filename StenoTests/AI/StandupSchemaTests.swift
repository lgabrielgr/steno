import Foundation
import Testing

@testable import StenoKit

/// §7.3's two schemas: the shape, and that it agrees with what decodes it.

private func document(for cadence: ReportCadence) throws -> [String: Any] {
    let schema = StandupSchema.schema(for: cadence)
    let parsed = try JSONSerialization.jsonObject(with: schema.json)
    return try #require(parsed as? [String: Any])
}

private func bulletDefinition(in document: [String: Any]) throws -> [String: Any] {
    let defs = try #require(document["$defs"] as? [String: Any])
    return try #require(defs["bullet"] as? [String: Any])
}

@Test("both schemas are JSON, named, and closed to extra properties")
func theSchemasAreWellFormed() throws {
    for cadence in [ReportCadence.daily, .periodic] {
        let document = try document(for: cadence)
        #expect(document["type"] as? String == "object")
        // Required for every object by the structured-output subset, and the
        // reason a section the model invents is a schema violation rather than
        // a silently ignored key.
        #expect(document["additionalProperties"] as? Bool == false)
        #expect(try bulletDefinition(in: document)["additionalProperties"] as? Bool == false)
    }

    #expect(StandupSchema.schema(for: .daily).name == "standup_daily")
    #expect(StandupSchema.schema(for: .periodic).name == "standup_periodic")
}

@Test("daily requires §7.3's three DSU sections; periodic requires its own three")
func eachCadenceRequiresItsOwnSections() throws {
    let daily = try document(for: .daily)
    #expect(daily["required"] as? [String] == ["since_last_standup", "today", "blockers"])

    let periodic = try document(for: .periodic)
    #expect(periodic["required"] as? [String] == ["completed", "in_flight", "blockers_and_risks"])
}

@Test("required and properties name exactly the same keys, both ways round")
func theSchemasAreInternallyConsistent() throws {
    // **Both directions, deliberately.** "Every required key exists" passes on
    // a schema carrying a fourth section the decoder has never heard of, and
    // "every property is required" passes on one whose `required` list has
    // drifted to a name no property defines — which the API rejects as an
    // invalid schema, on the call, in front of the user.
    for cadence in [ReportCadence.daily, .periodic] {
        let document = try document(for: cadence)
        let required = Set(try #require(document["required"] as? [String]))
        let properties = Set(try #require(document["properties"] as? [String: Any]).keys)
        #expect(required == properties, "\(cadence) root")

        let bullet = try bulletDefinition(in: document)
        let bulletRequired = Set(try #require(bullet["required"] as? [String]))
        let bulletProperties = Set(try #require(bullet["properties"] as? [String: Any]).keys)
        #expect(bulletRequired == bulletProperties, "\(cadence) bullet")
    }
}

@Test("the task reference is singular for daily and plural for periodic")
func theCardinalityDiffers() throws {
    // §7.3: the two schemas "are not cosmetic variants of each other — the
    // sections differ, and so does the cardinality of the task reference".
    let daily = try bulletDefinition(in: try document(for: .daily))
    #expect(daily["required"] as? [String] == ["task_id", "text"])
    let dailyID = try #require(
        (daily["properties"] as? [String: Any])?["task_id"] as? [String: Any])
    #expect(dailyID["type"] as? String == "string")
    // Shape, not membership: D-149 rejects constraining *which* ids are legal.
    #expect(dailyID["format"] as? String == "uuid")
    #expect(dailyID["enum"] == nil)

    let periodic = try bulletDefinition(in: try document(for: .periodic))
    #expect(periodic["required"] as? [String] == ["task_ids", "text"])
    let ids = try #require(
        (periodic["properties"] as? [String: Any])?["task_ids"] as? [String: Any])
    #expect(ids["type"] as? String == "array")
    let items = try #require(ids["items"] as? [String: Any])
    #expect(items["format"] as? String == "uuid")
    #expect(items["enum"] == nil)
}

@Test("a response built from the schema's own key names decodes into a draft")
func theSchemaAgreesWithTheDecoder() throws {
    // **The coupling test, and the reason the structural checks above are not
    // enough.** The schema names the wire keys the model will use; the drafts'
    // private `CodingKeys` name the wire keys the app will read, and nothing
    // connects the two but this. A schema key renamed without its `CodingKey`
    // passes every check above and then fails on every real call — reported as
    // a schema violation, which reads as a misbehaving model.
    //
    // The JSON below is built *out of the schema document*, never out of
    // literals: a version of this test that spelled the keys itself would agree
    // with the decoder while the schema drifted away from both.
    let identifier = UUID()

    let daily = try document(for: .daily)
    let dailySections = try #require(daily["required"] as? [String])
    let dailyKeys = try #require(bulletDefinition(in: daily)["required"] as? [String])
    #expect(dailySections.count == 3)
    #expect(dailyKeys.count == 2)

    let dailyBody = try encode([
        dailySections[0]: [[dailyKeys[0]: identifier.uuidString, dailyKeys[1]: "did a thing"]],
        dailySections[1]: [], dailySections[2]: [],
    ])
    guard case .daily(let draft) = try StandupDraft.decode(dailyBody, cadence: .daily) else {
        Issue.record("a daily response decoded as something other than a daily draft")
        return
    }
    #expect(draft.sinceLastStandup == [DailyBullet(taskID: identifier, text: "did a thing")])
    #expect(draft.today.isEmpty)
    #expect(draft.blockers.isEmpty)

    let periodic = try document(for: .periodic)
    let periodicSections = try #require(periodic["required"] as? [String])
    let periodicKeys = try #require(bulletDefinition(in: periodic)["required"] as? [String])
    #expect(periodicSections.count == 3)
    #expect(periodicKeys.count == 2)

    let periodicBody = try encode([
        periodicSections[0]: [
            [periodicKeys[0]: [identifier.uuidString], periodicKeys[1]: "shipped it"]
        ],
        periodicSections[1]: [], periodicSections[2]: [],
    ])
    guard case .periodic(let themed) = try StandupDraft.decode(periodicBody, cadence: .periodic)
    else {
        Issue.record("a periodic response decoded as something other than a periodic draft")
        return
    }
    #expect(themed.completed == [ThemedBullet(taskIDs: [identifier], text: "shipped it")])
    #expect(themed.inFlight.isEmpty)
    #expect(themed.blockersAndRisks.isEmpty)
}

/// A response body with the keys the schema asked for.
private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}
