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
}
