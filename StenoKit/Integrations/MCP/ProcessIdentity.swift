import Darwin

/// A process, identified so that a reused pid is a different identity.
///
/// **A pid alone is not an identity.** macOS recycles pids, so a ledger entry
/// left by a crash weeks ago may name a pid that now belongs to an unrelated
/// process. The start time is what tells them apart: two processes can share a
/// pid, never a pid *and* a start time (D-236).
struct ProcessIdentity: Codable, Equatable, Sendable {
    let pid: Int32
    /// Seconds and microseconds since the epoch, from `proc_pidinfo`.
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    /// The identity of `pid` as the kernel reports it now, or `nil` when no
    /// such process exists.
    static func current(of pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(
            pid: pid, startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec)
    }

    /// This process.
    static var this: ProcessIdentity? { current(of: getpid()) }

    /// Is the process this identity names still running?
    var isAlive: Bool { Self.current(of: pid) == self }
}

/// Process-group primitives, named for what they mean.
enum ProcessGroup {
    /// Does any process in group `pgid` exist?
    ///
    /// `killpg` with signal 0 checks without sending. `EPERM` means a member
    /// exists that this user may not signal — it exists, so it counts.
    static func hasMembers(_ pgid: Int32) -> Bool {
        if killpg(pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func signal(_ pgid: Int32, _ signal: Int32) {
        _ = killpg(pgid, signal)
    }

    /// Wait up to `timeout` for the group to empty, polling every 10 ms.
    ///
    /// **Polling, deliberately.** There is no kernel notification for "the last
    /// member of a group exited": kqueue watches a pid, and the members of an
    /// `npx` group are not ours to enumerate cheaply. Ten milliseconds is
    /// invisible against a grace period measured in seconds.
    static func waitUntilEmpty(_ pgid: Int32, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while hasMembers(pgid) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
