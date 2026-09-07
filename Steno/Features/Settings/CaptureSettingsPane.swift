import StenoKit
import SwiftUI

/// FR-6's Capture area: hotkey binding, launch at login, default project.
///
/// Kept deliberately small. This is a recall tool, and time spent in
/// configuration is time not spent capturing — so each control gets one line
/// of explanation and no more.
struct CaptureSettingsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let note = model.storeFailureNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Shortcut") {
                LabeledContent("Global shortcut") {
                    HStack {
                        HotkeyRecorderView(
                            display: model.chord.displayString,
                            onRecord: { keyCode, modifiers in
                                model.record(keyCode: keyCode, modifiers: modifiers)
                            }
                        )
                        .frame(width: 130, height: 22)
                        .disabled(model.storeFailureNote != nil)

                        Button("Reset") { model.resetHotkeyToDefault() }
                            .disabled(model.storeFailureNote != nil)
                    }
                }

                // The rejection and the registration problem are different
                // failures and both can be live: a chord can be refused for
                // its modifiers, and the chord already bound can be in
                // conflict with a system shortcut.
                if let rejection = model.recorderRejection {
                    Text(rejection).font(.callout).foregroundStyle(.secondary)
                }
                if let problem = model.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch Steno at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                if let problem = model.loginProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Default project") {
                Picker(
                    "Capture to",
                    selection: Binding(
                        get: { model.resolvedDefaultProjectID },
                        set: { model.setDefaultProject($0) }
                    )
                ) {
                    Text("None — capture follows the most recent task's project")
                        .tag(UUID?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .disabled(model.storeFailureNote != nil)

                // FR-1.4's ladder puts this below last-used, so it is a
                // fresh-install backstop rather than a routing preference.
                // Saying so is the whole obligation the ordering creates.
                Text(
                    "Used only when the text has no matching ticket key and no task has been captured yet."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
