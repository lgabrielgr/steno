import Foundation
import SwiftData

/// A reference from a task to an external system (REQUIREMENTS.md §3.4).
///
/// A first-class model rather than an embedded value: it carries its own `id`
/// so it participates in merge-by-UUID import like every other record, and so
/// `lastFetchedAt` / `cachedSummary` survive a round-trip.
@Model
public final class SourceRef {
    public private(set) var id: UUID = UUID()

    /// The authoritative link to the owning task.
    ///
    /// `task` below is the same fact expressed as a SwiftData relationship,
    /// kept for call-site ergonomics. **This field is what export, import, and
    /// M2.5-02's merge read** — see the M0-03 design doc §1.1, and the test
    /// asserting the two never disagree.
    public private(set) var taskID: UUID = UUID()

    public var task: TaskItem?

    public private(set) var kind: SourceRefKind = SourceRefKind.url
    public private(set) var identifier: String = ""
    public private(set) var url: String?
    public private(set) var lastFetchedAt: Date?
    public private(set) var cachedSummary: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        kind: SourceRefKind,
        identifier: String,
        url: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.identifier = identifier
        self.url = url
    }

    /// Record an observation of the external source (§5, §10.1).
    ///
    /// The summary and the timestamp move together because §10.1 resolves them
    /// as a pair — later `lastFetchedAt` wins, and `nil` loses to any value. A
    /// caller able to set the summary without the timestamp could produce a
    /// record the merge cannot order.
    public func recordFetch(summary: String?, at date: Date) {
        cachedSummary = summary
        lastFetchedAt = date
    }
}

extension SourceRef {
    /// The identity a ref is unique on (§3.4).
    ///
    /// This is a uniqueness rule enforced in code, never an
    /// `@Attribute(.unique)` — §6 forbids those.
    public struct DedupKey: Hashable, Sendable {
        public let taskID: UUID
        public let kind: SourceRefKind
        public let identifier: String

        public init(taskID: UUID, kind: SourceRefKind, identifier: String) {
            self.taskID = taskID
            self.kind = kind
            self.identifier = identifier
        }
    }

    public var dedupKey: DedupKey {
        DedupKey(taskID: taskID, kind: kind, identifier: identifier)
    }

    /// The refs in `candidates` that are not already in `existing`, with
    /// duplicates inside `candidates` collapsed.
    ///
    /// Callers insert only what this returns — that is what makes
    /// re-extraction a no-op rather than a new row. Extraction runs on the
    /// title and on every note (FR-1.5), so both halves of the rule earn their
    /// place: the same ticket key recurs across saves *and* within one pass.
    ///
    /// Pure and store-free on purpose, so extraction (M1-01) can apply it
    /// before anything is inserted, and so it is testable without a container.
    ///
    /// `identifier` matches exactly. Normalizing case or whitespace belongs to
    /// extraction; doing it in both places would mean two components decide
    /// what "the same ticket" means.
    public static func newRefs(
        from candidates: [SourceRef],
        existing: [SourceRef]
    ) -> [SourceRef] {
        var seen = Set(existing.map(\.dedupKey))
        var result: [SourceRef] = []
        for candidate in candidates {
            guard seen.insert(candidate.dedupKey).inserted else { continue }
            result.append(candidate)
        }
        return result
    }
}
