import Foundation

/// The total order every exported array carries (D-092), owned by a type that
/// is not tied to an actor.
///
/// **These comparators lived in `extension ExportEncoder` until M2.5-02.** That
/// type is `@MainActor`, so its static members are main-actor-isolated too, and
/// `StoreMerge` is deliberately `nonisolated` — the whole reason §10.6's three
/// algebraic properties can be asserted over values instead of over two live
/// stores. Moving them here is what lets the merge emit arrays in the same order
/// the encoder does, rather than declaring a second order that agrees with the
/// first until it doesn't.
enum ExportOrdering {

    // Every comparator ends in `id.uuidString`, and that tie-break carries the
    // weight. `sorted(by:)` is not documented as stable, so without it two
    // records sharing a timestamp have an unspecified relative order: two
    // exports of an unchanged store would differ, and M2.5-05's auto-export
    // history would be churn rather than a backup log. `UUID` is not
    // `Comparable`, so the tie-break goes through `uuidString`.
    //
    // Sorting happens in memory rather than through `FetchDescriptor.sortBy` so
    // the comparators sit together, and so `SourceRefKind` is not a special
    // case — an enum inside a SwiftData `#Predicate` does not compile in either
    // spelling (`EventQueries.swift`, D-085).

    /// Projects in the order the UI shows them.
    ///
    /// `(sortOrder, name)` is `MainWindowModel.fetchProjects`'s order, and
    /// `sortOrder` is not unique — so sorting on `(sortOrder, id)` would put two
    /// equally-ordered projects in a different sequence from the one the user
    /// sees in the sidebar. The id stays as a third component, because `name`
    /// is not unique either and the order still has to be total.
    static func precedes(_ lhs: ExportedProject, _ rhs: ExportedProject) -> Bool {
        (lhs.sortOrder, lhs.name, lhs.id.uuidString)
            < (rhs.sortOrder, rhs.name, rhs.id.uuidString)
    }

    /// Order `items` by the timestamp **as the file carries it**, then by id.
    ///
    /// **The sort key is the emitted string, not the in-memory `Date`.** Two
    /// events a fraction of a millisecond apart are distinguishable in memory
    /// and identical on the wire, so ordering on the `Date` puts them in a
    /// sequence the file cannot express: any store built from that file ties on
    /// them, falls through to the id, and can reverse the pair relative to the
    /// export it came from. Keying on the emitted value makes the array's order
    /// derivable from the file's own contents — which is what M2.5-05's backup
    /// history and M2.5-02's convergence actually need.
    ///
    /// The key comes from `ExportDocument.wireString`, the same function the
    /// encoder's date strategy uses, and that is the second attempt: a
    /// `(seconds * 1000).rounded(.down)` key disagreed with the formatter at
    /// `.999` — a second implementation of the same quantization, drifting from
    /// the first in the third decimal place. There is now only one, which
    /// matters more since that function rounds: `…20.9995` carries to
    /// `…21.000`, so the boundary the two implementations disagreed on is live.
    /// Fixed-width UTC ISO-8601 sorts lexicographically as it does
    /// chronologically, and the key is computed once per record rather than
    /// once per comparison.
    static func sortedByWireInstant<Element>(
        _ items: [Element],
        instant: (Element) -> Date,
        id: (Element) -> UUID
    ) -> [Element] {
        items
            .map {
                (
                    key: ExportDocument.wireString(instant($0)),
                    tieBreak: id($0).uuidString,
                    value: $0
                )
            }
            .sorted { ($0.key, $0.tieBreak) < ($1.key, $1.tieBreak) }
            .map(\.value)
    }

    /// §3.4's dedup key, which groups a task's refs together.
    static func precedes(_ lhs: ExportedSourceRef, _ rhs: ExportedSourceRef) -> Bool {
        (lhs.taskID.uuidString, lhs.kind.rawValue, lhs.identifier, lhs.id.uuidString)
            < (rhs.taskID.uuidString, rhs.kind.rawValue, rhs.identifier, rhs.id.uuidString)
    }
}
