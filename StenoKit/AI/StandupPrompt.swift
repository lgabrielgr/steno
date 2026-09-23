import Foundation

/// §7.3's prompt: the constraints on one side, the event log on the other.
///
/// **The system half carries no user data and the user half carries no
/// instructions.** The split is what makes the constraints assertable by
/// equality in a test rather than by substring against a string that grows with
/// the user's task list — and §7.3's constraints are the property this whole
/// milestone rests on, since a model that elevates register hands the user
/// words they have to say out loud to their team.
///
/// **Authored here rather than in a provider**, per `StandupRequest`'s own doc
/// comment: a provider that composed its own prompt would mean every future
/// provider re-derived these constraints, and the one that got them wrong would
/// inflate the user's language in front of their team.
public enum StandupPrompt {

    // MARK: - System

    /// §7.3's constraints, plus the two it implies rather than prints.
    ///
    /// Cadence-dependent because two of the constraints are: `daily` is "one
    /// line per task", `periodic` is "group into 8–12 themed bullets", and
    /// §7.3 is explicit that the two schemas "are not cosmetic variants of each
    /// other".
    public static func system(for cadence: ReportCadence) -> String {
        (shared + cadenceRules(for: cadence)).joined(separator: "\n")
    }

    /// The constraints that hold under both cadences.
    ///
    /// Copied from §7.3 rather than paraphrased. A paraphrase here is a second
    /// version of the requirement, and the one the model actually reads.
    private static let shared: [String] = [
        "You are summarizing a developer's own work log so they can read it "
            + "aloud at a stand-up.",
        "",
        "Rules, all of them hard:",
        "- Never introduce a fact that is not in the log below. Make no "
            + "inference about what the user \"probably\" did, intended, or "
            + "will do.",
        "- Preserve verbatim: ticket keys, service names, function names, "
            + "error strings, and acronyms. Copy them character for character.",
        "- Light polish only. Organize fragments into clean sentences. Do not "
            + "elevate the register. \"fixed the flaky auth test\" must not "
            + "become \"enhanced authentication reliability\" — the user has to "
            + "say these words out loud, and inflated language is actively "
            + "harmful.",
        "- If a task's events are too thin to summarize, output the raw note "
            + "rather than padding it.",
        "- Write plain sentences. No markdown, no bullet characters, no bold, "
            + "no headings. Formatting is the application's job.",
        "- Reference tasks only by the ids given below, exactly as spelled.",
    ]

    /// The two rules that differ by cadence (D17).
    private static func cadenceRules(for cadence: ReportCadence) -> [String] {
        switch cadence {
        case .daily:
            [
                "- One line per task. Stand-up updates are spoken, not read.",
                // D-153. The only forward-looking field in either schema, and
                // therefore the only structural invitation to violate D12 —
                // which forbids focus suggestions and prioritization outright.
                "- \"today\" restates which tasks are currently in progress, "
                    + "drawn from the log. Do not recommend what to work on, in "
                    + "what order, or what to prioritize.",
            ]
        case .periodic:
            [
                "- This window may cover dozens of tasks. Condense, do not "
                    + "enumerate: group related work into themed bullets and "
                    + "aim for 8–12 bullets in total, regardless of how long "
                    + "the window is.",
                "- A themed bullet may cover several tasks — list every task id "
                    + "it covers. This is the only place you may combine tasks, "
                    + "and you still may not invent facts.",
            ]
        }
    }

    // MARK: - User

    /// The window as a record the model reads (§7.3's "input: the event log").
    ///
    /// Plain text rather than JSON: the model reads this as a record, and the
    /// direction that needs a schema already has one.
    ///
    /// **`timeZone` is injected.** A formatter reading `TimeZone.current`
    /// directly makes these tests pass in one time zone and fail in another,
    /// which this repo has already paid for once in its date handling.
    ///
    /// Task order is `ReportGatherer`'s, preserved and never recomputed —
    /// ordering has exactly one owner, and it is not this file.
    public static func user(
        for window: GatheredWindow, timeZone: TimeZone = .current
    ) -> String {
        let formatter = Self.formatter(in: timeZone)
        var lines = [
            "Window: \(formatter.string(from: window.start)) to "
                + "\(formatter.string(from: window.end))"
        ]
        for task in window.tasks {
            lines.append("")
            lines.append(contentsOf: block(task, formatter: formatter))
        }
        return lines.joined(separator: "\n")
    }

    /// One task: its header, its title, its blocked reason, and its events.
    private static func block(
        _ task: GatheredTask, formatter: ISO8601DateFormatter
    ) -> [String] {
        let keys = task.ticketKeys.isEmpty ? "" : "  " + task.ticketKeys.joined(separator: ", ")
        var lines = [
            "TASK \(task.id.uuidString)  [\(label(task.status))]" + keys,
            "  Title: \(task.title)",
        ]
        if let reason = task.blockedReason {
            lines.append("  Blocked: \(reason)")
        }
        if task.events.isEmpty {
            // Emitted rather than omitted. `GatheredTask.events` "may be empty,
            // and a renderer must handle that honestly": a task admitted to the
            // window because it is currently in progress with nothing said
            // about it is precisely the task Monday's stand-up is about, and
            // silence here reads to a model as an omission rather than a fact.
            lines.append("  (no events in window)")
        }
        for event in task.events {
            lines.append(
                "  \(formatter.string(from: event.timestamp))  "
                    + "\(label(event.kind))  \(event.body)")
        }
        return lines
    }

    /// **Every kind the gatherer returns is sent, including the machine-authored
    /// ones.** §7.3 asks for "all events in [windowStart, now] with timestamps",
    /// and a status transition is a fact the summary needs — D-072 keeps
    /// `created` and `statusChanged` out of what the *user* reads aloud, not out
    /// of what the model reads. `standupReported` cannot appear: D-066 keeps it
    /// out of every window.
    private static func label(_ kind: EventKind) -> String {
        switch kind {
        case .created: "created"
        case .note: "note"
        case .statusChanged: "status"
        case .blockedReason: "blocked"
        case .externalUpdate: "external"
        case .standupReported: "reported"
        }
    }

    /// Prompt vocabulary, declared here rather than borrowed from the UI: a
    /// wording change in a menu must not silently change what is sent to a
    /// model.
    private static func label(_ status: Status) -> String {
        switch status {
        case .todo: "to do"
        case .inProgress: "in progress"
        case .blocked: "blocked"
        case .done: "done"
        }
    }

    /// Seconds precision, no fractional part: §10.2 needs milliseconds because
    /// it arbitrates merges by timestamp, and nothing here does.
    private static func formatter(in timeZone: TimeZone) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter
    }
}
