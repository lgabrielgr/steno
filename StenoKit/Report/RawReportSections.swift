/// FR-4's report structure, built from a gathered window with no AI (§7.4).
///
/// §7.4 makes this a P0 path built *before* the AI path, not an error handler
/// bolted on after it: "The user must never arrive at a stand-up
/// empty-handed because of a network error." Nothing here imports `Foundation`,
/// reads a clock, formats a date, or touches a store — which is what makes
/// "renders with no network and no API key configured" true by construction
/// rather than by test.
///
/// **A stenographer, not an editor.** It selects, orders, and lays out. §7.3's
/// constraint that "fixed the flaky auth test" must not become "enhanced
/// authentication reliability" is written about the model, but the discipline
/// binds harder here: this type has no licence to rephrase at all.
public enum RawReportSections {
    /// D17's two section sets, selected by the window's own cadence.
    ///
    /// Task order inside every section is the order `ReportGatherer` already
    /// established — `createdAt`, then `id.uuidString`. Preserved, never
    /// recomputed: ordering has exactly one owner and it is not this file.
    /// Every section is built by filtering `window.tasks` in place, so no
    /// `Dictionary` or `Set` iteration order can leak into the output.
    public static func build(from window: GatheredWindow) -> [ReportSection] {
        switch window.cadence {
        case .daily:
            daily(window.tasks)
        case .periodic:
            periodic(window.tasks)
        }
    }

    /// FR-4's daily set: a DSU's three questions.
    ///
    /// **The three sections are not one partition, and that is deliberate.**
    /// FR-4 defines them by two different tests — *Since last stand-up* is
    /// "completed and progressed work" (window activity), while *Today* is
    /// "current IN-PROGRESS tasks" and *Blockers* is "BLOCKED tasks with
    /// reasons" (current status). A task that is in progress *and* was worked
    /// on satisfies both, so it appears twice — and says something different
    /// each time, which is how a stand-up is actually spoken: "yesterday I
    /// found the race; today I'm still on it." §7.3's daily schema agrees:
    /// the same `task_id` may appear in more than one of its three arrays.
    ///
    /// The rejected alternative was a status partition, the literal reading of
    /// §7.4's "raw events grouped by status". It drops a week of notes on a
    /// task that is still in progress, because that task would appear only
    /// under *Today*.
    private static func daily(_ tasks: [GatheredTask]) -> [ReportSection] {
        [
            ReportSection(
                title: "Since last stand-up",
                bullets: tasks.filter(progressed).map { bullet($0, details: authored($0)) }),
            ReportSection(
                title: "Today",
                bullets: tasks.filter { $0.status == .inProgress }.map { bullet($0) }),
            ReportSection(
                title: "Blockers",
                bullets: tasks.filter { $0.status == .blocked }
                    .map { bullet($0, details: reason($0)) }),
        ]
    }

    /// FR-4's periodic set: D17's "summary", not a status ping.
    ///
    /// **An exhaustive partition, where `daily` is deliberately not one.** Each
    /// task appears exactly once, and the `switch` has no `default`, so a fifth
    /// `Status` is a compile error here rather than a silent omission from
    /// every periodic report — the construction `ReportGatherer.isReportable`
    /// already uses for the same reason.
    ///
    /// Not a rename of `daily`'s headings: *Completed* means finished, where
    /// *Since last stand-up* means everything that moved. Reading a fortnight
    /// of in-flight work under a heading that says "Completed" would be a false
    /// claim about the work. D17 and FR-4 both insist the distinction is real.
    ///
    /// **A `.todo` task with events goes under *In flight*.** D-068 admits it
    /// to the window and a partition has to place it somewhere; it is neither
    /// completed nor blocked, and the work demonstrably happened. A slightly
    /// loose heading is a smaller violation than dropping the user's words.
    private static func periodic(_ tasks: [GatheredTask]) -> [ReportSection] {
        var completed: [ReportBullet] = []
        var inFlight: [ReportBullet] = []
        var blocked: [ReportBullet] = []

        for task in tasks {
            switch task.status {
            case .done:
                completed.append(bullet(task, details: authored(task)))
            case .inProgress, .todo:
                inFlight.append(bullet(task, details: authored(task)))
            case .blocked:
                blocked.append(bullet(task, details: reason(task) + authored(task)))
            }
        }

        return [
            ReportSection(title: "Completed", bullets: completed),
            ReportSection(title: "In flight", bullets: inFlight),
            ReportSection(title: "Blockers & risks", bullets: blocked),
        ]
    }

