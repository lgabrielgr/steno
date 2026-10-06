import AppKit
import Foundation

/// §5.5's third refresh trigger: a pass at the user's configured time (D-221).
///
/// **It exists for the one thing a pure function cannot hold** — a `Timer`.
/// `ScheduledRefreshDue` decides; this arms a tick and asks. That is
/// `AutoExportController`'s division of labour (D-121), and it is why this type has
/// almost no branches of its own.
///
/// **A polling tick, not a timer armed at the occurrence.** Arming for 08:00 fires on
/// the minute, and then every edge case becomes re-arming: the toggle changes, the
/// time changes, the machine sleeps, the time zone moves. A stale armed timer is
/// *silent*, which is the failure mode nobody notices — a refresh that never happens
/// looks exactly like a refresh with nothing to report. Polling has no state to go
/// stale: sleep, a closed app, a daylight-saving boundary and a clock dragged
/// backwards all reduce to "the next tick re-asks".
///
/// `NSBackgroundActivityScheduler` was the other candidate and cannot express this
/// setting: it schedules by interval, not by time of day, and its whole value is the
/// right to defer — including past the morning this exists to make fast.
@MainActor
public final class ScheduledRefreshController {
    /// Five minutes. The due check is a comparison against a stored date rather than
    /// a countdown, so the tick rate decides only how soon after the configured time
    /// the pass starts — and a pass that starts by 08:05 serves a stand-up nobody
    /// gives before 09:00.
    public static let tickInterval: TimeInterval = 5 * 60

    /// How long the system may coalesce a tick by. The tick costs two date
    /// comparisons when nothing is due, and letting the OS fold it into other work is
    /// how it stays that cheap — M4-05's fourth acceptance criterion is that this
    /// does not spin the machine.
    static let tickTolerance: TimeInterval = 60

    private let settings: AppSettings
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let refresh: @MainActor () async -> RefreshOutcome

    /// Where sleep and wake are posted. **Not `NotificationCenter.default`** — AppKit posts
    /// workspace notifications on `NSWorkspace.shared.notificationCenter`, and an observer
    /// registered on the default center is silently never called.
    private let workspaceCenter: NotificationCenter

    /// Where this type *posts* (D-229): the center the Settings model observes.
    private let center: NotificationCenter

    private var timer: Timer?
    private var wakeObservation: WriteObservation?

    /// - Parameters:
    ///   - settings: the same instance the Settings pane writes, so the toggle and
    ///     the time take effect on the next tick with no relaunch.
    ///   - calendar: a closure, read per tick rather than stored, so a time-zone
    ///     change needs nothing re-armed — `SourceRegistry` reads enablement per
    ///     dispatch for the same reason (D-216).
    ///   - refresh: the pass to run. **A closure rather than a `SourceRefreshService`**
    ///     because the service needs a `ModelContext` only the composition root has,
    ///     and because a spy is what makes "dispatched once, not twice" assertable
    ///     without a container, a connector or a wait.
    ///
    ///     **It returns its `RefreshOutcome`, which the launch path used to discard**
    ///     (D-227). Nothing here acts on the counts; the one thing read is whether a
    ///     connector refused the credential, because an unattended pass is the only
    ///     thing that can discover a revoked token and the pane has no other way to
    ///     learn of it.
    public init(
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        center: NotificationCenter = .default,
        refresh: @escaping @MainActor () async -> RefreshOutcome
    ) {
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.workspaceCenter = workspaceCenter
        self.center = center
        self.refresh = refresh
    }

