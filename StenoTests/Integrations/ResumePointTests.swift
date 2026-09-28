import Foundation
import Testing

@testable import StenoKit

/// D-184: the resume point, recovered from payloads.

private let refID = UUID(uuidString: "0BC7A3A0-0000-4000-8000-0000000000AA") ?? UUID()
private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func payload(
    watermark: Date?, changeIDs: [String]? = nil, presentIDs: [String]? = nil
) -> ExternalUpdatePayload {
    ExternalUpdatePayload(
        refID: refID, kind: .jiraIssue, identifier: "PAY-421", changes: [], url: nil,
        fetchedAt: origin, watermark: watermark, changeIDs: changeIDs, presentIDs: presentIDs)
}

@Test("no payloads means no anchor, and a nil since")
func noPayloadsMeansNoAnchor() {
    #expect(ResumePoint.from(payloads: []) == .none)
    #expect(ResumePoint.none.since(now: origin) == nil)
}

@Test("D-185: since is the watermark less the overlap")
func sinceIsTheWatermarkLessTheOverlap() {
    let point = ResumePoint.from(payloads: [payload(watermark: origin)])
    #expect(point.since(now: origin) == origin.addingTimeInterval(-15 * 60))
    // The constant is the fifteen minutes §5.2's replication lag needs, named once.
    #expect(ResumePoint.overlap == 900)
}

@Test("the watermark is the newest across the scanned payloads, not the first one")
func theWatermarkIsTheNewest() {
    // Payloads arrive newest-first *by event timestamp*, which is the app's clock, while
    // the watermarks are the source's. Those two orders can disagree across a clock
    // change, and a watermark that moved backwards would re-report everything between
    // the two values. Mutation: take `first?.watermark` and this goes red.
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin.addingTimeInterval(-3600)),
        payload(watermark: origin),
    ])
    #expect(point.watermark == origin)
}

@Test("D-186: reported ids are unioned across the payloads, not read from the newest")
func reportedIDsAreUnioned() {
    // A pass writes at most one event per ref, so a dedup set one payload deep forgets
    // everything the previous pass reported the moment a new event lands — and the
    // overlap then re-reports it.
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin, changeIDs: ["c3"]),
        payload(watermark: origin, changeIDs: ["c2"]),
        payload(watermark: origin, changeIDs: ["c1"]),
    ])
    #expect(point.reportedIDs == ["c1", "c2", "c3"])
}

@Test("the union stops at the scan depth")
func theUnionStopsAtTheScanDepth() {
    let payloads = (0..<20).map { payload(watermark: origin, changeIDs: ["c\($0)"]) }
    let point = ResumePoint.from(payloads: payloads)

    #expect(point.reportedIDs.count == ResumePoint.scanDepth)
    #expect(point.reportedIDs.contains("c0"))
    #expect(point.reportedIDs.contains("c19") == false)
}

@Test("D-187: the link set is the newest recorded set exactly, never a union")
func theLinkSetIsTheNewestRecorded() {
    // A union could never see a link that was removed: L1 is gone as of the newest
    // payload, and a union would keep claiming it is present.
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin, presentIDs: ["L2"]),
        payload(watermark: origin, presentIDs: ["L1", "L2"]),
    ])
    #expect(point.presentIDs == ["L2"])
}

@Test("a payload that recorded no link set is skipped, not read as empty")
func anUnrecordedSetIsSkipped() {
    // A payload written before M4-02 has none. Treating that as "nothing present" would
    // report every existing link as new on the first pass after an upgrade.
    let point = ResumePoint.from(payloads: [
        payload(watermark: origin, presentIDs: nil),
        payload(watermark: origin, presentIDs: ["L1"]),
    ])
    #expect(point.presentIDs == ["L1"])
}

@Test("payloads with no watermark at all leave the window open")
func payloadsWithoutWatermarksLeaveTheWindowOpen() {
    let point = ResumePoint.from(payloads: [payload(watermark: nil, changeIDs: ["c1"])])
    #expect(point.watermark == nil)
    #expect(point.since(now: origin) == nil)
    // The ids are still remembered, so the pass that follows drops the repeat even
    // though it asks for everything.
    #expect(point.reportedIDs == ["c1"])
}

@Test("the window is clamped, so a stalled watermark cannot widen it forever")
func theWindowIsClamped() {
    // The watermark only advances when an event is written (D-184), so a ref whose fetches
    // find nothing new keeps its window — and on a long-lived ticket that means re-walking
    // the same pages every pass. Raised by Copilot in review of PR #43.
    let ancient = origin.addingTimeInterval(-400 * 24 * 60 * 60)
    let point = ResumePoint.from(payloads: [payload(watermark: ancient)])

    #expect(point.since(now: origin) == origin.addingTimeInterval(-ResumePoint.maxLookback))
    #expect(ResumePoint.maxLookback == 30 * 24 * 60 * 60)
}

@Test("a recent watermark is not clamped")
func arecentWatermarkIsNotClamped() {
    // The other direction, because a clamp that always fired would pass the test above and
    // throw away the overlap the window depends on.
    let recent = origin.addingTimeInterval(-3600)
    let point = ResumePoint.from(payloads: [payload(watermark: recent)])
    #expect(point.since(now: origin) == recent.addingTimeInterval(-ResumePoint.overlap))
}
