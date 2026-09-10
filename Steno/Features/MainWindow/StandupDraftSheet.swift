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
                Text(headline)
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

    /// The sheet's headline for each reachable state.
    ///
    /// **Three cases, not two.** A refused clipboard still moves `phase` to
    /// `.copied` — the report is committed and the clock has advanced, which is
    /// not reversible here — so keying the headline on `phase` alone would
    /// announce "Copied to clipboard" directly above the notice saying the
    /// clipboard refused it. The report being *recorded* and the text reaching
    /// the *clipboard* are two different facts, and this is the one state where
    /// they disagree.
    ///
    /// `notice` is non-nil exactly when the commit succeeded and the clipboard
    /// refused, so it is the discriminator rather than a second stored flag.
    /// The sheet's headline for each reachable state.
    ///
    /// **Four cases, not two.** A refused clipboard still moves `phase` to
    /// `.copied` — the report is committed and the clock has advanced — so
    /// keying the headline on `phase` alone would announce "Copied to
    /// clipboard" directly above the notice saying the clipboard refused it.
    /// The report being *recorded* and the text reaching the *clipboard* are
    /// two different facts, and `.copied` is the one state where they disagree.
    /// `notice` is non-nil exactly then, so it is the discriminator rather than
    /// a second stored flag.
    ///
    /// `.undone` is its own line rather than a return to "Prepare Stand-up".
    /// The store has changed twice and is back where it started, and a headline
    /// that reverted would leave the user unable to tell a successful undo from
    /// a button that did nothing.
    private var headline: String {
        switch draft.phase {
        case .editing:
            "Prepare Stand-up"
        case .copied:
            draft.notice == nil ? "Copied to clipboard" : "Recorded — not copied"
        case .undone:
            "Stand-up undone"
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            // ⌘↩ rather than a plain-Return default button, and the hint is
            // part of the fix. The first responder here is a multi-line
            // `TextEditor`, which consumes Return as `insertNewline(_:)`, so a
            // `.defaultAction` binding never fires — leaving Esc (which
            // *discards* the draft) as the only working key. FR-3 asks for a
            // keyboard path to the primary action, not to the destructive one.
            // `NoteComposerView` pairs a `TextEditor` with ⌘↩ and its own hint
            // for exactly this reason.
            if draft.phase == .editing {
                Text("⌘↩ to copy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch draft.phase {
            case .editing:
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Copy", action: onCopy)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!draft.canCopy)
            case .copied:
                // One button, not two: the earlier pair existed only to carry
                // two key equivalents, and two buttons that do the same thing
                // read as a choice the user does not have. Esc closes, which is
                // the only action left once the store is committed. M2-04 adds
                // Undo beside this.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            case .undone:
                // One button. Undo is not itself undoable — `Event.redact()` is
                // one-way by design and names this requirement as the reason
                // there is no `unredact()` — and Copy stays dead because the
                // draft's window has already been reported once.
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
