import Foundation
import SwiftData

/// The window's project and capture actions, split out of
/// `MainWindowModel.swift` to keep that file under SwiftLint's `file_length`
/// limit — the same move `+Status.swift` already is, and for the same reason.
/// Same type, same rules: the view never sees a `ModelContext`.
extension MainWindowModel {
    /// A capture service over this window's context, for the capture sheet.
    ///
    /// The view never touches the context itself — it gets a service that
    /// already holds one, so D-019's rule (no `@Query`, no
    /// `@Environment(\.modelContext)`) is untouched.
    public func captureService() -> CaptureService {
        CaptureService(context: context, now: now, save: save)
    }

    /// FR-1.4 rung 2, exposed for the capture sheet. See `preferredProjectID`.
    public var preferredProjectIDForCapture: UUID? { preferredProjectID() }

    public func createProject(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // The max must run over *all* projects, archived included — `projects`
        // is the visible set, and if the highest-sortOrder project is
        // archived, taking the max of the visible set would let the next
        // project reuse both its order and (via ProjectPalette) its colour.
        //
        // Fail closed if that read fails: `[]` would yield order 0 and mint a
        // project colliding with a stored one, which is the write-side version
        // of the lie `perform(_:_:)`'s rollback exists to prevent (D-018).
        // `lastError` is already set by the fetch, so the user sees why.
        guard let allProjects = fetchOrNil(FetchDescriptor<Project>(), "load your projects") else {
            return
        }
        let order = (allProjects.map(\.sortOrder).max() ?? -1) + 1
        let stamp = now()
        perform("create the project") {
            self.context.insert(
                Project(
                    name: trimmed,
                    colorHex: ProjectPalette.hex(forIndex: order),
                    sortOrder: order,
                    modifiedAt: stamp
                )
            )
        }
    }

    /// Edit a project's name and its Jira key prefixes — what FR-1.4 routes on,
    /// unreachable before this method (M1-02 design doc §7). Keys arrive
    /// comma-separated; normalising here keeps `ProjectRouter` typing-agnostic.
    public func updateProject(id: UUID, name: String, jiraKeys: String) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let keys = Self.normalisedKeys(jiraKeys)
        let stamp = now()
        perform("save the project") {
            project.rename(to: trimmed, at: stamp)
            project.setJiraProjectKeys(keys, at: stamp)
        }
    }

    /// `" pay , BILL,pay,, "` → `["PAY", "BILL"]`. Internal so `@testable
    /// import` can exercise the rule without a container.
    static func normalisedKeys(_ raw: String) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for piece in raw.split(separator: ",") {
            let key = piece.trimmingCharacters(in: .whitespaces).uppercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    /// FR-1.4 rung 2: this surface's own context.
    ///
    /// Under "All" the window has no opinion about where a task belongs, so it
    /// says so with `nil` and the ladder falls through to the last-used
    /// project — rather than asserting the first project, which is what
    /// D-021's stand-in did before this task retired it.
    private func preferredProjectID() -> UUID? {
        switch selection {
        case .project(let id): id
        case .all: nil
        }
    }

    /// §3.1: archived projects are hidden, never deleted. There is no delete.
    public func archive(projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }

        let stamp = now()
        let saved = perform("archive the project") { project.setArchived(true, at: stamp) }

        // Only after the save is known to have succeeded. `rollback()` can undo
        // the `isArchived` mutation, but it cannot undo a selection change — so
        // moving the selection first would leave a failed archive showing "All"
        // while the project is still in the sidebar.
        if saved, selection == .project(projectID) { selection = .all }
    }
}
