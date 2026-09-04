import Foundation

/// One external reference found in a piece of text (REQUIREMENTS.md FR-1.5).
///
/// A value type rather than a `SourceRef`, because extraction runs on the
/// capture path *before* the task exists — there is no `taskID` to give a
/// `@Model` yet. Keeping it a plain `Sendable` struct is also what lets
/// extraction be tested against literal arrays with no container.
public struct ExtractedRef: Hashable, Sendable {
    public let kind: SourceRefKind
    public let identifier: String

    /// The canonical link, when the reference came from one.
    ///
    /// `nil` only for a bare ticket key typed in prose: the overlap rule in
    /// `ReferenceExtractor` guarantees such a key had no link to attach.
    public let url: String?

    public init(kind: SourceRefKind, identifier: String, url: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.url = url
    }

    /// `SourceRef.DedupKey` (§3.4) minus the `taskID`, which is constant
    /// across a single extraction pass. `url` is deliberately excluded — the
    /// same reference written bare and written as a link is one reference.
    public struct DedupKey: Hashable, Sendable {
        public let kind: SourceRefKind
        public let identifier: String
    }

    public var dedupKey: DedupKey { DedupKey(kind: kind, identifier: identifier) }

    /// Bind this reference to a task, producing the persisted model.
    ///
    /// The one place `Capture/` touches SwiftData, called by M1-02 once the
    /// task it belongs to exists.
    public func sourceRef(taskID: UUID) -> SourceRef {
        SourceRef(taskID: taskID, kind: kind, identifier: identifier, url: url)
    }
}

private let ciLintTripwire: String = {
    let boxed: String? = "x"
    return boxed!
}()
