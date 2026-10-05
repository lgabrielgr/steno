import StenoKit
import SwiftUI

/// FR-6's Integrations area: the Atlassian credential, the per-integration toggle
/// and connection test, and "purge cached external data" (§5.2, §5.3, §8).
///
/// Kept as small as its three siblings, and for the same reason — this is a recall
/// tool, and time spent in configuration is time not spent capturing. Every
/// decision below lives on `IntegrationsSettingsModel`; this file arranges controls
/// and owns no rule, because the unhosted test bundle cannot reach this target
/// (D-010).
struct IntegrationsSettingsPane: View {
    @Bindable var model: IntegrationsSettingsModel

    var body: some View {
        Form {
            Section("Atlassian account") {
                // §5.2's three fields. One credential serves both Jira and
                // Confluence (§5.3), which is why this section is not per
                // integration while the rows below are.
                TextField("Site", text: $model.site, prompt: Text("acme.atlassian.net"))
                    .textFieldStyle(.roundedBorder)
                TextField("Email", text: $model.email, prompt: Text("you@example.com"))
                    .textFieldStyle(.roundedBorder)

                // **The string is the `prompt`, not the label, and the style is
                // explicit** — the fix D-157's pane already needed: a grouped
                // `Form` draws a titled field as left-hand static text plus
                // whatever width is left, which left a caret-width control against
                // the right edge that the user clicked with nothing happening.
                SecureField(
                    "API token", text: $model.tokenEntry,
                    prompt: Text(
                        model.hasStoredCredential
                            ? "Paste a new token to replace the stored one"
                            : "Paste your API token")
                )
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { model.saveCredential() }

                expiryControls

                HStack {
                    Button(model.hasStoredCredential ? "Replace Credential" : "Save Credential") {
                        model.saveCredential()
                    }
                    Button("Remove Credential") { model.removeCredential() }
                        .disabled(!model.hasStoredCredential)
                }

                storedCredentialNote

                if let problem = model.credentialProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                readOnlyNote
                adminPolicyNote
            }

            if let warning = model.expiryWarning {
                Section("Token expiry") {
                    expiryWarningRow(warning)
                }
            }

            Section("Integrations") {
                ForEach(model.rows) { row in
                    integrationRow(row)
                }
            }

            Section("Cached data") {
                purgeControls
            }
        }
        .formStyle(.grouped)
        // D-218 and D-157's rule: this model is built once in `StenoApp.init` and
        // held for the process, so "the token field starts empty" is a fact only
        // the view can make true. On disappear as well as appear, so an unsaved
        // token does not sit in memory for as long as the app runs.
        .onAppear { model.forgetEntry() }
        .onDisappear { model.forgetEntry() }
    }

    /// §5.2's user-entered expiry, behind its own switch.
    ///
    /// The toggle exists because the date is genuinely optional: `AtlassianLogin`
    /// accepts a blank one and §5.2's warning then cannot fire (D-192), so a picker
    /// with no off switch would invent a date the user never recorded.
    @ViewBuilder
    private var expiryControls: some View {
        Toggle("I recorded an expiry date", isOn: $model.recordsExpiry)
        if model.recordsExpiry {
            DatePicker(
                "Token expires", selection: $model.expiresAt, displayedComponents: .date
            )
            .datePickerStyle(.compact)
        }
    }

