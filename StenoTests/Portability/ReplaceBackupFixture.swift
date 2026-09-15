import Foundation
import SwiftData

@testable import StenoKit

/// A real `BackupReceipt`, for the tests that apply a `.replace` plan.
///
/// `ImportService.apply` refuses a replace plan without one (§10.1's mandatory
/// backup, enforced at the service boundary rather than in the UI — see D-110),
/// and a receipt can only be minted by `BackupWriter.write`. So these tests take
/// a genuine backup into a temp directory, which also means the guard is
/// exercised on the real path rather than mocked around.
@MainActor
func replaceBackup(for context: ModelContext) throws -> BackupReceipt {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-replace-backup-\(UUID().uuidString)", isDirectory: true)
    return try BackupWriter(
        context: context, directory: directory, now: { Date(timeIntervalSince1970: 1_700_000_000) }
    ).write(userAgent: "steno/test (macOS)")
}
