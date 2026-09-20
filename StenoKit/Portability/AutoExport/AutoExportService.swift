import Foundation
import SwiftData

/// Which trigger asked for an export (§10.5, D-121).
public enum AutoExportTrigger: String, Equatable, Sendable {
    /// `NSApplication.willTerminateNotification`. Unconditional: every quit
    /// rewrites the day's file with the freshest store.
    case quit

    /// At launch and on the hourly tick, when 24h have passed since the last
    /// success.
    case daily

    /// The Data pane's "Export now". Bypasses the dueness check, and nothing
    /// else.
    case manual

    /// Whether this trigger's own toggle is on. `manual` has no toggle — the
    /// button *is* the gesture — and the pane disables it when auto-export is
    /// off, so there is nothing for it to consult.
    func isEnabled(by settings: AppSettings) -> Bool {
        switch self {
        case .quit: return settings.autoExportOnQuit
        case .daily: return settings.autoExportDaily
        case .manual: return true
        }
    }
}

/// Why an export did not happen, when that is not a failure.
public enum AutoExportSkip: String, Equatable, Sendable {
    case disabled
    case triggerOff
    case notDue
}

/// What a run did. Returned *and* persisted — the return value is for the
/// caller, `AppSettings.autoExportStatus` is for the next launch.
public enum AutoExportOutcome: Equatable, Sendable {
    case written(URL)
    case skipped(AutoExportSkip)

    /// The user-facing sentence, already recorded in the status by the time
    /// this is returned.
    case failed(String)
}

/// §10.5's auto-export: the whole unattended write, and nothing else.
///
/// **It does not throw.** Every failure it can have is one the user must be
/// told about rather than one a caller could handle — with sync cancelled (D1,
/// §14) a failed auto-export means no backup exists and nobody knows — so it
/// records the outcome where a later process can find it, logs it, and returns
/// it. A `throws` signature would let the quit path, which has nowhere to
/// display anything, drop the one message that matters by simply not catching.
///
/// Every dependency is injected for `BackupWriter`'s reason: the headless
/// bundle (§9.4) drives the whole thing inside a temp directory, and "the disk
/// is full" is testable without filling a disk.
///
/// `@MainActor` because `ExportEncoder` is, which is because `ModelContext` is
/// not `Sendable`.
@MainActor
public struct AutoExportService {
    private let context: ModelContext
    private let settings: AppSettings
    private let now: () -> Date
    private let exportedBy: String
    private let write: (Data, URL) throws -> Void
    private let trash: (URL) throws -> Void
    private let contents: (URL) throws -> [URL]
    private let createDirectory: (URL) throws -> Void
    private let exists: (URL) -> Bool
    private let isRegularFile: (URL) -> Bool
    private let afterRead: () -> Void

    /// `exportedBy` is passed rather than defaulted at the call site for
    /// D-010's reason: the test bundle is unhosted, so `Bundle.main` there is
    /// the xctest runner.
    ///
    /// - Parameter afterRead: forwarded to the `ExportEncoder` built inside
    ///   `encode(at:)`. The only way to exercise the "store changed while
    ///   reading" arm of `run`'s `catch`: a real concurrent writer cannot be
    ///   arranged in a headless single-process test (§9.4).
    public init(
        context: ModelContext,
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init,
        exportedBy: String = ExportDocument.userAgent(),
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
        trash: @escaping (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        },
        contents: @escaping (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: nil)
        },
        createDirectory: @escaping (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        isRegularFile: @escaping (URL) -> Bool = {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        },
        afterRead: @escaping () -> Void = {}
    ) {
        self.context = context
        self.settings = settings
        self.now = now
        self.exportedBy = exportedBy
        self.write = write
        self.trash = trash
        self.contents = contents
        self.createDirectory = createDirectory
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.afterRead = afterRead
    }

    /// Why this folder cannot be the auto-export folder, or `nil`.
    ///
    /// Exposed so `Choose Folder…` refuses the mistake while the user is
    /// looking at it, rather than at the next quit through the failure banner.
    /// `run` asks the same question again before every write: the store's
    /// location comes from the open container, and a folder validated in
    /// January is not a promise about March.
    public func problem(withFolder folder: URL) -> String? {
        guard StoreFileGuard.isInsideStoreDirectory(folder, in: context) else { return nil }
        return "\(folder.path) is inside Steno's own data store. Exports there could destroy "
            + "your data, so Steno will not write to it. Choose another folder."
    }