    /// Run the launch pass, then arm the tick.
    ///
    /// Separate from `init` so building the controller cannot reach the network —
    /// `StenoApp.init` builds it, and an initializer that opened a socket would put a
    /// fetch on the launch path before anything had decided one was wanted.
    public func start(interval: TimeInterval = ScheduledRefreshController.tickInterval) {
        // **Idempotent, because the timer half is not self-correcting.** Reassigning
        // `timer` does not stop the old one: a scheduled `Timer` is retained by the
        // run loop, so a second `start()` would leave two live tickers firing
        // forever. Found by Copilot in review of PR #32, against the controller this
        // one is modelled on.
        stop()

        runCatchUpPass()

        // **A wake is a launch, for an app that never closed** (D-228). D-224 rejected this
        // observation on the grounds that a sleep spanning the window is indistinguishable
        // from the app having been closed, and that both end in the same catch-up. The second
        // half was false: a closed app refreshes when it is launched, while an app left
        // running across a long sleep refreshed nothing at all — the first resumed tick finds
        // the occurrence past its grace window and returns. Raised by Copilot in review round
        // 3 of PR #46.
        //
        // The same pass as launch, so a wake at 13:00 still warms a cache nothing else would
        // touch until the user pressed Prepare, while the *occurrence* is claimed only if one
        // is genuinely due — a long sleep does not resurrect a morning that has gone.
        wakeObservation = WriteObservation(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.runCatchUpPass() }
            }, center: workspaceCenter)

        let timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        timer.tolerance = Self.tickTolerance
        // `.common`, so the tick still fires while a menu is tracking or a window is
        // being resized — both put the run loop in a mode the default one does not
        // cover, and a schedule that pauses because a menu is open is one nobody can
        // reason about.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The armed tick, or `nil` when the controller is stopped.
    ///
    /// `internal` for one assertion: that a second `start()` invalidates the first
    /// timer rather than abandoning it to the run loop. A test cannot see that through
    /// behaviour — an abandoned timer keeps working, which is exactly why the bug
    /// survived in `AutoExportController` until PR #32 — so the handle itself is the
    /// only observable.
    var armedTimer: Timer? { timer }

    /// Disarm the tick. Nothing in the app calls this — `StenoApp` holds the
    /// controller for the life of the process — but a timer with no way to be
    /// invalidated is a leak waiting for the first test that builds two controllers.
    public func stop() {
        timer?.invalidate()
        timer = nil
        wakeObservation = nil
    }

    /// §5.5's launch behaviour and this task's, as **one pass** (D-224) — run at launch and
    /// again on wake (D-228).
    ///
    /// The pass runs either way; the schedule decides only whether it also serves today's
    /// occurrence. Asking the rule *and* keeping a separate unconditional pass would
    /// dispatch twice, where the second finds nothing stale, fetches nothing, and leaves two
    /// triggers claiming the same moment in the log.
    ///
    /// **Named for the catch-up rather than for launch**, since a wake runs it too: a Mac
    /// that slept through the window gets its cache warmed on the same terms a relaunch
    /// would have given it. Repeated wakes are harmless — `refreshDue()` fetches only refs
    /// older than thirty minutes and `SourceRefreshGate` serializes passes (D-183), so a
    /// burst costs one pass and no fetches.
    ///
    /// - Returns: whether this pass also served a due occurrence.
    @discardableResult
    func runCatchUpPass() -> Bool {
        let claimed = claimOccurrenceIfDue()
        if claimed {
            Log.sources.info("scheduled refresh: this catch-up pass serves the due occurrence")
        }
        dispatch()
        return claimed
    }

    /// One tick of the clock. Nothing happens unless an occurrence is owed.
    ///
    /// `internal` so tests drive it directly: a test that waited five minutes for a
    /// timer would not be run, and `start(interval:)` with a millisecond interval
    /// would assert that `Timer` works rather than that this rule does.
    ///
    /// **Returns the decision rather than only acting on it**, so a test can assert
    /// "this tick dispatched and the next did not" synchronously. Observing the same
    /// thing through the refresh closure would mean waiting on a `Task` that has not
    /// necessarily started when `tick()` returns — which is how an async test comes to
    /// pass for the wrong reason.
    @discardableResult
    func tick() -> Bool {
        guard claimOccurrenceIfDue() else { return false }
        Log.sources.info("scheduled refresh: the configured time has arrived; starting a pass")
        dispatch()
        return true
    }

    /// Whether an occurrence is owed — and, if it is, claim it by stamping.
    ///
    /// **The stamp is written here, before the pass runs, not after it succeeds**
    /// (D-223). This is the opposite of `AutoExportDue`, which measures from the last
    /// success so that a missing backup folder keeps re-announcing itself; a failed
    /// background refresh is not the user's problem — §5.5 makes it best-effort and
    /// the stand-up draft already labels stale data — so stamping on success would
    /// mean retrying every five minutes until the grace window closed, forty-eight
    /// passes at a source that is most likely down.
    ///
    /// One attempt per occurrence is also why there is no in-flight guard: the stamp
    /// makes the next tick not-due, so a second dispatch while the first is still
    /// fetching is unreachable rather than prevented. Do not add the flag back.
    private func claimOccurrenceIfDue() -> Bool {
        guard settings.scheduledRefreshEnabled else { return false }

        let moment = now()
        guard
            ScheduledRefreshDue.isDue(
                now: moment, at: settings.scheduledRefreshTime,
                lastRun: settings.scheduledRefreshLastRun, calendar: calendar())
        else { return false }

        settings.scheduledRefreshLastRun = moment
        return true
    }

    /// Fire and forget, silent, logs only — the launch pass's posture (D-176).
    ///
    /// This runs unattended, so it must never surface a modal, a permission prompt or
    /// an auth dialog. It cannot: `SourceRefreshService`'s refresh methods do not
    /// throw (D-167), and nothing on this path can present anything.
    ///
    /// **One thing is kept from the outcome rather than discarded** (D-227): whether a
    /// connector refused the credential. Everything else — the counts, the staleness, the
    /// expiry warnings — reaches the user at the next "Prepare Stand-up" through
    /// `SourceNotice` (D-193), which is the surface §5.2 chose for them.
    private func dispatch() {
        Task { @MainActor in
            let outcome = await refresh()
            record(outcome)
        }
    }

    /// Persist, or clear, what this pass learned about the credential (D-227).
    ///
    /// Three cases, and the third is the one that makes this correct:
    ///
    /// - A connector refused the credential → record it, with the time.
    /// - A pass that reached a source and was not refused → clear any recorded rejection.
    /// - **A pass that attempted nothing → leave the record alone.** Nothing due, nothing
    ///   configured, every integration switched off: none of those is evidence about the
    ///   token, and clearing on one would erase the warning on the very next tick, because
    ///   a pass with no refs due is the normal case.
    private func record(_ outcome: RefreshOutcome) {
        let before = settings.scheduledRefreshRejection

        if let rejection = CredentialRejection.from(outcome, at: now()) {
            settings.scheduledRefreshRejection = rejection
            Log.sources.error(
                "unattended refresh: \(rejection.displayName, privacy: .public) refused the stored credential"
            )
        } else if CredentialRejection.isCleared(by: outcome) {
            settings.scheduledRefreshRejection = nil
        }

        // **Only when it changed** (D-229). The Settings pane can be open while this runs, so
        // a stored value nothing announces is a warning the user never sees — or, on
        // recovery, one that stays on screen after it stopped being true. Posting
        // unconditionally would redraw the pane on every tick for no reason, which is how a
        // notification becomes something readers learn to ignore.
        if settings.scheduledRefreshRejection != before {
            center.post(name: .stenoScheduledRefreshDidChange, object: nil)
        }
    }

    deinit {
        // `timer` is `@MainActor` state and `deinit` is not, so the invalidation
        // cannot happen here — the Swift 6 constraint `AutoExportController` records.
        // The timer's block captures `self` weakly, so an armed timer does not retain
        // this object; it ticks a `nil` and does nothing until `stop()`.
    }
}
