import AppKit

/// D6's clipboard, and the only place in StenoKit that imports AppKit.
///
/// **Wrapped rather than called inline so `StandupService` can be tested.**
/// §9.4 runs the suite headless; a test that reached `NSPasteboard.general`
/// would mutate the developer's own clipboard and would be order-dependent on
/// anything else in the process that copies. The service takes a
/// `copy: (String) -> Bool` defaulting to `write`, so the real pasteboard is
/// reachable only from the app.
public enum SystemClipboard {
    /// Replace the clipboard's contents with `text`.
    ///
    /// Returns whether the write landed. `NSPasteboard.setString` returns
    /// `false` when another process holds the pasteboard, and
    /// `StandupService` reports that case rather than swallowing it — by the
    /// time it happens the report is already committed, so a silent failure
    /// would leave the user with an advanced clock and an empty clipboard and
    /// no idea why.
    ///
    /// `clearContents()` first: it is what declares the new owner and bumps the
    /// change count. Without it `setString` writes into a declaration that was
    /// never made and returns `false`.
    @discardableResult
    public static func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
