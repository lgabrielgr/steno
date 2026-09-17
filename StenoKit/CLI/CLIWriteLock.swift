import Darwin
import Foundation

/// One CLI writer at a time, across processes.
///
/// **`CLIInstanceCheck` only sees the GUI.** A terminal-launched `steno import`
/// never creates `NSApplication`, so it does not register with LaunchServices
/// and two of them pass that guard together. They then both `plan` against the
/// same snapshot, both pass `ImportService`'s staleness check — which compares
/// and then writes, with nothing between — and both save. Two concurrent
/// `--replace` runs would leave whichever finished last, silently discarding the
/// other; two merges would resolve against a store that moved underneath them.
/// Raised in review of PR #31.
///
/// **Advisory, non-blocking, and released by the kernel.** `flock` with
/// `LOCK_NB` fails immediately rather than queueing, so a second invocation
/// reports a refusal in the same shape as the running-app guard instead of
/// hanging a script. The lock lives on the open file description, so it is
/// dropped when this object is deallocated *and* if the process dies — there is
/// no stale lock file to clean up, which is the failure mode a hand-rolled
/// pid-file lock would add.
///
/// The lock file is never read or written; only its existence and its `flock`
/// state matter. It sits beside the store, so two CLIs pointed at *different*
/// stores (the `STENO_STORE_PATH` seam, or a backup directory) do not block each
/// other.
final class CLIWriteLock {
    private let descriptor: Int32

    /// `nil` when another process holds the lock.
    ///
    /// - Throws: nothing. A lock file that cannot be created at all — an
    ///   unwritable directory — returns `nil` too, which fails in the safe
    ///   direction: the import is refused rather than run unprotected. The
    ///   caller cannot tell the two apart, and does not need to: both mean "do
    ///   not write now".
    init?(besideStoreAt storeURL: URL) {
        let path = storeURL.deletingLastPathComponent()
            .appendingPathComponent(".steno-cli.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        // `close` alone releases it — the lock is a property of the open file
        // description — but unlocking first says so out loud.
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// What the user is told when the lock is held.
    static let busyMessage =
        "Another steno command is writing to this store. Wait for it to finish and run this "
        + "again. Nothing was imported."
}
