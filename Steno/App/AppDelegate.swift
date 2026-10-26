import AppKit
import StenoKit

/// The app's lifecycle edges.
///
/// M1-04's first acceptance criterion is that the menu bar icon is present
/// "without the main window open", which is a claim about process lifetime:
/// closing the last window must not quit Steno. Stating it costs three lines
/// and removes a dependency on a framework default that is free to change.
///
/// M5-01 adds the MCP host's two edges: the orphan reap at launch and the
/// bounded stop at quit (D-236, D-237).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Touching the host starts its reap of servers a crashed run left behind
    /// — at launch, before anything could ask it for a server.
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MCPHost.shared
    }

    /// Quit waits for MCP servers to stop, for at most `shutdownAll`'s budget.
    ///
    /// **Bounded by construction:** `shutdownAll` returns at its budget
    /// whatever the servers do, so quit can never hang on one. A server it did
    /// not finish stopping keeps its ledger entry and is reaped next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await MCPHost.shared.shutdownAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
