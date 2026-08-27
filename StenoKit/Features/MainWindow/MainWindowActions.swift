import Foundation

/// Which modal the main window is showing, if any.
///
/// One optional value rather than a `Bool` per sheet: two independent flags can
/// both be true at once — press ⌘⇧N while the New Task sheet is up — and that
/// state has no defined rendering. This makes it unrepresentable.
public enum ActiveSheet: Identifiable, Hashable, Sendable {
    case newProject
    case newTask

    /// Edit the named project — FR-3's project editing (REQUIREMENTS v1.11).
    case editProject(UUID)

    public var id: Self { self }
}

/// The main-window actions the menu bar can invoke.
///
/// `MainWindowCommands` in the app target depends on this rather than on
/// `MainWindowModel`, so adding a shortcut in M1-05 or M1-06 is one method
/// here plus one `Button` there — and forgetting the implementation is a
/// compile error rather than a menu item that silently does nothing.
///
/// `AnyObject` because `@FocusedValue` carries a reference to the live model.
@MainActor
public protocol MainWindowActions: AnyObject {
    /// FR-1.4: a task needs a project to belong to, and this window offers no
    /// way to create one implicitly. The menu and the toolbar both gate New
    /// Task on this so they cannot disagree about when it is live.
    var canCreateTask: Bool { get }

    func newTask()
    func newProject()
    func selectNextProject()
    func selectPreviousProject()
}
