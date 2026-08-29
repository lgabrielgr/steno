import StenoKit
import SwiftUI

/// The four statuses as menu items, with a checkmark on the current one.
///
/// **One list, every surface.** The detail pane's menu and the task rows'
/// context menu both render this, and M1-04's popover will too, so the four
/// statuses cannot acquire a per-surface spelling — the same argument that put
/// `Status.displayName` in StenoKit rather than in a view.
struct StatusMenuItems: View {
    let current: Status
    let onSelect: (Status) -> Void

    var body: some View {
        // `id: \.self` because `Status` is not `Identifiable`; it is a raw
        // `String` enum, so it is `Hashable` for free.
        ForEach(Status.allCases, id: \.self) { status in
            Button {
                onSelect(status)
            } label: {
                // Two branches rather than one `Label` with a conditional
                // image name: an empty `systemImage` string renders as a
                // missing-image placeholder, not as nothing.
                if status == current {
                    Label(status.displayName, systemImage: "checkmark")
                } else {
                    Text(status.displayName)
                }
            }
        }
    }
}

/// The detail pane's status control: the current status, clickable.
struct StatusControl: View {
    let current: Status
    let onSelect: (Status) -> Void

    var body: some View {
        Menu {
            StatusMenuItems(current: current, onSelect: onSelect)
        } label: {
            Text(current.displayName)
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
