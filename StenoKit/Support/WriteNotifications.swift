import Foundation

extension Notification.Name {
    /// Posted after a write is on disk — by each writing service, and by
    /// `MainWindowModel.perform` for project writes, which have no service.
    ///
    /// **That last clause was the exception until M1-08, and the exception was
    /// a bug.** This comment used to say project writes did not post, on the
    /// grounds that the main window was the only surface showing projects, and
    /// warned that "a future cache of projects elsewhere must not assume this
    /// notification covers them". FR-6's default-project picker became exactly
    /// that cache and made exactly that assumption, so archiving a project left
    /// it selected in Settings. Closing the gap is the fix; a second
    /// notification for project writes would only have moved the same
    /// forgettable registration one level down.
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
