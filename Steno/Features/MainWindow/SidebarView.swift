import StenoKit
import SwiftUI

/// FR-3's first column: a flat project list with an "All" pseudo-project.
///
/// Flat by decision, not omission — D9 rules out epics and nesting, so there
/// is no hierarchy to model here.
struct SidebarView: View {
    let model: MainWindowModel

    var body: some View {
        List(selection: selectionBinding) {
            Label("All", systemImage: "tray.full")
                .tag(ProjectSelection.all)

            Section("Projects") {
                ForEach(model.projects) { project in
                    Label {
                        Text(project.name)
                    } icon: {
                        Circle()
                            .fill(Color(projectHex: project.colorHex))
                            .frame(width: 10, height: 10)
                    }
                    .tag(ProjectSelection.project(project.id))
                    .contextMenu {
                        // Archive, not delete: §3.1 hides projects, never
                        // removes them, and there is deliberately no delete.
                        Button("Archive Project") { model.archive(projectID: project.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.newProject()
            } label: {
                Label("New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
    }

    /// `List` wants an optional selection; the model's is total, with `.all`
    /// as the resting state.
    private var selectionBinding: Binding<ProjectSelection?> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 ?? .all }
        )
    }
}
