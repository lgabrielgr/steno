import StenoKit
import SwiftUI

/// Carries the live main-window model out to the menu bar.
///
/// This is the plumbing that makes menu commands act on the front window's
/// selection. M1-05 and M1-06 do not touch this file — they add a method to
/// `MainWindowActions` and a `Button` to `MainWindowCommands`.
struct MainWindowActionsKey: FocusedValueKey {
    typealias Value = any MainWindowActions
}

extension FocusedValues {
    var mainWindowActions: (any MainWindowActions)? {
        get { self[MainWindowActionsKey.self] }
        set { self[MainWindowActionsKey.self] = newValue }
    }
}
