import Foundation

/// What to run, and how to talk to it.
///
/// **Not persisted, and holds no secret yet.** M5-02 stores definitions and
/// moves environment secrets to the Keychain (§8); this task needs only the
/// value a spawn takes.
public struct MCPServerDefinition: Sendable, Equatable {
    /// Stable identity, logged in place of the command: a command line can
    /// carry a token as an argument, and an id never does.
    public let id: String
    /// A bare name resolved against the child's `PATH`, or a path.
    public let command: String
    public let arguments: [String]
    /// Applied on top of the child's base environment, so it can override
    /// `PATH` among anything else.
    public let environment: [String: String]

    public init(
        id: String, command: String, arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }
}

/// The environment and executable a server is spawned with (D-239).
///
/// **The app's own environment is never passed through.** A Finder-launched
/// app's environment is launchd's, not the user's shell's, so passing it buys
/// nothing; and under `xctest` it carried `OS_ACTIVITY_DT_MODE`, which once
/// made a subprocess test fail for reasons unrelated to what it tested.
struct ChildLaunch: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]

    /// Where Homebrew installs on Apple silicon and on Intel, ahead of the
    /// system directories a Finder-launched app gets.
    static let basePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// The handful of variables a server needs to find its home directory and
    /// a scratch directory, and to decode text.
    static let inheritedKeys = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"]

    /// - Returns: `nil` when the command cannot be resolved to an executable.
    static func resolve(
        _ definition: MCPServerDefinition,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> ChildLaunch? {
        var environment = inheritedKeys.reduce(into: [String: String]()) { result, key in
            result[key] = parentEnvironment[key]
        }
        // **The command's own directory goes first** (D-239, measured
        // 2026-10-09). `npx` is a `#!/usr/bin/env node` script, so it needs
        // `node` on `PATH` as well as being found itself — and an nvm, Volta or
        // asdf install keeps both in one `bin` directory that no fixed list
        // contains. With `PATH=/usr/bin:/bin`, an absolute nvm `npx` fails with
        // `env: node: No such file or directory`; with its own directory
        // prepended it runs. The directory of the path as given, not of its
        // symlink target: nvm's `npx` resolves into `lib/node_modules`, where
        // there is no `node`.
        var path = basePath
        if definition.command.hasPrefix("/") {
            let directory = (definition.command as NSString).deletingLastPathComponent
            path = "\(directory):\(basePath)"
        }
        environment["PATH"] = path
        // An empty key, or one containing `=`, cannot be expressed in an
        // `envp` entry: `A=B=c` reads back as `A` with value `B=c`. Dropped,
        // so the child never sees a variable the user did not write.
        let expressible = definition.environment.filter { !$0.key.isEmpty && !$0.key.contains("=") }
        environment.merge(expressible) { _, override in override }

        guard
            let executable = executablePath(
                for: definition.command, path: environment["PATH"] ?? path,
                isExecutable: isExecutable)
        else { return nil }
        return ChildLaunch(
            executable: executable, arguments: definition.arguments, environment: environment)
    }

    /// An absolute path is used as given; a bare name is searched for on
    /// `path` — **the child's `PATH`, not the app's**, so what the app finds is
    /// what the child would.
    ///
    /// **A relative path is refused.** It would resolve against the app's
    /// working directory, which for a Finder-launched app is `/` — somewhere no
    /// user means when they type `./server`.
    private static func executablePath(
        for command: String, path: String, isExecutable: (String) -> Bool
    ) -> String? {
        if command.contains("/") {
            return command.hasPrefix("/") && isExecutable(command) ? command : nil
        }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/\(command)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
}
