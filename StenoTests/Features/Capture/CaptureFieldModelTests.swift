import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// `makeField`'s three-value return, as a named struct rather than a tuple —
/// SwiftLint's `large_tuple` rejects a bare 3-tuple, and this is fixture
/// plumbing rather than one of the brief's produced interfaces.
private struct Fixture {
    let field: CaptureFieldModel
    let context: ModelContext
    let projects: [Project]
}

@MainActor
private func makeField() throws -> Fixture {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "EM — Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let projects = [payments, hiring]
    let field = CaptureFieldModel(
        service: CaptureService(context: context, now: { epoch }),
        projects: { projects },
        preferred: { hiring.id }
    )
    return Fixture(field: field, context: context, projects: projects)
}

@MainActor
@Test("typing a configured key raises a chip naming its project")
func typingAKeyRaisesTheChip() throws {
    let fixture = try makeField()
    let field = fixture.field

    field.text = "PAY-421 fix the retry handler"

    let chip = try #require(field.chip)
    #expect(chip.key == "PAY-421")
    #expect(chip.projectID == fixture.projects[0].id)
    #expect(chip.projectName == "Payments")
    #expect(chip.colorHex == "#3B82F6")
}

@MainActor
@Test("text with no configured key raises no chip")
func plainTextRaisesNoChip() throws {
    let field = try makeField().field

    field.text = "write the interview loop doc"

    #expect(field.chip == nil)
}

@MainActor
@Test("dismissing clears the chip and it stays gone while the key stands")
func dismissalSticksForThatKey() throws {
    let field = try makeField().field
    field.text = "PAY-421 fix"

    field.dismissChip()
    #expect(field.chip == nil)

    field.text = "PAY-421 fix the retry handler"

    #expect(field.chip == nil)
}

@MainActor
@Test("a different key after a dismissal raises a new chip")
func aDifferentKeyRaisesANewChip() throws {
    let fixture = try makeField()
    let field = fixture.field
    field.text = "PAY-421 fix"
    field.dismissChip()

    field.text = "HIR-9 screen the candidate"

    // Dismissal drops one auto-assignment; it does not disable routing for
    // the rest of a capture still being typed (design §5.1).
    let chip = try #require(field.chip)
    #expect(chip.key == "HIR-9")
    #expect(chip.projectID == fixture.projects[1].id)
}

@MainActor
@Test("committing an undismissed chip routes to the key's project")
func commitHonoursTheChip() throws {
    let fixture = try makeField()
    let field = fixture.field
    field.text = "PAY-421 fix the retry handler"

    field.commit()

    let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    #expect(tasks.first?.projectID == fixture.projects[0].id)
}

@MainActor
@Test("committing a dismissed chip routes down the ladder")
func commitHonoursTheDismissal() throws {
    let fixture = try makeField()
    let field = fixture.field
    field.text = "PAY-421 fix the retry handler"
    field.dismissChip()

    field.commit()

    let tasks = try fixture.context.fetch(FetchDescriptor<TaskItem>())
    // preferred == hiring, so rung 2 catches it.
    #expect(tasks.first?.projectID == fixture.projects[1].id)
}

@MainActor
@Test("a successful commit clears the field for the next capture")
func commitResetsTheField() throws {
    let field = try makeField().field
    field.text = "PAY-421 fix"
    field.dismissChip()

    field.commit()

    #expect(field.text.isEmpty)
    #expect(field.chip == nil)
    #expect(field.lastError == nil)
}

@MainActor
@Test("a commit that cannot be saved reports it and keeps the text")
func failedCommitKeepsTheText() throws {
    struct Boom: Error {}
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", sortOrder: 0, modifiedAt: epoch)
    context.insert(payments)
    try context.save()
    let field = CaptureFieldModel(
        service: CaptureService(context: context, now: { epoch }, save: { _ in throw Boom() }),
        projects: { [payments] }
    )
    field.text = "this will not save"

    field.commit()

    // Losing the user's typing on a failed save is the capture-tool version
    // of the notebook page falling out.
    #expect(field.text == "this will not save")
    #expect(field.lastError != nil)
}

@MainActor
@Test("committing an empty field does nothing and reports nothing")
func emptyCommitIsSilent() throws {
    let fixture = try makeField()
    let field = fixture.field

    field.commit()

    #expect(try fixture.context.fetch(FetchDescriptor<TaskItem>()).isEmpty)
    #expect(field.lastError == nil)
}
