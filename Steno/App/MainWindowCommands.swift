import StenoKit
import SwiftUI

/// FR-3's keyboard-first requirement, as real menu-bar items.
///
/// Menu items rather than `.keyboardShortcut` on in-view buttons: on macOS a
/// shortcut that exists is expected to be listed in a menu, shortcuts bound
/// only to buttons are enumerated nowhere, and each later surface would
/// otherwise re-declare its own — the divergence the task file warns about.
///
/// **Extending this is the whole point.** M1-05 adds "Cycle Status" and M1-06
/// adds "Add Note": one method on `MainWindowActions`, one `Button` here.
struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindowActions) private var actions: (any MainWindowActions)?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { actions?.newTask() }
                .keyboardShortcut("n")
                .disabled(actions?.canCreateTask != true)

            Button("New Project") { actions?.newProject() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        // FR-3 lists "switch project" among the actions needing a shortcut,
        // and this milestone builds the switcher.
        CommandGroup(after: .sidebar) {
            Button("Next Project") { actions?.selectNextProject() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions == nil)

            Button("Previous Project") { actions?.selectPreviousProject() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions == nil)
        }
    }
}
