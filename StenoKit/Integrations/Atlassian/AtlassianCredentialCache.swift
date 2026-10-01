import Foundation

/// A short-lived memo over one Keychain read.
///
/// **Thirty seconds, chosen against two failure modes.** Shorter than a refresh pass's own
/// budget would put several Keychain reads back into one pass, which is what this exists to
/// prevent; much longer would make a credential the user has just saved look absent.
///
/// **And it is told when it is wrong**, by observing `.stenoCredentialsDidChange`, which every
/// store that writes a credential posts. The first version of this comment said M4-04 "should
/// call `invalidate()`" — a method reachable only from a private property on a struct, so
/// nothing could have called it, and a credential saved while the app ran would have left
/// routing on a memoized `nil` for half a minute. `testConnection()` bypasses the memo besides,
/// so the button that matters is never answered from it. Raised by Copilot in review round 4 of
/// PR #43.
///
/// A `final class` with a lock because `JiraConnector` is a `Sendable` struct and four
/// fetches run concurrently: an unsynchronized memo would be a data race in the one place
/// that reads a secret.
final class AtlassianCredentialCache: @unchecked Sendable {
    static let ttl: TimeInterval = 30

    private let lock = NSLock()
    private var stored: (credential: AtlassianCredential?, readAt: Date)?

    /// The center the observer was registered on, kept so `deinit` removes it from **that**
    /// center rather than from `.default`.
    ///
    /// The first version stored only the token and unregistered from `.default`, which leaks the
    /// registration whenever a center is injected — every test in this bundle does. Raised by
    /// Copilot in review round 5 of PR #43.
    private let notifications: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(notifications: NotificationCenter = .default) {
        self.notifications = notifications
        // `nonisolated` queue so the memo is dropped wherever the write happened, and `weak`
        // so an observer cannot keep a connector alive past the app.
        observer = notifications.addObserver(
            forName: .stenoCredentialsDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
    }

    /// The memoized credential, reading through `read` when the memo is cold, stale, or
    /// bypassed.
    ///
    /// **A `nil` result is memoized too.** "No credential" is the ordinary state of a
    /// machine nobody has configured, and re-reading the Keychain per ref to learn it again
    /// is exactly the cost being avoided.
    func credential(
        now: Date, fresh: Bool, read: () -> AtlassianCredential?
    ) -> AtlassianCredential? {
        lock.withLock {
            if !fresh, let stored, now.timeIntervalSince(stored.readAt) < Self.ttl {
                return stored.credential
            }
            let value = read()
            stored = (value, now)
            return value
        }
    }

    /// Drop the memo. Called by the observer above, and directly by tests.
    func invalidate() {
        lock.withLock { stored = nil }
    }
}
