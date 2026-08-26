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
            }
        }
    }
}
