import StenoKit
import SwiftUI

/// §10.5's first-run introduction to automatic backups (D-126).
///
/// **It does not ask whether to turn auto-export on.** It is already on —
/// §10.5 makes it an opt-*out*, because "manual export's failure mode is human:
/// forgetting to run it" — so the only question here is *where*, and the answer
/// already has a working default. Offering an enable checkbox would invite the
/// user to answer a question the requirement has answered.
struct AutoExportOnboardingSheet: View {
    @Bindable var model: AutoExportWindowModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Steno backs itself up", systemImage: "externaldrive.badge.checkmark")
                .font(.headline)

            Text(
                "Steno writes a copy of everything to a folder on this Mac — when you quit, and "
                    + "once a day. Nothing leaves your machine unless you point this at a folder "
                    + "that syncs."
            )
            .fixedSize(horizontal: false, vertical: true)

            Text(
                "Choosing a Dropbox, Google Drive or iCloud Drive folder keeps a copy off this "
                    + "Mac, which is the closest thing Steno has to a backup service."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Folder") {
                HStack {
                    Text(model.folder.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…") { model.chooseFolder() }
                }
            }

            if let problem = model.folderProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // The only button: there is nothing here to cancel, and a
                // "Not now" would imply an opt-in this deliberately is not.
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
