import AppKit
import Foundation

/// Owns auto-export's two automatic triggers: the hourly daily check and the
/// export on quit.
///
/// **It exists for the two things a pure function cannot hold** — a `Timer` and
/// an `NSApplication.willTerminateNotification` observation. Everything
/// decidable is in `AutoExportService`, `AutoExportDue` and
/// `AutoExportRetention`, which is why this type has no branches to test.
///
/// **The quit hook is a notification, not `AppDelegate`.**
/// `applicationWillTerminate(_:)` would put the call in the app target, where
/// the headless bundle cannot reach it (D-010) and where `AppDelegate` — which
/// exists for exactly one unrelated line — would acquire a store dependency.
/// The notification is posted at the same moment, and observing it keeps the
/// whole feature inside `StenoKit`.
@MainActor
public final class AutoExportController {
    /// Hourly. The daily check is a comparison against a stored date, not a
    /// countdown, so the tick rate only decides how soon after the 24h mark the
    /// export happens — an hour of slack on a daily backup, for one timer
    /// firing that does nothing but read a `Date`.
    public static let tickInterval: TimeInterval = 60 * 60

    private let service: AutoExportService
    private var timer: Timer?
    private var terminationObservation: WriteObservation?

    public init(service: AutoExportService) {
        self.service = service
    }

    /// Run the launch check, then arm both triggers.
    ///
    /// Separate from `init` so building the controller cannot have side
    /// effects — `StenoApp.init` builds it, and an initializer that wrote a
    /// file would put an export on the launch path before anything had decided
    /// one was due.
    public func start(interval: TimeInterval = AutoExportController.tickInterval) {
        // **Idempotent, because the timer half is not self-correcting.**
        // Reassigning `timer` does not stop the old one: a scheduled `Timer` is
        // retained by the run loop, so a second `start()` used to leave two
        // live tickers firing forever, and every later one added another. The
        // observation half *was* safe — replacing the `WriteObservation`
        // deallocates the old one, whose `deinit` removes the token — but
        // relying on that asymmetry is how the next reader gets it wrong.
        // Raised by Copilot in review of PR #32.
        stop()

        runDaily()

        let timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.runDaily() }
        }
        // `.common`, so the tick still fires while a menu is tracking or a
        // window is being resized — both put the run loop in a mode the default
        // one does not cover, and a backup that pauses because a menu is open
        // is a backup nobody can reason about.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        terminationObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.runOnQuit() }
            })
    }

    /// Stop both triggers. Nothing in the app calls this — the controller is
    /// built once in `StenoApp.init` and lives for the process — but a timer
    /// with no way to be invalidated is a leak waiting for the first test that
    /// builds two controllers.
    public func stop() {
        timer?.invalidate()
        timer = nil
        terminationObservation = nil
    }

    @discardableResult
    public func runDaily() -> AutoExportOutcome { service.run(trigger: .daily) }

    @discardableResult
    public func runOnQuit() -> AutoExportOutcome { service.run(trigger: .quit) }

    deinit {
        // `timer` is `@MainActor`-isolated state and `deinit` is not, so the
        // invalidation cannot happen here — the same Swift 6 constraint
        // `WriteObservation` exists for. That is not a gap: the timer's block
        // captures `self` weakly, matching `terminationObservation` above, so
        // the run loop's retention of an armed `Timer` does not retain this
        // object in turn — the object can still deallocate with the timer
        // left running (harmlessly ticking a `weak self` that resolves to
        // `nil`) until it is invalidated. `stop()` is what invalidates it;
        // nothing calls `stop()` today because `StenoApp.init` holds this
        // controller in a stored property for the life of the process, so it
        // never deallocates while the app is running.
    }
}
