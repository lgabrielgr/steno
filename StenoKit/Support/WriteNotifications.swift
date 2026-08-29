import Foundation

extension Notification.Name {
    /// Posted after a domain write is on disk.
    ///
    /// **Posted at the write, not by each surface** (D-031). View models fetch
    /// manually and do not refresh, so without this the floating panel and
    /// M1-04's popover would insert tasks — and change statuses — that an open
    /// main window never notices. One post site per writing service covers all
    /// three of D15's surfaces.
    ///
    /// Named for writes rather than captures because `StatusService` posts it
    /// too (D-035), and M1-06's notes will. The alternative — one notification
    /// per write kind — grows a registration per observer per feature, and the
    /// first one forgotten is a staleness bug that looks like SwiftData being
    /// flaky.
    public static let stenoDidWrite = Notification.Name("com.lgabrielgr.steno.didWrite")
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
final class WriteObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
