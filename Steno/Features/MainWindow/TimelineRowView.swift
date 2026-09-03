import StenoKit
import SwiftUI

/// One event in FR-3's timeline, with FR-2's affordances when they apply.
///
/// **"Correct" is present only while the event is inside FR-2's window and
/// disappears at five minutes.** That is the acceptance criterion "after 5
/// minutes, editing is unavailable" made visible rather than merely true; the
/// service refuses a late correction regardless, but a button that lingers
/// past its own deadline is a lie the user has to discover by clicking.
///
/// "Redact…" is a context menu behind a confirmation. `Event` has no
/// `unredact()` by design, so a one-way action reachable in a single misclick
/// would be a defect.
struct TimelineRowView: View {
    let event: Event
    let isCorrectable: Bool
    let onCorrect: () -> Void
    let onRedact: () -> Void

    @State private var isConfirmingRedaction = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.body)
            HStack(spacing: 10) {
                Text(event.timestamp, format: .dateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isCorrectable {
                    Button("Correct", action: onCorrect)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            if event.kind.isUserAuthored {
                Button("Redact…", role: .destructive) { isConfirmingRedaction = true }
            }
        }
        .confirmationDialog(
            "Redact this note?", isPresented: $isConfirmingRedaction, titleVisibility: .visible
        ) {
            Button("Redact", role: .destructive, action: onRedact)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "It is hidden from the timeline and from stand-up summaries, and the row is kept. This cannot be undone."
            )
        }
    }
}
