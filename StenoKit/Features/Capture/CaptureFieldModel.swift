import Foundation
import SwiftData

/// One in-progress capture: the draft text, the chip it raises, and the
/// commit.
///
/// **In `StenoKit`, not as `@State` in a view, and that is deliberate.**
/// M1-04's acceptance criterion is "the auto-routing chip behaving identically
/// to the main window" — chip state held in a view lives in `Steno/`, where
/// D-010 puts it beyond the headless test bundle, and where M1-03 and M1-04
/// would each rebuild it by hand. Three hand-rolled chips that drift is the
/// failure D15 names and this milestone exists to prevent.
///
/// The dependencies are closures rather than values because a surface's
/// project list and its preferred project both change under it while the field
/// is open — the sidebar selection being the obvious case.
@Observable
@MainActor
public final class CaptureFieldModel {
    /// The draft. Assigning re-derives the chip.
    public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            refreshChip()
        }
    }

    public private(set) var chip: CaptureChip?

    /// Set when a commit could not be saved. The text is kept when this is
    /// non-nil, so the user can retry rather than retype.
    public private(set) var lastError: String?

    /// The key whose chip was dismissed, if any.
    ///
    /// Keyed to the key rather than a `Bool`: dismissing drops *this*
    /// auto-assignment, it does not disable routing for the rest of a capture
    /// still being typed. Type on so a different key matches and a new chip
    /// appears (design §5.1).
    private var dismissedKey: String?

    private let service: CaptureService
    private let projects: () -> [Project]
    private let preferred: () -> UUID?
    private let onCaptured: (TaskItem) -> Void

    public init(
        service: CaptureService,
        projects: @escaping () -> [Project],
        preferred: @escaping () -> UUID? = { nil },
        onCaptured: @escaping (TaskItem) -> Void = { _ in }
    ) {
        self.service = service
        self.projects = projects
        self.preferred = preferred
        self.onCaptured = onCaptured
    }

    /// Decline the auto-assignment the chip is showing.
    ///
    /// One click, no modal, no confirmation — §1.1 treats a modal interruption
    /// during capture as a defect.
    ///
    /// **Dismissal is keyed to the key, but the key is whichever one resolves
    /// first.** So editing the text to *replace* `HIR-9` raises a new chip,
    /// while *appending* `PAY-421` after it does not: `ticketKeyMatch` still
    /// returns the dismissed `HIR-9`, and `commit` then skips rung 1 rather
    /// than falling through to PAY. The chip and the save agree in both cases
    /// — the user never sees one project and gets another — which is the
    /// property that actually matters. See
    /// `appendingAKeyAfterDismissalDoesNotRaiseANewChip`.
    public func dismissChip() {
        dismissedKey = chip?.key
        chip = nil
    }

    /// Write the draft as a task.
    ///
    /// Never throws: a capture surface has nowhere useful to propagate an
    /// error to, so a failure becomes `lastError` and the text is kept.
    public func commit() {
        do {
            if let task = try service.capture(
                text: text,
                preferred: preferred(),
                ignoringTicketKey: isCurrentMatchDismissed()
            ) {
                onCaptured(task)
            }
            reset()
        } catch CaptureError.noProjectAvailable {
            lastError = "Create a project before capturing a task."
        } catch {
            Log.app.error(
                "could not capture the task: \(String(describing: error), privacy: .public)"
            )
            lastError = "Could not save the task. Your text is still here."
        }
    }

    /// Clear the field for the next capture.
    public func reset() {
        text = ""
        chip = nil
        dismissedKey = nil
        lastError = nil
    }

    /// Whether the chip the user dismissed is still the one the text raises.
    ///
    /// Recomputed at commit rather than cached, so an edit between dismissal
    /// and `Return` is honoured: the save re-runs the decision the field is
    /// currently displaying.
    private func isCurrentMatchDismissed() -> Bool {
        guard let dismissedKey else { return false }
        let match = ProjectRouter.ticketKeyMatch(text: text, projects: projects())
        return match?.key == dismissedKey
    }

    /// Re-derive the chip from the current project list.
    ///
    /// Called per keystroke by `text`'s `didSet` — which is why it is a regex
    /// scan with an early exit and no `NSDataDetector`. See
    /// `ProjectRouter.ticketKeyMatch`.
    ///
    /// Public because a surface can outlive the project list it derived from:
    /// M1-03's panel keeps a draft across dismissals, so a project created
    /// while it is hidden would otherwise leave the chip stale against the list
    /// `CaptureService` actually routes with. Re-running this is safe — a
    /// dismissed key stays dismissed.
    public func refreshChip() {
        let live = projects()
        guard let match = ProjectRouter.ticketKeyMatch(text: text, projects: live),
            match.key != dismissedKey,
            let project = live.first(where: { $0.id == match.projectID })
        else {
            chip = nil
            return
        }
        chip = CaptureChip(
            key: match.key,
            projectID: project.id,
            projectName: project.name,
            colorHex: project.colorHex
        )
    }
}
