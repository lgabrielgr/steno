import Foundation

/// Holds a task at a chosen line until the test lets it past.
///
/// **Why this exists.** Cancellation tests that create a `Task` and cancel it on the next
/// line are racing: the body is scheduled on the global executor and may begin on another
/// thread concurrently with the next statement, so the work can finish before the
/// cancellation lands. A gate makes the ordering a property of the code rather than of the
/// machine — which is the difference between a test and a coin flip, and this repo has
/// paid for a flaky one before (`Deadline.swift` records the same lesson).
///
/// Raised by Copilot in review of PR #44, against a first version of these tests whose own
/// comment called the racy form deterministic.
actor TaskGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Let everything through, now and later.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Suspend until `open()`.
    ///
    /// Returns immediately once it has been called, so a test cannot deadlock by opening
    /// the gate before anything waits on it.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
