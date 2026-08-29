import StenoKit
import SwiftUI

/// FR-3's third column: title, status, and the event timeline.
///
/// **The status control writes through `MainWindowModel`, never directly.**
/// The model publishes live `@Model` objects, so a view holds a real
/// `TaskItem` — but `TaskItem`'s mutators are `internal` as of M1-05, so this
/// file cannot skip `StatusService` and the event it appends even by mistake
/// (D-033).
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

                    StatusControl(current: task.status) { new in
                        model.setStatus(new, on: task.id)
                    }

                    Divider()

                    Text("Timeline")
                        .font(.headline)

                    // Observed state, not a fetch: the model refreshes this
                    // when the selection or the store changes. Calling a
                    // fetching method here instead would give SwiftUI no
                    // dependency to track, and would let a failed read set
                    // `lastError` mid-render — which this window observes, so
                    // the failure would re-invalidate the view that caused it.
                    let events = model.selectedTaskEvents
                    if events.isEmpty {
                        // §3.3 gives every task a `created` event, so an empty
                        // timeline is never a normal state — the read failed,
                        // or the log is genuinely missing rows. Say which.
                        // "No events." would present either as a fact about
                        // the task.
                        Text(
                            model.selectedTaskTimelineFailed
                                ? "The timeline could not be loaded."
                                : "No events — every task should carry a created event, so this is unexpected."
                        )
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
