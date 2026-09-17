import AppKit
import Foundation

/// Is the Steno app running right now?
///
/// **`steno import` refuses when it is, and the hazard is specific.** There is
/// no cross-process change notification in this product: `.stenoDidWrite` is a
/// `NotificationCenter` post inside one process (D-019), and SwiftData gives the
/// GUI nothing that says its store moved underneath it. A CLI import writing
/// behind an open app therefore leaves that app holding live model instances
/// from before the merge — and its next save writes them back over the imported
/// rows. The user would see the import succeed and the data quietly revert.
///
/// Export carries no such hazard: it is a pure read (D-085), so it runs whether
/// or not the app is open. That asymmetry matters — M2.5-05 auto-exports from a
/// machine where Steno is by definition running.
///
/// A caseless `enum` for `StenoStore`'s reason: no instance state, nothing for
/// strict concurrency to reason about.
public enum CLIInstanceCheck {
    /// §9.1's fixed fact, written here rather than read from `Bundle.main`.
    ///
    /// `Bundle.main` is the app bundle in CLI mode and would be correct there —
    /// but it is the **xctest runner** in the unhosted test bundle (D-010), so a
    /// test exercising this check would silently ask about the wrong
    /// application and pass. The same reasoning made `Log.subsystem` a literal.
    public static let bundleIdentifier = "com.lgabrielgr.steno"

    /// **Excludes our own process, and that exclusion is load-bearing.** The
    /// CLI binary lives inside `Steno.app`, so if a terminal-launched process
    /// registers with LaunchServices at all, it registers under this same bundle
    /// identifier — and an unfiltered check would refuse every import on the
    /// grounds that the importer itself was running.
    ///
    /// Measured, not assumed: see the task's verification notes. A
    /// terminal-launched process that never creates `NSApplication` does not
    /// appear in this list, and the GUI app does.
    public static func anotherInstanceIsRunning() -> Bool {
        let ours = ProcessInfo.processInfo.processIdentifier
        return
            NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ours }
    }
}
