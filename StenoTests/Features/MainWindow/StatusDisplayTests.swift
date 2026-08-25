import Testing

@testable import StenoKit

@Test("the four statuses render with FR-3's spelling")
func statusDisplayNames() {
    #expect(Status.inProgress.displayName == "IN-PROGRESS")
    #expect(Status.blocked.displayName == "BLOCKED")
    #expect(Status.todo.displayName == "TODO")
    #expect(Status.done.displayName == "DONE")
    // Every case is covered, so adding a fifth status breaks this test rather
    // than silently rendering an unlabelled group. D11 says there is no fifth.
    #expect(Status.allCases.count == 4)
}
