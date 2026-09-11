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

// MARK: - Parsing the body back (M2.5-02, §10.1)

@Test("every transition survives eventBody → StatusTransition → eventBody")
func everyTransitionSurvivesTheRoundTrip() throws {
    // All sixteen ordered pairs, `allCases` squared rather than a written list:
    // a list would still compile with a status missing, and the missing one
    // would be a transition import cannot read rather than a build error.
    for from in Status.allCases {
        for into in Status.allCases {
            let original = StatusTransition(from: from, into: into)
            let parsed = try #require(
                StatusTransition(eventBody: original.eventBody),
                "\(original.eventBody) did not parse")

            #expect(parsed == original)
            #expect(parsed.eventBody == original.eventBody)
        }
    }
}

@Test("the four persisted spellings are pinned literally")
func theFourSpellingsArePinned() {
    // Asserted against literals, not against `displayName` itself, because this
    // is the test that has to fail if someone renames one. These strings are in
    // every `statusChanged` event ever written and §10.1's import parses them.
    #expect(Status.todo.displayName == "TODO")
    #expect(Status.inProgress.displayName == "IN-PROGRESS")
    #expect(Status.blocked.displayName == "BLOCKED")
    #expect(Status.done.displayName == "DONE")

    #expect(Status(displayName: "TODO") == .todo)
    #expect(Status(displayName: "IN-PROGRESS") == .inProgress)
    #expect(Status(displayName: "BLOCKED") == .blocked)
    #expect(Status(displayName: "DONE") == .done)
}

@Test("a body that is not a transition parses as nil, it does not guess")
func anUnreadableBodyParsesAsNil() {
    // §10.2 chose JSON partly so a file could be hand-edited, so these are
    // reachable in practice rather than defensive. Import falls back to the
    // record's own clock and reports the event; it does not refuse the file and
    // it does not pick a status.
    let unreadable = [
        "",
        "TODO",
        "TODO -> DONE",  // ASCII arrow: the divergence §3.3's byte-level check exists for
        "TODO→DONE",  // no spaces
        "TODO → NOPE",  // right half is not a status
        "NOPE → DONE",  // left half is not a status
        "TODO → IN-PROGRESS → DONE",  // two arrows
        "todo → done",  // wrong case
        "Reported to standup",  // a real body, from a different event kind
    ]

    for body in unreadable {
        #expect(StatusTransition(eventBody: body) == nil, "\(body) should not parse")
    }
}

@Test("a same-status body is readable, because the log may contain one")
func aSameStatusBodyIsReadable() throws {
    // `StatusService.setStatus` guards against writing one, but the parser is
    // fed whatever the file carries — including events written by a build that
    // did not have that guard. Reading it is strictly better than treating the
    // newest event in the log as unreadable.
    let parsed = try #require(StatusTransition(eventBody: "BLOCKED → BLOCKED"))

    #expect(parsed.into == .blocked)
}
