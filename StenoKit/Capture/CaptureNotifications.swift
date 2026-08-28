import Foundation

extension Notification.Name {
    /// Posted by `CaptureService` after a capture is on disk.
    ///
    /// **Posted at the write, not by each surface.** D-019 recorded that view
    /// models fetch manually and do not refresh, and named this task: the
    /// floating panel and M1-04's popover would otherwise insert tasks an open
    /// main window never notices. One post site covers all three of D15's
    /// surfaces and M1-05's and M1-06's future writes.
    ///
    /// The alternative D-019 itself suggested — reloading on
    /// `NSApplication.didBecomeActiveNotification` — is less code and leaves
    /// two holes: a main window visible on a second display and never
    /// re-activated stays stale, and the popover will not activate the
    /// application either.
    public static let stenoDidCapture = Notification.Name("com.lgabrielgr.steno.didCapture")
}

/// Holds a `NotificationCenter` token and removes it when its owner is
/// deallocated.
///
/// **Why this is a separate object rather than a stored token plus a
/// `deinit`.** In Swift 6 the `deinit` of a `@MainActor` class is nonisolated
/// and may not reference isolated stored properties, so the obvious
/// `deinit { NotificationCenter.default.removeObserver(token) }` inside
/// `MainWindowModel` does not compile. Holding the token in a non-isolated
/// object means ARC releases it along with the model and *this* `deinit`,
/// which touches nothing isolated, does the removal.
final class CaptureObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
