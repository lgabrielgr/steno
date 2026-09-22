import Foundation

/// Run `operation` against a wall clock, throwing `AIError.timedOut` if the
/// clock wins (D-145).
///
/// **A wall clock, not `URLSession`'s request timeout.** §7.4's fallback waits
/// on this: "if the API is slow, the user is standing in a meeting". The
/// retry loop runs *inside* the deadline, which is what makes D-144's budget
/// cover backoff rather than resetting it on the second attempt.
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
