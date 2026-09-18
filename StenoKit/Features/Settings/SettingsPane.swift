import Foundation

/// The Settings window's panes, in display order.
///
/// **This enum is the extensibility mechanism M1-08 exists to build.** FR-6
/// lists five Settings areas that land across four milestones; building the
/// shell once, here, is what stops M3-04, M4-04 and M6-01 from each inventing
/// a window structure. Adding a pane is one case below, one arm in
/// `SettingsView`'s switch, and one new view file. **No existing pane is
/// opened, and no pane knows another exists.**
///
/// The commented cases are not a wish list — they are the sketch M1-08's
/// fourth acceptance criterion asks for, naming the task that adds each one.
///
/// It lives in `StenoKit` rather than beside the views because pane titles,
/// symbols and ordering are data a headless test can read, while `TabView`
/// construction is not (D-010).
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case capture

    /// FR-6's Data area, arriving with M2.5-05's auto-export.
    ///
    /// It carries the auto-export settings and nothing else. FR-6 also lists
    /// "export all data as JSON", which is already the File menu's Export item
    /// and is not duplicated here, and "purge cached external data", which
    /// waits for M4 — there is no cached external data until integrations
    /// exist, and a button that purges nothing is one nobody can verify
    /// (D-127).
    case data
    // case ai           — M3-04: provider, Keychain-backed key, model picker
    // case integrations — M4-04: Atlassian site, credentials, MCP servers
    // case stale        — M6-01: the global default N in days

    public var id: String { rawValue }

    /// The tab's label.
    public var title: String {
        switch self {
        case .capture: return "Capture"
        case .data: return "Data"
        }
    }

    /// The tab's SF Symbol.
    public var systemImage: String {
        switch self {
        case .capture: return "keyboard"
        case .data: return "externaldrive"
        }
    }
}
