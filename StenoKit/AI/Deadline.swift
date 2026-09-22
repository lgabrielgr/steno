import Foundation

/// Run `operation` against a wall clock, throwing `AIError.timedOut` if the
/// clock wins (D-145).
///
/// **A wall clock, not `URLSession`'s request timeout.** §7.4's fallback waits
/// on this: "if the API is slow, the user is standing in a meeting". The
/// retry loop runs *inside* the deadline, which is what makes D-144's budget
/// cover backoff rather than resetting it on the second attempt.
///
/// **What this cannot do is return while the operation refuses to stop.**
/// `withThrowingTaskGroup` awaits its children before leaving scope and Swift
/// cancellation is cooperative, so an `HTTPTransport` that ignores cancellation
/// keeps this blocked past the budget — §7.4's fallback would then arrive late
/// rather than promptly (PR #35 review). The shipped transport is
/// `URLSession`, which honours cancellation, and `HTTPTransport.send` now says
/// in its own doc comment that an implementation must. That is the contract
/// rather than an enforcement: making the deadline return independently means
/// abandoning a live task, which trades a late answer for a leaked request.
/// The error stays correct either way — `DeadlineTests` pins that against an
/// operation that deliberately will not stop.
///
/// **The subtle part is which error the loser throws.** Cancelling an in-flight
/// `URLSession` task surfaces as `URLError.cancelled`, which sits in the same
/// error domain as the genuine connectivity failures — so mapping it by domain,
/// the obvious mapping, reports `.network` for a request that timed out and
/// tells the user they are offline while their connection is fine. The deadline
/// branch throws `.timedOut` itself, and `AnthropicErrors.error(forTransport:)`
/// maps a stray cancellation the same way, because nothing else here cancels.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await race(duration, operation: operation)
    } catch is CancellationError {
        // **Cancelling the caller cancels both children**, and a cancelled
        // `Task.sleep` throws `CancellationError` — from the deadline task
        // before it reaches its `throw`, and from anything inside `operation`
        // that sleeps. Either can win the race, so a mapping applied at one
        // call site is a coin flip: M3-02's first attempt caught this in
        // `availableModels` and a mutation survived, because the test happened
        // to hit the path the transport had already mapped (PR #35 review).
        //
        // Mapping it here covers every caller and makes the contract
        // deterministic: `withDeadline` throws `AIError` and nothing else.
        throw AIError.timedOut
    }
}

private func race<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw AIError.timedOut
        }

        guard let first = try await group.next() else {
            throw AIError.timedOut
        }
        // The loser is cancelled and its result discarded: a `URLError`
        // cancelled task and a `CancellationError` from the sleeper are both
        // noise once the race is settled.
        group.cancelAll()
        return first
    }
}
