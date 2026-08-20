import Foundation
import Testing

@testable import StenoKit

private let created = Date(timeIntervalSince1970: 0)
private let changed = Date(timeIntervalSince1970: 100)

private func project() -> Project {
    Project(name: "Payments Platform", colorHex: "#3B82F6", modifiedAt: created)
}

@Test("a new project carries its seeded values")
func projectInitialState() {
    let subject = Project(
        name: "EM — Hiring",
        colorHex: "#F59E0B",
        jiraProjectKeys: ["PAY", "BILL"],
        sortOrder: 3,
        reportCadence: .periodic,
        staleThresholdDays: 14,
        modifiedAt: created
    )

    #expect(subject.name == "EM — Hiring")
    #expect(subject.colorHex == "#F59E0B")
    #expect(subject.jiraProjectKeys == ["PAY", "BILL"])
    #expect(subject.sortOrder == 3)
    #expect(subject.reportCadence == .periodic)
    #expect(subject.staleThresholdDays == 14)
    #expect(subject.modifiedAt == created)
    #expect(subject.lastStandupAt == nil)
    #expect(!subject.isArchived)
}

@Test("design §4: every governed mutator stamps modifiedAt")
func governedMutatorsStampModifiedAt() {
    var subject = project()
    subject.rename(to: "Payments", at: changed)
    #expect(subject.name == "Payments")
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setColorHex("#EF4444", at: changed)
    #expect(subject.colorHex == "#EF4444")
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setJiraProjectKeys(["PAY"], at: changed)
    #expect(subject.jiraProjectKeys == ["PAY"])
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setArchived(true, at: changed)
    #expect(subject.isArchived)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setSortOrder(9, at: changed)
    #expect(subject.sortOrder == 9)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setCadence(.periodic, at: changed)
    #expect(subject.reportCadence == .periodic)
    #expect(subject.modifiedAt == changed)

    subject = project()
    subject.setStaleThresholdDays(7, at: changed)
    #expect(subject.staleThresholdDays == 7)
    #expect(subject.modifiedAt == changed)
}

// §10.1 gives lastStandupAt its own merge rule — take the later timestamp — so
// it must not stamp modifiedAt. It is a plain var precisely so this holds by
// construction rather than by a mutator remembering not to.
@Test("design §4: advancing lastStandupAt does not stamp modifiedAt")
func lastStandupAtDoesNotStampModifiedAt() {
    let subject = project()
    subject.lastStandupAt = changed
    #expect(subject.lastStandupAt == changed)
    #expect(subject.modifiedAt == created)
}

@Test("FR-6: staleThresholdDays can be cleared back to nil")
func staleThresholdCanBeCleared() {
    let subject = project()
    subject.setStaleThresholdDays(7, at: changed)
    subject.setStaleThresholdDays(nil, at: changed)
    // nil means "derive from cadence, then the global default" (FR-5), so
    // clearing it has to be expressible.
    #expect(subject.staleThresholdDays == nil)
}
