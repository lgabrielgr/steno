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
        // **Before the file is read**, so a refused import has touched nothing
        // at all — not the store, not the filesystem.
        guard !isAnotherInstanceRunning() else {
            err(
                "Steno is running, and importing underneath it would be overwritten by the "
                    + "app's next save. Quit Steno and run this again. Nothing was imported.")
            return ExitCode.failure
        }

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