    /// Whether `task` belongs under *Since last stand-up*.
    ///
    /// **Two clauses, because FR-4's phrase is two words: "completed *and*
    /// progressed work".** An activity-only test loses the task a user
    /// captured, finished, and never wrote a note on — its only event in the
    /// window is the `statusChanged` that `authored` excludes, so it would
    /// appear under no daily heading at all despite being the most reportable
    /// thing that happened all day.
    ///
    /// Testing `.done` on its own is safe here: D-068 only admits a `.done`
    /// task to the window when it had activity inside it.
    ///
    /// **One accepted gap, stated rather than hidden.** A task now `.todo`
    /// whose only window event is a status change — moved back from in
    /// progress, with nothing written — appears under no daily heading. A bare
    /// title under *Since last stand-up* would assert progress that did not
    /// happen. It does appear under `periodic`'s *In flight*, which must place
    /// every task somewhere. If that proves wrong in use, the fix is a third
    /// clause here, not a change to what counts as an authored event.
    private static func progressed(_ task: GatheredTask) -> Bool {
        task.status == .done || !authored(task).isEmpty
    }

    /// The user's own words from this task's window, oldest first.
    ///
    /// **`created` and `statusChanged` are excluded** (D-072). Their bodies are
    /// `"Task created"` and `"In Progress → Done"` — machine-authored strings
    /// the user would otherwise read aloud to their team. Under both mappings a
    /// task's status is already expressed by *which section it is in*, so
    /// emitting the transition as well is redundant rather than faithful.
    /// Verbatim fidelity is a constraint on the user's words; it does not
    /// oblige this type to speak the app's.
    ///
    /// Filters on `isUserAuthored` rather than re-listing kinds, so M4's
    /// `externalUpdate` — which cannot occur before the connector that writes
    /// it exists — gets a deliberate decision from whoever adds it, at the
    /// point they can judge whether a Jira comment belongs in a spoken
    /// stand-up.
    private static func authored(_ task: GatheredTask) -> [String] {
        task.events.filter { isBullet($0, on: task) }.map(\.body)
    }

    /// Whether `event` becomes a detail line on `task`'s bullet.
    ///
    /// **A currently-blocked task's `blockedReason` events are excluded, because
    /// `reason(_:)` already says them.** `StatusService.addBlockedReason` stamps
    /// `now()`, so a task blocked since the last stand-up — the ordinary case,
    /// not an exotic one — carries its reason both as an event inside the window
    /// and on `GatheredTask.blockedReason` (D-069). Without this the daily
    /// report says the reason under *Since last stand-up* and again under
    /// *Blockers*, and the periodic report says it twice inside a single bullet.
    ///
    /// **Conditioned on status rather than dropping the kind outright**, because
    /// D-069 leaves `blockedReason` `nil` for anything not currently blocked. On
    /// a task that was blocked during the window and has since been unblocked,
    /// the event is the *only* carrier of what the user wrote; filtering the
    /// kind unconditionally would delete their words rather than de-duplicate
    /// them.
    ///
    /// **One accepted gap**, consistent with the one D-069 already takes: a task
    /// blocked, unblocked, and re-blocked inside one window shows only the
    /// current reason, and the superseded one is dropped rather than listed as
    /// a note.
    private static func isBullet(_ event: GatheredEvent, on task: GatheredTask) -> Bool {
        guard event.kind.isUserAuthored else { return false }
        return !(task.status == .blocked && event.kind == .blockedReason)
    }

    /// A blocked task's reason as zero or one detail line.
    ///
    /// Returns an array rather than `String?` so both call sites concatenate
    /// rather than branch. `ReportGatherer` guarantees this is `nil` for any
    /// task not currently `.blocked` (D-069), so the two are never combined by
    /// accident.
    private static func reason(_ task: GatheredTask) -> [String] {
        task.blockedReason.map { [$0] } ?? []
    }

    /// The task line: title, then its ticket keys.
    ///
    /// `ticketKeys` is plural and already sorted (D-065): FR-1.5's extractor
    /// creates one ref per key, so a task whose notes mention two tickets
    /// carries two, and dropping either would lose a key the user has to say
    /// out loud. The parenthesis is omitted entirely when there are none —
    /// never a bare `()`.
    private static func bullet(_ task: GatheredTask, details: [String] = []) -> ReportBullet {
        let keys = task.ticketKeys.isEmpty ? "" : " (\(task.ticketKeys.joined(separator: ", ")))"
        return ReportBullet(text: task.title + keys, details: details)
    }
}
