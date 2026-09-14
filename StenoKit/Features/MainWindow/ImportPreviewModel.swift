import Foundation

/// Which half of §10.4's flow the preview sheet is showing.
public enum ImportPreviewPhase: Equatable, Sendable {
    /// The preview is up and nothing has been written.
    case previewing
    /// `apply` succeeded. The sheet stays up to say what happened.
    case applied
    /// §10.6's idempotency, seen from the user's side: this file has already
    /// been imported, so there is nothing to show and nothing to do.
    case nothingToImport
}

/// §10.4's preview: what an import will change, and the confirmation that lets
/// it happen.
///
/// **In `StenoKit`, not as `@State` in the sheet**, for `StandupDraftModel`'s
/// reason: D-010 puts view state beyond the headless bundle, and this task's
/// acceptance criteria — the preview's counts match what the import does,
/// cancelling changes nothing, Replace needs typed confirmation — are all
/// statements about this logic. GUI verification is unavailable here, so
/// anything a test can reach has to live on this side of the line.
///
/// **It holds no reference back to `MainWindowModel`.** Its inputs arrive as
/// parameters, so there is no closure web to initialise and no retain cycle to
/// weaken — the same split `MainWindowModel+Standup` makes for FR-4.
@Observable
@MainActor
public final class ImportPreviewModel {
    /// The word Replace demands, typed exactly.
    ///
    /// **Case-sensitive, and the word rather than the filename.** Retyping a
    /// filename is a transcription exercise, and the thing it actually trains
    /// is copy-and-paste — which is the one habit a typed confirmation exists
    /// to prevent. A fixed word cannot be pasted from anything on screen.
    public static let replaceConfirmationWord = "REPLACE"

    public private(set) var plan: ImportPlan?
    public private(set) var filename: String = ""
    public private(set) var mode: ImportMode = .merge
    public private(set) var phase: ImportPreviewPhase = .previewing

    /// Where the backup will be written, shown **before** the user commits.
    ///
    /// Non-nil only in `.replace`. That there is a way back is information the
    /// user needs while deciding, not a consolation afterwards.
    public private(set) var backupURL: URL?

    /// What the user has typed into the confirmation field.
    ///
    /// `var`, because the sheet binds a `TextField` to it. Every other property
    /// here is `private(set)`.
    public var confirmation: String = ""

    /// Set when the apply failed. See `StandupDraftModel` for why this is not
    /// the same property as `notice`: one means the write failed and retrying
    /// is safe, the other means it succeeded and retrying would import twice.
    public private(set) var lastError: String?

    /// Set when nothing failed but the user still needs telling — what was
    /// imported, and where the backup went.
    public private(set) var notice: String?

    public init() {}

    /// Show `plan` as the preview for the file named `filename`.
    ///
    /// **Writes nothing**, and there is no write path reachable from here. The
    /// plan was produced by `ImportService.plan`, which reads the store and
    /// writes nothing; this only puts it on screen. That is what makes
    /// "cancelling changes nothing" true by construction rather than by care.
    /// **The mode comes from the plan, and is not a separate parameter.**
    /// It was one until review of PR #30 pointed out what that allows: a
    /// `.replace` plan begun with `mode: .merge` makes `canApply` skip the
    /// typed-confirmation check while `applyImport` still applies the plan's
    /// deletion set — a public API that bypasses the only guard on the one
    /// destructive operation in the product. One source of truth removes the
    /// possibility rather than documenting it.
    public func begin(plan: ImportPlan, filename: String, backupURL: URL? = nil) {
        self.plan = plan
        self.filename = filename
        self.mode = plan.mode
        self.backupURL = backupURL
        self.confirmation = ""
        self.lastError = nil
        self.notice = nil
        // §10.6's idempotency is what the user sees here: the second import of
        // a file lands on this phase, and the sheet says so rather than showing
        // three lines of zeroes.
        self.phase = plan.isEmpty ? .nothingToImport : .previewing
    }

    /// The sheet closing, by Cancel, Esc, or Close.
    ///
    /// Clears everything. There is nothing worth preserving: re-reading the
    /// file is free and produces a plan against the store as it is now, which
    /// is strictly better than one computed before the user went away.
    public func dismiss() {
        plan = nil
        filename = ""
        mode = .merge
        backupURL = nil
        confirmation = ""
        lastError = nil
        notice = nil
        phase = .previewing
    }

    /// Whether the confirm button does anything.
    ///
    /// **Replace adds the typed word to every other condition rather than
    /// replacing them.** A Replace whose plan is empty is still nothing to do,
    /// and a button that is live only to refuse is worse than one that is not
    /// offered — `StandupDraftModel.canUndo` records the same reasoning.
    public var canApply: Bool {
        guard let plan, !plan.isEmpty, phase == .previewing else { return false }
        switch mode {
        case .merge:
            return true
        case .replace:
            return confirmation == Self.replaceConfirmationWord
        }
    }

    /// §10.4's lines, rendered from the plan the sheet is showing.
    public var summaryLines: [String] {
        guard let plan else { return [] }
        return ImportPreviewSummary.lines(for: plan)
    }

    public var headline: String {
        ImportPreviewSummary.headline(filename: filename, mode: mode)
    }

    public var provenance: String? {
        plan.map { ImportPreviewSummary.provenance($0.origin) }
    }

    /// Record that the apply succeeded, and what it did.
    ///
    /// Called by `MainWindowModel+Portability` rather than doing the write
    /// itself: the store, the service and the backup all belong to the window's
    /// model, and giving this type a `ModelContext` would make it the second
    /// thing in the app that can write during a preview.
    public func succeeded(backupURL: URL?) {
        phase = .applied
        lastError = nil
        notice = Self.successNotice(mode: mode, backupURL: backupURL)
    }

    /// Record that the apply failed. The preview stays up so the user can read
    /// what happened next to what they were about to do.
    public func failed(_ message: String) {
        lastError = message
        notice = nil
    }

    static func successNotice(mode: ImportMode, backupURL: URL?) -> String {
        switch mode {
        case .merge:
            return "Imported."
        case .replace:
            guard let backupURL else { return "Replaced." }
            // The path again, after the fact: the user who realises in ten
            // minutes that they restored the wrong snapshot should not have to
            // go looking for the folder.
            return "Replaced. Your previous data was backed up to \(backupURL.path)."
        }
    }
}
