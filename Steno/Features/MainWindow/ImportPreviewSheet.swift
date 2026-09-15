import StenoKit
import SwiftUI

/// §10.4's preview, and §10.1's typed confirmation.
///
/// Everything stateful is in `ImportPreviewModel` over in `StenoKit`, where the
/// headless bundle can reach it (D-010); this file is layout. The summary lines
/// come from `ImportPreviewSummary`, so what a test asserts is the text the
/// user actually reads rather than a parallel description of it.
///
/// **Replace is styled as the exception it is.** §10.1 puts Replace there "for
/// restoring a known-good snapshot, not for routine transfer", so the
/// destructive variant gets the warning colour, the deletion line first, the
/// backup path in plain sight, and a confirm button that stays dead until the
/// word is typed.
struct ImportPreviewSheet: View {
    @Bindable var preview: ImportPreviewModel
    let onApply: () -> Void
    let onClose: () -> Void

    private var isReplace: Bool { preview.mode == .replace }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch preview.phase {
            case .nothingToImport:
                // §10.6's idempotency, as the user meets it. An empty preview
                // with three zeroed lines would look like a failure; this says
                // what actually happened.
                Label(
                    "Everything in this file is already on this Mac. Nothing to import.",
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
            case .previewing, .applied:
                summary
            }

            if isReplace, preview.phase == .previewing {
                backupNotice
                confirmationField
            }

            if let notice = preview.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let error = preview.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            buttons
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: 620, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.headline)
                .font(.headline)
                .foregroundStyle(isReplace ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            // The line that catches importing the wrong file, which no count
            // can — built as a `String` first, because interpolating into
            // `Text` yields a `LocalizedStringKey`.
            if let provenance = preview.provenance {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// §10.4's `−`/`+`/`~`/`=` lines, monospaced so the leading signs align.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(preview.summaryLines, id: \.self) { line in
                Text(line)
                    .font(.callout.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The way back, shown before the user commits rather than only after.
    @ViewBuilder
    private var backupNotice: some View {
        if let url = preview.backupURL {
            VStack(alignment: .leading, spacing: 2) {
                Text("A backup will be written first to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var confirmationField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type \(ImportPreviewModel.replaceConfirmationWord) to confirm:")
                .font(.caption)
            // **No `.onSubmit`, deliberately.** Return in this field must not
            // commit: the acceptance criterion asks for typed confirmation
            // rather than "not a single click", and a field that fires on
            // Return turns the guard back into one keystroke past the last
            // letter.
            //
            // The empty title is deliberate — the instruction above is the
            // visible label — but an empty title leaves VoiceOver with no name
            // for the control, on the one field standing between the user and
            // an irreversible wipe. The explicit accessibility label is what
            // gives it one. Raised in review of PR #30.
            TextField("", text: $preview.confirmation)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .autocorrectionDisabled()
                .accessibilityLabel(
                    "Type \(ImportPreviewModel.replaceConfirmationWord) to confirm replacing all data"
                )
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            // Cancel is the default action on the destructive sheet, and
            // `.keyboardShortcut(.cancelAction)` binds Esc to it in both.
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)

            if preview.phase != .applied {
                Button(isReplace ? "Replace Everything" : "Import", action: onApply)
                    .disabled(!preview.canApply)
                    // **Not `.defaultAction` in replace mode.** The criterion
                    // forbids a default-focused destructive button, and
                    // `.defaultAction` is exactly that — Return would fire it
                    // from anywhere in the sheet.
                    .keyboardShortcut(isReplace ? .noDefault : .defaultAction)
            }
        }
    }
}

extension KeyboardShortcut {
    /// A shortcut that no key press produces, so a `.keyboardShortcut` call can
    /// be made conditional without one branch silently binding Return.
    ///
    /// SwiftUI has no "no shortcut" value and `keyboardShortcut` takes a
    /// non-optional in the modifier form used here, so the alternative was
    /// duplicating the whole `Button` under an `if`. `.escape` with an
    /// impossible modifier combination is inert: nothing produces it, and the
    /// sheet's Cancel button owns plain Esc through `.cancelAction`.
    static let noDefault = KeyboardShortcut(
        .escape, modifiers: [.command, .option, .control, .shift])
}
