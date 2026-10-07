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

        // **Names the limitation rather than implying a guarantee**, and this is the third
        // version of that sentence — the first two described behaviour the code had moved
        // past (Copilot, review round 5). It said "Steno catches up when it next wakes,
        // within a few hours of the time you set", which was wrong twice over: a *closed*
        // Steno cannot catch up on a wake, because there is no process to notice one; and
        // since D-228 a wake refreshes whether or not the occurrence is still inside its
        // four-hour window, so "within a few hours" limited something that is not limited.
        //
        // What it must convey is the one property of an in-process scheduler the user can
        // act on: Steno has to be running. The grace window is deliberately *not* mentioned
        // — it decides whether a pass counts as serving the morning, which is bookkeeping,
        // not something the user can see or do anything about.
        Text(
            "Fetches ticket and page updates at this time, so your stand-up is ready "
                + "without waiting. Steno has to be running: while it is, waking your Mac "
                + "refreshes too. If Steno is closed at that time, it refreshes the next "
                + "time you open it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
