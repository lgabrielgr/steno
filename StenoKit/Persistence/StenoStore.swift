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

    /// The application's store, at `defaultURL` unless a URL is given.
    ///
    /// `URL?` rather than `URL = defaultURL` because a default argument cannot
    /// be a throwing expression. Tests pass a temp directory; the app passes
    /// nothing.
    ///
    /// **The `createDirectory` call is not redundant.** SwiftData does open a
    /// store whose parent directory is missing — but by way of Core Data's
    /// error-recovery path, which first logs roughly 200 lines to stderr,
    /// including `Sandbox access to file-write-create denied` and
    /// `NSCocoaErrorDomain (512)`. Nothing is broken, and the app works; but
    /// `make run` streams stderr to the terminal (§9.2), so first launch on a
    /// clean machine would look like a catastrophic failure. Removing this call
    /// leaves every test green. See DECISIONS.md D-017.
    public static func live(at url: URL? = nil) throws -> ModelContainer {
        let storeURL = try url ?? defaultURL
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try ModelContainer(
            for: Schema(models()),
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
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
