import Foundation

/// Runs refresh passes one at a time (D-183).
///
/// **Why serialize rather than reconcile.** §5.5 gives the app three triggers —
/// the launch pass, "Prepare Stand-up", and M4-05's scheduled run — and nothing
/// stops two of them overlapping: the launch pass is fire-and-forget, and the user
/// can press Prepare while it is still in flight. Two passes then snapshot the same
/// ref with the same `since`, both fetch, and both try to write.
///
/// The first attempt at this was optimistic: let both run and drop the second
/// result if the row had moved underneath it (D-181). That guard is still here as
/// defence, but it cannot be the primary mechanism, because **dropping a result can
/// lose a real change.** `lastFetchedAt` is deliberately the app's clock (D-171),
/// so the winner stamps a time *later* than the moment the loser observed its
/// change — and the next pass, asking `since` that later stamp, may never be told
/// about it again. Raised by Copilot in review of PR #42, against a claim in D-181
/// that said the opposite.
///
/// Serializing removes the situation instead of reconciling it: the second pass
/// reads its rows *after* the first has written, so it sends the newer `since` and
/// its answer is about work the first pass genuinely did not see.
///
/// **The cost is a wait, never a block.** A Prepare arriving during a launch pass
/// waits for it — bounded by that pass's own budget (D-178) — and FR-4 step 4 is
/// non-blocking regardless, because the draft sheet is already open on cached text
/// with Copy live. Cancelling the launch pass instead was rejected: it covers every
/// non-done task, where Prepare covers only the window's, so cancelling would throw
/// away refs nothing else in the session will revisit.
@MainActor
public final class SourceRefreshGate {
    /// The gate every trigger in the running app shares.
    ///
    /// A shared instance rather than a coordinator each caller must remember to
    /// route through: `SourceRefreshService` takes this as its default, so a new
    /// trigger is serialized by construction. Tests pass their own instance so one
    /// test's pass cannot wait on another's.
    public static let shared = SourceRefreshGate()

    /// The tail of the queue: awaiting it means awaiting every pass admitted so
    /// far.
    private var tail: Task<Void, Never>?

    public init() {}

    /// Run `pass` after every pass already admitted, and return its result.
    ///
    /// **`pass` is not cancelled if the caller goes away.** It runs in its own
    /// unstructured task, so a Prepare whose sheet is dismissed mid-wait still lets
    /// the pass ahead of it finish and write — which is what we want: that pass's
    /// fetches were already paid for, and its cache write is what makes the next
    /// report offline-capable.
    func serialize<T: Sendable>(_ pass: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            return await pass()
        }
        // The queue's tail discards the value so every caller can await the same
        // `Task<Void, Never>` regardless of what its own pass returns.
        tail = Task { @MainActor in _ = await work.value }
        return await work.value
    }
}
