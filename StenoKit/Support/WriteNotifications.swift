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

    /// Posted after an auto-export changes `AppSettings.autoExportStatus` —
    /// by `AutoExportService` and nowhere else.
    ///
    /// **Separate from `.stenoDidWrite`, which is about the store.** Nothing
    /// auto-export does writes a row, and a reader of this notification wants
    /// to refresh a status line, not refetch a task list. Folding the two
    /// together would make every capture reload the backup status and every
    /// backup reload three surfaces' fetches, and would make "why did the
    /// window reload?" unanswerable.
    public static let stenoAutoExportDidChange = Notification.Name(
        "com.lgabrielgr.steno.autoExportDidChange")

    /// Posted after an integration credential is stored or deleted — by every store that
    /// writes one.
    ///
    /// **Because a memo needs a way to be told it is wrong.** D-198 memoizes the Atlassian
    /// credential for thirty seconds so routing does not read the Keychain once per ref, and
    /// its doc comment said M4-04 "should call `invalidate()`" — a method reachable only from
    /// a private property, so nothing could have called it. A credential saved in the running
    /// app would have left routing on a memoized `nil` for half a minute. Raised by Copilot in
    /// review round 4 of PR #43.
    ///
    /// **A notification rather than a protocol member**, for `.stenoDidWrite`'s reason: the
    /// alternative is an invalidation path threaded through `SourceRegistry` and every
    /// connector, and the first one forgotten is a staleness bug that looks like the Keychain
    /// being flaky. This way M4-03's Confluence connector and M4-04's pane both get it by
    /// posting, and a writer that forgets is the only failure mode — the same one
    /// `.stenoDidWrite` has carried since M1-08.
    ///
    /// Separate from `.stenoDidWrite`, which is about the store: nothing here writes a row, and
    /// a reader of this wants to forget a cached secret, not refetch a task list.
    public static let stenoCredentialsDidChange = Notification.Name(
        "com.lgabrielgr.steno.credentialsDidChange")

    /// Posted after an unattended refresh records or clears a credential rejection
    /// (D-227) — by `ScheduledRefreshController` and nowhere else.
    ///
    /// **Because the Settings window can be open while the pass runs.** D-227's first
    /// version read the stored rejection in `onAppear`, and this file's own history says
    /// why that is not enough: a surface that only reads on appearance shows nothing while
    /// it is already on screen. The doc comment there claimed "the pane cannot be open at
    /// the instant a background pass runs and then fail to redraw", which is simply false —
    /// a user can leave Settings open across 08:00. Raised by Copilot in review round 3 of
    /// PR #46, and the same class of defect as the M1-08 gap recorded above.
    ///
    /// **Separate from `.stenoCredentialsDidChange`, which the credential *stores* post.**
    /// Nothing here writes a credential, and this notification's reader wants to redraw a
    /// warning row, not drop a memoized secret — folding them together would make every
    /// refused pass invalidate the credential memo and make that file's doc comment false.
    public static let stenoScheduledRefreshDidChange = Notification.Name(
        "com.lgabrielgr.steno.scheduledRefreshDidChange")
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

    /// The center the token came from, so it is removed from the one it was added to.
    ///
    /// **Defaulted, because every caller but one uses `.default`.** The exception is
    /// `ScheduledRefreshController`, which observes sleep and wake — those are posted on
    /// `NSWorkspace.shared.notificationCenter`, not on the default center, and removing a
    /// token from the wrong center is a silent leak rather than an error.
    private let center: NotificationCenter

    init(_ token: any NSObjectProtocol, center: NotificationCenter = .default) {
        self.token = token
        self.center = center
    }

    deinit {
        center.removeObserver(token)
    }
}
