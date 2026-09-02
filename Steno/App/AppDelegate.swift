import AppKit

/// Exists for one line.
///
/// M1-04's first acceptance criterion is that the menu bar icon is present
/// "without the main window open", which is a claim about process lifetime:
/// closing the last window must not quit Steno. Stating it costs three lines
/// and removes a dependency on a framework default that is free to change.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
