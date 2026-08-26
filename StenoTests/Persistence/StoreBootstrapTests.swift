import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
@Test("an empty store gets exactly one default project")
func emptyStoreIsSeeded() throws {
    let context = ModelContext(try StenoStore.inMemory())

    let seeded = try #require(try StenoStore.seedDefaultProjectIfEmpty(in: context))

    #expect(seeded.name == StenoStore.defaultProjectName)
    #expect(seeded.jiraProjectKeys.isEmpty)
    #expect(seeded.sortOrder == 0)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("seeding twice does not produce a second project")
func seedingIsIdempotent() throws {
    let context = ModelContext(try StenoStore.inMemory())
    try StenoStore.seedDefaultProjectIfEmpty(in: context)

    let second = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    #expect(second == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("a store whose only project is archived is not re-seeded")
func archivedOnlyStoreIsNotReseeded() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let seeded = try #require(try StenoStore.seedDefaultProjectIfEmpty(in: context))
    seeded.setArchived(true, at: epoch)
    try context.save()

    let second = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    // Seeding happens once in a store's life. Re-seeding would resurrect a
    // project the user archived on purpose (design §4.2).
    #expect(second == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).count == 1)
}

@MainActor
@Test("a store that already has projects is left alone")
func populatedStoreIsNotSeeded() throws {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(name: "Payments", colorHex: "#3B82F6", sortOrder: 0, modifiedAt: epoch)
    )
    try context.save()

    let seeded = try StenoStore.seedDefaultProjectIfEmpty(in: context)

    #expect(seeded == nil)
    #expect(try context.fetch(FetchDescriptor<Project>()).map(\.name) == ["Payments"])
}
