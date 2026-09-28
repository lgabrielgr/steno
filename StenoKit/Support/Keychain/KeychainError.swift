import Foundation
import Security

/// A Keychain failure, as something a caller can switch on.
///
/// **Kept out of both `AIError` and `SourceError` on purpose** (D-189):
/// credential storage is its own layer, and each consumer's view of it is
/// narrow — the AI layer's is exactly two outcomes, a credential or none, and
/// the source layer's is the same.
public enum KeychainError: Error, Equatable, Sendable {
    case duplicateItem
    case interactionNotAllowed
    case userCancelled
    case unexpected(OSStatus)

    static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecDuplicateItem: return .duplicateItem
        case errSecInteractionNotAllowed: return .interactionNotAllowed
        case errSecUserCanceled: return .userCancelled
        default: return .unexpected(status)
        }
    }
}
