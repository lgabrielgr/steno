import Foundation

/// Why an import was refused, and what to tell the user.
///
/// **Every case is raised before the store is written to.** §10.4 requires that
/// a malformed file leave the store untouched, and the strongest form of that is
/// not a rollback but an absence of any write: `ImportService.plan` does all of
/// the decoding and all of the validation, and `apply` is reached only with a
/// plan that already passed. `saveFailed` is the one case that can occur with a
/// transaction open, and it is the one case that rolls back.
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

    /// The store changed between planning and applying, so the plan no longer
    /// describes what would happen.
    ///
    /// §10.4 makes the preview the user's only chance to inspect before
    /// committing. Applying a stale plan would both mis-describe the result and
    /// overwrite the newer rows with the merge's older resolution of them.
    case storeChanged

    public var message: String {
        switch self {
        case .malformed(let detail):
            "This file isn't a readable Steno export. \(detail)"
        case .unsupportedSchemaVersion(let found, let supported):
            """
            This file was written by a newer version of Steno (format \(found); \
            this build reads format \(supported)). Nothing was imported. \
            Update Steno and try again.
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
        case .storeChanged:
            """
            Something changed on this Mac while the import was being previewed, \
            so nothing was imported. Open the file again to see an up-to-date \
            summary.
            """
        }
    }
}
