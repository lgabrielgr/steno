import Foundation

/// The AI pane's credential half: §8's rules, in the file that owns them.
///
/// Split from `AISettingsModel` because the two halves are separate subjects —
/// what happens to the key, and what happens to the model list — and because
/// one file carrying both runs past SwiftLint's 400-line limit. Nothing here is
/// reachable without the state declared there; this is one type in two files,
/// the arrangement `MainWindowModel` already uses for FR-4.
extension AISettingsModel {
    /// Store what the user typed, then fetch the list and adopt a default.
    ///
    /// **`async`, and awaited by the pane inside a `Task`** — not a method that
    /// starts a detached task of its own. A `Task` has not started when the
    /// function that created it returns, so a test of the second shape can only
    /// poll; awaiting this directly removes the question.
    ///
    /// Whitespace is trimmed because the common way to produce a key is a paste
    /// from a web page, which brings a trailing newline with it; an all-blank
    /// entry stores nothing, since `UserDefaults`-shaped "it saved!" feedback
    /// for an empty key would be a lie the user only discovers at a stand-up.
    public func saveKey() async {
        guard let provider else { return }
        let trimmed = keyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try credentials.store(.apiKey(trimmed), for: provider.id)
        } catch {
            // The error, not a generic sentence: `errSecInteractionNotAllowed`
            // (a locked keychain) needs a different action from a bug in this
            // app. Narrowed by `detail(for:)`, because the value that reaches
            // this `catch` is an `any Error` and only a `KeychainError` is
            // known not to quote the credential.
            keyProblem = "macOS refused to store the key: \(Self.detail(for: error))."
            return
        }

        keyProblem = nil
        keyEntry = ""
        hasStoredKey = true
        connection = .untested
        await fetchModels(adoptingRecommendedDefault: true)
    }

    /// Drop whatever is in the key field without storing it.
    ///
    /// Called by the pane on appear and on disappear, which is what makes
    /// D-157's "the field is empty on every appearance" true of a model that
    /// outlives every appearance. It is also the only thing that takes an
    /// unsaved key out of memory before the process ends.
    public func forgetEntry() {
        keyEntry = ""
    }

    /// Delete the stored credential (§8's only removal path in the UI).
    ///
    /// **`aiSelectedModelID` is left alone.** A model id is not a secret, the
    /// picker should not lose its place because a key was rotated, and
    /// re-entering a key restores the previous behaviour with nothing to redo.
    /// §7.4 covers the interval: the provider throws `.notConfigured` and the
    /// stand-up is M2-02's raw report.
    public func removeKey() {
        guard let provider else { return }
        do {
            try credentials.delete(for: provider.id)
        } catch {
            keyProblem = "macOS refused to remove the key: \(Self.detail(for: error))."
            return
        }
        keyProblem = nil
        keyEntry = ""
        hasStoredKey = false
        models = []
        listState = .idle
        connection = .untested
    }

    /// What the Keychain says about the selected provider's credential.
    ///
    /// **A presence check whose answer is never the value.** The `Credential`
    /// read here is compared against `nil` and goes no further; nothing assigns
    /// it, and no property of this type can hold it (D-157).
    ///
    /// **A refused read is its own case, not "absent".** `AnthropicProvider`
    /// collapses the two because its caller's remedy is the same either way; a
    /// Settings pane's is not — a locked keychain is unlocked, not re-keyed —
    /// and the pane would otherwise state as fact that no key is stored.
    enum StoredKeyState: Equatable {
        case present
        case absent
        case unreadable(String)
    }

    static func storedKey(in store: any CredentialStore, for providerID: String)
        -> StoredKeyState
    {
        guard !providerID.isEmpty else { return .absent }
        do {
            return try store.credential(for: providerID) == nil ? .absent : .present
        } catch {
            return .unreadable(detail(for: error))
        }
    }

    /// What is safe to render about an error that is not known to be tame.
    ///
    /// A `KeychainError` is an `OSStatus` and a case name. Anything else could
    /// be an `EncodingError` quoting the credential it failed on, so only its
    /// type name is shown — the narrowing `ModelsSelftest.describe` makes for
    /// the same reason (§8).
    static func detail(for error: any Error) -> String {
        guard let keychainError = error as? KeychainError else {
            return String(describing: type(of: error))
        }
        return String(describing: keychainError)
    }
}