    /// What is stored, at a glance.
    ///
    /// Three states, not two: "the Keychain refused the read" is distinct from "no
    /// credential", because telling a user with a locked keychain that nothing is
    /// stored sends them to retype a token that is already there.
    @ViewBuilder
    private var storedCredentialNote: some View {
        switch model.storedCredential {
        case .present(let site, let email, _):
            Label {
                Text(
                    "Stored in your login Keychain: \(email) at \(site). "
                        + "Steno never shows the token again.")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)
        case .unreadable:
            Label(
                "Steno couldn't read your stored credential — it may still be there. "
                    + "Unlock your login Keychain and reopen this window.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .absent:
            Label(
                "No Atlassian credential yet. Without one, Steno still writes your stand-up "
                    + "from your log alone.", systemImage: "key.slash"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    /// §8: "Atlassian credentials must be read-scoped. Document this in onboarding."
    ///
    /// **Inline and always visible, rather than a first-run sheet**, for the AI
    /// pane's reason: a modal shown once is the surface a policy change cannot
    /// bring back. Every clause is checked against code rather than against a
    /// design document — `ReadOnlyTransport.isAllowed` permits `.get` and nothing
    /// else and `send` traps on anything else, `JiraEndpoint.request` and
    /// `ConfluenceEndpoint.request` hard-code `method: .get`, and
    /// `AtlassianCredential.baseURL` builds its own `https` URL from a validated
    /// `*.atlassian.net` host.
    private var readOnlyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steno only reads").font(.callout.bold())
            Text(
                "Create your token with read-only scopes. Steno only ever sends GET requests — "
                    + "it cannot change a ticket, a page or a comment, and a build that tried "
                    + "would stop rather than send it. Your token goes to your Atlassian site "
                    + "over HTTPS and nowhere else, and is stored only in your login Keychain "
                    + "— never in Steno's data file, its preferences, or its logs."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// §5.2's org-policy caveat, said here rather than discovered during stand-up
    /// prep.
    private var adminPolicyNote: some View {
        Text(
            "If your Atlassian admin has blocked API token creation, nothing here can work "
                + "around it — that's a conversation with them."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// §5.2's 14-day warning, with the link it requires.
    private func expiryWarningRow(_ warning: SourceCredentialWarning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(expiryText(warning), systemImage: "exclamationmark.triangle.fill")
            Link("Create a new token", destination: warning.renewalURL)
        }
        .font(.callout)
    }

    /// The same wording the stand-up banner uses, for the same reason: "expires
    /// 2027-03-01" asks the reader to do arithmetic in the ninety seconds before
    /// their stand-up.
    private func expiryText(_ warning: SourceCredentialWarning) -> String {
        switch warning.daysRemaining {
        case ..<0: return "Your Atlassian token has expired."
        case 0: return "Your Atlassian token expires today."
        case 1: return "Your Atlassian token expires tomorrow."
        default: return "Your Atlassian token expires in \(warning.daysRemaining) days."
        }
    }

    /// One integration: its toggle, its test, and its verdict.
    @ViewBuilder
    private func integrationRow(_ row: IntegrationsSettingsModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(
                    row.displayName,
                    isOn: Binding(
                        get: { row.isEnabled },
                        // Not `$model.rows`: enablement goes through the model, which
                        // is what puts it in `AppSettings` where `SourceRegistry`
                        // reads it per dispatch (D-216).
                        set: { model.setIntegration(row.id, enabled: $0) }))

                Spacer()

                Button("Test") { Task { await model.testConnection(id: row.id) } }
                    .disabled(!row.isEnabled || model.isBusy)

                if row.test == .testing {
                    ProgressView().controlSize(.small)
                }
            }

            verdict(for: row)
        }
    }

    /// The sentence for one row's last test.
    ///
    /// **The four the third acceptance criterion requires are four different
    /// sentences**, and they come from `SourceError.errorDescription` so the pane
    /// and the stand-up banner cannot drift apart — except `.siteNotFound`, which
    /// names the site this pane holds and the type deliberately does not carry
    /// (D-217).
    @ViewBuilder
    private func verdict(for row: IntegrationsSettingsModel.Row) -> some View {
        switch row.test {
        case .untested, .testing:
            if !row.isEnabled {
                Text("Switched off. Steno won't fetch for it, and your credential is kept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .passed:
            Label("Reached \(model.site).", systemImage: "checkmark.circle")
                .font(.callout)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(sentence(for: error), systemImage: symbol(for: error))
                if error == .credentialExpired {
                    Link("Create a new token", destination: AtlassianTokenExpiry.renewalURL)
                }
            }
            .font(.callout)
            .foregroundStyle(error == .credentialExpired ? .primary : .secondary)
        }
    }

    private func sentence(for error: SourceError) -> String {
        switch error {
        case .siteNotFound:
            // The one case that names the site, because this is the surface that
            // holds it.
            return "Steno couldn't find \(model.site). Check the site above."
        case .invalidCredential:
            return "Atlassian rejected this email and token. Check both, and see the note above "
                + "about admin policy."
        case .notConfigured:
            return "This integration isn't set up yet — save a credential above."
        default:
            return error.errorDescription ?? "The integration could not be reached."
        }
    }

    private func symbol(for error: SourceError) -> String {
        switch error {
        case .credentialExpired, .invalidCredential, .notConfigured: return "key.slash"
        case .siteNotFound: return "mappin.slash"
        default: return "exclamationmark.triangle"
        }
    }

    /// FR-6's "purge cached external data", behind a confirmation.
    @ViewBuilder
    private var purgeControls: some View {
        if let note = model.storeFailureNote {
            Text(note).font(.callout).foregroundStyle(.secondary)
        }

        Text(
            "Steno keeps each reference's last known state so a draft has something to show "
                + "when a fetch fails. Purging forgets it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        Button("Purge Cached External Data…") { isConfirmingPurge = true }
            .disabled(!model.canPurge)
            .confirmationDialog(
                "Purge cached external data?", isPresented: $isConfirmingPurge,
                titleVisibility: .visible
            ) {
                Button("Purge", role: .destructive) { model.purgeCache() }
                Button("Cancel", role: .cancel) {}
            } message: {
                // **What survives, named.** The claims here are checked against
                // `SourceCachePurge` and against what actually reads those columns:
                // nothing displays `cachedSummary` today, and the age a failed fetch
                // quotes comes from `lastFetchedAt`.
                Text(
                    "Your tasks, notes and history stay. Steno re-fetches on the next refresh; "
                        + "until then it can't tell you how old the data behind a failed fetch is."
                )
            }

        switch model.purgeState {
        case .idle:
            EmptyView()
        case .purged(let cleared):
            Label(
                cleared == 0
                    ? "There was nothing cached to purge."
                    : "Purged cached data for \(cleared) reference\(cleared == 1 ? "" : "s").",
                systemImage: "checkmark.circle"
            )
            .font(.callout)
        case .failed(let detail):
            Label(
                "Steno couldn't purge the cache: \(detail).",
                systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @State private var isConfirmingPurge = false
}
