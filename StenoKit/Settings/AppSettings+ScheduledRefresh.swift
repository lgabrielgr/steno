import Foundation

/// §5.5's scheduled refresh, as settings (M4-05).
///
/// **A second file rather than more of `AppSettings.swift`**, which reached SwiftLint's
/// 400-line `file_length` limit when D-227's rejection record was added. Split by subject,
/// the way `IntegrationsSettingsModel+Credential.swift` splits its own type: everything here
/// belongs to one feature, and the audit that reads `AppSettings.allKeys` is unaffected —
/// the keys below are declared in this extension and listed in that array, which the
/// compiler checks and `AISecretsTests` counts.
extension AppSettings {
    // MARK: - §5.5, the scheduled background refresh

    /// M4-05's three keys, namespaced for the reason auto-export's six are.
    ///
    /// `lastRun` is state rather than preference, and lives here anyway, beside
    /// `autoExportStatus` which is also state — this type's doc comment above is
    /// explicit that one place for every `UserDefaults` key is what makes §8's
    /// audit possible.
    public static let scheduledRefreshEnabledKey = "com.lgabrielgr.steno.scheduledRefresh.enabled"
    public static let scheduledRefreshTimeKey = "com.lgabrielgr.steno.scheduledRefresh.time"
    public static let scheduledRefreshLastRunKey = "com.lgabrielgr.steno.scheduledRefresh.lastRun"
    public static let scheduledRefreshRejectionKey =
        "com.lgabrielgr.steno.scheduledRefresh.rejection"

    /// Whether §5.5's scheduled pass runs at all.
    ///
    /// **Absent means `true`.** §5.5 states the schedule as policy rather than as an
    /// option, so a fresh install schedules; the toggle exists because unattended
    /// network activity deserves an off switch that is not "switch the integration
    /// off entirely", which would also stop the launch and Prepare passes. `flag(_:)`
    /// is what expresses that, for the reason it was written: `bool(forKey:)` answers
    /// `false` for a key never written, and a schedule that silently never fires looks
    /// exactly like one with nothing to fetch.
    public var scheduledRefreshEnabled: Bool {
        get { flag(Self.scheduledRefreshEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.scheduledRefreshEnabledKey) }
    }

    /// When the scheduled pass runs. 08:00 unless the user says otherwise (§5.5).
    ///
    /// Stored as minutes since midnight — see `TimeOfDay`, which exists so this is not
    /// a `Date` whose date component is noise and whose meaning moves with the time
    /// zone it was written in.
    ///
    /// **An unusable stored value reads as the default rather than trapping**, which
    /// is `hotkeyChord`'s posture and for its reason: a hand-written `defaults write`
    /// must not be able to break the app. `object(forKey:)` rather than
    /// `integer(forKey:)`, because the latter answers `0` for an absent key and `0` is
    /// a legitimate setting — midnight.
    public var scheduledRefreshTime: TimeOfDay {
        get {
            guard let stored = defaults.object(forKey: Self.scheduledRefreshTimeKey) as? Int,
                let time = TimeOfDay(minutesSinceMidnight: stored)
            else { return .eightAM }
            return time
        }
        nonmutating set {
            defaults.set(newValue.minutesSinceMidnight, forKey: Self.scheduledRefreshTimeKey)
        }
    }

    /// When a scheduled pass was last **dispatched** — not when one last succeeded
    /// (D-223).
    ///
    /// `nil` until the first one runs, which is what makes the first launch after
    /// install serve the day's occurrence if it is inside the grace window.
    public var scheduledRefreshLastRun: Date? {
        get { defaults.object(forKey: Self.scheduledRefreshLastRunKey) as? Date }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.scheduledRefreshLastRunKey)
                return
            }
            defaults.set(newValue, forKey: Self.scheduledRefreshLastRunKey)
        }
    }

    /// The credential an unattended pass last found broken (D-227), or `nil`.
    ///
    /// **This is the M4-05 requirement that `expiryWarning` cannot meet.** That warning is
    /// derived from the user-entered expiry date, so a revoked token — or one that expired
    /// with no date recorded — leaves the pane silent; the scheduled pass is the only thing
    /// that knows, and before this key it discarded what it knew (Copilot, PR #46).
    ///
    /// Stored as JSON, the shape `autoExportStatus` uses, and an unreadable value reads as
    /// `nil` rather than being overwritten — `hotkeyChord`'s posture.
    public var scheduledRefreshRejection: CredentialRejection? {
        get {
            guard let data = defaults.data(forKey: Self.scheduledRefreshRejectionKey),
                let decoded = try? JSONDecoder().decode(CredentialRejection.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue, let encoded = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.scheduledRefreshRejectionKey)
                return
            }
            defaults.set(encoded, forKey: Self.scheduledRefreshRejectionKey)
        }
    }
}
