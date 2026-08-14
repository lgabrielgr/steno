import SwiftUI

@main
struct StenoApp: App {
    init() {
        Log.app.info("Steno launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
