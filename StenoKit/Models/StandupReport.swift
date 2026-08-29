import Foundation
import SwiftData

/// A stand-up report as it was copied (REQUIREMENTS.md §3.5).
///
/// A record of something that happened, so nothing but `isUndone` changes after
/// creation. FR-4.1 requires the row be retained and marked, never deleted —
/// and undo reads the previous `lastStandupAt` back out of `windowStart`, so
/// the window has to survive too.
@Model
public final class StandupReport {
    public private(set) var id: UUID = UUID()
    public private(set) var projectID: UUID = UUID()
    public private(set) var generatedAt: Date = Date.now

    /// The previous `lastStandupAt`, or 24h before now on a project's first
    /// report (FR-4 step 2).
    public private(set) var windowStart: Date = Date.now
    public private(set) var windowEnd: Date = Date.now

    /// The final text as copied.
    public private(set) var markdownBody: String = ""

    /// False when §7.4's deterministic fallback produced this report.
    public private(set) var wasAIGenerated: Bool = false

    /// For debugging quality regressions; nil for a fallback report.
    public private(set) var modelUsed: String?

    /// Set by FR-4.1's undo. The row is retained and excluded from history.
    public private(set) var isUndone: Bool = false

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        generatedAt: Date,
        windowStart: Date,
        windowEnd: Date,
        markdownBody: String,
        wasAIGenerated: Bool,
        modelUsed: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.markdownBody = markdownBody
        self.wasAIGenerated = wasAIGenerated
        self.modelUsed = modelUsed
    }

    /// Mark this report undone, retaining the row (FR-4.1).
    func markUndone() {
        isUndone = true
    }
}
