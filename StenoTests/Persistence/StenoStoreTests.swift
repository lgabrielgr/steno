import Foundation
import SwiftData
import Testing

@testable import StenoKit

// §1 (design): the location is pinned rather than left to SwiftData, because
// M2.5-03's Replace mode and §8's "delete my data" both have to name it.
@Test("§1: the store is pinned to Application Support, under Steno/")
func defaultURLIsPinnedToApplicationSupport() throws {
    let url = try StenoStore.defaultURL

    #expect(url.lastPathComponent == "Steno.store")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Steno")
    #expect(try url.deletingLastPathComponent() == StenoStore.storeDirectory)

    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    #expect(url.path.hasPrefix(applicationSupport.path))
}

// AC-2. Asserting the url is /dev/null is stronger than the boolean alone: it
// says no file path is involved at all.
@Test("AC-2: the test container touches no file")
func inMemoryContainerIsNotOnDisk() throws {
    let container = try StenoStore.inMemory()

    #expect(container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
    #expect(container.configurations.allSatisfy { $0.url.path == "/dev/null" })
}

// AC-4. The configuration cannot carry this assertion —
// ModelConfiguration.CloudKitDatabase is not Equatable, and its description
// exposes private stored properties that are not a stable contract — so the
// criterion is tested where it is actually stated: the entitlements file.
@Test("AC-4: the app declares no CloudKit entitlement")
func theAppDeclaresNoCloudKitEntitlement() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)  // …/StenoTests/Persistence/<this file>
        .deletingLastPathComponent()  // Persistence
        .deletingLastPathComponent()  // StenoTests
        .deletingLastPathComponent()  // repository root
    let entitlements = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Steno/Steno.entitlements"),
        encoding: .utf8
    )

    #expect(!entitlements.contains("com.apple.developer.icloud"))
    #expect(!entitlements.contains("com.apple.developer.ubiquity"))
}

/// A unique store directory per test. Swift Testing has no teardown hook for
/// free functions, so each test calls `remove()` from a `defer`.
private struct TemporaryStore {
    /// The directory this test owns outright and deletes.
    ///
    /// Stored, never derived by walking up from `directory` — `..` from a
    /// non-nested store directory is the shared temp directory itself, and
    /// `remove()` would take the whole thing with it.
    let root: URL

    /// Where the store file sits. Neither variant exists on disk until
    /// `live(at:)` creates it.
    let directory: URL

    var url: URL { directory.appendingPathComponent("Steno.store") }

    init(nested: Bool = false) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-tests-\(UUID().uuidString)", isDirectory: true)
        directory = nested ? root.appendingPathComponent("Steno", isDirectory: true) : root
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

// AC-1, and the reason this task exists. Exercises the application's own code
// path: same factory, same configuration, only the URL differs.
@Test("AC-1: a record written through one container is readable from the next")
func dataSurvivesAContainerRestart() throws {
    let store = TemporaryStore()
    defer { store.remove() }
    let identifier = UUID()

    // Scoped so the container is released before the store is reopened.
    do {
        let container = try StenoStore.live(at: store.url)
        let context = ModelContext(container)
        context.insert(
            Project(
                id: identifier,
                name: "Payments Platform",
                colorHex: "#3B82F6",
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        )
        try context.save()
    }

    let reopened = ModelContext(try StenoStore.live(at: store.url))
    let stored = try reopened.fetch(FetchDescriptor<Project>())

    #expect(stored.count == 1)
    #expect(stored.first?.id == identifier)
    #expect(stored.first?.name == "Payments Platform")
}

// The check M0-03's TestContainer.swift says M0-04 owes: nothing in M0-03
// catches a model type missing from the *shipped* list.
@Test("§6: the shipped container registers every model")
func liveContainerRegistersEveryModel() throws {
    let store = TemporaryStore()
    defer { store.remove() }

    let container = try StenoStore.live(at: store.url)

    let registered = Set(container.schema.entities.map(\.name))
    let declared = Set(StenoStore.models().map { String(describing: $0) })
    #expect(registered == declared)
    #expect(registered.count == 5)
}

// §2 (design): Core Data recovers from a missing parent on its own, but only
// after ~200 lines of "CoreData: error:" on stderr — including "Sandbox access
// to file-write-create denied" — which is what first launch would look like
// under `make run`. This test sees that the container opens; it cannot see how
// loudly, so the comment in live(at:) is the real guard. See design §7.1.
@Test("§2: live() creates a missing store directory itself")
func liveCreatesAMissingStoreDirectory() throws {
    let store = TemporaryStore(nested: true)
    defer { store.remove() }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))

    _ = try StenoStore.live(at: store.url)

    #expect(FileManager.default.fileExists(atPath: store.directory.path))
}
