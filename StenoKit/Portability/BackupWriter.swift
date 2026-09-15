import Foundation
import SwiftData

/// Proof that a backup was actually written.
///
/// **The point is that nothing else can construct one.** §10.1 makes the
/// pre-Replace backup mandatory, but it was enforced only in
/// `MainWindowModel.applyImport()` — so `ImportService.apply` would happily
/// wipe a store for any other caller, and M2.5-04's `steno import --replace` is
/// exactly such a caller. A guard that lives in one of two call sites is a
/// guard the next surface forgets. Raised in review of PR #30.
///
/// `init` is private to this file, so the only way to obtain a receipt is to
/// have called `BackupWriter.write`.
public struct BackupReceipt: Equatable, Sendable {
    public let url: URL

    fileprivate init(url: URL) { self.url = url }
}

/// §10.1's "must auto-export a backup beforehand", for Replace.
///
/// **It throws rather than returning an optional.** The acceptance criterion is
/// that Replace "fails safe if that backup cannot be written", and a throw is
/// the shape that makes forgetting to check impossible — an optional invites a
/// caller to carry on with `nil`, and the thing they would carry on to is a
/// wipe. Replace is the only destructive operation in the product, and with
/// sync cancelled (§10, D1) there is no remote copy to fall back on.
///
/// `@MainActor` because `ExportEncoder` is, which is because `ModelContext` is
/// not `Sendable`.
@MainActor
public struct BackupWriter {
    private let context: ModelContext
    private let directory: URL
    private let now: () -> Date
    private let write: (Data, URL) throws -> Void

    /// `directory` and `now` are injected so the headless bundle writes into a
    /// temp directory and can assert the filename (§9.4); `write` is injected
    /// so "the backup could not be written" is testable without contriving a
    /// read-only filesystem. The defaults are what the app uses.
    public init(
        context: ModelContext,
        directory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) throws {
        self.context = context
        self.directory = try directory ?? Self.defaultDirectory
        self.now = now
        self.write = write
    }

    /// `~/Library/Application Support/Steno/Backups`.
    ///
    /// Beside the store rather than in the user's Documents: the backup exists
    /// to undo a mistaken Replace, and living next to the thing it snapshots is
    /// the property that matters for that. It is explicitly **not** a
    /// disaster-recovery copy — §10.5's auto-export, pointed at a sync folder,
    /// is that story. `create: false` for `StenoStore.storeDirectory`'s reason:
    /// resolving a path should have no side effects.
    public static var defaultDirectory: URL {
        get throws {
            try StenoStore.storeDirectory.appendingPathComponent("Backups", isDirectory: true)
        }
    }

    /// `steno-backup-2026-09-14-142205.json`.
    ///
    /// Seconds, where `ExportFilename` stops at the day: two Replaces in one
    /// afternoon are entirely plausible — the first one restored the wrong
    /// snapshot — and a name collision there would overwrite the backup taken
    /// before the mistake. Local time, for `ExportFilename.forDate`'s reason:
    /// the name exists so a person can find the file.
    public static func filename(for date: Date, timeZone: TimeZone = .current) -> String {
        // `.space`, not `.standard` — the latter is ISO-8601's `T`, which would
        // put a `T` in the middle of the filename. Checked, not assumed.
        let stamp = date.formatted(
            Date.ISO8601FormatStyle(
                dateTimeSeparator: .space, timeZone: timeZone
            )
            .year().month().day().time(includingFractionalSeconds: false))
        let compact =
            stamp
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
        return "steno-backup-\(compact).json"
    }

    /// Where the next backup would go, so the confirmation sheet can show the
    /// path **before** the user commits rather than only afterwards. That there
    /// is a way back is information they need while deciding.
    public func plannedURL() -> URL {
        directory.appendingPathComponent(Self.filename(for: now()))
    }

    /// Write the backup, and return where it went.
    ///
    /// **`includesCachedExternalData: true` is not optional here**, for the
    /// reason `ImportService.localStore()` gives about the same two fields: a
    /// snapshot that silently drops `cachedSummary` and `lastFetchedAt` is not
    /// one anybody can restore from, and §10.1's "nil loses to any value" would
    /// hand those fields away on the way back in. It is deliberately unrelated
    /// to the export panel's checkbox, which governs only exports the user asks
    /// for.
    ///
    /// `exportedBy` is passed rather than defaulted for D-010's reason: the
    /// test bundle is unhosted, so `Bundle.main` there is the xctest runner.
    /// `to` is the path the confirmation sheet already showed the user.
    ///
    /// **Not defaulted away.** `plannedURL()` reads the clock, so a preview
    /// shown at 14:22:05 and confirmed at 14:22:06 wrote a *different* filename
    /// from the one in the safety prompt — the recovery path the sheet promised
    /// pointed at nothing. Raised in review of PR #30. Passing the planned URL
    /// back in is what makes the promise and the file the same thing.
    @discardableResult
    public func write(
        userAgent: String = ExportDocument.userAgent(), to destination: URL? = nil
    ) throws -> BackupReceipt {
        let url = destination ?? plannedURL()
        let data = try ExportEncoder(
            context: context,
            includesCachedExternalData: true,
            now: now,
            exportedBy: userAgent
        ).encode()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try write(data, url)
        Log.app.info("replace backup written to \(url.path, privacy: .public)")
        return BackupReceipt(url: url)
    }
}
