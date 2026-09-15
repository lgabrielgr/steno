import Foundation

/// Which of §10.1's two imports this is.
///
/// **Merge is the default, in the type as well as in the UI.**
/// `ImportService.plan(_:mode:)` defaults to `.merge`, so every M2.5-02 caller
/// keeps its meaning and a surface that forgets to pass a mode gets the
/// non-destructive one. §10.1's "Replace is never the path of least resistance"
/// is a statement about the menu, but it costs nothing to make it true of the
/// API too.
public enum ImportMode: Equatable, Sendable {
    /// §10.1's union by UUID. Never removes a record.
    case merge

    /// §10.1's break-glass path: the file becomes the whole store, and local
    /// records the file lacks are deleted.
    ///
    /// "It exists for restoring a known-good snapshot, not for routine
    /// transfer." Callers must write a backup before applying a plan built in
    /// this mode — see `BackupWriter`.
    case replace
}
