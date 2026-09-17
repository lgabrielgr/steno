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
        // **A `VStack`, not `.safeAreaInset(edge: .top)`.** The inset is
        // applied to the window's *top safe area*, which on a
        // `NavigationSplitView` is the region the title bar and each column's
        // own header already occupy — so the banner drew over "Projects" and
        // "IN-PROGRESS" rather than above them, and the translucent tint let
        // both show through underneath it. A stacked row reserves its own
        // height, which is what "an inline row" was always meant to be.
        VStack(spacing: 0) {
            // An inline row, not an alert: a modal interruption during capture
            // is the behaviour §1.1 treats as a defect.
            if let message = model.lastError {
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .yellow.opacity(0.25),
                    text: message,
                    dismiss: model.dismissError)
            }

            // §10.5's export has an outcome worth stating — where the file
            // went — and it is not a failure. Its own row rather than reusing
            // the error banner above, for `MainWindowModel.lastNotice`'s
            // reason: rendering a success in the error colours would misreport
            // an operation that just wrote a file.
            if let notice = model.lastNotice {
                banner(
                    icon: "checkmark.circle.fill",
                    tint: .green.opacity(0.18),
                    text: notice,
                    dismiss: model.dismissNotice)
            }

            NavigationSplitView {
                SidebarView(model: model)
            } content: {
                TaskListView(model: model)
            } detail: {
                TaskDetailView(model: model, taskID: model.selectedTaskID)
            }
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

    /// One inline row — icon, message, Dismiss — and the rule under it.
    ///
    /// **The tint is layered over an opaque window background, not over the
    /// content.** Both banners are deliberately translucent so the two kinds of
    /// news read differently at a glance, but a translucent row drawn straight
    /// onto the split view let the column headers show through it. Painting the
    /// window background first keeps the tint and loses the bleed.
    ///
    /// Text is selectable in both: the notice carries a path worth copying, and
    /// an error message is worth pasting into a bug report.
    @ViewBuilder
    private func banner(
        icon: String, tint: Color, text: String, dismiss: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        // **`ignoresSafeAreaEdges: []` is the whole point of these two lines.**
        // A background view extends into adjacent safe areas by default — the
        // parameter defaults to `.all` — and this row sits at the top of a
        // window whose content view runs under the title bar. So the tint
        // filled the title bar too, colouring the traffic lights and the window
        // title along with the row. Two calls rather than one layered view
        // because only the `ShapeStyle` overload takes the parameter; the
        // window background goes on last so it lands *behind* the tint.
        .background(tint, ignoresSafeAreaEdges: [])
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        // The window has no title-bar separator of its own while a banner is
        // showing, so without this the row and the columns below it run
        // together into one block of colour.
        Divider()
    }
}
