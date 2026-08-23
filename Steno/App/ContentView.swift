import StenoKit
import SwiftData
import SwiftUI

/// Placeholder window contents. M0-05 replaces this with the three-column shell.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]

    var body: some View {
        VStack(spacing: 12) {
            Text("Steno")

            // TEMPORARY — M0-04 only. The sole way to exercise acceptance
            // criterion 1 ("add a record, quit, relaunch") before M0-05 builds
            // real UI. **Delete this with the rest of the placeholder in
            // M0-05**, which replaces this file wholesale.
            Text("\(projects.count) projects stored")
            Button("Add sample project") {
                context.insert(
                    Project(
                        name: "Sample \(projects.count + 1)",
                        colorHex: "#3B82F6",
                        modifiedAt: .now
                    )
                )
                do {
                    try context.save()
                } catch {
                    // `@Query`'s count already reflects the in-memory insert
                    // even if this save fails, so a silent `try?` would leave
                    // the button lying about what's actually persisted —
                    // during precisely the manual check this file exists for.
                    Log.app.error(
                        "sample project save failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