    /// Export, if this trigger says to.
    ///
    /// The order is load-bearing: gate, guard the folder, create it, encode,
    /// write, *then* record success and sweep. Nothing marks a success until
    /// the bytes are on disk, so a throw anywhere leaves the previous success
    /// record intact and adds a failure beside it.
    ///
    /// **One clock reading for the whole call.** `now` is read once, into
    /// `instant`, and every date this run produces — the dueness check, the
    /// filename, the encoded `exportedAt`, and either the success or the
    /// failure record — is derived from that one value. `Date.init` reads the
    /// wall clock fresh each call, so re-reading it at each of those points
    /// let a run that straddled midnight name its file for one day and record
    /// `writtenAt` on the next: two disagreeing timestamps describing what was
    /// supposed to be a single, atomic operation. `MainWindowModel.reload` and
    /// `StandupService.commit` take the same one-reading-per-operation shape,
    /// for the same reason.
    @discardableResult
    public func run(trigger: AutoExportTrigger) -> AutoExportOutcome {
        let instant = now()
        guard settings.autoExportEnabled else { return .skipped(.disabled) }
        guard trigger.isEnabled(by: settings) else { return .skipped(.triggerOff) }
        if trigger == .daily,
            !AutoExportDue.isDue(
                lastSuccess: settings.autoExportStatus.lastSuccess?.writtenAt, now: instant)
        {
            return .skipped(.notDue)
        }

        let folder = settings.autoExportFolder
        if let failure = prepareFolder(folder, at: instant) { return failure }

        // **Two failures, two sentences**, the distinction
        // `MainWindowModel.exportStore()` and `CLIRunner.export` both already
        // draw: `encode()` throws when the *store* cannot be read, `write`
        // throws when the *file* cannot be written, and one message for both
        // sends someone whose store is merely busy off to check their disk.
        let data: Data
        do {
            data = try encode(at: instant)
        } catch let error as ExportError {
            return fail(error.message, at: instant)
        } catch {
            Log.app.error(
                "auto-export could not be built: \(String(describing: error), privacy: .public)")
            return fail(
                "Steno could not read its own store, so no backup was written.", at: instant)
        }

        let url = folder.appendingPathComponent(ExportFilename.forDate(instant))
        do {
            try write(data, url)
        } catch {
            return fail(
                "Could not write \(url.path). Nothing on this Mac was changed. "
                    + error.localizedDescription, at: instant)
        }

        record(
            AutoExportStatus(
                lastSuccess: .init(writtenAt: instant, path: url.path), lastFailure: nil))
        Log.app.info(
            "auto-export (\(trigger.rawValue, privacy: .public)) written to \(url.path, privacy: .public)"
        )
        sweep(folder)
        return .written(url)
    }

    /// Encode the store as it stood at `instant`.
    ///
    /// Pulled out of `run` so the reasoning below stays attached to the call
    /// it explains without pushing `run`'s body past SwiftLint's length gate;
    /// the two-sentence distinction between this throwing and `write`
    /// throwing is drawn in `run`, where both are caught.
    ///
    /// `includesCachedExternalData: true`, not optional and not a setting
    /// (D-122). `BackupWriter` documents the argument: a snapshot that
    /// silently drops `cachedSummary` and `lastFetchedAt` is not one anybody
    /// can restore from, and §10.1's "nil loses to any value" would hand
    /// those fields away on the way back in.
    ///
    /// `now: { instant }`, not `now: now` — the encoder reads its clock twice
    /// more internally for the stability check, and both reads must agree
    /// with the timestamp this run already committed to.
    private func encode(at instant: Date) throws -> Data {
        try ExportEncoder(
            context: context,
            includesCachedExternalData: true,
            now: { instant },
            exportedBy: exportedBy,
            afterRead: afterRead
        ).encode()
    }

