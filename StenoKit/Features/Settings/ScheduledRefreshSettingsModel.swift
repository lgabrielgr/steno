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
    public init(
        settings: AppSettings = AppSettings(),
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.settings = settings
        self.calendar = calendar
        self.isEnabled = settings.scheduledRefreshEnabled
        self.time = settings.scheduledRefreshTime
    }

    /// What an unattended pass last learned about the credential (D-227), or `nil`.
    ///
    /// **Re-read rather than mirrored**, which is the opposite of `isEnabled` and `time`
    /// above, because this one is written by the controller rather than by this model: a
    /// mirror taken at launch would still say "nothing" after an 08:00 pass was refused.
    /// `reload()` is what the pane calls as it appears, which is the only moment the value
    /// has to be right — the pane cannot be open at the instant a background pass runs and
    /// then fail to redraw, because appearing is what triggers the read.
    public private(set) var credentialRejection: CredentialRejection?

    /// Re-read the rejection from the store. Called by the pane as it appears, beside the
    /// `forgetEntry()` the credential half already does there.
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
