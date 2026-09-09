import StenoKit
import SwiftUI

/// FR-4 steps 6–7: the editable draft, and Copy.
///
/// Everything stateful is in `StandupDraftModel` over in `StenoKit`, where the
/// headless bundle can reach it (D-010); this file is layout.
///
/// **It does not dismiss on Copy.** M2-04's undo has to be "easy to find right
/// after a Copy and not require hunting through settings" (FR-4.1), and this
/// confirmed state is that place. Dismissing here would leave M2-04 to invent a
/// home for Undo after the affordance it belongs beside had already gone.
struct StandupDraftSheet: View {
    @Bindable var draft: StandupDraftModel
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Editable, per FR-4 step 6: the user's own last-second correction
            // is the final word, and §7.3's philosophy is that their phrasing
            // wins. The binding is what makes `markdownBody` the edited text
            // rather than the generated text.
            TextEditor(text: $draft.text)
                .font(.body.monospaced())
                .frame(minWidth: 520, minHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                }

            if let notice = draft.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = draft.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            buttons
        }
        .padding(20)
        .frame(maxWidth: 720)
    }

    /// What is about to be reported on, so Copy is never a blind commit.
    @ViewBuilder
    private var header: some View {
        if let window = draft.window {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.phase == .copied ? "Copied to clipboard" : "Prepare Stand-up")
                    .font(.headline)
                // Built as a `String` first: interpolating into `Text` yields a
                // `LocalizedStringKey`, which has no `+`.
                Text(summary(of: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The window's bounds and how many tasks fall inside it.
    private func summary(of window: GatheredWindow) -> String {
        let span = window.start.formatted(.dateTime) + " – " + window.end.formatted(.dateTime)
        let count = window.tasks.count
        return span + " · \(count) task" + (count == 1 ? "" : "s")
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch draft.phase {
            case .editing:
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Copy", action: onCopy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canCopy)
            case .copied:
                // Esc and Return both close: once the store is committed there
                // is no second action to protect, and M2-04 adds Undo here.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
