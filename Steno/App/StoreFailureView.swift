import AppKit
import SwiftUI

/// Shown when the store cannot be opened.
///
/// Deliberately not a `fatalError`, which reads as a crash to anyone not
/// watching stderr — and this is the one situation where the reason matters
/// most. Deliberately not an in-memory fallback either: for a capture tool,
/// accepting writes that evaporate at quit is worse than not launching (§1.1),
/// because the loss would surface at the next stand-up. See DECISIONS.md D-018.
struct StoreFailureView: View {
    let path: String
    let error: Error

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steno could not open its data store.")
                .font(.headline)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text(String(describing: error))
                .font(.callout)
                .textSelection(.enabled)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320, alignment: .topLeading)
    }
}
