import Darwin  // fflush/stdout — explicit rather than transitively via SwiftUI
import StenoKit
import SwiftData
import SwiftUI

/// **`@main` lives on `StenoMain`, not here.** The app binary also runs §10.5's
/// `steno export` / `steno import` subcommands, and a subcommand must not start
/// `NSApplication` — which SwiftUI's generated `main` does before any of our
/// code gets control. `StenoMain` calls `StenoApp.main()` for an ordinary
/// launch; nothing else about this type changed.
struct StenoApp: App {
    /// Built once, here, rather than by `.modelContainer(for:)` — which traps
    /// on failure. See `StoreFailureView` for why this is a `Result`.
    private let store: Result<ModelContainer, Error>
    private let storePath: String

    /// FR-1.1's surface. Held here so it lives for the whole process — a
    /// controller that goes out of scope takes the hotkey with it.
    private let quickCapture: QuickCaptureController?

    /// FR-1.2's surface, held for the same reason: a released controller takes
    /// the status item out of the menu bar with it.
    private let menuBar: MenuBarController?

    /// FR-6's surface. Built here for the reason the two controllers are: the
    /// `Settings` scene's content is rebuilt freely by SwiftUI, and the state
    /// behind it must not be.
    private let settingsModel: SettingsModel

    /// FR-6's Data pane, built here for the reason above.
    private let dataSettingsModel: DataSettingsModel

    /// FR-6's AI pane, built here for the reason above — and built outside the
    /// `store` switch below, unlike its two siblings: a credential lives in the
    /// Keychain and a model id in `UserDefaults`, so this pane is fully
    /// functional in a build whose store will not open (§13).
    private let aiSettingsModel: AISettingsModel

    /// §5.1's connectors, built once for the process.
    ///
    /// **Empty this milestone** (D-179): no connector conforms to
    /// `SourceConnector` until M4-02, so every `SourceRef` dispatches
    /// `.unhandled` and both refresh paths are no-ops. Registration order is
    /// priority, and it lives here — one readable array literal — rather than in a
    /// `register()` call some pane could reorder.
    private let sourceRegistry = SourceRegistry(connectors: [])

    /// §10.5's auto-export. Held for the whole process because it owns a timer
    /// and a termination observation — a controller that went out of scope
    /// would take both with it, and the backup would quietly stop happening.
    private let autoExport: AutoExportController?

    /// Exists to keep the app alive when the last window closes, which is what
    /// makes "the icon is present without the main window open" true.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // os.Logger writes to the unified log, never to stdio — this line is
        // what makes `make run` self-evidencing that it execs the binary and
        // inherits the terminal's stdout rather than detaching via `open`
        // (REQUIREMENTS.md §9.2). The flush matters: stdout is fully buffered
        // when it is not a TTY, and the app is killed by a signal rather than
        // exiting, so without it the line is discarded whenever output is
        // redirected — which is how it gets verified.
        print("Steno launched")
        fflush(stdout)
        Log.app.info("Steno launched")

        // §7.1's list, with the one provider that ships. The two
        // `KeychainCredentialStore` values are separate instances of a
        // stateless struct, the posture D-109 records for `AppKitFilePanels`.
        aiSettingsModel = AISettingsModel(
            providers: [AnthropicProvider(credentials: KeychainCredentialStore())],
            credentials: KeychainCredentialStore())

        let path = (try? StenoStore.defaultURL.path) ?? "<could not resolve Application Support>"
        storePath = path
        store = Result { try StenoStore.live() }

        // A store path is not a secret, so §8's redaction rule is not engaged —
        // and knowing where the data went is worth a line in the log.
        switch store {
        case .success:
            Log.app.info("store opened at \(path, privacy: .public)")
        case .failure(let error):
            // A single interpolated literal, not two concatenated with `+` —
            // `OSLogMessage` has no `+` operator, so the prescribed two-piece
            // form does not compile (see the report for this task).
            let detail = "store failed to open at \(path): \(String(describing: error))"
            Log.app.fault("\(detail, privacy: .public)")
        }

        // Capture must always have somewhere to go (FR-1.4, §1.1). A failure
        // here is not fatal — the window still opens, and the empty state
        // tells the user to create a project — so it is logged, not surfaced.
        if case .success(let container) = store {
            do {
                // `container.mainContext`, deliberately — **not** a fresh
                // `ModelContext(container)`. `MainWindowView.init` builds its
                // view model over `mainContext`, so seeding into the same
                // context makes the window's first fetch a same-context read
                // that is guaranteed to see the seeded row. A sibling context
                // would leave the one guarantee this seeding exists to make
                // resting on cross-context visibility, which SwiftData does
                // not contractually document — and which no test here could
                // cover, since GUI automation is unavailable.
                //
                // This does not contradict the tests' use of
                // `ModelContext(container)`: that rule exists because
                // `mainContext` does not retain its container, and a test
                // whose container is a local would dangle. Here `store` is a
                // stored property of the `@main` App, so the container lives
                // for the whole process.
                if let seeded = try StenoStore.seedDefaultProjectIfEmpty(
                    in: container.mainContext)
                {
                    Log.app.info("seeded default project \(seeded.name, privacy: .public)")
                }
            } catch {
                Log.app.error(
                    "could not seed the default project: \(String(describing: error), privacy: .public)"
                )
            }
        }

