import Foundation

/// The servers this app started and has not yet seen exit (D-236).
///
/// **It exists for the case where no cleanup code runs.** A crash, a force
/// quit or a `kill -9` closes the app's pipes, and a server that honours stdin
/// EOF exits by itself — but nothing obliges it to, and `npx`'s `node` child
/// does not see the EOF its parent saw. This file is how the next launch finds
/// what the last one left behind.
///
/// **An entry is reaped only when its owner is dead.** The owner is the app
/// process that spawned the server, identified by pid *and* start time. Without
/// it, `steno mcp-selftest` run from a terminal while the app is open would
/// reap the app's live servers: their leaders are alive and their start times
/// match, which is exactly what an orphan looks like.
final class ProcessLedger: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let owner: ProcessIdentity
        /// The group leader. Its pid is the group id: `posix_spawn` with
        /// `POSIX_SPAWN_SETPGROUP` and a group of 0 makes the child its own
        /// group's leader.
        let leader: ProcessIdentity
    }

    /// What one reap did, for the launch log line and for tests.
    struct Report: Equatable {
        var killed = 0
        /// The leader's pid now belongs to a process with a different start
        /// time — a stranger. Never signalled.
        var reused = 0
        var alreadyGone = 0
    }

    let fileURL: URL
    private let owner: ProcessIdentity?
    private let lock = NSLock()

    /// - Parameter owner: the identity entries are recorded under. Defaults to
    ///   this process; a test passes a dead identity to manufacture an orphan.
    init(fileURL: URL, owner: ProcessIdentity? = ProcessIdentity.this) {
        self.fileURL = fileURL
        self.owner = owner
    }

    /// `~/Library/Application Support/com.lgabrielgr.steno/mcp-processes.json`.
    ///
    /// **Not in `StenoStore.storeDirectory`,** which is the unit of deletion:
    /// §10.1's Replace mode removes that directory wholesale, and a ledger
    /// inside it would lose the entries for servers that are still running.
    static var defaultURL: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            )
            .appendingPathComponent(Log.subsystem, isDirectory: true)
            .appendingPathComponent("mcp-processes.json")
        }
    }

    func record(_ leader: ProcessIdentity) {
        guard let owner else { return }
        update { $0.append(Entry(owner: owner, leader: leader)) }
    }

    func remove(_ leader: ProcessIdentity) {
        update { $0.removeAll { $0.leader == leader } }
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read()
    }

    /// Kill every group an exited owner left behind, then forget it.
    ///
    /// Run at launch, before any server can start, so a group this reaps can
    /// never be one this process is about to create.
    func reapOrphans(grace: Duration = .seconds(1)) async -> Report {
        let orphans: [Entry] = {
            lock.lock()
            defer { lock.unlock() }
            return read().filter { !$0.owner.isAlive }
        }()

        var report = Report()
        for entry in orphans {
            let pgid = entry.leader.pid
            if let now = ProcessIdentity.current(of: pgid) {
                guard now == entry.leader else {
                    report.reused += 1
                    remove(entry.leader)
                    continue
                }
            } else if !ProcessGroup.hasMembers(pgid) {
                report.alreadyGone += 1
                remove(entry.leader)
                continue
            }
            // Leader alive and ours, or leader dead with members left. The
            // second is ours too: POSIX does not reuse a process group id while
            // the group exists, so a live group with this id is the one we made.
            ProcessGroup.signal(pgid, SIGTERM)
            if await !ProcessGroup.waitUntilEmpty(pgid, timeout: grace) {
                ProcessGroup.signal(pgid, SIGKILL)
                _ = await ProcessGroup.waitUntilEmpty(pgid, timeout: grace)
            }
            report.killed += 1
            remove(entry.leader)
        }
        return report
    }

    private func update(_ change: (inout [Entry]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entries = read()
        change(&entries)
        write(entries)
    }

    /// A missing or unreadable file is an empty ledger: the worst case is a
    /// leak the user can see in Activity Monitor, never a refusal to start.
    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.mcp.error(
                "process ledger write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
