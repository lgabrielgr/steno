import AppKit

/// D6's clipboard, and the only place in StenoKit that touches `NSPasteboard`.
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
        write(text, rtf: nil)
    }

    /// As `write(_:)`, but also offering `rtf` as a richer flavour.
    ///
    /// **Both flavours, declared richest first.** `declareTypes` fixes the
    /// pasteboard's preference order, so a target that understands RTF takes the
    /// formatted version while a plain-text field still gets `text` unchanged.
    /// Knowing *what* to put in `rtf` is not this type's business — see
    /// `StandupClipboard`, which owns the dialect; this stays a wrapper over
    /// `NSPasteboard` and nothing more.
    ///
    /// Success is reported on the **plain** write alone. A refused `rtf` costs
    /// emphasis, which is not worth telling the user their stand-up failed to
    /// copy when the text itself landed.
    @discardableResult
    public static func write(_ text: String, rtf: Data?) -> Bool {
        let pasteboard = NSPasteboard.general
        // `declareTypes` clears the pasteboard and claims ownership in one call,
        // which is what makes the order below the order a reader sees.
        pasteboard.declareTypes(rtf == nil ? [.string] : [.rtf, .string], owner: nil)
        if let rtf {
            pasteboard.setData(rtf, forType: .rtf)
        }
        return pasteboard.setString(text, forType: .string)
    }
}
