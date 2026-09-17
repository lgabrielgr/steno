import Foundation

/// Why an export could not be produced.
///
/// One case, and deliberately not a mirror of `ImportError`: export reads and
/// never writes (D-085), so the only failures are "the store could not be read"
/// — which surfaces as the underlying error — and this one.
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

    public var message: String {
        switch self {
        case .storeChangedWhileReading:
            """
            Steno's data kept changing while the export was being written, so \
            nothing was exported. Quit Steno, or wait for whatever is writing \
            to finish, and try again.
            """
        }
    }
}
