import Foundation
import Testing

@testable import StenoKit

@Suite struct ChildLaunchTests {
    private let parent = [
        "HOME": "/Users/someone", "TMPDIR": "/tmp/x/", "PATH": "/parent/only",
        "OS_ACTIVITY_DT_MODE": "YES", "SECRET_FROM_APP": "x",
    ]

    @Test("only the allowlisted variables reach the child")
    func environmentIsMinimal() throws {
        let launch = try #require(
            ChildLaunch.resolve(
                MCPServerDefinition(id: "s", command: "sh"), parentEnvironment: parent))
        #expect(launch.environment["HOME"] == "/Users/someone")
        #expect(launch.environment["TMPDIR"] == "/tmp/x/")
        #expect(launch.environment["OS_ACTIVITY_DT_MODE"] == nil)
        #expect(launch.environment["SECRET_FROM_APP"] == nil)
        // The app's PATH is not the child's.
        #expect(launch.environment["PATH"] == ChildLaunch.basePath)
    }

    @Test("a bare name resolves on the child's PATH, not the app's")
    func bareNameUsesChildPath() throws {
        let launch = try #require(
            ChildLaunch.resolve(
                MCPServerDefinition(id: "s", command: "npx"), parentEnvironment: parent,
                isExecutable: { $0 == "/usr/local/bin/npx" || $0 == "/parent/only/npx" }))
        #expect(launch.executable == "/usr/local/bin/npx")
    }

    @Test("a path's own directory goes first on PATH, so a script finds its interpreter")
    func commandDirectoryLeadsPath() throws {
        let npx = "/Users/someone/.nvm/versions/node/v22/bin/npx"
        let launch = try #require(
            ChildLaunch.resolve(
                MCPServerDefinition(id: "s", command: npx), parentEnvironment: parent,
                isExecutable: { $0 == npx }))
        #expect(launch.executable == npx)
        #expect(
            launch.environment["PATH"]
                == "/Users/someone/.nvm/versions/node/v22/bin:\(ChildLaunch.basePath)")
    }

    @Test("the definition's PATH overrides the base, and resolution follows it")
    func definitionOverridesPath() throws {
        let definition = MCPServerDefinition(
            id: "s", command: "server", environment: ["PATH": "/custom", "TOKEN": "t"])
        let launch = try #require(
            ChildLaunch.resolve(
                definition, parentEnvironment: parent,
                isExecutable: { $0 == "/custom/server" }))
        #expect(launch.executable == "/custom/server")
        #expect(launch.environment["PATH"] == "/custom")
        #expect(launch.environment["TOKEN"] == "t")
    }

    @Test("an environment key that envp cannot express is dropped")
    func invalidKeysAreDropped() throws {
        let definition = MCPServerDefinition(
            id: "s", command: "sh", environment: ["": "x", "A=B": "c", "GOOD": "yes"])
        let launch = try #require(ChildLaunch.resolve(definition, parentEnvironment: parent))
        #expect(launch.environment["GOOD"] == "yes")
        #expect(launch.environment[""] == nil)
        #expect(launch.environment["A=B"] == nil)
    }

    @Test("a relative command path is refused, even if it exists from here")
    func relativePathIsRefused() {
        #expect(
            ChildLaunch.resolve(
                MCPServerDefinition(id: "s", command: "./server"), parentEnvironment: parent,
                isExecutable: { _ in true }) == nil)
    }

    @Test("a command that resolves nowhere is nil")
    func unresolvable() {
        #expect(
            ChildLaunch.resolve(
                MCPServerDefinition(id: "s", command: "no-such-server-xyz"),
                parentEnvironment: parent) == nil)
    }
}
