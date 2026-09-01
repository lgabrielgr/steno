import StenoKit
import SwiftUI

/// FR-1.2's popover: the quick-add field, the in-progress tasks with inline
/// status toggles, and the way back into the main window. Exactly those three
/// things — this is the surface seen most often without opening the app, and
/// it is not a second main window.
struct MenuBarPopoverView: View {
    let model: MenuBarModel
    let onDismiss: () -> Void
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptureFieldView(field: model.field, onDismiss: onDismiss, style: .popover)
                // Keyed on the open count so each open re-creates this view and
                // re-runs its `.onAppear` focus. The hosting controller is
                // resident, so without this the field is focused on the first
                // open of a launch and no other — see `MenuBarModel.showCount`.
                .id(model.showCount)

            if let message = model.lastError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider()

            if model.rows.isEmpty {
                Text("Nothing in progress.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                // A plain VStack, not a `List`: D18 caps the whole dataset
                // under 20 live tasks, and §2.1's "build the simple thing"
                // applies here more than anywhere — a scroller inside a
                // popover is a workflow problem, not a UI problem.
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        MenuBarTaskRow(row: row) { model.setStatus($0, on: row.id) }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            Button("Open Main Window", action: onOpenMainWindow)
                .buttonStyle(.plain)
                .padding(12)
        }
        .frame(width: CaptureFieldStyle.popover.width)
    }
}

/// One in-progress task, with FR-1.2's inline status toggle.
private struct MenuBarTaskRow: View {
    let row: MenuBarRow
    let onSelect: (Status) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(projectHex: row.colorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(row.projectName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // `StatusMenuItems`, not a second list of four: M1-05 put it in
            // one place so the statuses cannot acquire a per-surface spelling.
            Menu {
                StatusMenuItems(current: row.status, onSelect: onSelect)
            } label: {
                Text(row.status.displayName)
                    .font(.caption2.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
