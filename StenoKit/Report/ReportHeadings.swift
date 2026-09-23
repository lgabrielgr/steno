/// The section titles both report paths use (FR-4, D17).
///
/// **One owner, because the AI path and the raw path must agree.** M3-03's
/// sixth acceptance criterion is that a failed, unconfigured or offline AI call
/// still produces "the same three headings, rougher content" — and until this
/// type existed the strings lived as literals inside two private functions in
/// `RawReportSections`, with `DraftSections` about to add a third and fourth
/// copy. A criterion stated over two copies of a string holds only until
/// someone edits one of them.
///
/// Imports nothing, for `RawReportSections`' reason: a type that cannot read a
/// clock or a store cannot be the thing that broke §7.4's guarantee.
public enum ReportHeadings {
    /// FR-4's daily set: a DSU's three questions.
    public static let sinceLastStandup = "Since last stand-up"
    public static let today = "Today"
    public static let blockers = "Blockers"

    /// D17's periodic set. Not a rename of the daily headings — *Completed*
    /// means finished, where *Since last stand-up* means everything that moved.
    public static let completed = "Completed"
    public static let inFlight = "In flight"
    public static let blockersAndRisks = "Blockers & risks"

    /// The three titles a cadence's report uses, in the order they are emitted.
    ///
    /// Exists so a test can assert the two paths agree by comparing each
    /// against this list, rather than by comparing them to each other — which
    /// would pass if both drifted the same way.
    public static func ordered(for cadence: ReportCadence) -> [String] {
        switch cadence {
        case .daily:
            [sinceLastStandup, today, blockers]
        case .periodic:
            [completed, inFlight, blockersAndRisks]
        }
    }
}
