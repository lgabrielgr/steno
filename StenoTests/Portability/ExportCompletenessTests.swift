import Foundation
import Testing

@testable import StenoKit

/// §10.3's erosion guard and the two things it cannot see on its own.
///
/// Three tests, failing for three different reasons.
///
/// `exportedKeysAreExactlyTheAllowedSet` reads the emitted JSON. It catches a
/// field that reaches the file and should not.
///
/// `declaredPropertiesAreExactlyTheAllowedSet` reads the *types*, and it is not
/// redundant — it was added because the JSON test demonstrably missed the case
/// §10.3 is about. Adding `let apiToken: String?` to a record encodes nothing
/// while it is `nil`: `encodeIfPresent` omits the key, the JSON is byte-for-byte
/// unchanged, and a field with no fixture value is never anything *but* `nil`.
/// Mutation-tested — the JSON assertion alone let exactly that through.
///
/// `everyFieldRoundTripsToTheRightPlace` reads the values. Neither key test can
/// see `createdAt` written into `statusChangedAt`: both keys are present and
/// both hold plausible dates.

/// The keys each record is allowed to carry. One declaration, asserted from
/// both directions.
private enum AllowedKeys {
    static let projects: Set<String> = [
        "id", "name", "colorHex", "jiraProjectKeys", "isArchived", "sortOrder",
        "lastStandupAt", "reportCadence", "staleThresholdDays", "modifiedAt",
    ]
    static let tasks: Set<String> = [
        "id", "title", "projectID", "status", "createdAt", "statusChangedAt",
        "completedAt", "isArchived", "modifiedAt",
    ]
    static let events: Set<String> = [
        "id", "taskID", "timestamp", "kind", "body", "payload", "isRedacted",
    ]
    static let sourceRefs: Set<String> = [
        "id", "taskID", "kind", "identifier", "url", "lastFetchedAt", "cachedSummary",
    ]
    static let reports: Set<String> = [
        "id", "projectID", "generatedAt", "windowStart", "windowEnd", "markdownBody",
        "wasAIGenerated", "modelUsed", "isUndone",
    ]
}

/// The stored property names of `value`, whatever their values.
///
/// `Mirror` rather than the encoded keys, because a `nil` optional encodes to
/// no key at all — see this file's note.
private func declaredKeys(_ value: Any) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
}

/// The stored property names of a SwiftData `@Model`.
///
/// The macro renames every stored property with a leading underscore and adds
/// `_$backingData` and `_$observationRegistrar`, so the names are recovered by
/// dropping the artifacts and then the underscore.
private func modelKeys(_ value: Any) -> Set<String> {
    Set(
        Mirror(reflecting: value).children
            .compactMap(\.label)
            .filter { !$0.hasPrefix("_$") }
            .map { String($0.dropFirst()) })
}

/// Fields a model has and its record deliberately does not carry.
///
/// Both are the same fact expressed twice: §3.4 makes `SourceRef.taskID` the
/// authoritative link, and the top-level `sourceRefs` array is keyed by it. The
/// relationship in either direction is a cycle, and a file carrying both could
/// disagree with itself.
private enum DeliberatelyNotExported {
    static let tasks: Set<String> = ["sourceRefs"]
    static let sourceRefs: Set<String> = ["task"]
}

@MainActor
@Test("§10.3: the exported keys of every record are exactly the allowed set")
func exportedKeysAreExactlyTheAllowedSet() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()

    let data = try fixture.encoder(includingCachedData: true).encode()

    #expect(try ExportJSON.recordKeys("projects", in: data) == AllowedKeys.projects)
    #expect(try ExportJSON.recordKeys("tasks", in: data) == AllowedKeys.tasks)
    #expect(try ExportJSON.recordKeys("events", in: data) == AllowedKeys.events)
    #expect(try ExportJSON.recordKeys("sourceRefs", in: data) == AllowedKeys.sourceRefs)
    #expect(try ExportJSON.recordKeys("reports", in: data) == AllowedKeys.reports)
}

