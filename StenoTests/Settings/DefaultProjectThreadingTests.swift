import AppKit
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// FR-1.4's ladder is already covered as a pure function by
/// `ProjectRouterTests`. **What these tests cover is the wiring**: that each
/// capture surface actually passes FR-6's configured default down to
/// `CaptureService`, which is the thing M1-02 left as a `nil` argument and
/// M1-08 fills in.
///
/// The fixture is built so the default is the only thing that can decide the
/// outcome. Two live projects, no ticket key in the text, no prior task — so
/// rung 1 (ticket key), rung 2 (surface preference) and rung 3 (last-used) all
/// miss. Drop the `defaultProjectID:` argument from any one surface and that
/// surface routes to Payments, the lowest `sortOrder`, by rung 5.
@MainActor
private struct Surfaces {
    let context: ModelContext
    let settings: AppSettings
    let payments: Project
    let hiring: Project
}

@MainActor
private func makeSurfaces(defaultProject: (Project) -> UUID?) throws -> Surfaces {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    settings.defaultProjectID = defaultProject(hiring)
    return Surfaces(context: context, settings: settings, payments: payments, hiring: hiring)
}

@MainActor
private func onlyTask(in context: ModelContext) throws -> TaskItem {
    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    return try #require(tasks.first)
}

@Test("the floating panel captures to the configured default")
@MainActor
func theFloatingPanelUsesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.hiring.id)
}

@Test("the menu bar popover captures to the configured default")
@MainActor
func theMenuBarPopoverUsesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = MenuBarModel(
        context: surfaces.context, now: { epoch }, settings: surfaces.settings)
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.hiring.id)
}

/// The main window builds its `CaptureFieldModel` in `NewTaskSheet`, which is
/// a view — so what a headless test can reach is the property that view reads.
@Test("the main window exposes the configured default to its capture sheet")
@MainActor
func theMainWindowExposesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = MainWindowModel(
        context: surfaces.context, now: { epoch }, settings: surfaces.settings)

    #expect(model.defaultProjectIDForCapture == surfaces.hiring.id)
}

/// With no default configured the ladder falls through to the first project,
/// which is what makes the three tests above discriminating rather than
/// tautological: this is the answer they would give if the wiring were absent.
@Test("with no configured default the capture falls through to the first project")
@MainActor
func withNoDefaultTheCaptureFallsThrough() throws {
    let surfaces = try makeSurfaces(defaultProject: { _ in nil })
    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.payments.id)
}

/// A default pointing at an archived project must not strand the capture:
/// `ProjectRouter` drops the rung and the next one answers.
@Test("a default naming an archived project falls through rather than routing there")
@MainActor
func anArchivedDefaultFallsThrough() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    surfaces.hiring.setArchived(true, at: epoch)
    try surfaces.context.save()

    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.payments.id)
}

/// Registers nothing: these tests are about routing, not about the hotkey.
@MainActor
private final class NullHotkeyMonitor: GlobalHotkeyMonitor {
    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {}
    func unregister() {}
}
