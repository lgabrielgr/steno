import Foundation

/// What the last auto-export did, persisted so a failure survives the process
/// that suffered it.
///
/// **One value in one `UserDefaults` key, not four keys.** A quit-time failure
/// has no UI left to display it — the app is terminating — so the record has to
/// outlive the process and be read at the next launch. Splitting it into
/// separate timestamp and message keys would make two half-written records
/// representable, and the pair that disagrees is exactly the one a user would
/// read as "the backup is fine" while it is not.
///
/// `Codable` into `Data` for `AppSettings.hotkeyChord`'s reason: the facade
/// already encodes a struct that way, and a value `defaults read` cannot show
/// as plain text is an acceptable price for a record that cannot be half
/// present.
public struct AutoExportStatus: Codable, Equatable, Sendable {
    /// Where the last successful export went, and when.
    public struct Success: Codable, Equatable, Sendable {
        public let writtenAt: Date
        public let path: String

        public init(writtenAt: Date, path: String) {
            self.writtenAt = writtenAt
            self.path = path
        }
    }

    /// Why the last attempt failed, in the sentence the user sees.
    ///
    /// The message is stored rather than an error code: the sentence is written
    /// where the failure happens, by the code that knows whether the *store* or
    /// the *file* was the problem, and a code would force every reader to
    /// reconstruct that distinction from less information.
    public struct Failure: Codable, Equatable, Sendable {
        public let failedAt: Date
        public let message: String

        public init(failedAt: Date, message: String) {
            self.failedAt = failedAt
            self.message = message
        }
    }

    public var lastSuccess: Success?

    /// **Cleared by a success, and by nothing else.** Not by dismissing a
    /// banner, not by opening Settings: §10.5 makes silent failure the one
    /// unacceptable behaviour, and with sync cancelled (D1, §14) a stale
    /// "auto-export failed" is the user's only signal that they have no backup.
    public var lastFailure: Failure?

    public init(lastSuccess: Success? = nil, lastFailure: Failure? = nil) {
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
    }

    /// The sentence every surface shows, or `nil` when the last attempt worked.
    public var problem: String? { lastFailure?.message }
}
