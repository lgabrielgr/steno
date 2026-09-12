import Foundation

/// Why an import was refused, and what to tell the user.
///
/// **Almost every case is raised before the store is written to.** §10.4 requires
/// that a malformed file leave the store untouched, and the strongest form of
/// that is not a rollback but an absence of any write: `ImportService.plan` does
/// all of the decoding and all of the validation, and `apply` is reached only
/// with a plan that already passed.
///
/// Two cases can occur once writing has begun — `saveFailed`, and
/// `storeUnreadable` from a fetch inside the apply sequence. Both are staged in
/// a scratch `ModelContext` that is discarded whole, so neither can leave a live
/// model instance holding a value that was never saved.
///
/// `message` lives here rather than in a view so M2.5-03's alert and M2.5-04's
/// stderr say the same thing about the same failure. `Equatable`, so tests can
/// assert the case rather than matching on a string — which is also why
/// `saveFailed` carries a description rather than the underlying `Error`.
public enum ImportError: Error, Equatable, Sendable {
    /// Not JSON, truncated, or shaped wrongly once decoding got into it.
    case malformed(detail: String)

    /// §10.2's mandatory version gate: refuse rather than partially apply.
    case unsupportedSchemaVersion(found: Int, supported: Int)

    /// A record whose parent is in neither the file nor the store.
    case danglingReference(detail: String)

    /// One id, two different histories — see `StoreMerge`.
    case inconsistentRecord(detail: String)

    /// The single transaction failed. The store is unchanged.
    case saveFailed(detail: String)

    /// Reading the existing store failed, so the import never started.
    ///
    /// Distinct from `saveFailed` because the two are different events for the
    /// user and for a caller: nothing was attempted here, and telling someone
    /// their import "could not be saved" when the store could not be *read* is
    /// simply false.
    case storeUnreadable(detail: String)

    /// The store changed between planning and applying, so the plan no longer
    /// describes what would happen.
    ///
    /// §10.4 makes the preview the user's only chance to inspect before
    /// committing. Applying a stale plan would both mis-describe the result and
    /// overwrite the newer rows with the merge's older resolution of them.
    case storeChanged

    /// The payload, without the sentence around it — so a failure attributed to
    /// the wrong side can be re-reported against the right one.
    var detail: String {
        switch self {
        case .malformed(let detail), .danglingReference(let detail),
            .inconsistentRecord(let detail), .saveFailed(let detail),
            .storeUnreadable(let detail):
            detail
        case .unsupportedSchemaVersion(let found, let supported):
            "format \(found); this build reads format \(supported)"
        case .storeChanged:
            "the store changed while the import was being previewed"
        }
    }

    public var message: String {
        switch self {
        case .malformed(let detail):
            "This file isn't a readable Steno export. \(detail)"
        case .unsupportedSchemaVersion(let found, let supported):
            // **Not every unrecognized version is a newer one.** `ImportReader`
            // raises this case for any value it does not recognise, including
            // `0` or a negative from a hand-edited file, and telling the user to
            // update Steno there sends them after a release that will not help.
            found > supported
                ? """
                This file was written by a newer version of Steno (format \(found); \
                this build reads format \(supported)). Nothing was imported. \
                Update Steno and try again.
                """
                : """
                This file isn't in a format Steno recognises (format \(found); \
                this build reads format \(supported)). Nothing was imported.
                """
        case .danglingReference(let detail):
            """
            This file is incomplete — it refers to something that isn't in the \
            file or on this Mac. Nothing was imported. \(detail)
            """
        case .inconsistentRecord(let detail):
            """
            This file disagrees with what's already on this Mac about a record \
            they share. Nothing was imported. \(detail)
            """
        case .saveFailed(let detail):
            "The import could not be saved, so nothing was changed. \(detail)"
        case .storeUnreadable(let detail):
            "Steno could not read its own store, so nothing was imported. \(detail)"
        case .storeChanged:
            """
            Something changed on this Mac while the import was being previewed, \
            so nothing was imported. Open the file again to see an up-to-date \
            summary.
            """
        }
    }
}
