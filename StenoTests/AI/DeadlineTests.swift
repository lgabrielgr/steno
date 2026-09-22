import Foundation
import Testing

@testable import StenoKit

// D-145. §7.4's fallback waits on this, so the two things asserted are that the
// clock actually wins and that losing it is `.timedOut` — never `.network`.

@Test("work that finishes inside the budget returns its value")
func fastWorkSurvivesTheDeadline() async throws {
    let value = try await withDeadline(.seconds(30)) { 42 }
    #expect(value == 42)
}

@Test("work that overruns the budget throws .timedOut")
func slowWorkLosesTheRace() async {
    // A minute of work against a millisecond of budget. Mutation: return the
    // operation's result without racing the sleeper — the test then hangs
    // rather than failing, which is itself the signal.
    await #expect(throws: AIError.timedOut) {
        try await withDeadline(.milliseconds(10)) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
    }
}

@Test("the deadline does not swallow the operation's own error")
func realFailuresPropagate() async {
    // A timeout that masked every failure as `.timedOut` would tell the user
    // the provider was slow when their key was rejected.
    await #expect(throws: AIError.invalidCredential) {
        try await withDeadline(.seconds(30)) {
            throw AIError.invalidCredential
        }
    }
}