        // Only on a working store: with no container there is nowhere to
        // capture to, and a hotkey opening a panel over a failure scene would
        // be worse than no hotkey (D-018).
        if case .success(let container) = store {
            let controller = QuickCaptureController(container: container)
            controller.start()
            quickCapture = controller
            menuBar = MenuBarController(container: container)
            settingsModel = SettingsModel(
                hotkey: controller.hotkeyBinding, context: container.mainContext)

            // §10.5. One service, shared by the automatic triggers and the
            // Data pane's "Back Up Now", so the two cannot disagree about
            // where a backup goes or what the last one did.
            let exporter = AutoExportService(context: container.mainContext)
            dataSettingsModel = DataSettingsModel(
                // A second `AppKitFilePanels` — `MainWindowView` builds its
                // own. The type is stateless, and threading one instance
                // through two scenes would buy nothing (D-109).
                panels: AppKitFilePanels(), service: exporter)
            let exportController = AutoExportController(service: exporter)
            exportController.start()
            autoExport = exportController

            Self.startLaunchRefresh(container: container, registry: sourceRegistry)
        } else {
            quickCapture = nil
            menuBar = nil
            // No store means nothing to export. The pane still opens and says
            // so, which is §13's rule that degradation ships with the feature.
            dataSettingsModel = DataSettingsModel()
            autoExport = nil
            // Settings still opens. Launch at login has no store dependency
            // and stays live; the hotkey and default-project controls disable
            // themselves and say why (§13 — degradation ships with the
            // feature, not after it).
            settingsModel = SettingsModel()
        }
    }

    /// §5.5's launch pass: refs on non-done tasks not fetched in the last 30
    /// minutes.
    ///
    /// Fire-and-forget, silent, logs only (D-176) — it warms the cache so the
    /// morning view is instant, and a visible indicator would invite the user to
    /// wait for something designed not to be waited on.
    ///
    /// **Here rather than in `MainWindowModel.init`** (D-179). The CLI bundle
    /// builds a store too, and `steno export` must not open network connections.
    /// `mainContext`, for the reason the seeding above uses it: the window's own
    /// model reads that context, so a pass writing into a sibling would depend on
    /// cross-context visibility.
    ///
    /// M4-05 replaces this single call with its scheduled equivalent.
    ///
    /// `static`, so `init` can call it before `self` exists — and its own function
    /// rather than six lines inline, because `init` is at SwiftLint's
    /// `function_body_length` limit.
    private static func startLaunchRefresh(
        container: ModelContainer, registry: SourceRegistry
    ) {
        let context = container.mainContext
        Task { @MainActor in
            _ = await SourceRefreshService(context: context, registry: registry).refreshDue()
        }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`. The main window is already
        // single-instance in practice — `MainWindowCommands` replaces
        // `.newItem`, so nothing opens a second — and `Window` is what makes
        // reopening *the* window possible: a `WindowGroup` answers a reopen by
        // minting another one (D-040). A `Window` scene is also expected to
        // contribute its own Window-menu item, which would make the popover's
        // button not the only way back — expected, not observed: nobody has
        // been able to look at the menu here, so M1-04's manual pass checks it
        // rather than this comment asserting it.
        Window("Steno", id: MainWindowReveal.sceneID) {
            switch store {
            case .success(let container):
                // No `.modelContainer(container)`: no view reaches the store
                // directly, so ARCHITECTURE §2 rule 2 holds by construction
                // rather than by discipline. Do not add it back without a view
                // that genuinely needs `@Query`.
                MainWindowView(container: container, registry: sourceRegistry)
            case .failure(let error):
                StoreFailureView(path: storePath, error: error)
            }
        }
        .commands { MainWindowCommands() }

        // FR-6. A `Settings` scene rather than a second `Window`: this is what
        // puts "Steno › Settings…" in the application menu at the right
        // position with ⌘, bound, and makes macOS treat the window as a
        // settings window. ⌘, is the only entry point by decision — clicking
        // the menu bar icon activates the app (`MenuBarController.show` calls
        // `NSApp.activate`), so the application menu is reachable even with no
        // window open, and M1-04's popover is left as it was built.
        Settings {
            SettingsView(
                model: settingsModel, dataModel: dataSettingsModel, aiModel: aiSettingsModel)
        }
    }
}
