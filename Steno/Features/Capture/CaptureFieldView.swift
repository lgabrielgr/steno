import StenoKit
import SwiftUI

/// FR-1's capture field: one focused line, `Return` commits, `Esc` dismisses.
///
/// **The surface-shared one.** M1-03's floating window and M1-04's popover
/// embed this view rather than rebuilding it, which is what makes D15's "one
/// code path" true of the UI as well as the write.
///
/// Everything stateful lives in `CaptureFieldModel` over in `StenoKit`, where
/// the headless bundle can reach it; this file is layout.
struct CaptureFieldView: View {
    @Bindable var field: CaptureFieldModel
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What are you working on?", text: $field.text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)

            if let chip = field.chip {
                chipView(chip)
            }

            if let message = field.lastError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(field.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        // FR-1.1: focused the instant it appears, no click required.
        .onAppear { isFocused = true }
    }

    /// FR-1.4's dismissible inline chip.
    ///
    /// A plain button with an `xmark`, not a confirmation: §1.1 treats a modal
    /// interruption during capture as a defect, so declining the routing costs
    /// exactly one click and blocks nothing.
    private func chipView(_ chip: CaptureChip) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(projectHex: chip.colorHex))
                .frame(width: 8, height: 8)
            Text(chip.projectName)
                .font(.caption)
            Button {
                field.dismissChip()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Don't file under \(chip.projectName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(projectHex: chip.colorHex).opacity(0.15), in: Capsule())
    }

    private func commit() {
        field.commit()
        // A failed save keeps the text and reports why, so the sheet stays
        // open for the retry rather than swallowing the capture.
        if field.lastError == nil { onDismiss() }
    }
}

/// Owns the field model for one presentation of the capture sheet.
///
/// `@State`, not a value built in `body`: `.sheet(item:)`'s content closure
/// re-runs on every render of the presenting view, and rebuilding the model
/// there would replace it with an empty one mid-capture — losing the user's
/// typing, which is the single worst thing a capture tool can do (§1.1).
///
/// `MainWindowView.init` already establishes this pattern for
/// `MainWindowModel`, and for the same reason.
struct NewTaskSheet: View {
    private let model: MainWindowModel
    @State private var field: CaptureFieldModel

    init(model: MainWindowModel) {
        self.model = model
        _field = State(
            initialValue: CaptureFieldModel(
                service: model.captureService(),
                projects: { model.projects },
                preferred: { model.preferredProjectIDForCapture },
                onCaptured: { _ in model.reload() }
            )
        )
    }

    var body: some View {
        CaptureFieldView(field: field) { model.activeSheet = nil }
    }
}
