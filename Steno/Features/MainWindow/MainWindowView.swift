import StenoKit
import SwiftData
import SwiftUI

/// FR-3's three-column main window.
struct MainWindowView: View {
    @State private var model: MainWindowModel

    /// The model is built once here, from the container, rather than in `body`
    /// — which would rebuild it on every render and drop the selection.
    init(container: ModelContainer) {
        _model = State(initialValue: MainWindowModel(context: container.mainContext))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            TaskListView(model: model)
        } detail: {
            TaskDetailView(model: model, taskID: model.selectedTaskID)
        }
        .frame(minWidth: 900, minHeight: 520)
        .focusedSceneValue(\.mainWindowActions, model)
        .safeAreaInset(edge: .top) {
            // An inline row, not an alert: a modal interruption during capture
            // is the behaviour §1.1 treats as a defect.
            if let message = model.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message)
                    Spacer()
                    Button("Dismiss") { model.dismissError() }
                }
                .padding(8)
                .background(.yellow.opacity(0.25))
            }
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .newProject:
                TextEntrySheet(
                    title: "New Project",
                    placeholder: "Project name",
                    confirm: "Create"
                ) { model.createProject(named: $0) }
            case .newTask:
                NewTaskSheet(model: model)
            case .editProject(let id):
                if let project = model.project(withID: id) {
                    ProjectEditSheet(
                        projectName: project.name,
                        jiraKeys: project.jiraProjectKeys
                    ) { name, keys in
                        model.updateProject(id: id, name: name, jiraKeys: keys)
                    }
                } else {
                    // Unreachable today — archiving lives in the sidebar's
                    // context menu, which is behind this modal. It is one
                    // M1-05 keyboard shortcut away from being reachable, and
                    // without this branch the sheet would render empty with
                    // no way out. A sheet you cannot close is worse than any
                    // stale-data problem it might be hiding.
                    VStack(spacing: 16) {
                        Text("That project is no longer available.")
                        Button("Close") { model.activeSheet = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(24)
                }
            }
        }
    }
}
