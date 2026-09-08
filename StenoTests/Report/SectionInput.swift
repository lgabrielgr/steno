import Foundation

@testable import StenoKit

/// Literal `GatheredWindow`s for the renderer's tests.
///
/// **No store, no `ModelContainer`, no `ReportFixture`.** `GatheredWindow`,
/// `GatheredTask` and `GatheredEvent` all have public initialisers (D-065), so
/// every case here is literals in and a string out. That is the point of the
/// value-snapshot type, and it keeps this suite independent of SwiftData's
/// behaviour entirely.
///
/// An `enum` namespace rather than free functions because `task` and `window`
/// are exactly the names a future test file would also want at module scope.
enum SectionInput {
    /// Timestamps are arbitrary: no bullet carries one (D-073), so nothing in
    /// the renderer reads them. Event *order* is what matters, and that is the
    /// order of the array passed to `task`.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    static func event(_ body: String, kind: EventKind = .note) -> GatheredEvent {
        GatheredEvent(timestamp: origin, kind: kind, body: body)
    }

    static func task(
        _ title: String,
        status: Status = .todo,
        ticketKeys: [String] = [],
        blockedReason: String? = nil,
        events: [GatheredEvent] = []
    ) -> GatheredTask {
        GatheredTask(
            id: UUID(), title: title, status: status, ticketKeys: ticketKeys,
            blockedReason: blockedReason, events: events)
    }

    static func window(_ cadence: ReportCadence, _ tasks: [GatheredTask]) -> GatheredWindow {
        GatheredWindow(
            projectID: UUID(), cadence: cadence, start: origin,
            end: origin.addingTimeInterval(86_400), tasks: tasks)
    }

    /// The bullets under `title`, or `nil` if no such section was built.
    ///
    /// Looks the section up by name rather than by index so a test that expects
    /// *Blockers* fails with "no such section" if the order changes, instead of
    /// silently asserting against *Today*.
    static func section(_ title: String, of sections: [ReportSection]) -> [ReportBullet]? {
        sections.first { $0.title == title }?.bullets
    }
}
