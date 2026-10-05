import Foundation
import Testing

@testable import StenoKit

/// The Integrations pane's model, its credential store and its settings.
///
/// **A type rather than a 3-tuple**, which SwiftLint's `large_tuple` refuses at
/// three members — and which read worse at every call site anyway.
@MainActor
struct IntegrationsFixture {
    let model: IntegrationsSettingsModel
    let store: InMemoryAtlassianStore
    let settings: AppSettings

    /// 2023-11-14 22:13:20 UTC. A fixed instant, so every expiry boundary is
    /// arithmetic the reader can check by hand.
    nonisolated static let now = Date(timeIntervalSince1970: 1_700_000_000)
    nonisolated static let day: TimeInterval = 24 * 60 * 60

    init(
        credential: AtlassianCredential? = nil,
        readError: (any Error)? = nil,
        writeError: (any Error)? = nil,
        connectors: [any SourceConnector] = [
            StubSourceConnector(id: "jira", displayName: "Jira")
        ],
        purge: SourceCachePurge? = nil,
        clock: Date = IntegrationsFixture.now
    ) throws {
        store = InMemoryAtlassianStore(credential, readError: readError, writeError: writeError)
        let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        self.settings = settings
        model = IntegrationsSettingsModel(
            credentials: store,
            registry: SourceRegistry(
                connectors: connectors, isEnabled: { settings.isIntegrationEnabled($0) }),
            settings: settings,
            purge: purge,
            now: { clock })
    }

    /// A registry over the same settings, for asserting that a toggle reaches
    /// routing in the same process.
    func registry(_ connectors: [any SourceConnector]) -> SourceRegistry {
        let settings = self.settings
        return SourceRegistry(
            connectors: connectors, isEnabled: { settings.isIntegrationEnabled($0) })
    }
}
