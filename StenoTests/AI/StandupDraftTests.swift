import Foundation
import Testing

@testable import StenoKit

/// §7.3's two schemas, as the type that has to survive contact with them.

/// `UUID(uuidString:)` is failable and these literals are statically valid, but
/// `force_unwrapping` is on and three suppressions in a row would be worse than
/// one helper that says what it means.
private func fixedUUID(_ string: String) -> UUID {
    guard let uuid = UUID(uuidString: string) else {
        fatalError("malformed test fixture UUID: \(string)")
    }
    return uuid
}

private let taskOne = fixedUUID("11111111-1111-1111-1111-111111111111")
private let taskTwo = fixedUUID("22222222-2222-2222-2222-222222222222")
private let hallucinated = fixedUUID("99999999-9999-9999-9999-999999999999")

/// Written as §7.3 prints it — snake_case keys included. If `CodingKeys` drift
/// from the spec's wire names, this is the test that says so, and it is the
/// only place in the codebase those names appear twice on purpose.
private let dailyJSON = """
    {
      "since_last_standup": [{ "task_id": "11111111-1111-1111-1111-111111111111",
                               "text": "fixed the flaky auth test" }],
      "today":              [{ "task_id": "22222222-2222-2222-2222-222222222222",
                               "text": "start on the import preview" }],
      "blockers":           []
    }
    """

private let periodicJSON = """
    {
      "completed":          [{ "task_ids": ["11111111-1111-1111-1111-111111111111",
                                            "22222222-2222-2222-2222-222222222222"],
                               "text": "export and import both landed" }],
      "in_flight":          [],
      "blockers_and_risks": []
    }
    """

@Test("a daily draft decodes from §7.3's wire names")
func aDailyDraftDecodes() throws {
    let draft = try StandupDraft.decode(Data(dailyJSON.utf8), cadence: .daily)

    guard case .daily(let daily) = draft else {
        Issue.record("expected a daily draft, got \(draft)")
        return
    }
    #expect(
        daily.sinceLastStandup == [DailyBullet(taskID: taskOne, text: "fixed the flaky auth test")])
    #expect(daily.today == [DailyBullet(taskID: taskTwo, text: "start on the import preview")])
    #expect(daily.blockers.isEmpty)
}

@Test("a periodic bullet carries every task it themed together")
func aPeriodicDraftDecodes() throws {
    let draft = try StandupDraft.decode(Data(periodicJSON.utf8), cadence: .periodic)

    guard case .periodic(let periodic) = draft else {
        Issue.record("expected a periodic draft, got \(draft)")
        return
    }
    // The plural is the point: §7.3 says a `daily` bullet doing this would be
    // a bug, and the app has to link the themed bullet back to *both* tasks.
    #expect(periodic.completed.first?.taskIDs == [taskOne, taskTwo])
}

@Test("the cadence selects the schema, so the other cadence's JSON is rejected")
func theCadenceSelectsTheSchema() {
    // Decoding daily bytes as periodic must not quietly succeed with three
    // empty sections — which is exactly what would happen if the properties
    // were optional or defaulted.
    #expect(throws: AIError.invalidResponse(.schemaViolation)) {
        try StandupDraft.decode(Data(dailyJSON.utf8), cadence: .periodic)
    }
}

@Test("bytes that are not JSON are undecodable, not a schema violation")
func nonJSONIsUndecodable() {
    #expect(throws: AIError.invalidResponse(.undecodable)) {
        try StandupDraft.decode(Data("I'm afraid I can't do that".utf8), cadence: .daily)
    }
}

@Test("well-formed JSON with a malformed task id is a schema violation")
func aMalformedTaskIDIsASchemaViolation() {
    // The distinction this test defends: `JSONDecoder` reports a bad UUID as
    // `dataCorrupted`, the same case it reports for bytes that are not JSON at
    // all. Switching on the error kind would file this under `.undecodable`
    // and tell M3-03 the provider returned garbage when it returned JSON.
    let json = """
        { "since_last_standup": [{ "task_id": "not-a-uuid", "text": "x" }],
          "today": [], "blockers": [] }
        """
    #expect(throws: AIError.invalidResponse(.schemaViolation)) {
        try StandupDraft.decode(Data(json.utf8), cadence: .daily)
    }
}

@Test("a draft that only mentions ids the app sent is returned unchanged")
func aValidDraftPassesValidation() throws {
    let draft = try StandupDraft.decode(Data(dailyJSON.utf8), cadence: .daily)

    let validated = try draft.validated(against: [taskOne, taskTwo])

    #expect(validated == draft)
}

@Test("§7.3: a hallucinated task id fails loudly")
func aHallucinatedTaskIDIsRejected() throws {
    let json = """
        { "since_last_standup": [{ "task_id": "99999999-9999-9999-9999-999999999999",
                                   "text": "shipped the thing" }],
          "today": [], "blockers": [] }
        """
    let draft = try StandupDraft.decode(Data(json.utf8), cadence: .daily)

    // The count, not the ids — §8 governs what may be logged, and the ids name
    // the user's tasks.
    #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try draft.validated(against: [taskOne, taskTwo])
    }
    #expect(draft.allTaskIDs == [hallucinated])
}

@Test("a hallucinated id inside a themed bullet is caught too")
func aHallucinatedThemedIDIsRejected() throws {
    // The periodic path flattens `task_ids`, so a draft whose *first* id is
    // legitimate would pass a check that only looked at one per bullet.
    let json = """
        { "completed": [{ "task_ids": ["11111111-1111-1111-1111-111111111111",
                                       "99999999-9999-9999-9999-999999999999"],
                          "text": "two things" }],
          "in_flight": [], "blockers_and_risks": [] }
        """
    let draft = try StandupDraft.decode(Data(json.utf8), cadence: .periodic)

    #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try draft.validated(against: [taskOne, taskTwo])
    }
}

@Test("an empty draft is a failure, not a quiet success", arguments: ReportCadence.allCases)
func anEmptyDraftIsRejected(cadence: ReportCadence) throws {
    let json =
        cadence == .daily
        ? #"{ "since_last_standup": [], "today": [], "blockers": [] }"#
        : #"{ "completed": [], "in_flight": [], "blockers_and_risks": [] }"#
    let draft = try StandupDraft.decode(Data(json.utf8), cadence: cadence)

    // §7.4's raw fallback is strictly better than a report with nothing in it,
    // so this must reach the fallback rather than render.
    #expect(throws: AIError.invalidResponse(.emptyDraft)) {
        try draft.validated(against: [taskOne])
    }
}
