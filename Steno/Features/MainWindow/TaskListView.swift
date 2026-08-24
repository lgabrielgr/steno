import StenoKit
import SwiftUI

/// FR-3's second column: tasks grouped by status.
///
/// A plain `List`. FR-3 and D18 are explicit — no pagination, no
/// virtualization, no search, no filter chips. "If the task list ever needs a
/// scrollbar the user has a workflow problem, not a UI problem."
struct TaskListView: View {
    @Bindable var model: MainWindowModel

    /// FR-3: DONE is collapsed by default. Held explicitly rather than left to
    /// `DisclosureGroup`'s default so the requirement holds by construction —
    /// no test can catch this, since views need a window server (D-010).
    @State private var isDoneExpanded = false

    var body: some View {
        Group {
            if model.projects.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "folder.badge.plus",
                    description: Text("Create a project (⌘⇧N) to start capturing tasks.")
                )
            } else if model.groups.isEmpty {
                ContentUnavailableView(
                    "No tasks",
                    systemImage: "checklist",
                    description: Text("Press ⌘N to add one.")
                )
            } else {
                List(selection: $model.selectedTaskID) {
                    ForEach(model.groups) { group in
                        if group.status == .done {
                            DisclosureGroup(
                                group.status.displayName,
                                isExpanded: $isDoneExpanded
                            ) { rows(group) }
                        } else {
                            Section(group.status.displayName) { rows(group) }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        .toolbar {
            Button {
                model.newTask()
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .disabled(!model.canCreateTask)
        }
    }

    @ViewBuilder
    private func rows(_ group: TaskGroup) -> some View {
        ForEach(group.tasks) { task in
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                // Under "All" the project is not implied by the sidebar, so
                // show it — this is also what makes M0-05's stand-in project
                // routing visible rather than silent (see targetProjectID).
                if case .all = model.selection, let project = model.project(withID: task.projectID) {
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(task.id)
        }
    }
}
