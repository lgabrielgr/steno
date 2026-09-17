import Foundation

extension CLIRunner {
    /// `steno import --file PATH [--replace]`.
    ///
    /// **Two calls and a print, exactly as §10.4 describes and
    /// `MainWindowModel` performs them.** `plan` decodes, validates and diffs
    /// without writing; the preview is `ImportPreviewSummary` over that plan;
    /// `apply` commits it in one transaction. Cancelling, in a CLI, is not
    /// running the command — which is why there is no confirmation step here and
    /// why `--replace` is the explicit gesture §10.1 asks for.
    func importFile(_ url: URL, mode: ImportMode) -> Int32 {
        // **Before the file is read, and before any row is touched.**
        //
        // This is the *second* place the guard runs: `CLIEntry` checks it before
        // opening the container, because `StenoStore.live` creates the store
        // directory and the store file, so a refusal that happened only here had
        // already written to disk — and the comment that used to sit on this
        // line claimed otherwise. Raised in review of PR #31.
        //
        // It stays here as well, for callers that build a `CLIRunner` directly.
        // A guard that lives at one of two entrances is a guard the next surface
        // forgets — the same reasoning that moved Replace's backup into
        // `ImportService.apply` (D-110).
        guard !isAnotherInstanceRunning() else {
            err(CLIInstanceCheck.refusalMessage)
            return ExitCode.failure
        }

        // **Held for the whole of plan-then-apply.** `ImportService` compares
        // the store against the plan and then writes, with nothing in between,
        // so two CLI writers that both passed the guard above could each see a
        // fresh store and each commit. `CLIInstanceCheck` cannot see them:
        // neither creates `NSApplication`, so neither registers with
        // LaunchServices. Raised in review of PR #31.
        //
        // `nil` only for an in-memory store, which no second process can reach.
        var lock: CLIWriteLock?
        if let store = storeFileURL {
            guard let acquired = CLIWriteLock(besideStoreAt: store) else {
                err(CLIWriteLock.busyMessage)
                return ExitCode.failure
            }
            lock = acquired
        }
        // Silences "never used"; the lock's whole job is to exist until this
        // function returns, at which point `deinit` releases it.
        defer { lock = nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.app.error(
                "cli could not read the import file: \(String(describing: error), privacy: .public)"
            )
            err("Could not read \(url.path). Nothing was imported.")
            return ExitCode.failure
        }

        let service = ImportService(context: context)
        let plan: ImportPlan
        do {
            plan = try service.plan(data, mode: mode)
        } catch let error as ImportError {
            err(error.message)
            return ExitCode.failure
        } catch {
            Log.app.error(
                "cli import planning failed: \(String(describing: error), privacy: .public)")
            err("Could not read \(url.lastPathComponent). Nothing was imported.")
            return ExitCode.failure
        }

        printPreview(of: plan, filename: url.lastPathComponent, mode: mode)

        // **§10.6's idempotency, made visible.** `apply` already refuses to
        // write for an empty plan; stopping here means the second import of a
        // file also prints nothing misleading and exits 0, which is what a
        // script re-running an import needs to see.
        guard !plan.isEmpty else {
            out("Nothing to import.")
            return ExitCode.success
        }

        return apply(plan, from: url, with: service)
    }

    /// §10.4's summary, on stdout.
    ///
    /// `ImportPreviewSummary` and not a second renderer: D-108 put that type in
    /// `StenoKit` for this call site specifically, so the sheet and the terminal
    /// are two views of one plan rather than two descriptions of it.
    private func printPreview(of plan: ImportPlan, filename: String, mode: ImportMode) {
        out(ImportPreviewSummary.headline(filename: filename, mode: mode))
        out(ImportPreviewSummary.provenance(plan.origin))
        for line in ImportPreviewSummary.lines(for: plan) {
            out(line)
        }
    }

    /// The transaction, plus §10.1's mandatory backup when this is a Replace.
    ///
    /// **The writer is handed to `apply`, which takes the backup itself** (D-110)
    /// — after its own staleness check and immediately before the first write.
    /// A receipt minted out here would prove only that some backup exists
    /// somewhere, not that it describes the store this transaction is about to
    /// wipe. `backupTo:` pins the path, because `plannedURL()` reads the clock
    /// and a second call a second later names a different file.
    private func apply(_ plan: ImportPlan, from url: URL, with service: ImportService) -> Int32 {
        var writer: BackupWriter?
        var backupURL: URL?
        if plan.mode == .replace {
            do {
                let built = try makeBackupWriter(context)
                writer = built
                backupURL = built.plannedURL()
            } catch {
                Log.app.error(
                    "cli backup writer could not be built: \(String(describing: error), privacy: .public)"
                )
                err(
                    "Steno could not prepare a backup of your current data, so nothing was "
                        + "replaced.")
                return ExitCode.failure
            }
        }

        do {
            let receipt = try service.apply(plan, backupWith: writer, backupTo: backupURL)
            if let receipt {
                out("Backup written to \(receipt.url.path)")
            }
            out("Imported \(url.lastPathComponent).")
            return ExitCode.success
        } catch let error as ImportError {
            err(error.message)
            return ExitCode.failure
        } catch {
            // Reached when the backup write itself threw: `apply` propagates it
            // untouched, and nothing was written, because the backup runs before
            // the first staged change.
            Log.app.error("cli import failed: \(String(describing: error), privacy: .public)")
            err(
                plan.mode == .replace
                    ? "Steno could not write a backup of your current data, so nothing was "
                        + "replaced. \(error.localizedDescription)"
                    : "The import could not be saved, so nothing was changed.")
            return ExitCode.failure
        }
    }
}