    /// Guard the destination, and create it only when it is genuinely new.
    ///
    /// Extracted from `run` when it crossed SwiftLint's 50-line function limit,
    /// the same way `encode(at:)` was. The three checks belong together anyway:
    /// each answers "may we write into this folder at all", and each returns the
    /// sentence the user sees. `nil` means the folder is ready.
    private func prepareFolder(_ folder: URL, at instant: Date) -> AutoExportOutcome? {
        if let problem = problem(withFolder: folder) {
            return fail(problem, at: instant)
        }

        // **A folder that has worked before and is now gone is reported, not
        // recreated.** `createDirectory` below would happily make a fresh empty
        // one at the same path and report a successful backup — which is right
        // on a first run, and actively harmful afterwards. The case §10.5 cares
        // about is a folder pointed at Dropbox or an external drive that has
        // since moved, unmounted, or been signed out of: recreating a plain
        // local directory there writes a file nobody is syncing while telling
        // the user their off-machine copy is fine. Found in manual
        // verification of M2.5-05, where renaming the folder away produced an
        // unbroken run of green backups. See D-128.
        if !exists(folder), hasBackedUp(into: folder) {
            return fail(
                "\(folder.path) is gone, and Steno had been backing up there. It was not "
                    + "recreated: if that folder was on a sync service or another drive, a new "
                    + "empty one would not be the backup you had. No backup was written.",
                at: instant)
        }

        do {
            try createDirectory(folder)
        } catch {
            return fail(
                "Steno could not create \(folder.path), so no backup was written. "
                    + error.localizedDescription, at: instant)
        }

        return nil
    }

    /// Has a backup ever landed in *this* folder?
    ///
    /// The question separates "make me a folder" from "your backup folder has
    /// disappeared", and `AutoExportStatus` already holds the evidence: a
    /// recorded success names the file it wrote, whose parent is the folder it
    /// wrote into. A success recorded against a *different* folder answers no,
    /// which is what lets the user pick a folder that does not exist yet and
    /// have it created for them.
    private func hasBackedUp(into folder: URL) -> Bool {
        guard let path = settings.autoExportStatus.lastSuccess?.path else { return false }
        let recorded = URL(fileURLWithPath: path)
            .deletingLastPathComponent().standardizedFileURL.path
        // Case-insensitively, for `StoreFileGuard`'s reason: HFS+ and APFS fold
        // case by default, so two spellings of one folder must compare equal.
        return recorded.compare(folder.standardizedFileURL.path, options: .caseInsensitive)
            == .orderedSame
    }

    /// Delete the surplus, keeping the newest 14 (D-124).
    ///
    /// **A retention failure is logged and nothing more.** The export
    /// succeeded; reporting a stuck sweep through the failure channel would put
    /// a false alarm on the one channel that has to stay trustworthy, and the
    /// consequence of doing nothing is a folder one file larger until the next
    /// run tries again.
    ///
    /// Caught per file rather than around the loop, so one undeletable file
    /// does not strand the rest.
    private func sweep(_ folder: URL) {
        let urls: [URL]
        do {
            urls = try contents(folder)
        } catch {
            Log.app.error(
                "auto-export could not list \(folder.path, privacy: .public) to apply retention")
            return
        }
        // **Directories are not candidates, whatever they are called.**
        // `contentsOfDirectory` lists subdirectories too, and
        // `AutoExportRetention` is pure over names — it cannot see that
        // `steno-export-2026-09-18.json` is a folder somebody made. Trashing a
        // directory Steno never wrote is exactly what retention promises never
        // to do. Filtered here, where the filesystem is reachable, rather than
        // in the pure rule. Raised by Copilot in review of PR #32.
        for url in AutoExportRetention.prunable(from: urls.filter(isRegularFile)) {
            do {
                // `trashItem`, not `removeItem` (D-124): this is a product
                // whose event log is append-only because permanent loss is the
                // thing it refuses to risk, and an over-eager sweep that puts
                // files in the Trash is recoverable.
                try trash(url)
                Log.app.info("auto-export retention trashed \(url.path, privacy: .public)")
            } catch {
                Log.app.error(
                    "auto-export could not trash \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Record a failure and hand back the sentence.
    ///
    /// `instant` is passed in rather than read here, so a failure is stamped
    /// with the same clock reading the rest of `run` used — see `run`'s note.
    private func fail(_ message: String, at instant: Date) -> AutoExportOutcome {
        var status = settings.autoExportStatus
        status.lastFailure = .init(failedAt: instant, message: message)
        record(status)
        Log.app.error("auto-export failed: \(message, privacy: .public)")
        return .failed(message)
    }

    /// Persist, then tell the surfaces. Persisting first is what makes a
    /// quit-time failure survive the process that could not display it.
    private func record(_ status: AutoExportStatus) {
        settings.autoExportStatus = status
        NotificationCenter.default.post(name: .stenoAutoExportDidChange, object: nil)
    }
}
