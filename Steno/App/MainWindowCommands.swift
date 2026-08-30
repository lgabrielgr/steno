import StenoKit
import SwiftUI

/// FR-3's keyboard-first requirement, as real menu-bar items.
///
/// Menu items rather than `.keyboardShortcut` on in-view buttons: on macOS a
/// shortcut that exists is expected to be listed in a menu, shortcuts bound
/// only to buttons are enumerated nowhere, and each later surface would
/// otherwise re-declare its own — the divergence the task file warns about.
///
/// **Extending this is the whole point.** M1-05 added "Cycle Status" and
/// "Mark Blocked"; M1-06 adds "Add Note": one method on `MainWindowActions`,
/// one `Button` here.
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

        // FR-3's "cycle status" and the deliberate way into BLOCKED (D-034).
        // Its own menu rather than an addition to File: M1-06's "Add Note"
        // belongs beside these, and neither is a File operation.
        //
        // ⌘⇧S and ⌘⇧B rather than the otherwise natural arrow chords: a menu
        // item bound to ⌘⇧→ would shadow "extend selection to end of line"
        // inside the capture field, and §1.1 makes that field the one thing
        // that must not degrade. Steno has no Save item, so ⌘⇧S is free here.
        CommandMenu("Task") {
            Button("Cycle Status") { actions?.cycleStatusOnSelection() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.canChangeStatus != true)

            Button("Mark Blocked") { actions?.markSelectionBlocked() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.canChangeStatus != true)
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
