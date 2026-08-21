import Foundation
import SwiftData

@testable import StenoKit

/// The five model types.
///
/// **This list is test-only.** The list the application ships belongs to M0-04
/// with the `ModelContainer` it feeds — a list here as well would be a second
/// declaration of the schema that M0-04's container could silently disagree
/// with. The consequence M0-04 inherits: a model type missing from *its* list
/// is caught by nothing in M0-03, so M0-04 needs its own test asserting the
/// container it builds covers every model.
///
/// A function rather than a global `let` so there is no shared mutable state
/// for strict concurrency to reason about.
func stenoModelTypes() -> [any PersistentModel.Type] {
    [Project.self, TaskItem.self, Event.self, SourceRef.self, StandupReport.self]
}

/// An in-memory store for tests that need a live context.
///
/// **A test fixture, not a store configuration.** M0-04 owns where the
/// application's store actually lives (open question O-3).
func inMemoryContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema(stenoModelTypes()),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}
