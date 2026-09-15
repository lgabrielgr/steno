import Foundation
import SwiftData

@testable import StenoKit

/// A real `BackupReceipt`, for the tests that apply a `.replace` plan.
///
/// `ImportService.apply` refuses a replace plan without one (§10.1's mandatory
/// backup, enforced at the service boundary rather than in the UI — see D-110),
/// and `apply` takes the backup itself so it cannot be a stale one. These tests
/// hand it a real writer pointed at a temp directory, so the guard is exercised
/// on the real path rather than mocked around.
@MainActor
func replaceBackupWriter(for context: ModelContext) throws -> BackupWriter {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("steno-replace-backup-\(UUID().uuidString)", isDirectory: true)
    return try BackupWriter(
        context: context, directory: directory,
        now: { Date(timeIntervalSince1970: 1_700_000_000) })
}
