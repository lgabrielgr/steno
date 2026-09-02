import Foundation
import ServiceManagement

/// FR-6's "launch at login", as a capability with no caller yet.
///
/// **Nothing in the app calls `enable()`.** FR-6 owns the setting and places
/// it in the Settings window's Capture pane, which is M1-08; registering the
/// user for launch-at-login without asking is not this surface's decision
/// (D-041). This ships now so M1-08 adds a pane rather than redesigning a
/// type — the posture `QuickCaptureModel.rebind` already established.
///
/// `@MainActor` because the only thing that will ever drive it is a settings
/// toggle, and an isolated protocol lets the test double be a plain class with
/// mutable state.
@MainActor
public protocol LoginItem {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    func enable() throws
    func disable() throws
}

/// `LoginItem` over `SMAppService`, which is the supported route on macOS 13+.
///
/// A failure — an unsigned or relocated bundle, which a debug build run out of
/// `.build/` may well be — is thrown, never trapped. M1-08's pane reports it.
public struct SystemLoginItem: LoginItem {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func enable() throws {
        try SMAppService.mainApp.register()
    }

    public func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