@MainActor
@Test("§10.3: no record type declares a field outside the allowed set")
func declaredPropertiesAreExactlyTheAllowedSet() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()
    let document = try fixture.encoder(includingCachedData: true).snapshot()

    // A field added to any of these fails here the moment it is declared,
    // whether or not any fixture gives it a value — which is the erosion §10.3
    // names: "construction-based guarantees erode silently when someone later
    // adds a field."
    #expect(declaredKeys(try #require(document.projects.first)) == AllowedKeys.projects)
    #expect(declaredKeys(try #require(document.tasks.first)) == AllowedKeys.tasks)
    #expect(declaredKeys(try #require(document.events.first)) == AllowedKeys.events)
    #expect(declaredKeys(try #require(document.sourceRefs.first)) == AllowedKeys.sourceRefs)
    #expect(declaredKeys(try #require(document.reports.first)) == AllowedKeys.reports)
}

@MainActor
@Test("§10.3: every model field is either exported or deliberately excluded")
func everyModelFieldIsAccountedFor() throws {
    let fixture = try ExportFixture()
    let models = try fixture.maximal()

    // **This is the direction the two allowlists above cannot see.** They
    // compare the records to a literal set, so a field added to `Project` and
    // forgotten in `ExportedProject` changes nothing: the DTO has not grown,
    // the JSON has not changed, and the export silently drops user data — the
    // erosion §10.3 names, arriving from the side nobody was watching.
    //
    // Every exclusion is named rather than filtered by a rule, so adding a
    // model field cannot be absorbed silently by a pattern.
    #expect(modelKeys(models.project) == AllowedKeys.projects)
    #expect(modelKeys(models.task) == AllowedKeys.tasks.union(DeliberatelyNotExported.tasks))
    #expect(modelKeys(models.event) == AllowedKeys.events)
    #expect(
        modelKeys(models.ref) == AllowedKeys.sourceRefs.union(DeliberatelyNotExported.sourceRefs))
    #expect(modelKeys(models.report) == AllowedKeys.reports)
}

@MainActor
@Test("§10.2: a real standupReported payload survives byte-exactly")
func aRealPayloadRoundTripsByteExactly() throws {
    let fixture = try ExportFixture()
    try fixture.realistic()

    let data = try fixture.encoder().encode()
    let decoded = try ExportDocument.decoder().decode(ExportDocument.self, from: data)

    // `StandupService` writes a `StandupReportedPayload` on every Copy (D-085),
    // so this is not a hypothetical field: an ordinary store has one per
    // reported task. Base64 is opaque in the file — D-097 takes that trade
    // openly — but the bytes must survive, because §10 has no second copy.
    let reported = decoded.events.filter { $0.kind == .standupReported }
    #expect(!reported.isEmpty)
    for event in reported {
        let payload = try #require(event.payload)
        #expect(StandupReportedPayload.decoded(from: payload) != nil)
    }
}

