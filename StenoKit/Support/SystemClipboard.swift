import AppKit

/// D6's clipboard, and the only place in StenoKit that touches `NSPasteboard`.
///
/// **Wrapped rather than called inline so `StandupService` can be tested.**
/// §9.4 runs the suite headless; a test that reached `NSPasteboard.general`
/// would mutate the developer's own clipboard and would be order-dependent on
/// anything else in the process that copies. The service takes an injected
/// `copy` seam whose default is `StandupClipboard.write` — which composes the
/// markdown-to-rich-text conversion with this function (D-083) — so the real
/// pasteboard is reachable only from the app.
public enum SystemClipboard {
    /// Put `text` on the clipboard, offering `rtf` as a richer flavour when
    /// there is one.
    ///
    /// Returns whether the write landed. `NSPasteboard.setString` returns
    /// `false` when another process holds the pasteboard, and `StandupService`
    /// reports that case rather than swallowing it — by the time it happens the
    /// report is already committed, so a silent failure would leave the user
    /// with an advanced clock and an empty clipboard and no idea why.
    ///
    /// **`declareTypes` rather than `clearContents()`.** Both clear the
    /// pasteboard and claim ownership — which is what bumps the change count and
    /// what `setString` needs to have happened, or it writes into a declaration
    /// nobody made and returns `false` — but `declareTypes` also fixes the
    /// *order* of the flavours, and the order is what a reader's preference
    /// resolves against. Richest first, so a target that understands RTF takes
    /// the formatted version while a plain-text field still gets `text`
    /// unchanged.
    ///
    /// Knowing *what* to put in `rtf` is not this type's business — see
    /// `StandupClipboard`, which owns the dialect; this stays a wrapper over
    /// `NSPasteboard` and nothing more.
    ///
    /// Success is reported on the **plain** write alone. A refused `rtf` costs
    /// emphasis, which is not worth telling the user their stand-up failed to
    /// copy when the text itself landed.
    @MainActor
    @discardableResult
    public static func write(_ text: String, rtf: Data?) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes(rtf == nil ? [.string] : [.rtf, .string], owner: nil)
        if let rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
        return pasteboard.setString(text, forType: .string)
    }
}
