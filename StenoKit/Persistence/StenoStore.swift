import Foundation
import SwiftData

/// The application's persistence surface: one schema, one store location, and
/// the two containers anything in this project should ever build
/// (REQUIREMENTS.md §6, D2).
///
/// A caseless `enum` rather than a struct or a singleton: there is no instance
/// state here, so there is nothing for strict concurrency to reason about — the
/// same reasoning that made M0-03's model list a function rather than a global.
public enum StenoStore {
    /// The shipped schema — the single declaration of which models exist.
    ///
    /// A function rather than a `let` so there is no shared mutable state.
    /// **Adding a model means adding it here and nowhere else**: the test
    /// bundle derives its list from this one, so a type missing here is missing
    /// from every §6 and §3 conformance gate too.
    public static func models() -> [any PersistentModel.Type] {
        [Project.self, TaskItem.self, Event.self, SourceRef.self, StandupReport.self]
    }

    /// `~/Library/Application Support/Steno` — closing open question O-3.
    ///
    /// **This directory is the unit of deletion.** M2.5-03's Replace mode and
    /// §8's "delete my data" remove *this*, not `defaultURL`: a SwiftData store
    /// is three files (`Steno.store`, `-shm`, `-wal`), and deleting only the
    /// first strands the write-ahead log.
    ///
    /// A real path rather than a container path, because the app is
    /// deliberately unsandboxed (§6.1). `create: false` keeps this side-effect
    /// free — `live(at:)` creates the directory when it actually opens a store.
    public static var storeDirectory: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Steno", isDirectory: true)
        }
    }

    /// The store file itself. Throwing, because resolving Application Support
    /// can fail and the alternative — trapping, or inventing a fallback path —
    /// is how a user's data quietly ends up somewhere nobody looks.
    public static var defaultURL: URL {
        get throws { try storeDirectory.appendingPathComponent("Steno.store") }
    }

    /// A store that exists only for the lifetime of the container.
    ///
    /// **Tests only.** Its configuration reports `/dev/null` as its url, which
    /// is what makes "this test touched no file" assertable.
    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(models()),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
}