@MainActor
@Test("every field reaches the field it belongs in")
func everyFieldRoundTripsToTheRightPlace() throws {
    let fixture = try ExportFixture()
    let models = try fixture.maximal()

    let document = try fixture.encoder(includingCachedData: true).snapshot()

    let project = try #require(document.projects.first)
    #expect(project.id == models.project.id)
    #expect(project.name == "Payments Platform")
    #expect(project.colorHex == "#AABBCC")
    #expect(project.jiraProjectKeys == ["PAY", "BILL"])
    #expect(project.isArchived)
    #expect(project.sortOrder == 7)
    #expect(project.lastStandupAt == ExportFixture.at(3600))
    #expect(project.reportCadence == .periodic)
    #expect(project.staleThresholdDays == 10)
    #expect(project.modifiedAt == ExportFixture.at(1800))

    let task = try #require(document.tasks.first)
    #expect(task.id == models.task.id)
    #expect(task.title == "Fix the retry handler")
    #expect(task.projectID == models.project.id)
    #expect(task.status == .done)
    #expect(task.createdAt == ExportFixture.at(60))
    #expect(task.statusChangedAt == ExportFixture.at(120))
    #expect(task.completedAt == ExportFixture.at(120))
    #expect(task.isArchived)
    #expect(task.modifiedAt == ExportFixture.at(180))

    let event = try #require(document.events.first)
    #expect(event.id == models.event.id)
    #expect(event.taskID == models.task.id)
    #expect(event.timestamp == ExportFixture.at(240))
    #expect(event.kind == .blockedReason)
    #expect(event.body == "Waiting on infra to provision staging")
    #expect(event.payload == Data("{\"ticket\":\"PAY-421\"}".utf8))
    #expect(event.isRedacted)

    let ref = try #require(document.sourceRefs.first)
    #expect(ref.id == models.ref.id)
    #expect(ref.taskID == models.task.id)
    #expect(ref.kind == .githubPR)
    #expect(ref.identifier == "acme/api#421")
    #expect(ref.url == "https://github.com/acme/api/pull/421")
    #expect(ref.lastFetchedAt == ExportFixture.at(300))
    #expect(ref.cachedSummary == "In review, 2 comments")

    let report = try #require(document.reports.first)
    #expect(report.id == models.report.id)
    #expect(report.projectID == models.project.id)
    #expect(report.generatedAt == ExportFixture.at(420))
    #expect(report.windowStart == ExportFixture.at(360))
    #expect(report.windowEnd == ExportFixture.at(400))
    #expect(report.markdownBody == "*Yesterday*\n- fixed the retry handler")
    #expect(report.wasAIGenerated)
    #expect(report.modelUsed == "claude-opus-5")
    #expect(report.isUndone)
}

@MainActor
@Test("a document survives encode and decode unchanged")
func theDocumentRoundTripsThroughJSON() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()
    let encoder = fixture.encoder(includingCachedData: true)

    let decoded = try ExportDocument.decoder()
        .decode(ExportDocument.self, from: try encoder.encode())

    // `==` works here only because every fixture date is millisecond-clean;
    // see `ExportDateTests` for the clock-date case, which needs a tolerance.
    #expect(decoded == (try encoder.snapshot()))
}

@MainActor
@Test("§10: archived, redacted and undone rows all export, flags intact")
func nothingIsFiltered() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()

    let document = try fixture.encoder().snapshot()

    // Export is the only way Steno moves between machines (§10, D1). Dropping a
    // redacted event into an empty store does not hide its text, it loses the
    // row — and `isRedacted`/`isUndone` are what O-8 leaves for M2.5-02 to
    // merge, which it cannot do with a flag it never received.
    #expect(document.projects.count == 1)
    #expect(document.tasks.count == 1)
    #expect(document.events.count == 1)
    #expect(document.reports.count == 1)
    #expect(document.projects.first?.isArchived == true)
    #expect(document.tasks.first?.isArchived == true)
    #expect(document.events.first?.isRedacted == true)
    #expect(document.reports.first?.isUndone == true)
}

@MainActor
@Test("§10.2: cached external data is absent by default, refs are not")
func cachedDataIsExcludedByDefault() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()

    let data = try fixture.encoder().encode()
    let text = try ExportJSON.text(of: data)
    let document = try fixture.encoder().snapshot()

    #expect(document.sourceRefs.count == 1)
    #expect(document.sourceRefs.first?.identifier == "acme/api#421")
    #expect(document.sourceRefs.first?.cachedSummary == nil)
    #expect(document.sourceRefs.first?.lastFetchedAt == nil)
    #expect(!text.contains("cachedSummary"))
    #expect(!text.contains("lastFetchedAt"))
    #expect(!text.contains("In review, 2 comments"))
}

@MainActor
@Test("§10.2: the opt-in carries cached external data and says so in the envelope")
func cachedDataIsCarriedWhenAskedFor() throws {
    let fixture = try ExportFixture()
    _ = try fixture.maximal()

    let document = try fixture.encoder(includingCachedData: true).snapshot()

    #expect(document.includesCachedExternalData)
    #expect(document.sourceRefs.first?.cachedSummary == "In review, 2 comments")
    #expect(document.sourceRefs.first?.lastFetchedAt == ExportFixture.at(300))
}
