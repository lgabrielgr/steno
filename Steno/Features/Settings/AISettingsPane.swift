import StenoKit
import SwiftUI

/// FR-6's AI area: provider, key, model, and "Test connection" (§7.1, §7.2, §8).
///
/// Kept as small as its two siblings, and for the same reason — this is a
/// recall tool, and time spent in configuration is time not spent capturing.
/// Every decision below lives on `AISettingsModel`; this file arranges controls
/// and owns no rule, because the unhosted test bundle cannot reach this target
/// (D-010).
struct AISettingsPane: View {
    @Bindable var model: AISettingsModel

    var body: some View {
        Form {
            // The question a user opens this pane asking, answered before they
            // read anything else. `AISettingsModel.readiness` derives it from
            // the same two conditions `MainWindowModel.standupPolish` reads, so
            // it cannot claim the AI is on while §7.4's raw path is what runs.
            Section {
                readinessLine
            }

            Section("Provider") {
                Picker("Provider", selection: $model.selectedProviderID) {
                    ForEach(model.providerChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .disabled(model.providerChoices.count < 2 || model.isBusy)

                // §7.2: the API key is the only enabled option in Settings v1,
                // so one selectable kind renders as a label rather than as a
                // picker of one.
                if model.credentialKinds.count == 1 {
                    LabeledContent("Sign in with") { Text("An API key") }
                }

                disclosure
            }

            Section("API key") {
                // Entry only (D-157): this field never receives the stored key,
                // so what is on screen is what the user just typed.
                //
                // **The string is the `prompt`, not the label, and the style is
                // explicit.** A grouped `Form` renders a labelled field as a
                // left-hand label plus whatever width is left over, so
                // `SecureField("Paste your API key", …)` drew that sentence as
                // static text and left a caret-width control against the right
                // edge — the user reported clicking the words and nothing
                // happening. `BackupFolderField` already draws its own bordered
                // box for this same reason; this is the editable version of
                // that fix. `labelsHidden()` keeps the accessibility label
                // without drawing a second copy of the section header.
                SecureField(
                    "API key", text: $model.keyEntry,
                    prompt: Text(
                        model.hasStoredKey
                            ? "Paste a new key to replace the stored one" : "Paste your API key")
                )
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                // Paste, Return, done. `saveKey()` refuses an empty or
                // all-whitespace entry, so Return on an empty field is a
                // no-op rather than a spurious Keychain write.
                .onSubmit { Task { await model.saveKey() } }

                // Directly under the field it describes, not three controls
                // below it: the reporter of this change had a key stored and
                // said nothing on screen told them so. A glyph carries the
                // state at a glance; the sentence carries the detail.
                if model.hasStoredKey {
                    Label {
                        Text("A key is stored in your login Keychain. Steno never shows it again.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.callout)
                } else {
                    Label(
                        "Without a key, Steno still writes your stand-up — from your log alone, "
                            + "a little rougher.", systemImage: "key.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button(model.hasStoredKey ? "Replace Key" : "Save Key") {
                        Task { await model.saveKey() }
                    }
                    .disabled(model.keyEntry.isEmpty || model.isBusy)

                    Button("Remove Key") { model.removeKey() }
                        .disabled(!model.hasStoredKey || model.isBusy)
                }

                if let problem = model.keyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(model.modelRows) { row in
                        Text(row.displayName).tag(row.id)
                    }
                    // Tied to the *selection*, not to the row count: a
                    // successful refresh with nothing selected (a key saved
                    // while offline, refreshed later) leaves rows with no tag
                    // matching the binding's "", which renders a blank picker.
                    if model.selectedModelID == nil {
                        Text("No model selected").tag("")
                    }
                }
                .disabled(model.isBusy)

                Button("Refresh Models") { Task { await model.refreshModels() } }
                    .disabled(model.isBusy)

                // `selectionIsUnlisted` covers two situations that need
                // different sentences: the list has not been fetched (D-158's
                // ordinary state), and the list was fetched and no longer
                // offers this model. Telling the second user to press Refresh
                // sends them to a button that cannot help.
                switch model.selectionStatus {
                case .notFetchedYet:
                    Text(
                        "Steno hasn't fetched the model list yet — it only asks when you save a "
                            + "key or press Refresh. Your stand-ups use the model above until then."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                case .noLongerOffered:
                    Text(
                        "Your provider no longer offers this model. Steno keeps using it until "
                            + "you pick another — pick one above if your stand-ups stop working."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                case .none, .offered:
                    EmptyView()
                }

                if case .failed(let error) = model.listState {
                    note(error, advice: model.listAdvice)
                }
            }

            Section("Connection") {
                Button("Test Connection") { Task { await model.testConnection() } }
                    .disabled(model.isBusy)

                switch model.connection {
                case .untested:
                    EmptyView()
                case .testing:
                    Text("Asking the provider…").font(.callout).foregroundStyle(.secondary)
                case .passed:
                    Label("The key works.", systemImage: "checkmark.circle")
                        .font(.callout)
                case .failed(let error):
                    note(error, advice: model.connectionAdvice)
                }
            }
        }
        .formStyle(.grouped)
        // D-157: the model is built once in `StenoApp.init` and held for the
        // process, so "the field starts empty" is a fact only the view can
        // make true. On disappear as well as appear, so an unsaved key does not
        // sit in memory for as long as the app runs.
        .onAppear { model.forgetEntry() }
        .onDisappear { model.forgetEntry() }
    }

    /// Whether the AI path will run, in one line.
    ///
    /// Three states rather than two, because "a key but no model" is reachable
    /// — a first key saved while offline adopts no default (D-159) — and its
    /// remedy is Refresh, not another key. Saying only "off" there would send
    /// the user back to the field they already filled in correctly.
    @ViewBuilder
    private var readinessLine: some View {
        switch model.readiness {
        case .ready(let name):
            Label {
                Text("AI polishing is on — stand-ups go to \(name).")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .noKey:
            Label(
                "AI polishing is off — stand-ups come from your log alone. Add a key below.",
                systemImage: "info.circle")
        case .noModel:
            Label(
                "AI polishing is off — a key is stored, but no model is selected. "
                    + "Press Refresh Models below.", systemImage: "info.circle")
        }
    }

    /// §8: "onboarding must state plainly which content is transmitted to the
    /// AI provider, so the user can re-evaluate if their employer's policy
    /// changes."
    ///
    /// **Inline and always visible, rather than a first-run sheet.** A modal
    /// shown once is exactly the surface a policy change cannot bring back.
    ///
    /// Every clause is checked against `StandupPrompt.user`,
    /// `ReportGatherer.gather` and `EventQueries.inWindow` — it describes what
    /// this build sends, not what a future one will: M4-02 and M4-03 add
    /// fetched Jira and Confluence text, which D4 permits, and this paragraph
    /// must grow a clause when they land.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What Steno sends to Anthropic").font(.callout.bold())
            Text(
                "When a stand-up is polished, Steno sends one project's report window: its start "
                    + "and end, and for every task in it — the title, the status, any ticket keys, "
                    + "the blocked reason, and every event inside that window, each with its "
                    + "timestamp. Your notes and blocked reasons go in the words you typed, whole "
                    + "and unshortened; the rest is recorded data Steno wrote itself (when the "
                    + "task was created, and each status change). Each task also carries a stable "
                    + "internal identifier so the model can refer to it, and a blocked reason is "
                    + "sent even if you wrote it before this window."
            )
            Text(
                "Not sent: other projects, tasks outside the window, and notes you have redacted. "
                    + "Your API key travels in the request's `x-api-key` header and is stored only "
                    + "in your login Keychain — never in Steno's data file, its preferences, or "
                    + "its logs."
            )
            Text(
                "Your stand-ups reach Anthropic only when a key is set and a model is selected — "
                    + "otherwise Steno builds them from your log alone. \"Test Connection\" and "
                    + "\"Refresh Models\" contact Anthropic when you press them, and send no "
                    + "task content."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// One failure, worded by `AIError` and pointed by the model's advice.
    @ViewBuilder
    private func note(_ error: AIError, advice: AISettingsModel.Advice?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                error.errorDescription ?? "The provider could not be reached.",
                systemImage: advice == .fixTheKey
                    ? "key.slash" : "exclamationmark.triangle")
            if advice == .fixTheKey {
                Text("Check the key above, then try again.")
            } else {
                Text("Nothing here is wrong — try again in a moment.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// The picker's binding.
    ///
    /// Written by hand rather than with `$model.selectedModelID` because the
    /// setter is not a property write: it goes through `select(modelID:)`,
    /// which is what puts the choice in `AppSettings` where
    /// `MainWindowModel.standupPolish` reads it.
    private var modelSelection: Binding<String> {
        Binding(
            get: { model.selectedModelID ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                model.select(modelID: newValue)
            })
    }
}
