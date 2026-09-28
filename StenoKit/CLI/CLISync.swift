import Foundation

/// The bridge from `main()`'s thread to an `async` harness.
///
/// **One mechanism, not one per selftest.** `ModelsSelftest` invented this to run
/// an async provider call from a synchronous CLI entry point, and M4-02 added two
/// more harnesses that need exactly the same thing; three copies of a
/// semaphore-and-box would be three chances to get the ordering subtly wrong.
///
/// The caller must be `nonisolated`: this blocks the calling thread — the main
/// thread, for `steno jira-selftest` — while `work` runs on the cooperative pool,
/// and an actor-isolated hop inside `work` would deadlock that bridge.
enum CLISync {
    /// Run `work` to completion, blocking this thread, and return its exit code.
    static func runSynchronously(_ work: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = ExitCode()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            finished.signal()
        }
        finished.wait()
        return box.value
    }

    /// A box the detached task writes and the waiting thread reads.
    ///
    /// `@unchecked Sendable` with no lock: the semaphore is the ordering. The write
    /// happens before `signal()` and the read after `wait()`, which is the same
    /// happens-before a lock would establish.
    private final class ExitCode: @unchecked Sendable {
        var value: Int32 = 1
    }
}
