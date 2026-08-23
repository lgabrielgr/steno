import Foundation
import Testing

@testable import StenoKit

@Test("cycling starts at All and reaches the first project")
func nextFromAllSelectsFirstProject() {
    let ids = [UUID(), UUID()]

    #expect(ProjectSelection.next(after: .all, in: ids) == .project(ids[0]))
}

@Test("cycling forward wraps back round to All", arguments: [0, 1, 2, 5])
func forwardCycleWraps(projectCount: Int) {
    let ids = (0..<projectCount).map { _ in UUID() }
    var selection = ProjectSelection.all

    // One step per project, plus one to come back round to All.
    for _ in 0...projectCount {
        selection = .next(after: selection, in: ids)
    }

    #expect(selection == .all)
}

@Test("cycling backward from All wraps to the last project")
func previousFromAllWrapsToLast() {
    let ids = [UUID(), UUID(), UUID()]

    #expect(ProjectSelection.previous(before: .all, in: ids) == .project(ids[2]))
}

@Test("a selection that is no longer in the list falls back to All")
func staleSelectionFallsBackToAll() {
    // The project was archived between the keystroke and the lookup.
    #expect(ProjectSelection.next(after: .project(UUID()), in: [UUID()]) == .all)
}
