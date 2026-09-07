import Testing

@testable import StenoKit

/// The double M1-08's Capture pane codes against.
///
/// The real `SystemLoginItem` is not exercised here: `SMAppService` registers
/// the *test runner's* bundle from an unhosted bundle, which is a side effect
/// on the developer's machine and not something a headless suite may do.
@MainActor
final class FakeLoginItem: LoginItem {
    private(set) var status: LoginItemStatus = .notRegistered
    var failure: (any Error)?

    /// What `status` becomes after a successful `enable()`.
    ///
    /// Settable so a test can reproduce the case this type exists for: macOS
    /// accepting the registration and then waiting for the user to approve it.
    var statusAfterEnabling: LoginItemStatus = .enabled

    func enable() throws {
        if let failure { throw failure }
        status = statusAfterEnabling
    }

    func disable() throws {
        if let failure { throw failure }
        status = .notRegistered
    }
}

@MainActor
@Test("the launch-at-login hook round-trips")
func theLoginItemHookRoundTrips() throws {
    let item: any LoginItem = FakeLoginItem()
    #expect(item.status == .notRegistered)

    try item.enable()
    #expect(item.status == .enabled)

    try item.disable()
    #expect(item.status == .notRegistered)
}

@MainActor
@Test("a failing registration throws rather than reporting success")
func aFailingLoginItemRegistrationThrows() throws {
    struct Denied: Error {}
    let item = FakeLoginItem()
    item.failure = Denied()

    #expect(throws: Denied.self) { try item.enable() }
    #expect(item.status == .notRegistered)
}

/// The state a `Bool` could not express, and the reason this protocol changed.
///
/// `register()` returns without throwing, and macOS still will not launch the
/// app until the user approves it in System Settings. Read as a `Bool` this is
/// indistinguishable from "off".
@MainActor
@Test("a registration awaiting approval is neither enabled nor a failure")
func aRegistrationCanAwaitApproval() throws {
    let item = FakeLoginItem()
    item.statusAfterEnabling = .requiresApproval

    try item.enable()

    #expect(item.status == .requiresApproval)
    #expect(item.status != .enabled)
}
