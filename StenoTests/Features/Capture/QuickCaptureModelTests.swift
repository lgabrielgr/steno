import AppKit
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private final class FakeHotkeyMonitor: GlobalHotkeyMonitor {
    var registered: HotkeyChord?
    var unregisterCount = 0
    var failure: (any Error)?

    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        if let failure { throw failure }
        registered = chord
    }

    func unregister() {
        unregisterCount += 1
        registered = nil
    }
}

/// The helper's three values as a named struct rather than a tuple.
/// SwiftLint's `large_tuple` rejects a bare 3-tuple — the same reason
/// `CaptureFieldModelTests` declares a `Fixture`.
private struct Fixture {
    let model: QuickCaptureModel
    let context: ModelContext
    let monitor: FakeHotkeyMonitor
}

@MainActor
private func makeModel(
    monitor: FakeHotkeyMonitor = FakeHotkeyMonitor(),
    reserved: [ReservedHotkey] = [],
    stored: HotkeyChord? = nil
) throws -> Fixture {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    // `try #require`, never `!` — `force_unwrapping` is an enabled opt-in rule
    // and `--strict` promotes it to a build failure.
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    if let stored {
        defaults.set(try JSONEncoder().encode(stored), forKey: QuickCaptureModel.chordKey)
    }

    let model = QuickCaptureModel(
        context: context, monitor: monitor, reserved: { reserved }, defaults: defaults,
        now: { epoch })
    return Fixture(model: model, context: context, monitor: monitor)
}

@Test("with no stored chord the model binds ⌥Space")
@MainActor
func bindsTheDefaultChord() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start {}

    #expect(model.chord == .default)
    #expect(monitor.registered == .default)
    #expect(model.registrationProblem == nil)
}

@Test("a stored chord is used in place of the default")
@MainActor
func storedChordIsUsed() throws {
    let stored = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)
    let fixture = try makeModel(stored: stored)
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start {}

    #expect(model.chord == stored)
    #expect(monitor.registered == stored)
}

@Test("an undecodable stored chord falls back to the default without erasing it")
@MainActor
func undecodableStoredChordFallsBack() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    defaults.set(Data([0x01, 0x02]), forKey: QuickCaptureModel.chordKey)

    let model = QuickCaptureModel(
        context: context, monitor: FakeHotkeyMonitor(), reserved: { [] }, defaults: defaults,
        now: { epoch })
    model.start {}

    #expect(model.chord == .default)
    // M1-08's pane will want to show what the bad value was.
    #expect(defaults.data(forKey: QuickCaptureModel.chordKey) == Data([0x01, 0x02]))
}

@Test("a reserved chord warns and is registered anyway")
@MainActor
func reservedChordWarnsAndStillBinds() throws {
    let spotlight = ReservedHotkey(
        identifier: 64, name: "Spotlight search",
        chord: .default)
    let fixture = try makeModel(reserved: [spotlight])
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start {}

    let problem = try #require(model.registrationProblem)
    #expect(problem.contains("Spotlight search"))
    // Refusing to bind guarantees a dead hotkey; binding leaves a chord that
    // may still work, plus an explanation if it does not. Design §3.4.
    #expect(monitor.registered == .default)
}

@Test("a failed registration is reported in the monitor's own words")
@MainActor
func failedRegistrationIsReported() throws {
    let monitor = FakeHotkeyMonitor()
    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let model = try makeModel(monitor: monitor).model

    model.start {}

    #expect(model.registrationProblem == "That shortcut is already registered.")
}

@Test("rebinding replaces the chord and clears a stale problem")
@MainActor
func rebindingReplacesTheChord() throws {
    let monitor = FakeHotkeyMonitor()
    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let model = try makeModel(monitor: monitor).model
    model.start {}
    #expect(model.registrationProblem != nil)

    monitor.failure = nil
    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement) {}

    #expect(model.chord == replacement)
    #expect(model.registrationProblem == nil)
    #expect(monitor.registered == replacement)
}

@Test("preparing to show refetches projects so a new one routes immediately")
@MainActor
func prepareForShowRefetchesProjects() throws {
    let fixture = try makeModel()
    let (model, context) = (fixture.model, fixture.context)
    model.prepareForShow()

    context.insert(
        Project(
            name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
            sortOrder: 1, modifiedAt: epoch))
    try context.save()
    model.prepareForShow()

    model.field.text = "HIR-9 schedule the loop"

    let chip = try #require(model.field.chip)
    #expect(chip.projectName == "Hiring")
}

/// Design §8.1: blur and the hotkey toggle hide the panel without discarding
/// the draft, so showing must not clear it. Only `Return` and `Esc` clear.
@Test("preparing to show preserves an in-progress draft")
@MainActor
func prepareForShowPreservesTheDraft() throws {
    let model = try makeModel().model
    model.field.text = "half a thought"

    model.prepareForShow()

    #expect(model.field.text == "half a thought")
}

@Test("a capture through the panel routes on a ticket key with no surface context")
@MainActor
func panelCaptureRoutesOnTicketKey() throws {
    let fixture = try makeModel()
    let (model, context) = (fixture.model, fixture.context)
    model.prepareForShow()

    model.field.text = "PAY-421 fix the retry handler"
    model.field.commit()

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    #expect(model.field.text.isEmpty)
}
