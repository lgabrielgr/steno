import Foundation

@testable import StenoKit

extension MCPStub {
    /// Short deadlines, so a hang costs a test a fraction of a second. The
    /// startup deadline stays generous: spawning under a parallel suite on a
    /// loaded runner is slow, and this is the deadline a slow start would hit.
    static var fast: MCPServer.Configuration {
        var configuration = MCPServer.Configuration()
        configuration.startupTimeout = .seconds(10)
        configuration.requestTimeout = .seconds(10)
        configuration.pingTimeout = .seconds(10)
        configuration.terminateGrace = .milliseconds(300)
        return configuration
    }

    static func server(
        _ definition: MCPServerDefinition, ledger: ProcessLedger = ledger(),
        configuration: MCPServer.Configuration = fast
    ) -> MCPServer {
        MCPServer(definition: definition, configuration: configuration, ledger: ledger)
    }
}
