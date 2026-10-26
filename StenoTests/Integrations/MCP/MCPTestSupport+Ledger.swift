import Foundation

@testable import StenoKit

extension MCPStub {
    /// A ledger in a scratch file of its own — never the app's.
    static func ledger(owner: ProcessIdentity? = ProcessIdentity.this) -> ProcessLedger {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-mcp-ledger-\(UUID().uuidString).json")
        return ProcessLedger(fileURL: url, owner: owner)
    }
}
