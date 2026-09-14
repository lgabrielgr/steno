import StenoKit
import SwiftData
import SwiftUI

/// FR-3's three-column main window.
struct MainWindowView: View {
    @State private var model: MainWindowModel

    /// The model is built once here, from the container, rather than in `body`
    /// — which would rebuild it on every render and drop the selection.
    /// **The one place `AppKitFilePanels` is constructed.** Every other
    /// injection point defaults to `UnavailableFilePanels`, so the headless
    /// test bundle cannot open a modal panel and hang the suite (D-010).
    init(container: ModelContainer) {
        _model = State(
            initialValue: MainWindowModel(
                context: container.mainContext, panels: AppKitFilePanels()))
    }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } content: {
            TaskListView(model: model)
        } detail: {
            TaskDetailView(model: model, taskID: model.selectedTaskID)
        }
        .frame(minWidth: 900, minHeight: 520)
        // Both halves of what `MainWindowReveal` needs: a way to find this
        // window while it exists, and a way to reopen it once the user has
        // closed it. The popover is hosted outside the scene tree, so it has
        // no environment of its own to read `openWindow` from.
        .background(WindowTagger(identifier: MainWindowReveal.identifier))
        .onAppear {
            MainWindowReveal.reopen = { openWindow(id: MainWindowReveal.sceneID) }
        }
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

            // §10.5's export has an outcome worth stating — where the file
            // went — and it is not a failure. Its own row rather than reusing
            // the error banner above, for `MainWindowModel.lastNotice`'s
            // reason: rendering a success in the error colours would misreport
            // an operation that just wrote a file. Selectable, so the path can
            // be copied.
            if let notice = model.lastNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(notice)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.dismissNotice() }
                }
                .padding(8)
                .background(.green.opacity(0.18))
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
            case .blockedReason(let id):
                // §3.3's reason is optional, and the transition to BLOCKED has
                // already committed by the time this appears — Esc declines to
                // annotate, it does not undo. `TextEntrySheet` disables its
                // confirm on empty input, so "no reason" costs one keystroke.
                TextEntrySheet(
                    title: "Why is this blocked?",
                    placeholder: "Optional — waiting on what?",
                    confirm: "Add Reason"
                ) { model.addBlockedReason($0, to: id) }
            case .importPreview:
                ImportPreviewSheet(
                    preview: model.importPreview,
                    onApply: { model.applyImport() },
                    onClose: { model.dismissImportPreview() })
            case .standupDraft:
                StandupDraftSheet(
                    draft: model.standupDraft,
                    onCopy: { model.copyStandup() },
                    onUndo: { model.undoStandupDraft() },
                    onClose: { model.dismissStandupDraft() })
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
