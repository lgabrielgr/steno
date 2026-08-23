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
    func newTask()
    func newProject()
    func selectNextProject()
    func selectPreviousProject()
}
