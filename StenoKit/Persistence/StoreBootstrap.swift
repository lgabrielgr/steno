import Foundation
import SwiftData

extension StenoStore {
    /// The project a first-ever capture lands in.
    public static let defaultProjectName = "Inbox"

    /// Give a brand-new store one project, so capture always has a target.
    ///
    /// On a fresh install there are zero projects, so a task has no
    /// `projectID` to take — and M0-05 handled that by disabling New Task,
    /// which is a capture surface refusing text and so is exactly what §1.1
    /// forbids. It gets worse in M1-03, where the hotkey window would open
    /// above every other app into a field whose `Return` does nothing.
    ///
    /// The seeded project is ordinary: renameable, archivable, no Jira keys.
    ///
    /// **The emptiness check counts archived projects too.** Seeding happens
    /// once in a store's life. Were it to skip them, archiving every project
    /// would resurrect one the user deliberately put away — see the design
    /// doc §4.2, which keeps that state as capture's one documented refusal.
    ///
    /// Returns the seeded project, or `nil` when the store already had one.
    @discardableResult
    public static func seedDefaultProjectIfEmpty(in context: ModelContext) throws -> Project? {
        var descriptor = FetchDescriptor<Project>()
        descriptor.fetchLimit = 1
        guard try context.fetch(descriptor).isEmpty else { return nil }

        let project = Project(
            name: defaultProjectName,
            colorHex: ProjectPalette.hex(forIndex: 0),
            sortOrder: 0,
            modifiedAt: Date.now
        )
        context.insert(project)
        try context.save()
        return project
    }
}
