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
