import Foundation
import Testing

@testable import StenoKit

private struct DueCase {
    let name: String
    let lastSuccess: Date?
    let now: Date
    let isDue: Bool
}

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

/// D-121's daily rule, as a table.
///
/// The clock-moved-backwards row is the one worth having: a `lastSuccess` in
/// the future would otherwise disable backups until real time caught up, and
/// for a mis-set year that means never.
@Test(
    "the daily trigger is due only past 24h, and always after a clock moves backwards",
    arguments: [
        DueCase(name: "never exported", lastSuccess: nil, now: origin, isDue: true),
        DueCase(
            name: "one minute ago", lastSuccess: origin.addingTimeInterval(-60), now: origin,
            isDue: false),
        DueCase(
            name: "23h59m ago", lastSuccess: origin.addingTimeInterval(-(24 * 3600 - 60)),
            now: origin, isDue: false),
        DueCase(
            name: "exactly 24h ago", lastSuccess: origin.addingTimeInterval(-24 * 3600),
            now: origin, isDue: true),
        DueCase(
            name: "25h ago", lastSuccess: origin.addingTimeInterval(-25 * 3600), now: origin,
            isDue: true),
        DueCase(
            name: "in the future", lastSuccess: origin.addingTimeInterval(3600), now: origin,
            isDue: true),
    ])
@MainActor
private func theDailyRuleHolds(dueCase: DueCase) {
    #expect(
        AutoExportDue.isDue(lastSuccess: dueCase.lastSuccess, now: dueCase.now) == dueCase.isDue,
        "\(dueCase.name)")
}
