import Foundation
import Testing

@testable import StenoKit

// D-146. §7.4's fallback waits on this, so the two things asserted are that the
// clock actually wins and that losing it is `.timedOut` — never `.network`.

@Test("work that finishes inside the budget returns its value")
func fastWorkSurvivesTheDeadline() async throws {
    let value = try await withDeadline(.seconds(30), throwing: AIError.timedOut) { 42 }
    #expect(value == 42)
}

@Test("work that overruns the budget throws .timedOut")
func slowWorkLosesTheRace() async {
    // A minute of work against a millisecond of budget. Mutation: return the
    // operation's result without racing the sleeper — the test then hangs
    // rather than failing, which is itself the signal.
    await #expect(throws: AIError.timedOut) {
        try await withDeadline(.milliseconds(10), throwing: AIError.timedOut) {
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
        try await withDeadline(.seconds(30), throwing: AIError.timedOut) {
            throw AIError.invalidCredential
        }
    }
}

@Test("a cancelled deadline surfaces .timedOut, never a raw CancellationError")
func cancellationStaysInsideTheContract() async {
    // M3-01's contract: a provider throws `AIError` and nothing else, because
    // §7.4 "cannot switch on an error type it has never heard of". Cancelling
    // the caller cancels both children of the race, and a cancelled
    // `Task.sleep` throws `CancellationError` — from the deadline task before
    // it reaches its own `throw`, and from anything inside the operation that
    // sleeps. Either can win.
    //
    // The operation here does no mapping of its own, so this fails the moment
    // `withDeadline` stops mapping. Mutation: remove its `catch is
    // CancellationError`. Red.
    let task = Task {
        try await withDeadline(.seconds(60), throwing: AIError.timedOut) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
    }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected the cancelled deadline to fail")
    } catch is AIError {
        // The contract held.
    } catch {
        Issue.record("escaped as \(type(of: error)), which §7.4 cannot classify")
    }
}
