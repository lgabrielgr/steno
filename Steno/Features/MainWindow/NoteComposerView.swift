import StenoKit
import SwiftUI

/// FR-2's note entry: a multi-line field above the timeline, never a modal.
///
/// Not a `TextEntrySheet`. That one is a single-line `TextField`, and §3.3's
/// own example of a note — "Repro'd the race condition, it's in the retry
/// handler" — is prose. A modal would also cover the timeline the user is
/// reading while writing about it.
///
/// Everything stateful is in `NoteComposerModel` over in `StenoKit`, where the
/// headless bundle can reach it (D-010); this file is layout.
struct NoteComposerView: View {
    @Bindable var composer: NoteComposerModel
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    private var isCorrecting: Bool {
        if case .correcting = composer.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCorrecting {
                Text("Correcting a note — it keeps its original time in the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // `TextEditor` has no placeholder of its own, hence the overlay.
            TextEditor(text: $composer.text)
                .font(.body)
                .frame(minHeight: 58, maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    if composer.text.isEmpty {
                        Text("Add a note…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator)
                }
                .focused($isFocused)

            if let notice = composer.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = composer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Text("⌘↩ to add")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isCorrecting || !composer.text.isEmpty {
                    Button("Cancel") { composer.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(isCorrecting ? "Save Correction" : "Add Note", action: onCommit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!composer.canCommit)
            }
        }
        // A counter rather than a `Bool`: a second focus request while the
        // field is already focused must still re-focus, and `isFocused = true`
        // when it is already `true` changes nothing observable.
        .onChange(of: composer.focusRequests) { isFocused = true }
    }
}
