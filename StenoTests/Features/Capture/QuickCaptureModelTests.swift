import AppKit
import Carbon.HIToolbox
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

    /// Kept so a test can fire the action the model registered. Without this,
    /// "rebinding keeps the hotkey working" is unprovable here.
    var onPress: (() -> Void)?

    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        if let failure { throw failure }
        registered = chord
        self.onPress = onPress
    }

    func unregister() {
        unregisterCount += 1
        registered = nil
    }
}

/// The helper's values as a named struct rather than a tuple. SwiftLint's
/// `large_tuple` rejects a bare 3-tuple — the same reason
/// `CaptureFieldModelTests` declares a `Fixture`.
private struct Fixture {
    let model: QuickCaptureModel
    let context: ModelContext
    let monitor: FakeHotkeyMonitor
    let settings: AppSettings
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
        defaults.set(try JSONEncoder().encode(stored), forKey: AppSettings.hotkeyChordKey)
    }

    let settings = AppSettings(defaults: defaults)
    let model = QuickCaptureModel(
        context: context, monitor: monitor, reserved: { reserved },
        settings: settings, now: { epoch })
    return Fixture(model: model, context: context, monitor: monitor, settings: settings)
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

/// A chord that decodes cleanly can still be one that must never be
/// registered. Before M1-08 nothing in the app could write this key — `rebind`
/// had no caller — so the load path had never been handed a hostile value; the
/// Settings pane makes it a real, user-writable setting. `defaults write` and a
/// future second caller of `rebind` are both now reachable.
///
/// A bare key bound globally is swallowed in *every* application, so this is
/// the one invalid state that damages the machine rather than the app.
@Test("a stored chord with no modifiers is refused and the default is bound instead")
@MainActor
func storedBareKeyFallsBackToTheDefault() throws {
    let bare = HotkeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)
    let fixture = try makeModel(stored: bare)
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start {}

    #expect(model.chord == .default)
    #expect(monitor.registered == .default)
    // The stored value is left alone, exactly as an undecodable one is: this
    // is a read-side refusal, not a correction (D-056).
    #expect(fixture.settings.hotkeyChord == bare)
}

@Test("a stored shift-only chord is refused the same way")
@MainActor
func storedShiftOnlyChordFallsBackToTheDefault() throws {
    let shifted = HotkeyChord(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.shift.rawValue)
    let fixture = try makeModel(stored: shifted)

    fixture.model.start {}

    #expect(fixture.model.chord == .default)
    #expect(fixture.monitor.registered == .default)
}

/// The masking half of `validate` is load-bearing on the load path too, not
/// just the judging half — a hand-written chord can carry bits the recorder
/// would never have produced. `HotkeyChord` compares modifiers for exact
/// equality (D-059), so an unmasked `.capsLock` bit would silently stop the
/// chord matching `SystemHotkeys` and convert to the wrong Carbon mask.
///
/// Asserted rather than left to the doc comment, because a comment claiming a
/// behaviour nothing exercises is this repo's most repeated defect.
@Test("a stored chord carrying stray modifier bits is masked before it is bound")
@MainActor
func storedChordWithStrayBitsIsMasked() throws {
    let command = NSEvent.ModifierFlags.command.rawValue
    let stored = HotkeyChord(
        keyCode: UInt16(kVK_ANSI_K), modifiers: command | NSEvent.ModifierFlags.capsLock.rawValue)
    let fixture = try makeModel(stored: stored)

    fixture.model.start {}

    let masked = HotkeyChord(keyCode: UInt16(kVK_ANSI_K), modifiers: command)
    #expect(fixture.model.chord == masked)
    #expect(fixture.monitor.registered == masked)
    // Refuse, don't correct: what is bound differs from what is stored, and
    // the file is left as the user wrote it.
    #expect(fixture.settings.hotkeyChord == stored)
}

@Test("an undecodable stored chord falls back to the default without erasing it")
@MainActor
func undecodableStoredChordFallsBack() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    defaults.set(Data([0x01, 0x02]), forKey: AppSettings.hotkeyChordKey)

    let model = QuickCaptureModel(
        context: context, monitor: FakeHotkeyMonitor(), reserved: { [] },
        settings: AppSettings(defaults: defaults), now: { epoch })
    model.start {}

    #expect(model.chord == .default)
    // The Capture pane shows the user what is actually stored, so the bad
    // value is reported as absent rather than erased.
    #expect(defaults.data(forKey: AppSettings.hotkeyChordKey) == Data([0x01, 0x02]))
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
    model.rebind(to: replacement)

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

/// The gap the keystroke-driven chip refresh leaves: the draft outlives the
/// dismissal, so a project created while the panel was hidden changes what
/// `CaptureService` will route with — but nothing types a character to
/// re-derive the chip. Without an explicit refresh the panel shows no chip
/// while the write routes to Hiring, which is FR-1.4's promise breaking
/// silently. Note the ordering: the draft is typed BEFORE the project exists.
@Test("preparing to show re-derives the chip for a draft typed before the project existed")
@MainActor
func prepareForShowRefreshesTheChipForAnExistingDraft() throws {
    let fixture = try makeModel()
    let (model, context) = (fixture.model, fixture.context)
    model.prepareForShow()

    model.field.text = "HIR-9 schedule the loop"
    #expect(model.field.chip == nil, "no Hiring project exists yet")

    context.insert(
        Project(
            name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
            sortOrder: 1, modifiedAt: epoch))
    try context.save()

    // No keystroke — this is the whole point.
    model.prepareForShow()

    let chip = try #require(model.field.chip)
    #expect(chip.projectName == "Hiring")
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

/// M1-08's first acceptance criterion, as far as a headless test reaches:
/// rebinding takes effect with no relaunch, and the action survives it.
///
/// The action surviving is the half that could silently break. `rebind(to:)`
/// re-registers using the closure `start` stored; drop that and the chord
/// still changes, the monitor still reports the new binding, and pressing it
/// does nothing.
@Test("rebinding keeps the registered action live")
@MainActor
func rebindingKeepsTheActionLive() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    var presses = 0
    model.start { presses += 1 }
    monitor.onPress?()
    #expect(presses == 1)

    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(monitor.registered == replacement)
    monitor.onPress?()
    #expect(presses == 2, "the action stored by start() must survive a rebind")
}

/// A chord bound in front of no action is worse than no chord: it swallows the
/// keystroke system-wide and does nothing.
@Test("rebinding before start registers nothing and says so")
@MainActor
func rebindingBeforeStartRegistersNothing() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(monitor.registered == nil)
    #expect(model.registrationProblem != nil)
}

/// The chord is persisted before registration is attempted, so a failure
/// leaves the user's choice recorded rather than silently reverting it.
@Test("a rebind that fails to register still persists the chosen chord")
@MainActor
func aFailedRebindStillPersistsTheChord() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    let monitor = FakeHotkeyMonitor()
    let model = QuickCaptureModel(
        context: ModelContext(try StenoStore.inMemory()), monitor: monitor, reserved: { [] },
        settings: settings, now: { epoch })
    model.start {}

    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(model.registrationProblem == "That shortcut is already registered.")
    #expect(settings.hotkeyChord == replacement)
}
