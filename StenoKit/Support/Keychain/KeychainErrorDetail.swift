import Foundation

/// What is safe to show about an error that came from a credential store (§8).
///
/// **A `KeychainError` is an `OSStatus` and a case name, and anything else is not
/// known to be tame.** A `DecodingError` or an `EncodingError` describes itself by
/// quoting the value it choked on — which, on every path that reaches here, is a
/// credential. So an unrecognised error is named by *type* only.
///
/// **One implementation, because there were three and then a fourth got it wrong**
/// (Copilot, PR #45). `AISettingsModel.detail(for:)` and
/// `IntegrationsSettingsModel.detail(for:)` had already written this rule, and
/// `IntegrationsSelftest` then printed `String(describing: error)` straight into a
/// harness whose stated guarantee is that the token never appears on any path. A
/// rule spelled out at each call site is a rule the next call site can skip.
///
/// `nonisolated` and free-standing on purpose: the two models are `@MainActor`, so a
/// static on either is isolated to it and unreachable from `CLISync`'s detached
/// context — which is how the harness came to have its own, worse version.
enum KeychainErrorDetail {
    /// `error` as a string that cannot contain a credential.
    static func of(_ error: any Error) -> String {
        guard let keychainError = error as? KeychainError else {
            return String(describing: type(of: error))
        }
        return String(describing: keychainError)
    }
}
