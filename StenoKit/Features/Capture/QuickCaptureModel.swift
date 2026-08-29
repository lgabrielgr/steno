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
public final class QuickCaptureModel {
    /// The shared capture field — the same type the main window's sheet uses,
    /// so the FR-1.4 chip cannot drift between surfaces.
    public let field: CaptureFieldModel

    /// The chord currently bound.
    public private(set) var chord: HotkeyChord

    /// A conflict or a registration failure, in words. M1-08's rebinding pane
    /// renders this; M1-03 has no settings UI to put it in, so the property
    /// *is* the attachment point (design §3.4).
    public private(set) var registrationProblem: String?

    /// Where the user's chord is stored. `UserDefaults`, not SwiftData: it is
    /// configuration, not domain data, and §10's export carries the domain.
    public static let chordKey = "com.lgabrielgr.steno.hotkeyChord"

    private let context: ModelContext
    private let monitor: any GlobalHotkeyMonitor
    private let reserved: () -> [ReservedHotkey]
    private let defaults: UserDefaults
    private let projectBox: ProjectBox

    /// Holds the project list the field reads through.
    ///
    /// A separate object because `CaptureFieldModel` takes its projects as a
    /// closure, and that closure has to be built during `init` — before `self`
    /// can be captured. A box constructed as a local first, then stored,
    /// sidesteps that without an implicitly unwrapped property.
    @MainActor
    final class ProjectBox {
        var projects: [Project] = []
    }

    public init(
        context: ModelContext,
        monitor: any GlobalHotkeyMonitor,
        reserved: @escaping () -> [ReservedHotkey] = {
            SystemHotkeys.reserved(in: SystemHotkeys.systemDomain())
        },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        onCaptured: @escaping () -> Void = {}
    ) {
        let box = ProjectBox()
        self.projectBox = box
        self.context = context
        self.monitor = monitor
        self.reserved = reserved
        self.defaults = defaults
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
        chord = storedChord()
        bind(onPress: onPress)
    }

    /// M1-08's entry point. Deliberately present from day one so that task
    /// adds a pane rather than redesigning this type.
    public func rebind(to replacement: HotkeyChord, onPress: @escaping () -> Void) {
        chord = replacement
        if let encoded = try? JSONEncoder().encode(replacement) {
            defaults.set(encoded, forKey: Self.chordKey)
        }
        bind(onPress: onPress)
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

    private func bind(onPress: @escaping () -> Void) {
        registrationProblem = nil

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

    /// A bad stored value falls back without being overwritten — M1-08's pane
    /// will want to show the user what is actually in there.
    private func storedChord() -> HotkeyChord {
        guard let data = defaults.data(forKey: Self.chordKey),
            let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data)
        else { return .default }
        return decoded
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
