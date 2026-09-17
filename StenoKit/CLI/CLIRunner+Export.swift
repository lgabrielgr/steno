import Foundation

extension CLIRunner {
    /// `steno export [--output PATH] [--include-cached]`.
    ///
    /// **Read-only, and structurally so.** `ExportEncoder` has no `save`
    /// parameter and no write path — D-085 records that absence as the design —
    /// so there is nothing on this path that could change the store even when
    /// the file write fails. That is why export runs whether or not the app is
    /// open, while `importFile` refuses.
    func export(to output: URL?, includingCachedData: Bool) -> Int32 {
        let destination: URL
        do {
            destination = try resolveDestination(output)
        } catch let failure as ExportDestinationError {
            err(failure.message)
            return ExitCode.failure
        } catch {
            err("Could not work out where to write the export. \(error.localizedDescription)")
            return ExitCode.failure
        }

        // **Two failures, two sentences**, the same distinction
        // `MainWindowModel.exportStore()` draws: `encode()` throws when the
        // *store* cannot be read, `write(to:)` when the *file* cannot be
        // written. One message for both sends someone whose store failed to
        // read off to check their disk.
        let data: Data
        do {
            data = try ExportEncoder(
                context: context,
                includesCachedExternalData: includingCachedData,
                now: now,
                exportedBy: exportedBy
            ).encode()
        } catch {
            Log.app.error(
                "cli export could not be built: \(String(describing: error), privacy: .public)")
            err("Steno could not read its own store, so nothing was exported.")
            return ExitCode.failure
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            Log.app.error("cli export failed: \(String(describing: error), privacy: .public)")
            err(
                "Could not write \(destination.path). Nothing on this Mac was changed. "
                    + error.localizedDescription)
            return ExitCode.failure
        }

        Log.app.info("cli export written to \(destination.path, privacy: .public)")
        out("Exported to \(destination.path)")
        return ExitCode.success
    }

    /// Where `--output` means the file should go.
    ///
    /// Three cases, and the middle one is the reason this is a function rather
    /// than a line:
    ///
    /// - **No `--output`** — §10.2's dated filename in the working directory.
    /// - **`--output` naming an existing directory** — that same filename
    ///   inside it. M2.5-05 points a folder at a sync drive and wants exactly
    ///   this, and without it `--output ~/Dropbox/steno` would try to write a
    ///   file *over* a directory and fail with a decidedly unhelpful errno.
    /// - **Anything else** — the path as given, overwritten if it exists.
    ///
    /// `ExportFilename`'s own documentation defers collisions to this task, and
    /// the answer is overwrite: a scripted daily export to one folder has to be
    /// re-runnable, and export is a pure read, so nothing is lost that the store
    /// does not still hold. The exposure is a mistyped `--output` clobbering an
    /// unrelated file, accepted as the price of conventional `-o` behaviour.
    private func resolveDestination(_ output: URL?) throws -> URL {
        let name = ExportFilename.forDate(now())
        guard let output else {
            return workingDirectory.appendingPathComponent(name)
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: output.path, isDirectory: &isDirectory)
        let destination =
            exists && isDirectory.boolValue ? output.appendingPathComponent(name) : output

        // **Checked here rather than left to `write(to:)`.** An atomic write
        // into a missing directory fails with "The file “x.json” doesn’t
        // exist.", which describes the file the user is trying to *create* and
        // sends them looking in the wrong place. Creating the directory instead
        // was rejected: `--output` is a destination, not an instruction to
        // build a tree, and a typo'd path would silently produce one.
        // **Never over the store this process has open.** `--output` is taken
        // verbatim, so `--output ~/Library/Application\ Support/Steno/Steno.store`
        // encoded successfully and then atomically replaced the SQLite file with
        // JSON — destroying the data the export exists to protect, and saying
        // "Exported to …" while it did. The `-wal` and `-shm` siblings are
        // refused too: `StenoStore.storeDirectory` calls the three files the
        // unit of deletion, and losing the write-ahead log strands the store
        // just as effectively. Raised in review of PR #31.
        guard !isStoreFile(destination) else {
            throw ExportDestinationError(
                message:
                    "\(destination.path) is Steno's own store. Exporting over it would "
                    + "destroy your data, so nothing was exported.")
        }

        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
            parentIsDirectory.boolValue
        else {
            throw ExportDestinationError(
                message: "There is no directory at \(parent.path), so nothing was exported.")
        }
        return destination
    }
}

extension CLIRunner {
    /// Would writing here overwrite the open store or one of its two SwiftData
    /// siblings?
    ///
    /// **Filesystem identity first, path text only as a fallback.** Comparing
    /// `standardizedFileURL.path` as a string was wrong on the volume macOS
    /// actually ships: HFS+ and APFS are case-**insensitive** by default, so
    /// `--output steno.store` names the same database as `Steno.store` and
    /// walked straight past a case-sensitive `Set<String>` lookup. Raised in
    /// review of PR #31.
    ///
    /// `fileResourceIdentifierKey` is the right instrument — it answers "same
    /// file?" across case folding, symlinks, hard links and `..` — but it is
    /// only available for a file that **exists**. The store always does, having
    /// just been opened; its `-wal` and `-shm` siblings may not, and a
    /// destination that does not exist yet cannot be compared that way either.
    /// Case-insensitive path comparison covers those, which is the safe
    /// direction: it can only ever refuse *more*, and the thing it might refuse
    /// is a file differing from the store's name by case alone.
    fileprivate func isStoreFile(_ destination: URL) -> Bool {
        let candidate = destination.standardizedFileURL
        for url in protectedURLs {
            if let left = fileIdentifier(of: candidate), let right = fileIdentifier(of: url) {
                if left.isEqual(right) { return true }
            } else if candidate.path.compare(url.path, options: .caseInsensitive) == .orderedSame {
                return true
            }
        }
        return false
    }

    /// The open store and its two siblings.
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
    /// lock has quietly stopped being one. Raised in review of PR #31.
    private var protectedURLs: [URL] {
        context.container.configurations.flatMap { configuration -> [URL] in
            let url = configuration.url.standardizedFileURL
            let directory = url.deletingLastPathComponent()
            return [url, CLIWriteLock.url(besideStoreAt: url)]
                + ["-wal", "-shm"].map {
                    directory.appendingPathComponent(url.lastPathComponent + $0)
                }
        }
    }

    /// The volume's own identity for this file, or `nil` if it does not exist.
    private func fileIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}

/// A destination that cannot be written to, with the sentence to print.
///
/// Private to the export path: `ImportError` is the vocabulary for everything
/// on the import side, and this is the one failure export has that it does not
/// share.
private struct ExportDestinationError: Error {
    let message: String
}
