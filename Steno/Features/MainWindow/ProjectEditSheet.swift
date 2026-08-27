import StenoKit
import SwiftUI

/// FR-3's project editing: a name, and the Jira key prefixes FR-1.4 routes on.
///
/// Two fields and nothing else. FR-6 owns Settings; project colour has no
/// picker by decision (see `ProjectPalette`); and §3.1 has no delete, only
/// archive, which the sidebar's context menu already offers.
struct ProjectEditSheet: View {
    let onCommit: (String, String) -> Void

    @State private var name: String
    @State private var keys: String
    @Environment(\.dismiss) private var dismiss

    /// `projectName` and `jiraKeys` seed the `@State` and are not stored:
    /// after the sheet appears the edited copies are the truth, and keeping
    /// the originals around would offer a stale value to read by mistake.
    init(
        projectName: String,
        jiraKeys: [String],
        onCommit: @escaping (String, String) -> Void
    ) {
        self.onCommit = onCommit
        _name = State(initialValue: projectName)
        _keys = State(initialValue: jiraKeys.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Jira keys, comma separated", text: $keys)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Text("A task mentioning PAY-421 files itself here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed, keys)
        dismiss()
    }
}
