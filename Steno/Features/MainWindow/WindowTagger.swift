import AppKit
import SwiftUI

/// Stamps a stable identifier on the `NSWindow` hosting this view.
///
/// `MainWindowReveal` needs to find the main window among `NSApp.windows`, and
/// SwiftUI does not expose the window it made. A zero-sized representable in
/// the background is the supported way to reach it.
///
/// The write is in `updateNSView`, not `makeNSView`: at `makeNSView` the view
/// has not been added to a window yet and `view.window` is nil.
struct WindowTagger: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = identifier
    }
}
