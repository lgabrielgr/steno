import Foundation
import ServiceManagement

/// Where the app stands with macOS's login-item registry.
///
/// **This is an enum rather than the `Bool` D-041 shipped, and the difference
/// is a silent failure.** `SMAppService.mainApp.register()` can succeed and
/// leave the service at `.requiresApproval`: macOS lists Steno under Login
/// Items with its switch off, waiting for the user. Read through a
/// `isEnabled: Bool` that state is indistinguishable from "off", with nothing
/// thrown — so the Settings toggle would flip itself back and say nothing,
/// which is the failure §13 exists to design out and the same one FR-1.1's
/// conflict warning prevents for the hotkey.
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and live: Steno will launch at login.
    case enabled
    /// Not registered. The ordinary "off" state.
    case notRegistered
    /// Registered, but macOS is waiting for the user to approve it in
    /// System Settings › General › Login Items.
    case requiresApproval
    /// macOS cannot find the bundle to register — a relocated or deleted app.
    case notFound
}

/// FR-6's "launch at login", as a capability M1-08's Capture pane drives.
///
/// `@MainActor` because the only thing that drives it is a settings toggle,
/// and an isolated protocol lets the test double be a plain class with mutable
/// state.
@MainActor
public protocol LoginItem {
    /// What macOS currently reports. Re-read after every `enable()`/`disable()`
    /// rather than inferred from the call returning — see `LoginItemStatus`.
    var status: LoginItemStatus { get }
    func enable() throws
    func disable() throws
}

/// `LoginItem` over `SMAppService`, which is the supported route on macOS 13+.
///
/// A failure — an unsigned or relocated bundle, which a debug build run out of
/// `.build/` may well be — is thrown, never trapped, and the Capture pane
/// reports the thrown error verbatim rather than a generic message. That is
/// what lets a manual check tell "this build cannot register" apart from "this
/// feature is broken" (D-041).
public struct SystemLoginItem: LoginItem {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        // `SMAppService.Status` is an Objective-C enum, so a future OS may add
        // a case. Reporting it as "not registered" is the honest degradation:
        // the toggle reads off, and `enable()` remains available.
        @unknown default: return .notRegistered
        }
    }

    public func enable() throws {
        try SMAppService.mainApp.register()
    }

    public func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
