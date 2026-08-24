import StenoKit
import SwiftUI

/// FR-3's third column: title, status, and the event timeline.
///
/// **The status is a label, not a control.** Status changes are M1-05; this
/// task displays status and never mutates it.
///
/// The timeline is not empty, though the task file said it would be: §3.3
/// requires a `created` event on every task, so there is always exactly one
/// row here today. M1-06 adds note entry, the correction window, and redaction.
struct TaskDetailView: View {
    let model: MainWindowModel
    let taskID: UUID?

    var body: some View {
        if let taskID, let task = model.task(withID: taskID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(task.title)
                        .font(.title2)

                    Text(task.status.displayName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())

                    Divider()

                    Text("Timeline")
                        .font(.headline)

                    let events = model.events(forTaskID: taskID)
                    if events.isEmpty {
                        Text("No events.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.body)
                                Text(event.timestamp, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            ContentUnavailableView("No task selected", systemImage: "sidebar.right")
        }
    }
}
