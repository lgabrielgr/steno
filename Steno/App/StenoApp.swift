import SwiftUI

@main
struct StenoApp: App {
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
