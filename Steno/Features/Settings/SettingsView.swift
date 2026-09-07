import StenoKit
import SwiftUI

/// The Settings window's shell.
///
/// **The `switch` carries no `default` arm, deliberately.** An exhaustive
/// switch means adding a `SettingsPane` case fails to compile until its view
/// exists, so the registry cannot silently acquire a tab that renders nothing
/// — the one failure mode a registry of this shape has.
///
/// With a single case today the `TabView` draws a toolbar with one segment,
/// which reads a little oddly until M3-04 lands. Left alone on purpose: a
/// `count == 1` special case becomes dead code the day the second pane
/// arrives, and this is the shape all five panes use.
struct SettingsView: View {
    let model: SettingsModel
    @State private var selection: SettingsPane = .capture

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPane.allCases) { pane in
                content(for: pane)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        // A fixed width, as macOS settings windows are; the height follows the
        // pane, so a later, taller pane does not have to fight this frame.
        .frame(width: 460)
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .capture:
            CaptureSettingsPane(model: model)
        }
    }
}
