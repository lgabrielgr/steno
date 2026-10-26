import Darwin
import Foundation

/// A server process in a process group of its own (D-235).
///
/// **`posix_spawn`, not `Foundation.Process`,** for two flags `Process` does
/// not expose:
///
/// - `POSIX_SPAWN_SETPGROUP` makes the child a group leader, so one `killpg`
///   reaches everything it started. `npx` runs the server as a `node` child,
///   and killing `npx` alone leaves `node` running — the leak this task exists
///   to prevent, on exactly the servers M5-03 needs.
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT` gives the child stdin, stdout and stderr and
///   nothing else. Without it a server inherits every descriptor the app has
///   open, including another server's pipes — and a server holding a copy of a
///   second server's stdout keeps that pipe open after the second one dies, so
///   its EOF never arrives.
///
/// Three threads per process, none from the cooperative pool: one blocked in
/// `waitpid` and one in `read` per output pipe. Blocking is what they are for,
/// and blocking a pool thread is what this design exists to avoid (D-238).
final class SpawnedProcess: @unchecked Sendable {
    /// The process id, which is also its group id.
    let pid: Int32
    let identity: ProcessIdentity
    let standardOutput: AsyncStream<Data>
    let standardError: AsyncStream<Data>

    /// The raw `waitpid` status, once the leader has exited and been reaped.
    let exitStatus: Task<Int32, Never>

    private let stdinFD: Int32
    /// Writes block, deliberately, on this queue and nowhere else (D-238).
    private let writer: DispatchQueue
    /// Read and written only on `writer`, whose serial order is its lock: a
    /// close can never interleave with a write in progress.
    private var stdinClosed = false

    private init(
        pid: Int32, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32
    ) {
        self.pid = pid
        // A process that has already exited may not report a start time; the
        // zero identity can then never match a live leader, so a reap treats
        // it by group membership alone — which is the right answer for a
        // process that is gone.
        identity =
            ProcessIdentity.current(of: pid)
            ?? ProcessIdentity(pid: pid, startSeconds: 0, startMicroseconds: 0)
        self.stdinFD = stdinFD
        writer = DispatchQueue(label: "com.lgabrielgr.steno.mcp.writer.\(pid)")
        standardOutput = Self.reader(stdoutFD)
        standardError = Self.reader(stderrFD)
        exitStatus = Self.waiter(pid)
    }

    /// Spawn `launch` in a new process group with only fds 0, 1 and 2.
    static func spawn(_ launch: ChildLaunch) throws(MCPError) -> SpawnedProcess {
        let pipes = try makePipes()
        var pid: pid_t = 0
        let variables = launch.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let result = withSpawnAttributes(pipes: pipes) { actions, attributes in
            withCStrings([launch.executable] + launch.arguments) { argv in
                withCStrings(variables) { envp in
                    posix_spawn(&pid, launch.executable, &actions, &attributes, argv, envp)
                }
            }
        }
        // The child's ends belong to the child now (or to nobody, on failure).
        close(pipes.stdin.read)
        close(pipes.stdout.write)
        close(pipes.stderr.write)

        guard result == 0 else {
            close(pipes.stdin.write)
            close(pipes.stdout.read)
            close(pipes.stderr.read)
            switch result {
            case ENOENT, EACCES, ENOEXEC: throw .commandNotFound
            default: throw .launchFailed(errno: result)
            }
        }
        return SpawnedProcess(
            pid: pid, stdinFD: pipes.stdin.write, stdoutFD: pipes.stdout.read,
            stderrFD: pipes.stderr.read)
    }

    /// Write `data` to the child's stdin, blocking the writer queue — never the
    /// caller — until it is accepted or the pipe breaks.
    ///
    /// **A blocking write on a queue of its own, not `O_NONBLOCK`** (D-238). A
    /// wedged server stops reading and its pipe buffer fills; a write that
    /// blocks there blocks only this queue, while the request awaiting it is
    /// resumed by its deadline. The write unblocks when the group is killed —
    /// the read end closes and the write fails with `EPIPE` — which
    /// `MCPServer` does after any timeout.
    func write(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        writer.async { [self] in
            completion(writeAll(data))
        }
    }

    /// Close the child's stdin — the MCP-specified "please exit" — after any
    /// write already queued.
    func closeStandardInput() {
        writer.async { [self] in
            guard !stdinClosed else { return }
            stdinClosed = true
            close(stdinFD)
        }
    }

    /// Stop the whole group: close stdin, wait, `SIGTERM`, wait, `SIGKILL`.
    ///
    /// Each wait ends as soon as the group is empty. **The group, not the
    /// leader:** `npx` can exit on EOF while its `node` child lingers, and a
    /// stop that only watched the leader would report success over a leak.
    ///
    /// - Returns: `true` once the group is confirmed empty. `false` means the
    ///   budget ran out with a member still alive, and the ledger keeps the
    ///   entry for the next launch.
    func terminate(grace: Duration) async -> Bool {
        closeStandardInput()
        if await ProcessGroup.waitUntilEmpty(pid, timeout: grace) { return true }
        ProcessGroup.signal(pid, SIGTERM)
        if await ProcessGroup.waitUntilEmpty(pid, timeout: grace) { return true }
        ProcessGroup.signal(pid, SIGKILL)
        return await ProcessGroup.waitUntilEmpty(pid, timeout: grace)
    }

    /// `SIGKILL` the group now — for a leader that already crashed, whose
    /// remaining members have no reason to be asked politely.
    func killGroup(timeout: Duration) async -> Bool {
        ProcessGroup.signal(pid, SIGKILL)
        return await ProcessGroup.waitUntilEmpty(pid, timeout: timeout)
    }

    private func writeAll(_ data: Data) -> Bool {
        guard !stdinClosed else { return false }
        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(stdinFD, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    // MARK: - Threads

    private static func reader(_ descriptor: Int32) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    continuation.yield(Data(buffer[0..<count]))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(descriptor)
            continuation.finish()
        }
        thread.name = "com.lgabrielgr.steno.mcp.reader"
        thread.start()
        return stream
    }

    /// Reap the leader, so it never lingers as a zombie, and publish its status.
    private static func waiter(_ pid: Int32) -> Task<Int32, Never> {
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        let thread = Thread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            continuation.yield(status)
            continuation.finish()
        }
        thread.name = "com.lgabrielgr.steno.mcp.waiter"
        thread.start()
        return Task {
            for await status in stream { return status }
            return -1
        }
    }

    // MARK: - posix_spawn plumbing

    private struct Pipe {
        let read: Int32
        let write: Int32
    }

    private struct Pipes {
        let stdin: Pipe
        let stdout: Pipe
        let stderr: Pipe
    }

    private static func makePipes() throws(MCPError) -> Pipes {
        var made: [Pipe] = []
        for _ in 0..<3 {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                let failure = errno
                for pipe in made {
                    close(pipe.read)
                    close(pipe.write)
                }
                throw .launchFailed(errno: failure)
            }
            // Close-on-exec in the parent too: a process spawned elsewhere in
            // the app, by something without `POSIX_SPAWN_CLOEXEC_DEFAULT`, must
            // not inherit a server's pipe and hold it open.
            for descriptor in fds { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            made.append(Pipe(read: fds[0], write: fds[1]))
        }
        // A write to a server that has exited raises `SIGPIPE`, whose default
        // action terminates the *writer* — the app. This turns it into `EPIPE`
        // on this descriptor alone, so a crashed server cannot take the app
        // down with it (the task's second criterion).
        _ = fcntl(made[0].write, F_SETNOSIGPIPE, 1)
        return Pipes(stdin: made[0], stdout: made[1], stderr: made[2])
    }

    private static func withSpawnAttributes(
        pipes: Pipes,
        _ body: (inout posix_spawn_file_actions_t?, inout posix_spawnattr_t?) -> Int32
    ) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipes.stdin.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes.stdout.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipes.stderr.write, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Group 0 means "a new group whose id is the child's pid".
        posix_spawnattr_setpgroup(&attributes, 0)
        // Signal dispositions the app set — an ignored `SIGPIPE`, say — would
        // otherwise survive `exec` into the server. Reset all, block none.
        var everything = sigset_t()
        sigfillset(&everything)
        posix_spawnattr_setsigdefault(&attributes, &everything)
        var nothing = sigset_t()
        sigemptyset(&nothing)
        posix_spawnattr_setsigmask(&attributes, &nothing)
        let flags =
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))

        return body(&actions, &attributes)
    }

    /// A `NULL`-terminated `char *[]` that lives for the duration of `body`.
    private static func withCStrings<R>(
        _ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R
    ) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer {
            for pointer in pointers { free(pointer) }
        }
        return body(pointers)
    }
}
