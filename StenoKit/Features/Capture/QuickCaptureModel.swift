import Foundation
import SwiftData

/// The floating panel's model: its capture field, its project list, and the
/// state of its hotkey registration.
///
/// **It does not reach for `MainWindowModel`.** The panel must open, route and
/// write correctly when no main window exists at all — that is most of the
/// point of a global hotkey. It shares the *code path* with the main window,
/// per D15, not the main window's state. The other direction is handled for
/// it: `CaptureService` posts `.stenoDidWrite`, and any open main window
/// reloads itself.
@Observable
@MainActor
public final class QuickCaptureModel: HotkeyBinding {
    /// The shared capture field — the same type the main window's sheet uses,
    /// so the FR-1.4 chip cannot drift between surfaces.
    public let field: CaptureFieldModel

    /// The chord currently bound.
    public private(set) var chord: HotkeyChord

    /// A conflict or a registration failure, in words. M1-08's Capture pane
    /// renders this; M1-03 had no settings UI to put it in, so the property
    /// *was* the attachment point (design §3.4).
    public private(set) var registrationProblem: String?

    /// What the hotkey does. Stored by `start` so `rebind(to:)` can re-register
    /// without the caller having to supply it again.
    ///
    /// **This is why `rebind` takes a chord and nothing else.** The Settings
    /// pane's business is *which chord*, not what pressing it does; had it
    /// been obliged to pass the action, the settings layer would have to know
    /// how `QuickCaptureController` toggles its panel, and the next pane
    /// driving a controller would copy that. No retain cycle: the controller
    /// passes `{ [weak self] in self?.toggle() }`.
    private var onPress: (() -> Void)?

    private let context: ModelContext
    private let monitor: any GlobalHotkeyMonitor
    private let reserved: () -> [ReservedHotkey]
    private let settings: AppSettings
    private let projectBox: ProjectBox

    public init(
        context: ModelContext,
        monitor: any GlobalHotkeyMonitor,
        reserved: @escaping () -> [ReservedHotkey] = {
            SystemHotkeys.reserved(in: SystemHotkeys.systemDomain())
        },
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init,
        onCaptured: @escaping () -> Void = {}
    ) {
        let box = ProjectBox()
        self.projectBox = box
        self.context = context
        self.monitor = monitor
        self.reserved = reserved
        self.settings = settings
        self.chord = .default
        self.field = CaptureFieldModel(
            service: CaptureService(context: context, now: now),
            projects: { box.projects },
            // The panel has no surface context to prefer — routing falls to
            // the ticket key, then last-used. `CaptureService`'s own
            // documentation specifies `nil` for exactly this surface.
            preferred: { nil },
            onCaptured: { _ in onCaptured() }
        )
    }

    /// Read the stored chord, check it, and bind it.
    public func start(onPress: @escaping () -> Void) {
        self.onPress = onPress
        chord = settings.hotkeyChord ?? .default
        bind()
    }

    /// M1-08's entry point: bind a different chord, with no relaunch.
    ///
    /// Persist first, then register, so a registration that fails still leaves
    /// the user's choice recorded — the pane shows the problem and the chord
    /// they picked rather than silently reverting to the old one.
    public func rebind(to replacement: HotkeyChord) {
        chord = replacement
        settings.hotkeyChord = replacement
        bind()
    }

    /// Called on every open.
    ///
    /// Refetches live projects so a project created since the last capture
    /// routes immediately. **It does not clear the draft** — clearing is a
    /// dismissal responsibility (design §8.1): `Return` and `Esc` clear, while
    /// losing key focus and the hotkey toggle deliberately do not, so a
    /// half-typed thought survives a fumbled chord.
    public func prepareForShow() {
        projectBox.projects = liveProjects()

        // The draft survives a dismissal, so the project list can change
        // underneath it — a project created while the panel was hidden. The
        // chip is otherwise only re-derived on a keystroke, which would leave
        // the UI promising one routing while `CaptureService` performed
        // another. FR-1.4's chip is a claim about where the task will land, so
        // it re-derives here rather than waiting for the next character.
        field.refreshChip()
    }

    private func bind() {
        registrationProblem = nil

        // Nothing has told this model what the hotkey does yet, so there is no
        // action to register. Binding anyway would put a live system-wide
        // chord in front of a no-op — a hotkey that swallows the keystroke and
        // does nothing, which is worse than the unbound state it replaces.
        guard let onPress else {
            Log.app.error("hotkey bind requested before start(); nothing was registered")
            registrationProblem = "The shortcut could not be registered."
            return
        }

        // Warn, then register anyway. Refusing to bind guarantees a dead
        // hotkey; binding a claimed chord leaves the user with one that may
        // still work plus an explanation if it does not. The failure FR-1.1
        // exists to prevent is silence, not registration.
        if let conflict = HotkeyConflictChecker.conflict(for: chord, against: reserved()) {
            registrationProblem =
                "\(chord.displayString) is already used by \(conflict.name). "
                + "Steno's shortcut may not work until you change one of them."
            Log.app.error(
                "hotkey \(self.chord.displayString, privacy: .public) conflicts with \(conflict.name, privacy: .public)"
            )
        }

        do {
            try monitor.register(chord, onPress: onPress)
        } catch let error as HotkeyRegistrationError {
            registrationProblem = error.message
            Log.app.fault("hotkey registration failed: \(error.message, privacy: .public)")
        } catch {
            registrationProblem = "The shortcut could not be registered."
            Log.app.fault(
                "hotkey registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func liveProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            // An empty list means the chip does not appear; capture itself
            // still routes, because `CaptureService` fetches its own projects.
            Log.app.error(
                "could not load projects for quick capture: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }
}
