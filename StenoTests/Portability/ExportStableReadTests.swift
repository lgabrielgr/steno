import Foundation
import SwiftData
import Testing

@testable import StenoKit

/// `ExportEncoder.snapshot()` must not hand back a document assembled from two
/// generations of the store.
///
/// The five fetches are five separate reads with no transaction around them, so
/// a writer committing between two of them produces a file whose tasks reference
/// a project that was not fetched. Nothing is lost on this Mac — the failure
/// surfaces later, as `ImportError.danglingReference`, on the machine trying to
/// restore from it, and with sync cancelled that file may be the only copy.
/// Raised in review of PR #31.
@Suite @MainActor struct ExportStableReadTests {
    /// A store that holds still exports on the first comparison, and the second
    /// reading is the one returned.
    @Test("a store that is not changing exports normally")
    func stableStoreExports() throws {
        let fixture = try ExportFixture()
        let maximal = try fixture.maximal()

        let document = try fixture.encoder(includingCachedData: true).snapshot()

        #expect(document.tasks.map(\.id) == [maximal.task.id])
        #expect(document.projects.map(\.id) == [maximal.project.id])
    }

    /// **The defect itself.** A writer commits between the two readings; the
    /// encoder must refuse rather than return either of them.
    @Test("a store changing under the export is refused, not exported")
    func changingStoreIsRefused() throws {
        let fixture = try ExportFixture()
        try fixture.maximal()

        // Inserts on every gap between readings, so the store never settles —
        // which is what a concurrent writer looks like from in here.
        var inserted = 0
        let encoder = ExportEncoder(
            context: fixture.context,
            now: { ExportFixture.origin },
            exportedBy: "steno/test (macOS)",
            afterRead: {
                inserted += 1
                let project = Project(
                    id: UUID(), name: "Added mid-read \(inserted)", colorHex: "#445566",
                    modifiedAt: ExportFixture.at(TimeInterval(inserted)))
                fixture.context.insert(project)
                try? fixture.context.save()
            })

        #expect(throws: ExportError.storeChangedWhileReading) { try encoder.snapshot() }
        // Proof the seam actually fired: a test where `afterRead` never ran
        // would pass for the wrong reason.
        #expect(inserted > 0)
    }

    /// A single writer that commits once and stops must **not** fail the export:
    /// the retry exists to ride out exactly that, and an export that refused
    /// every time anything had just been written would be useless.
    @Test("one write between readings is ridden out by the retry")
    func oneWriteIsTolerated() throws {
        let fixture = try ExportFixture()
        try fixture.maximal()

        var reads = 0
        let encoder = ExportEncoder(
            context: fixture.context,
            now: { ExportFixture.origin },
            exportedBy: "steno/test (macOS)",
            afterRead: {
                reads += 1
                guard reads == 1 else { return }
                let project = Project(
                    id: UUID(), name: "Added once", colorHex: "#445566",
                    modifiedAt: ExportFixture.at(1))
                fixture.context.insert(project)
                try? fixture.context.save()
            })

        let document = try encoder.snapshot()
        // The returned document is the settled one, so it carries the write —
        // it is a coherent reading of the store *after* the change, which is
        // the point. A document missing it would be the stale first reading.
        #expect(document.projects.count == 2)
        #expect(document.projects.contains { $0.name == "Added once" })
    }

    /// `==` cannot answer "same records": `exportedAt` comes from the clock
    /// once per document, so two readings of an unchanged store are never equal
    /// — which would make the comparison above always disagree and refuse every
    /// export.
    @Test("the comparison ignores exportedAt and nothing else")
    func comparisonIgnoresOnlyTheEnvelope() throws {
        let fixture = try ExportFixture()
        try fixture.maximal()
        let first = try fixture.encoder(nowOffset: 0).snapshot()
        let later = try fixture.encoder(nowOffset: 500).snapshot()

        #expect(first != later)
        #expect(first.holdsSameRecords(as: later))
    }
}
