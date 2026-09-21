import Foundation

/// §7.1's provider abstraction, so another AI provider can be plugged in.
///
/// **No Anthropic-specific type appears in any signature here**, and §14 keeps
/// this protocol for that reason alone: it is what lets M3-03's summarization be
/// tested with networking denied (§9.4). A protocol that leaked a vendor type
/// would defeat the only justification it has.
///
/// **`Sendable` is added to §7.1's printed signature.** The spec prints the
/// protocol without a conformance, but `SWIFT_VERSION` is 6.0 and
/// `generateStandup` is awaited across an isolation boundary, so a
/// non-`Sendable` provider cannot be held by the caller that awaits it. This is
/// the same reasoning `GatheredWindow` already records for returning value types
/// rather than `@Model` rows. Declared in the PR body rather than absorbed
/// silently, per CLAUDE.md.
///
/// **The error contract: an implementation throws `AIError` and nothing else.**
/// A `URLError` or a `DecodingError` escaping a provider is a defect in that
/// provider — §7.4 must be able to degrade on any failure, and it cannot switch
/// on an error type it has never heard of.
///
/// §13: this layer and `SourceConnector` are independent. Nothing here may
/// reference an integration, and M4 must not reference this.
public protocol AIProvider: Sendable {
    /// Stable across launches — it keys the Keychain item (`CredentialStore`).
    var id: String { get }

    /// What Settings shows.
    var displayName: String { get }

    /// §7.1: fetched at runtime, never hardcoded, so a new model needs no release.
    func availableModels() async throws -> [AIModel]

    /// Summarize a window.
    ///
    /// The returned draft has already been through
    /// `StandupDraft.validated(against:)` with `request.allowedTaskIDs` — §7.3's
    /// hallucinated-id rejection is the provider's job, not the caller's, so
    /// that a second provider inherits it instead of re-deriving it.
    func generateStandup(_ request: StandupRequest) async throws -> StandupDraft

    /// Verify the stored credential.
    ///
    /// Must distinguish a rejected key (`.invalidCredential`) from an
    /// unreachable network (`.network`): the user needs to know which, and
    /// "Test connection" that says only "failed" tells them nothing actionable.
    func testConnection() async throws
}
