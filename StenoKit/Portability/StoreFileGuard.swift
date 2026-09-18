import Foundation
import SwiftData

/// Refuses to let Steno write over its own data store.
///
/// **Extracted from `CLIRunner+Export` in M2.5-05, unchanged, because a second
/// writer arrived.** Every line below was written against a defect found in
/// review of PR #31: `--output ~/Library/Application Support/Steno/Steno.store`
/// encoded successfully and then atomically replaced the SQLite file with JSON,
/// saying "Exported to …" while it did. Auto-export takes a *folder* from the
/// user, writes into it unattended, and deletes files in it — so it needs the
/// same guard, and a guard living on one of two paths is a guard the next
/// surface forgets.
///
/// `@MainActor` because `ModelContext` is not `Sendable`.
@MainActor
enum StoreFileGuard {
    /// Would writing here overwrite the open store or one of its siblings?
    ///
    /// **Filesystem identity first, path text only as a fallback.** Comparing
    /// `standardizedFileURL.path` as a string was wrong on the volume macOS
    /// actually ships: HFS+ and APFS are case-**insensitive** by default, so
    /// `--output steno.store` names the same database as `Steno.store` and
    /// walked straight past a case-sensitive `Set<String>` lookup.
    ///
    /// `fileResourceIdentifierKey` is the right instrument — it answers "same
    /// file?" across case folding, symlinks, hard links and `..` — but it is
    /// only available for a file that **exists**. The store always does, having
    /// just been opened; its `-wal` and `-shm` siblings may not, and a
    /// destination that does not exist yet cannot be compared that way either.
    /// Case-insensitive path comparison covers those, which is the safe
    /// direction: it can only ever refuse *more*, and the thing it might refuse
    /// is a file differing from the store's name by case alone.
    static func isStoreFile(_ destination: URL, in context: ModelContext) -> Bool {
        let candidate = resolved(destination)
        for url in protectedURLs(in: context) {
            let known = resolved(url)
            if let left = fileIdentifier(of: candidate), let right = fileIdentifier(of: known) {
                if left.isEqual(right) { return true }
            } else if candidate.path.compare(known.path, options: .caseInsensitive)
                == .orderedSame
            {
                return true
            }
        }
        return false
    }

    /// Is this folder the store's own directory, or inside it?
    ///
    /// **The folder-shaped question, which `--output` never had to ask.**
    /// Auto-export writes a *new* file per day into a directory the user chose,
    /// so `isStoreFile` on today's name would answer "no" and the sweep would
    /// then go looking for files to delete beside the database. The directory
    /// is the unit that has to be refused.
    ///
    /// Compared by resolved path rather than by resource identifier: the folder
    /// may not exist yet — `Choose Folder…` can name one the user is about to
    /// create — and a non-existent directory has no identity to compare.
    static func isInsideStoreDirectory(_ folder: URL, in context: ModelContext) -> Bool {
        let candidate = fullyResolved(folder).path
        for url in storeDirectories(in: context) {
            let base = fullyResolved(url).path
            if candidate.compare(base, options: .caseInsensitive) == .orderedSame { return true }
            // The separator matters: without it `/tmp/Steno-backups` would be
            // read as living inside `/tmp/Steno`.
            if candidate.lowercased().hasPrefix(base.lowercased() + "/") { return true }
        }
        return false
    }

    /// The open store and its siblings.
    ///
    /// Read from the container's own configurations rather than from
    /// `StenoStore.defaultURL`, so the `STENO_STORE_PATH` seam is covered by the
    /// same guard — a test store is no less destroyable than the real one.
    ///
    /// `-wal` and `-shm` are appended to the *filename*, not added as path
    /// extensions: the files are `Steno.store-wal`, not `Steno.store.wal`.
    ///
    /// **`.steno-cli.lock` is in the list too, and it is not a database file.**
    /// `CLIWriteLock` holds an `flock` on an open file description, so replacing
    /// that pathname atomically leaves the holder on the orphaned inode while
    /// the next process opens and locks the replacement — two writers, and the
    /// lock has quietly stopped being one.
    static func protectedURLs(in context: ModelContext) -> [URL] {
        context.container.configurations.flatMap { configuration -> [URL] in
            let url = configuration.url.standardizedFileURL
            let directory = url.deletingLastPathComponent()
            return [url, CLIWriteLock.url(besideStoreAt: url)]
                + ["-wal", "-shm"].map {
                    directory.appendingPathComponent(url.lastPathComponent + $0)
                }
        }
    }

    /// The directories the store's files live in.
    private static func storeDirectories(in context: ModelContext) -> [URL] {
        context.container.configurations.map {
            $0.url.standardizedFileURL.deletingLastPathComponent()
        }
    }

    /// The path with its **parent's** symlinks resolved, keeping the last
    /// component as written.
    ///
    /// **`resolvingSymlinksInPath()` on the whole URL is not enough**, because
    /// the case this closes is a file that does not exist yet: when the
    /// destination and the protected sibling are both absent, neither has a
    /// resource identifier and the comparison falls back to path text. A parent
    /// that is a symlink to the store directory — `/tmp/steno` pointing at it,
    /// with `Steno.store-wal` not yet created — then produces two spellings of
    /// one location that compare unequal, and the atomic write follows the link
    /// and replaces the live write-ahead log. Resolving the parent makes both
    /// sides name the same directory.
    ///
    /// The last component is deliberately *not* resolved: if it is itself a
    /// symlink, writing to it follows the link, which is what
    /// `fileIdentifier(of:)` already compares — and resolving it would be wrong
    /// for a destination that does not exist.
    static func resolved(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent)
    }

    /// The whole path resolved, last component included.
    ///
    /// Right for a *directory* comparison and wrong for a file one: a folder
    /// that is itself a symlink into the store directory must be refused, while
    /// a file that is a symlink is compared by identity instead. `/tmp` being a
    /// symlink to `/private/tmp` on macOS makes this the difference between two
    /// spellings of one directory comparing equal and comparing unequal.
    private static func fullyResolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The volume's own identity for this file, or `nil` if it does not exist.
    private static func fileIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}
