/// How often a project is reported on (REQUIREMENTS.md §3.1, D17).
///
/// The cadence-to-staleness mapping (FR-5's 3 days / 10 days) deliberately
/// does not live here — it is a stale-detection rule and belongs to the task
/// that implements FR-5.
public enum ReportCadence: String, Codable, CaseIterable, Sendable {
    case daily
    case periodic
}
