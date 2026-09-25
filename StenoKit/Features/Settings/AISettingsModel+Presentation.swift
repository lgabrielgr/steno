import Foundation

/// Everything the AI pane *reads*: the picker's rows, the state of the
/// selection, whether the AI will actually run, and what a failure means.
///
/// Split from `AISettingsModel` because it answers a different question from
/// the state and the actions — "what does the pane draw right now" rather than
/// "what happened" — and because one file carrying all three runs past
/// SwiftLint's 400-line limit. It is one type in three files, the arrangement
/// `MainWindowModel` already uses.
///
/// **None of it is stored.** Every property here is derived from the state next
/// door, so no two facts about the same thing can disagree — the reason
/// `SettingsModel.chord` reads straight from the binding rather than mirroring
/// it.
extension AISettingsModel {
    /// What the user can do about a failure.
    ///
    /// **Lives here rather than in the pane's `if` statements** for
    /// `DataSettingsModel.canBackUpNow`'s reason: the unhosted test bundle
    /// cannot reach the app target (D-010), so a rule only a view knows is a
    /// rule no test can hold. The third acceptance criterion — "Test
    /// connection" distinguishes an invalid key from a network failure — is
    /// exactly such a rule.
    public enum Advice: Equatable, Sendable {
        /// The key is wrong or missing. The field above is the fix.
        case fixTheKey
        /// Nothing here is wrong. Try again later.
        case tryAgainLater
    }

    /// What the model picker shows.
    ///
    /// **The stored selection is always a row, even when the list does not
    /// contain it** — because it has not been fetched yet (D-158), because the
    /// network is unreachable, or because the vendor retired the model. This is
    /// the second acceptance criterion: an unreachable model list must not
    /// block using a previously selected model. The selection is never
    /// reassigned by a fetch that fails to mention it; `saveKey()` is the only
    /// path that re-points it, and only onto element zero (D-159).
    public var modelRows: [AIModel] {
        guard let selectedModelID, !models.contains(where: { $0.id == selectedModelID }) else {
            return models
        }
        return [AIModel(id: selectedModelID, displayName: selectedModelID)] + models
    }

    /// Where the selected model stands against the list that was fetched.
    ///
    /// **Three cases, because the pane has three different things to say.** An
    /// unlisted selection before any fetch is D-158's ordinary state ("we have
    /// not asked"); an unlisted selection *after* a fetch means the provider
    /// retired the model, and telling that user the list has not been fetched
    /// sends them to a Refresh button that cannot help them.
    public enum SelectionStatus: Equatable, Sendable {
        /// Nothing is selected.
        case none
        /// The fetched list contains it.
        case offered
        /// No list has been fetched yet (D-158).
        case notFetchedYet
        /// A list was fetched and does not contain it.
        case noLongerOffered
    }

    public var selectionStatus: SelectionStatus {
        guard let selectedModelID else { return .none }
        if models.contains(where: { $0.id == selectedModelID }) { return .offered }
        return hasFetchedModels ? .noLongerOffered : .notFetchedYet
    }

    /// Whether the selected model is a row the provider did not offer.
    public var selectionIsUnlisted: Bool {
        selectionStatus == .notFetchedYet || selectionStatus == .noLongerOffered
    }

    /// Whether the AI path will actually run, and why not when it will not.
    ///
    /// **The same two conditions `MainWindowModel.standupPolish` reads**, which
    /// is the point: it builds a provider over the Keychain and passes
    /// `settings.aiSelectedModelID`, and `StandupSummarizer` takes §7.4's raw
    /// path unless both are present. A pane that answered "configured?" from
    /// different evidence would drift from what the stand-up actually does.
    ///
    /// Lives here rather than in the pane's `if` statements because the
    /// unhosted test bundle cannot reach the app target (D-010) — the same
    /// reasoning `DataSettingsModel.canBackUpNow` records.
    public enum Readiness: Equatable, Sendable {
        /// A key is stored and a model is selected. Carries what the picker
        /// shows, so the line names the model rather than an opaque id.
        case ready(model: String)
        /// No credential for this provider.
        case noKey
        /// The Keychain refused the read, so whether a key exists is unknown.
        ///
        /// **Not `.noKey`.** The remedy is to unlock the keychain, not to paste
        /// another key, and a line that said "add a key below" would send a
        /// user with a perfectly good key to do the one thing that cannot help.
        /// `keyProblem` carries the detail. Raised by Copilot on PR #41.
        case keyUnreadable
        /// A credential, but the user has not chosen a model — the state a
        /// first key saved while offline leaves behind (D-159).
        ///
        /// **Carries whether there is anything to choose from**, because the
        /// remedy differs and D-159 is why: a refresh deliberately adopts no
        /// default, so a successful refresh leaves a populated picker and no
        /// selection. Telling that user to press Refresh again is a loop with
        /// no exit. Raised by Copilot on PR #41.
        case noModel(canChooseNow: Bool)
    }

    public var readiness: Readiness {
        if case .unreadable = storedKey { return .keyUnreadable }
        guard hasStoredKey else { return .noKey }
        guard let selectedModelID else { return .noModel(canChooseNow: !models.isEmpty) }
        // `modelRows` always contains the selection, synthesised from the id
        // when no list has been fetched, so this is a display name when one is
        // known and the id otherwise — never blank.
        return .ready(
            model: modelRows.first { $0.id == selectedModelID }?.displayName ?? selectedModelID)
    }

    /// Whether a network call is in flight. The pane disables its buttons on it.
    public var isBusy: Bool {
        isSavingKey || listState == .loading || connection == .testing
    }

    /// What the user should do about the last failed fetch, if it failed.
    public var listAdvice: Advice? {
        guard case .failed(let error) = listState else { return nil }
        return Self.advice(for: error)
    }

    /// What the user should do about the last connection test, if it failed.
    public var connectionAdvice: Advice? {
        guard case .failed(let error) = connection else { return nil }
        return Self.advice(for: error)
    }

    /// The third acceptance criterion, as a function.
    ///
    /// `.invalidCredential` and `.notConfigured` point at the field above;
    /// everything else is not something this pane can fix. The *sentence* the
    /// user reads stays `AIError.errorDescription` — a second vocabulary here
    /// would be a second place for "the provider rejected this credential" to
    /// be worded, free to drift from the one M3-02 already ships.
    static func advice(for error: AIError) -> Advice {
        switch error {
        case .notConfigured, .invalidCredential:
            return .fixTheKey
        case .invalidRequest, .network, .timedOut, .rateLimited, .providerUnavailable,
            .invalidResponse, .unknownTaskIDs:
            return .tryAgainLater
        }
    }
}
