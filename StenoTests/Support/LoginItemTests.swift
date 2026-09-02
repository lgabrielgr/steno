import Testing

@testable import StenoKit

/// The double M1-08's settings pane will code against.
///
/// The real `SystemLoginItem` is not exercised here: `SMAppService` registers
/// the *test runner's* bundle from an unhosted bundle, which is a side effect
/// on the developer's machine and not something a headless suite may do.
@MainActor
private final class FakeLoginItem: LoginItem {
    private(set) var isEnabled = false
    var failure: (any Error)?

    func enable() throws {
        if let failure { throw failure }
        isEnabled = true
    }

    func disable() throws {
        if let failure { throw failure }
        isEnabled = false
    }
}

@MainActor
@Test("the launch-at-login hook round-trips")
func theLoginItemHookRoundTrips() throws {
    let item: any LoginItem = FakeLoginItem()
    #expect(!item.isEnabled)

    try item.enable()
    #expect(item.isEnabled)

    try item.disable()
    #expect(!item.isEnabled)
}

@MainActor
@Test("a failing registration throws rather than reporting success")
func aFailingLoginItemRegistrationThrows() throws {
    struct Denied: Error {}
    let item = FakeLoginItem()
    item.failure = Denied()

    #expect(throws: Denied.self) { try item.enable() }
    #expect(!item.isEnabled)
}
