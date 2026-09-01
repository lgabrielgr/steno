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

@Test("the picker's order is named, not inherited from the enum")
func statusMenuOrderIsNamed() {
    #expect(Status.menuOrder == [.todo, .inProgress, .blocked, .done])
    // Every case appears exactly once, so a fifth status added to the enum
    // fails here rather than quietly missing from every picker. The literal
    // above is what makes reordering `Status` a test failure instead of a
    // silent reshuffle of the menu under the user's cursor.
    #expect(Set(Status.menuOrder) == Set(Status.allCases))
    #expect(Status.menuOrder.count == Status.allCases.count)
    // Deliberately different from the window's section order (D-042).
    #expect(Status.menuOrder != TaskGrouping.order)
}
