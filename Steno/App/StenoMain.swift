import Darwin  // exit — explicit rather than transitively via StenoKit
import StenoKit

/// The process entry point, and the one thing in this target the headless test
/// bundle cannot reach.
///
/// **Six lines, deliberately.** The test bundle is unhosted and links `StenoKit`
/// rather than the application (D-010), so every line here is a line no test can
/// run. Both halves of the decision live in `CLIEntry`, which the suite covers
/// directly; what remains is the `@main` attribute, which cannot live anywhere
/// else, and the call into SwiftUI.
///
/// **Why the attribute moved off `StenoApp`.** A GUI `.app` bundle taking argv
/// is unusual on macOS, and the alternative — branching inside `StenoApp.init`
/// — does not work at all: SwiftUI's generated `main` starts `NSApplication`
/// before any of our code runs, so a subcommand would already have required a
/// window server by the time it could refuse to open a window. §10.5's "on the
/// app binary" rules out a second executable target, which would also double the
/// signing configuration §9.3 pins.
@main
enum StenoMain {
    static func main() {
        let arguments = CommandLine.arguments
        if CLIEntry.isCommandLineInvocation(arguments) {
            // `assumeIsolated`, not a `Task`: `main()` runs on the main thread,
            // and hopping to an actor would return here immediately and fall
            // through to `StenoApp.main()` — launching the GUI *and* running the
            // command. The assumption is checked at runtime, so a future change
            // that moves this off the main thread traps here rather than
            // producing a data race in a `ModelContext`.
            exit(MainActor.assumeIsolated { CLIEntry.run(arguments) })
        }
        // `if` / `exit`, not `guard` / `else`: `App.main()` is declared to
        // return `Void` rather than `Never`, so a `guard` whose `else` branch
        // called it would not compile.
        StenoApp.main()
    }
}
