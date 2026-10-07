import Foundation

/// What the Integrations pane's "Scheduled refresh" section binds to (FR-6, §5.5).
///
/// **Its own model rather than two more properties on `IntegrationsSettingsModel`.**
/// That type is about the Atlassian credential and the connectors over it, and it is
/// already 387 lines — adding a second subject would push the file past SwiftLint's
/// `file_length` limit, which `make lint --strict` reports as a failure. Splitting by
/// subject is also what makes this testable in four short tests instead of inside a
/// type that needs a Keychain double to build.
///
/// **Observable, mirroring `UserDefaults` rather than reading through to it.**
/// `@Observable` tracks stored properties; a computed property over `UserDefaults`
/// would change the setting and leave the control drawing its old value, because
/// nothing SwiftUI observes would have changed. The mirror is written through on every
/// set, so `ScheduledRefreshController` — which reads `AppSettings` per tick — sees the
/// change on the next tick with no relaunch and no notification between them.
///
/// Every rule lives here rather than in the pane: the unhosted test bundle cannot
/// reach the app target (D-010), so a rule only a view knows is a rule no test can
/// hold.
@Observable
@MainActor
public final class ScheduledRefreshSettingsModel {
    private let settings: AppSettings
    private let calendar: () -> Calendar
    private var rejectionObservation: WriteObservation?

    /// §5.5's schedule, on or off.
    public var isEnabled: Bool {
        didSet { settings.scheduledRefreshEnabled = isEnabled }
    }

    /// The configured time of day.
    ///
    /// Written through on set, like `isEnabled`. The pane does not bind to this
    /// directly — `DatePicker` needs a `Date` — it binds to `pickerDate` below.
    public var time: TimeOfDay {
        didSet { settings.scheduledRefreshTime = time }
    }

    /// - Parameters:
    ///   - settings: injected so tests use a scratch suite rather than the developer's
    ///     own preferences (§9.4).
    ///   - calendar: injected for `pickerDate`'s conversion, so a test can pin a time
    ///     zone instead of inheriting the machine's.
    ///   - center: injected so a test can post `.stenoScheduledRefreshDidChange` without
    ///     touching the process-wide center.
    public init(
        settings: AppSettings = AppSettings(),
        calendar: @escaping () -> Calendar = { .current },
        center: NotificationCenter = .default
    ) {
        self.settings = settings
        self.calendar = calendar
        self.isEnabled = settings.scheduledRefreshEnabled
        self.time = settings.scheduledRefreshTime
        self.credentialRejection = settings.scheduledRefreshRejection

        // Registered last: `self` may only be captured once every stored property has a
        // value — `SettingsModel`'s posture, for its reason.
        rejectionObservation = WriteObservation(
            center.addObserver(
                forName: .stenoScheduledRefreshDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }, center: center)
    }

    /// What an unattended pass last learned about the credential (D-227), or `nil`.
    ///
    /// **Kept current by a notification, not by the pane appearing** (D-229). The first
    /// version read the store in `onAppear` and its comment claimed "the pane cannot be open
    /// at the instant a background pass runs and then fail to redraw" — which is false: a
    /// user can leave Settings open across 08:00, and then a refused pass wrote
    /// `UserDefaults` while this property, the one SwiftUI observes, never changed. The same
    /// is true of recovery: the row would stay on screen after it stopped being true. Raised
    /// by Copilot in review round 3 of PR #46.
    public private(set) var credentialRejection: CredentialRejection?

    /// Re-read the rejection from the store.
    ///
    /// Called by the observation below, and directly by tests. The pane does not need to
    /// call it: a model built at launch reads the stored value in `init`, and every later
    /// change arrives as `.stenoScheduledRefreshDidChange`. Having the pane re-read on
    /// appearance *as well* would be a second mechanism for one fact, which is how the two
    /// come to disagree.
    public func reload() {
        credentialRejection = settings.scheduledRefreshRejection
    }

    /// `time` as the `Date` a `DatePicker(displayedComponents: .hourAndMinute)` binds.
    ///
    /// **The date component is deliberately today's and deliberately ignored.** The
    /// picker shows and edits hours and minutes only; the setter takes the hour and
    /// minute off whatever instant the picker produces and throws the rest away, which
    /// is what keeps the stored setting a time of day rather than an instant that
    /// drifts with the time zone it was set in.
    ///
    /// A `nil` from `instant(on:calendar:)` is unreachable — see
    /// `TimeOfDay.instant(on:calendar:)` — and falls back to the day's start, which
    /// shows 00:00 in the control rather than refusing to draw it.
    public var pickerDate: Date {
        get {
            let today = Date()
            return time.instant(on: today, calendar: calendar())
                ?? calendar().startOfDay(for: today)
        }
        set { time = TimeOfDay(of: newValue, calendar: calendar()) }
    }
}
