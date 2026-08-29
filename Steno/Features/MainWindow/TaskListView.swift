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
                // show it. FR-1.4's ladder can route a capture away from the
                // selected project — a matching ticket key outranks the
                // sidebar selection — so this label is what keeps that
                // routing visible rather than silent.
                if case .all = model.selection, let project = model.project(withID: task.projectID)
                {
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(task.id)
            // A context menu rather than an always-visible per-row picker: the
            // list is already grouped *by* status, so an inline control would
            // restate its own section header on every row. M1-04's popover is
            // where an always-visible toggle earns the space, because that
            // list has no section headers.
            .contextMenu {
                StatusMenuItems(current: task.status) { new in
                    model.setStatus(new, on: task.id)
                }
            }
        }
    }
}
