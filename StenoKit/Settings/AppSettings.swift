import Foundation

/// Every `UserDefaults`-backed setting, declared in one place.
///
/// **`UserDefaults`, not SwiftData**, for the reason D-024 gives: these are
/// configuration, not domain data, so §10's export deliberately does not carry
/// them and M2.5-02's merge never has to reason about them.
///
/// **One type rather than a key per model.** M1-03 declared its own
/// `chordKey` on `QuickCaptureModel`, which was right when there was one
/// setting; FR-6 lists five Settings areas and four of them arrive with later
/// milestones. A codebase where every model declares its own key is one where
/// §10.3's "secrets are never exported" audit has no single place to look.
///
/// A `struct` with `nonmutating` setters, so an owner can hold it as a `let`
/// and still write through it — the store behind it is a reference type.
public struct AppSettings {
    /// FR-1.1's chord. Moved here from `QuickCaptureModel.chordKey`.
    public static let hotkeyChordKey = "com.lgabrielgr.steno.hotkeyChord"

    /// FR-6's default project — rung 4 of FR-1.4's ladder.
    public static let defaultProjectIDKey = "com.lgabrielgr.steno.defaultProjectID"

    private let defaults: UserDefaults

    /// - Parameter defaults: injected so tests use a scratch suite rather than
    ///   the developer's own preferences (§9.4).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored chord, or `nil` when absent or undecodable.
    ///
    /// **A bad stored value is reported as absent, never overwritten.** The
    /// caller falls back to `HotkeyChord.default`, and the original bytes stay
    /// on disk so the Settings pane can still show what is actually in there —
    /// the posture M1-03's `storedChord()` already took.
    public var hotkeyChord: HotkeyChord? {
        get {
            guard let data = defaults.data(forKey: Self.hotkeyChordKey),
                let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue, let encoded = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.hotkeyChordKey)
                return
            }
            defaults.set(encoded, forKey: Self.hotkeyChordKey)
        }
    }

    /// FR-6's configured default project, or `nil` when unset or unparseable.
    ///
    /// Stored as a string rather than as `Data`: it is a single UUID, and a
    /// readable `defaults read` is worth more here than symmetry with the
    /// chord.
    ///
    /// **Whether the project still exists is not this type's question.**
    /// `ProjectRouter.route` already guards the rung with `live.contains`, so
    /// an archived or deleted default degrades to the next rung with no
    /// validation here and none at the call sites.
    public var defaultProjectID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Self.defaultProjectIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.defaultProjectIDKey)
                return
            }
            defaults.set(newValue.uuidString, forKey: Self.defaultProjectIDKey)
        }
    }

    // MARK: - §10.5, auto-export

    /// M2.5-05's keys. Namespaced under `autoExport.` rather than flattened:
    /// six of the facade's eight keys now belong to one feature, and a prefix
    /// is what keeps `defaults read com.lgabrielgr.steno` legible.
    public static let autoExportEnabledKey = "com.lgabrielgr.steno.autoExport.enabled"
    public static let autoExportOnQuitKey = "com.lgabrielgr.steno.autoExport.onQuit"
    public static let autoExportDailyKey = "com.lgabrielgr.steno.autoExport.daily"
    public static let autoExportFolderKey = "com.lgabrielgr.steno.autoExport.folder"
    public static let autoExportStatusKey = "com.lgabrielgr.steno.autoExport.status"
    public static let autoExportOnboardedKey = "com.lgabrielgr.steno.autoExport.onboarded"

    /// §10.5's "auto-export should default to ON".
    public var autoExportEnabled: Bool {
        get { flag(Self.autoExportEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoExportEnabledKey) }
    }

    /// Export as the app terminates (D-121).
    public var autoExportOnQuit: Bool {
        get { flag(Self.autoExportOnQuitKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoExportOnQuitKey) }
    }

    /// Export once every 24h while the app runs (D-121).
    public var autoExportDaily: Bool {
        get { flag(Self.autoExportDailyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoExportDailyKey) }
    }

    /// **Absent means `true`, which `UserDefaults.bool(forKey:)` cannot say.**
    /// It returns `false` for a key that was never written, which is the wrong
    /// answer for all three of the settings above and would turn §10.5's
    /// opt-*out* into an opt-in on every fresh install — silently, and in the
    /// one direction nobody would notice, because a backup that never runs
    /// looks exactly like a backup that has nothing to do.
    private func flag(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// `~/Steno Backups`.
    ///
    /// **Not `~/Documents`, and that is the whole point of choosing it.**
    /// `~/Documents`, `~/Desktop` and `~/Downloads` are TCC-protected for every
    /// app, sandboxed or not — this app being deliberately unsandboxed buys
    /// nothing there — so the first write into one raises a system prompt. The
    /// trigger most likely to arrive first is quit, and a permission dialog
    /// attached to an app that is going away is the worst possible first
    /// contact with a feature whose promise is that it works unwatched. The
    /// home directory itself is not protected. See D-120.
    public static var defaultAutoExportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Steno Backups", isDirectory: true)
    }

    /// Where auto-export writes. Stored as a path, not a security-scoped
    /// bookmark: the app is unsandboxed, so `NSOpenPanel` choosing the folder
    /// *is* the durable grant, and a bookmark would encode a capability this
    /// process already has.
    public var autoExportFolder: URL {
        get {
            guard let path = defaults.string(forKey: Self.autoExportFolderKey), !path.isEmpty
            else { return Self.defaultAutoExportFolder }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        nonmutating set {
            defaults.set(newValue.path, forKey: Self.autoExportFolderKey)
        }
    }

    /// The last auto-export's outcome. An unreadable value reads as empty, for
    /// `hotkeyChord`'s reason: the bytes stay on disk rather than being
    /// overwritten by a reader.
    public var autoExportStatus: AutoExportStatus {
        get {
            guard let data = defaults.data(forKey: Self.autoExportStatusKey),
                let decoded = try? JSONDecoder().decode(AutoExportStatus.self, from: data)
            else { return AutoExportStatus() }
            return decoded
        }
        nonmutating set {
            guard let encoded = try? JSONEncoder().encode(newValue) else {
                // Unreachable for `Date` and `String`, and logged rather than
                // ignored because the value that would be dropped is the one
                // telling the user they have no backup.
                Log.app.error("could not encode the auto-export status")
                return
            }
            defaults.set(encoded, forKey: Self.autoExportStatusKey)
        }
    }

    /// Whether the first-run sheet has been shown (D-126). Absent means `false`
    /// — the one new flag whose default `UserDefaults.bool` already gets right.
    public var hasSeenAutoExportOnboarding: Bool {
        get { defaults.bool(forKey: Self.autoExportOnboardedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.autoExportOnboardedKey) }
    }
}
