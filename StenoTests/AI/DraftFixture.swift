import Foundation

@testable import StenoKit

/// Windows built by hand, for the types between the gatherer and the provider.
///
/// **No `ModelContainer` here, unlike `ReportFixture`.** `GatheredWindow` and
/// its parts are plain value types — that is the reason they exist (their own
/// doc comment: "M3-03 hands this to an `AIProvider` across an async boundary")
/// — so a prompt, a schema or a section mapping can be tested without a store
/// at all. `ReportFixture` stays the right tool for anything that must read
/// what the gatherer actually produces.
enum DraftFixture {
    /// 2023-11-14 22:13:20 UTC, matching `ReportFixture.origin` so a reader
    /// comparing the two suites is looking at the same instant.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    static func event(
        _ body: String, kind: EventKind = .note, offset: TimeInterval = 3600
    ) -> GatheredEvent {
        GatheredEvent(timestamp: origin.addingTimeInterval(offset), kind: kind, body: body)
    }

    static func task(
        _ title: String,
        id: UUID = UUID(),
        status: Status = .inProgress,
        keys: [String] = [],
        blockedReason: String? = nil,
        events: [GatheredEvent] = []
    ) -> GatheredTask {
        GatheredTask(
            id: id, title: title, status: status, ticketKeys: keys,
            blockedReason: blockedReason, events: events)
    }

    static func window(
        _ cadence: ReportCadence = .daily, tasks: [GatheredTask]
    ) -> GatheredWindow {
        GatheredWindow(
            projectID: UUID(), cadence: cadence, start: origin,
            end: origin.addingTimeInterval(86_400), tasks: tasks)
    }
}
