import Foundation

/// One model a provider will accept, as the app sees it (§7.1).
///
/// **Two fields, and no third.** §7.1 requires the list to be fetched at
/// runtime "so the app doesn't need a release to expose a new model", and the
/// only consumer is M3-04's picker, which renders a name and stores an id.
/// Context windows, pricing and tier are all things a vendor response carries
/// and nothing here reads — and a field added now is one M3-02 must populate
/// for every model, correctly, with no test able to say it got it wrong.
///
/// M3-02 picks its own mid-tier default from the fetched list; §7.1 puts that
/// choice in the provider, not in a flag on the model.
public struct AIModel: Sendable, Equatable, Identifiable {
    /// The vendor's model id, sent back on the next request verbatim.
    public let id: String

    /// What Settings shows. May equal `id` when a provider offers nothing better.
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
