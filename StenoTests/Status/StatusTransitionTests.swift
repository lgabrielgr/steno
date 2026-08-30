import Testing

@testable import StenoKit

@Test("the event body is FR-3's spelling with §3.3's arrow")
func eventBodyUsesDisplayNamesAndTheSpecArrow() {
    let transition = StatusTransition(from: .inProgress, into: .blocked)
    #expect(transition.eventBody == "IN-PROGRESS → BLOCKED")
}

@Test("the arrow is U+2192, not an ASCII hyphen-arrow")
func eventBodyArrowIsTheSpecCharacter() {
    let body = StatusTransition(from: .todo, into: .done).eventBody
    #expect(body.contains("\u{2192}"))
    #expect(!body.contains("->"))
}

@Test("the cycle is TODO, IN-PROGRESS, DONE — BLOCKED is not in it (D-034)")
func cycleExcludesBlocked() {
    #expect(Status.cycle == [.todo, .inProgress, .done])
    #expect(!Status.cycle.contains(.blocked))
}

@Test("next walks the cycle and wraps at the end")
func nextWalksAndWraps() {
    #expect(Status.todo.next == .inProgress)
    #expect(Status.inProgress.next == .done)
    #expect(Status.done.next == .todo)
}

@Test("cycling out of BLOCKED goes to IN-PROGRESS")
func nextFromBlockedIsInProgress() {
    #expect(Status.blocked.next == .inProgress)
}

@Test("three presses from TODO returns to TODO without ever passing through BLOCKED")
func cyclingNeverProducesBlocked() {
    var status = Status.todo
    var visited: [Status] = []
    for _ in 0..<3 {
        status = status.next
        visited.append(status)
    }
    #expect(status == .todo)
    #expect(!visited.contains(.blocked))
}
