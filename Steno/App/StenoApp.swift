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
    }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                ContentView().modelContainer(container)
            case .failure(let error):
                StoreFailureView(path: storePath, error: error)
            }
        }
    }
}
