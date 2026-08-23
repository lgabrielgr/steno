import Foundation
import SwiftData
import Testing

@testable import StenoKit

// Derived, not transcribed: the shipped schema is the only declaration of which
// models exist (StenoStore.models()). `shippedEntitiesMatchTheSpecTables` below
// checks this list against the §3 tables in this file.
private let entityNames = Schema(StenoStore.models()).entities.map(\.name)

private func entity(named name: String) throws -> Schema.Entity {
    let schema = Schema(StenoStore.models())
    return try #require(
        schema.entities.first { $0.name == name },
        "no entity named \(name) — is it missing from StenoStore.models()?"
    )
}

// §6, and the standing instruction in §14 not to strip it: keeping the schema
// CloudKit-compatible costs nothing and is independently required by M2.5's
// merge. Reinstating it later would be a data migration on a live store.
@Test("§6: no attribute is unique, id included", arguments: entityNames)
func noAttributeIsUnique(name: String) throws {
    for attribute in try entity(named: name).attributes {
        #expect(
            !attribute.isUnique,
            "\(name).\(attribute.name) is unique — §6 forbids @Attribute(.unique)"
        )
    }
}

@Test("§6: every attribute is optional or has a default", arguments: entityNames)
func everyAttributeIsOptionalOrDefaulted(name: String) throws {
    for attribute in try entity(named: name).attributes {
        #expect(
            attribute.isOptional || attribute.defaultValue != nil,
            "\(name).\(attribute.name) is neither optional nor defaulted — §6 requires one"
        )
    }
}

@Test("§6: every relationship is optional", arguments: entityNames)
func everyRelationshipIsOptional(name: String) throws {
    for relationship in try entity(named: name).relationships {
        #expect(
            relationship.isOptional,
            "\(name).\(relationship.name) is a non-optional relationship — CloudKit forbids it"
        )
    }
}

// The field tables from §3.1–§3.5, transcribed. This is what catches a field
// silently dropped by a later refactor — the failure mode that makes M0-03
// expensive to get wrong, because a field missed here is a store migration.
private let expectedAttributes: [String: [String: Bool]] = [
    "Project": [
        "id": false, "name": false, "colorHex": false, "jiraProjectKeys": false,
        "isArchived": false, "sortOrder": false, "lastStandupAt": true,
        "reportCadence": false, "staleThresholdDays": true, "modifiedAt": false,
    ],
    "TaskItem": [
        "id": false, "title": false, "projectID": false, "status": false,
        "createdAt": false, "statusChangedAt": false, "completedAt": true,
        "isArchived": false, "modifiedAt": false,
    ],
    "Event": [
        "id": false, "taskID": false, "timestamp": false, "kind": false,
        "body": false, "payload": true, "isRedacted": false,
    ],
    "SourceRef": [
        "id": false, "taskID": false, "kind": false, "identifier": false,
        "url": true, "lastFetchedAt": true, "cachedSummary": true,
    ],
    "StandupReport": [
        "id": false, "projectID": false, "generatedAt": false, "windowStart": false,
        "windowEnd": false, "markdownBody": false, "wasAIGenerated": false,
        "modelUsed": true, "isUndone": false,
    ],
]

private let expectedRelationships: [String: [String]] = [
    "Project": [],
    "TaskItem": ["sourceRefs"],
    "Event": [],
    "SourceRef": ["task"],
    "StandupReport": [],
]

@Test(
    "§3.1–§3.5: every specified field exists, with the specified optionality",
    arguments: entityNames)
func fieldsMatchTheSpec(name: String) throws {
    let entity = try entity(named: name)
    let expected = try #require(expectedAttributes[name])

    let actualNames = Set(entity.attributesByName.keys)
    #expect(
        actualNames == Set(expected.keys),
        """
        \(name) attributes drifted from §3.
        missing: \(Set(expected.keys).subtracting(actualNames).sorted())
        unexpected: \(actualNames.subtracting(Set(expected.keys)).sorted())
        """
    )

    for (attributeName, isOptional) in expected {
        let attribute = try #require(entity.attributesByName[attributeName])
        #expect(
            attribute.isOptional == isOptional,
            "\(name).\(attributeName) optionality differs from §3"
        )
    }
}

@Test("§3: relationships are exactly the ones the spec names", arguments: entityNames)
func relationshipsMatchTheSpec(name: String) throws {
    let entity = try entity(named: name)
    let expected = try #require(expectedRelationships[name])
    #expect(Set(entity.relationshipsByName.keys) == Set(expected))
}

// The gate M0-04 adds. Before this, `entityNames` was a second hard-coded list:
// a model present in one list and absent from the other skipped every check in
// this file silently. Now the names are derived from the shipped schema and
// checked against the transcribed §3 tables, so a new model either appears in
// both or fails here.
@Test("§6: the shipped entities are exactly the ones §3's tables describe")
func shippedEntitiesMatchTheSpecTables() {
    #expect(Set(entityNames) == Set(expectedAttributes.keys))
    #expect(Set(entityNames) == Set(expectedRelationships.keys))
}
