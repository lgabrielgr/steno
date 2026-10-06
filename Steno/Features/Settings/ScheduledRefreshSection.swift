import StenoKit
import SwiftUI

/// FR-6's control over §5.5's scheduled refresh: a switch and a time.
///
/// Its own file rather than another section inside `IntegrationsSettingsPane`, which
/// is at SwiftLint's `type_body_length` limit — the same reason
/// `IntegrationsPurgeSection` lives at the bottom of that file. It owns no rule;
/// everything it reads and writes is `ScheduledRefreshSettingsModel`, because the
/// unhosted test bundle cannot reach this target (D-010).
struct ScheduledRefreshSection: View {
    @Bindable var model: ScheduledRefreshSettingsModel

    var body: some View {
        // **A `Group`, so the whole section can carry one `.onAppear`.** The rows below are
        // separate `Form` children and a modifier cannot attach to the implicit tuple; a
        // `Group` is transparent in a `Form`, so each child is still its own row.
        Group {
            Toggle("Refresh in the background", isOn: $model.isEnabled)

            DatePicker(
                "At", selection: $model.pickerDate, displayedComponents: .hourAndMinute
            )
            .disabled(!model.isEnabled)
            // The visible label is one word, which tells a screen-reader user nothing
            // about what happens at that time. Nothing automated reaches VoiceOver, so
            // this line and the manual pass are the only things holding it.
            .accessibilityLabel("Scheduled refresh time")

            // D-227: the one thing an unattended pass can discover that no other surface can.
            // `expiryWarning` above is derived from the date the user typed, so a *revoked*
            // token shows nothing there — this is where the user finds out before a stand-up
            // depends on it. A timestamped fact, so it stays true after the token is replaced
            // and until a later pass clears it.
            if let rejection = model.credentialRejection {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A background refresh couldn't sign in to \(rejection.displayName).")
                        Text(
                            "Your token may have been revoked. Test the connection above, or paste a "
                                + "new one."
                        )
                        .foregroundStyle(.secondary)
                        Text(rejection.discoveredAt, format: .dateTime.weekday().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.slash")
                }
                .font(.callout)
            }

            // **Names the limitation rather than implying a guarantee.** The schedule
            // needs the app to be running, and a Mac asleep until the afternoon simply
            // refreshes on the next launch — "within a few hours" is
            // `ScheduledRefreshDue.grace`, so if that changes this sentence is part of the
            // change.
            Text(
                "Fetches ticket and page updates at this time, so your stand-up is ready "
                    + "without waiting. Skipped while your Mac is asleep; Steno catches up when "
                    + "it next wakes, within a few hours of the time you set."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        // D-227: a background pass refused at 08:00 is recorded while this window is closed,
        // so appearing is when the view has to go and look. Here rather than on the pane's
        // own `onAppear`, which is where it started: `IntegrationsSettingsPane` is at
        // SwiftLint's `file_length` limit, and the reload belongs with the view that reads
        // the value anyway.
        .onAppear { model.reload() }
    }
}
