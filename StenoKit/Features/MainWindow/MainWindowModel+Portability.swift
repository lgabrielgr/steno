import Foundation
import SwiftData

/// §10.5's Export and Import, and §10.1's Replace: the thin layer between the
/// File menu and the portability services.
///
/// `ImportPreviewModel` holds what the preview shows and decides when the
/// confirm button is live; this supplies the things it deliberately does not
/// hold — the store, the file, and the backup — and reloads when a write lands.
/// The same split `MainWindowModel+Standup` makes for FR-4.
extension MainWindowModel {
    /// See `MainWindowActions.canExchangeData`.
    public var canExchangeData: Bool { activeSheet == nil }

    // MARK: - §10.5, export

    /// Write the whole store to a file the user picks.
    ///
    /// **Reads only.** `ExportEncoder` has no `save` parameter and no write
    /// path — D-085 records that absence as the design — so there is nothing
    /// here that could change the store even if the file write fails.
    public func exportStore() {
        guard canExchangeData else { return }
        guard
            let destination = panels.chooseExportDestination(
                defaultName: ExportFilename.forDate(now()))
        else { return }

        // **Two failures, two sentences.** `encode()` throws when the *store*
        // cannot be read; `write(to:)` throws when the *file* cannot be written.
        // One catch told the user "Could not write the export" for both, sending
        // someone whose store failed to read off to check their disk. Raised in
        // review of PR #30, and the same distinction `ImportError` already draws
        // between `.storeUnreadable` and `.saveFailed`.
        let data: Data
        do {
            data = try ExportEncoder(
                context: context,
                includesCachedExternalData: destination.includesCachedExternalData
            ).encode()
        } catch {
            Log.app.error(
                "export could not be built: \(String(describing: error), privacy: .public)")
            lastNotice = nil
            lastError = "Steno could not read its own store, so nothing was exported."
            return
        }

        do {
            try data.write(to: destination.url, options: .atomic)
            lastError = nil
            lastNotice = "Exported to \(destination.url.path)."
            Log.app.info("export written to \(destination.url.path, privacy: .public)")
        } catch {
            Log.app.error(
                "export failed: \(String(describing: error), privacy: .public)")
            lastNotice = nil
            lastError = "Could not write the export. Nothing on this Mac was changed."
        }
    }

    // MARK: - §10.4, import

    public func importStore() { beginImport(mode: .merge) }

    public func replaceStoreFromFile() { beginImport(mode: .replace) }

    /// Read a file, plan the import, and show the preview.
    ///
    /// **A failed plan does not open the sheet**, for `prepareStandup()`'s
    /// reason: a modal whose only content is an error asks the user to dismiss
    /// something they did not summon. `ImportError.message` already says the
    /// store was untouched, and it goes to the window's inline banner.
    ///
    /// Nothing here writes. The plan is a pure read of the store plus a decode
    /// of the file, which is what makes "cancel leaves the store untouched"
    /// true without a rollback being involved at all.
    func beginImport(mode: ImportMode) {
        guard canExchangeData else { return }
        guard let url = panels.chooseImportSource() else { return }

        let plan: ImportPlan
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.app.error(
                "could not read the import file: \(String(describing: error), privacy: .public)")
            lastNotice = nil
            lastError = "Could not read \(url.lastPathComponent). Nothing was imported."
            return
        }

        do {
            plan = try ImportService(context: context, save: save).plan(data, mode: mode)
        } catch let error as ImportError {
            lastNotice = nil
            lastError = error.message
            return
        } catch {
            Log.app.error(
                "import planning failed: \(String(describing: error), privacy: .public)")
            lastNotice = nil
            lastError = "Could not read \(url.lastPathComponent). Nothing was imported."
            return
        }

        // **Resolved before the sheet opens, and a failure here stops Replace
        // now rather than after the user has typed the word.** §10.1 makes the
        // backup mandatory; a Replace that reaches the confirmation field and
        // only then discovers it has nowhere to write the backup has wasted the
        // user's decision and taught them the guard is unreliable.
        var backupURL: URL?
        if mode == .replace {
            do {
                backupURL = try makeBackupWriter(context).plannedURL()
            } catch {
                Log.app.error(
                    "backup location could not be resolved: \(String(describing: error), privacy: .public)"
                )
                lastNotice = nil
                lastError =
                    "Steno could not work out where to put a backup, so Replace is not available. "
                    + "Nothing was changed."
                return
            }
        }

        lastError = nil
        lastNotice = nil
        importPreview.begin(
            plan: plan, filename: url.lastPathComponent, backupURL: backupURL)
        activeSheet = .importPreview
    }

    /// The sheet's confirm button: §10.4's single transaction.
    ///
    /// **Backup first, and the order is the whole safety argument.** For
    /// `.replace` the backup is a separate file write that completes before a
    /// single row is touched; its throw returns here with the store untouched
    /// and the deletion phase never reached. §10.1 calls the backup mandatory,
    /// and the acceptance criterion is that Replace "fails safe if that backup
    /// cannot be written" — this is that, and there is no path around it.
    public func applyImport() {
        guard importPreview.canApply, let plan = importPreview.plan else { return }

        var receipt: BackupReceipt?
        if plan.mode == .replace {
            do {
                receipt = try makeBackupWriter(context).write(to: importPreview.backupURL)
            } catch {
                Log.app.error(
                    "replace backup failed: \(String(describing: error), privacy: .public)")
                importPreview.failed(
                    "Steno could not write a backup of your current data, so nothing was "
                        + "replaced. \(error.localizedDescription)")
                return
            }
        }

        do {
            try ImportService(context: context, save: save).apply(plan, backup: receipt)
        } catch let error as ImportError {
            importPreview.failed(error.message)
            // Reloads even on the failure: a rollback keeps the refused write
            // off disk, but what it leaves in the objects this window still
            // holds is not dependable (D-051).
            reload()
            return
        } catch {
            Log.app.error(
                "import failed: \(String(describing: error), privacy: .public)")
            importPreview.failed("The import could not be saved, so nothing was changed.")
            reload()
            return
        }

        importPreview.succeeded(backupURL: receipt?.url)
        // `apply` posts `.stenoDidWrite`, which this window's own observer turns
        // into a `reload()`, and then this line reloads again. Known and
        // harmless — `reload()` is idempotent — and the same shape
        // `MainWindowModel+Notes` and `+Standup` both document. Load-bearing
        // beyond the timeline: an import can move `lastStandupAt`, which moves
        // FR-3's DONE cutoff for every affected project.
        reload()
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    ///
    /// **No store access on this path at all**, which is the strongest
    /// available form of §10.4's "cancel leaves the store untouched": there is
    /// no rollback to get right because there was never a write to roll back.
    public func dismissImportPreview() {
        importPreview.dismiss()
        activeSheet = nil
    }

    /// Clear the success banner — the companion to `dismissError()`.
    public func dismissNotice() {
        lastNotice = nil
    }
}
