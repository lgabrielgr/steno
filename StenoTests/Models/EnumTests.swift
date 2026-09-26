import Testing

@testable import StenoKit

@Test("D11: exactly four statuses, no custom ones")
func statusHasExactlyFourCases() {
    #expect(Status.allCases.count == 4)
}

// Raw values are the export format (§10.2), so renaming a case silently
// breaks every file already written. Pinning them makes that a test failure
// instead of a bug found on import.
@Test("Status raw values are stable")
func statusRawValues() {
    #expect(Status.todo.rawValue == "todo")
    #expect(Status.inProgress.rawValue == "inProgress")
    #expect(Status.blocked.rawValue == "blocked")
    #expect(Status.done.rawValue == "done")
}

@Test("§3.3: six event kinds")
func eventKindHasSixCases() {
    #expect(EventKind.allCases.count == 6)
}

@Test("EventKind raw values are stable")
func eventKindRawValues() {
    #expect(EventKind.created.rawValue == "created")
    #expect(EventKind.note.rawValue == "note")
    #expect(EventKind.statusChanged.rawValue == "statusChanged")
    #expect(EventKind.blockedReason.rawValue == "blockedReason")
    #expect(EventKind.externalUpdate.rawValue == "externalUpdate")
    #expect(EventKind.standupReported.rawValue == "standupReported")
}

@Test("§3.4: five source-ref kinds")
func sourceRefKindHasFiveCases() {
    #expect(SourceRefKind.allCases.count == 5)
}

@Test("SourceRefKind raw values are stable")
func sourceRefKindRawValues() {
    #expect(SourceRefKind.jiraIssue.rawValue == "jiraIssue")
    #expect(SourceRefKind.confluencePage.rawValue == "confluencePage")
    #expect(SourceRefKind.githubPR.rawValue == "githubPR")
    #expect(SourceRefKind.url.rawValue == "url")
    #expect(SourceRefKind.mcpResource.rawValue == "mcpResource")
}

@Test("D17: two cadences")
func reportCadenceHasTwoCases() {
    #expect(ReportCadence.allCases.count == 2)
    #expect(ReportCadence.daily.rawValue == "daily")
    #expect(ReportCadence.periodic.rawValue == "periodic")
}

@Test("D-180: externalUpdate is reportable but not user-authored")
func externalUpdateIsReportableButNotAuthored() {
    // Two predicates, two questions. **`isUserAuthored` must stay false here**:
    // FR-2's correction and redaction scope reads it, and an integration's
    // sentence must never become editable as though the user had typed it.
    #expect(EventKind.externalUpdate.isReportable)
    #expect(!EventKind.externalUpdate.isUserAuthored)
}

@Test("D-072: the machine-authored kinds are neither reportable nor user-authored")
func machineKindsAreNeitherReportableNorAuthored() {
    for kind in [EventKind.created, .statusChanged, .standupReported] {
        #expect(!kind.isReportable, "\(kind.rawValue) should not be reportable")
        #expect(!kind.isUserAuthored, "\(kind.rawValue) should not be user-authored")
    }
}

@Test("the kinds the user types are both")
func typedKindsAreBoth() {
    for kind in [EventKind.note, .blockedReason] {
        #expect(kind.isReportable, "\(kind.rawValue) should be reportable")
        #expect(kind.isUserAuthored, "\(kind.rawValue) should be user-authored")
    }
}
