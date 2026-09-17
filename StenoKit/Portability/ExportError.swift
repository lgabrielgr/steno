import Foundation

/// Why an export could not be produced.
///
/// `message` lives here for `ImportError.message`'s reason: the File menu's
/// banner and `steno export`'s stderr must say the same thing about the same
/// failure.
public enum ExportError: Error, Equatable, Sendable {
    /// The store changed while it was being read, repeatedly.
    ///
    /// `ExportEncoder.snapshot()` fetches each record type separately, so a
    /// writer committing between two of those fetches produces a document whose
    /// parts come from different generations — tasks whose project was fetched
    /// before it existed, events whose task was not. Nothing is lost on this
    /// Mac, but the *file* is incoherent, and the failure surfaces much later as
    /// `ImportError.danglingReference` on a machine trying to restore from it.
    /// With sync cancelled (§10, D1) that file may be the only copy.
    case storeChangedWhileReading

    /// The bytes produced for a pre-Replace backup cannot be read back.
    ///
    /// **A backup that cannot be restored is not a backup**, and §10.1 makes
    /// this one mandatory precisely because Replace is the product's only
    /// destructive operation. Reachable since `.replace` began proceeding on a
    /// store holding duplicate ids (PR #31): `ExportEncoder` serializes every
    /// physical row, so the backup carries the duplicates and `ImportReader`
    /// refuses it on the way back in. Wiping the store behind such a file would
    /// leave the user with neither their data nor a way back.
    case backupNotRestorable(detail: String)

    public var message: String {
        switch self {
        case .storeChangedWhileReading:
            """
            Steno's data kept changing while the export was being written, so \
            nothing was exported. Quit Steno, or wait for whatever is writing \
            to finish, and try again.
            """
        case .backupNotRestorable(let detail):
            """
            Steno could not make a backup it would be able to restore, so \
            nothing was replaced. Your data has not been changed. \(detail)
            """
        }
    }
}

extension ExportError: LocalizedError {
    /// So `localizedDescription` says what `message` says.
    ///
    /// Both call sites for Replace's backup failure report the caught error's
    /// `localizedDescription`; without this they would print
    /// `The operation couldn’t be completed. (StenoKit.ExportError error 1.)`
    /// at the moment the user most needs to know what happened.
    public var errorDescription: String? { message }
}
