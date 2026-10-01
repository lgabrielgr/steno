import Foundation

/// Nested on `ConfluenceClient` rather than free-standing — it is that walk's vocabulary
/// and nothing else's — but in its own file, because `make lint` caps a file at 400 lines
/// and the client had reached it.
extension ConfluenceClient {
    /// Why a version walk stopped.
    ///
    /// **A reason rather than a Bool, because one Bool was being asked to mean three
    /// things** (D-213). `isWindowCapped` is true for the page cap, for a cursor that did
    /// not advance, and for a `next` with no usable cursor — so a log line and a
    /// verification message that both said "hit the page cap" were wrong two thirds of the
    /// time, and a human reading either would have gone looking for a long page history
    /// that was not the problem. Raised by Copilot in review of PR #44.
    /// Internal rather than private so `WalkStopTests` can assert the lines themselves.
    /// Prose about log messages is what this review round kept finding wrong; a test is
    /// the only form of that claim which cannot drift.
    enum WalkStop {
        /// The window ended: a page older than `since`, or no `next` to follow.
        case windowEnd
        case pageCap
        case repeatedCursor
        case unusableNext

        /// Whether the walk covered everything it set out to. Only `windowEnd` does.
        var isComplete: Bool { self == .windowEnd }

        /// What the log says. Each ends the same way, because the consequence is the same
        /// whatever the cause: the oldest versions in the window were not read, and the
        /// watermark is held so the fetch does not claim they were.
        var logLine: String {
            let held = "the watermark is held at the oldest version read"
            switch self {
            case .windowEnd: return ""
            case .pageCap:
                return
                    "confluence version paging hit the \(ConfluenceClient.maxPages)-page cap for one ref; \(held)"
            case .repeatedCursor:
                return
                    "confluence version paging stopped for one ref: the cursor did not advance; \(held)"
            case .unusableNext:
                return
                    "confluence version paging stopped for one ref: `_links.next` carried no usable cursor; \(held)"
            }
        }
    }
}
