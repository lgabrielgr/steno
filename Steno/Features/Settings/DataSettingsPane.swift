import StenoKit
import SwiftUI

/// FR-6's Data area: §10.5's automatic backups.
///
/// Kept as small as `CaptureSettingsPane`, and for the same reason — this is a
/// recall tool, and time spent in configuration is time not spent capturing.
/// The pane's job is to say where backups go and whether the last one worked.
struct DataSettingsPane: View {
    @Bindable var model: DataSettingsModel

    var body: some View {
        Form {
            if let note = model.storeFailureNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Automatic backup") {
                Toggle("Back up automatically", isOn: $model.isEnabled)
                Toggle("When Steno quits", isOn: $model.exportsOnQuit)
                    .disabled(!model.isEnabled)
                Toggle("Once a day", isOn: $model.exportsDaily)
                    .disabled(!model.isEnabled)
            }

            Section("Folder") {
                // The same field the first-run sheet shows, for the reason
                // `BackupFolderField` gives: these two surfaces have drifted
                // apart once already.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backups go to")
                    BackupFolderField(folder: model.folder) { model.chooseFolder() }
                }
                Text(
                    "A Dropbox, Google Drive or iCloud Drive folder keeps a copy off this Mac. "
                        + "Steno keeps the 14 most recent backups and moves older ones to the Trash."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if let problem = model.folderProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Last backup") {
                // The failure first, and unconditionally: with sync cancelled
                // there is no other copy, so "it failed" outranks "it worked
                // last Tuesday".
                if let failure = model.status.lastFailure {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                }
                if let success = model.status.lastSuccess {
                    LabeledContent(
                        model.status.lastFailure == nil ? "Written" : "Last good backup"
                    ) {
                        Text(success.writtenAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Text(success.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else if model.status.lastFailure == nil {
                    Text("No backup yet.").font(.callout).foregroundStyle(.secondary)
                }

                Button("Back Up Now") { model.exportNow() }
                    .disabled(!model.canBackUpNow)
            }
        }
        .formStyle(.grouped)
    }
}
