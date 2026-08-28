import Darwin  // fflush/stdout — explicit rather than transitively via SwiftUI
import StenoKit
import SwiftData
import SwiftUI

@main
struct StenoApp: App {
    /// Built once, here, rather than by `.modelContainer(for:)` — which traps
    /// on failure. See `StoreFailureView` for why this is a `Result`.
    private let store: Result<ModelContainer, Error>
    private let storePath: String

    /// FR-1.1's surface. Held here so it lives for the whole process — a
    /// controller that goes out of scope takes the hotkey with it.
    private let quickCapture: QuickCaptureController?

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
        } else {
            quickCapture = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                // No `.modelContainer(container)`: no view reaches the store
                // directly, so ARCHITECTURE §2 rule 2 holds by construction
                // rather than by discipline. Do not add it back without a view
                // that genuinely needs `@Query`.
                MainWindowView(container: container)
            case .failure(let error):
                StoreFailureView(path: storePath, error: error)
            }
        }
        .commands { MainWindowCommands() }
    }
}
