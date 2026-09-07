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
}
