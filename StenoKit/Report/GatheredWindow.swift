import Foundation

/// One project's report window and everything inside it (FR-4 steps 2–3, D8).
///
/// **Value types, not the SwiftData rows they were read from.** M3-03 hands
/// this to an `AIProvider` across an async boundary, and `TaskItem` and `Event`
/// are `@Model` classes: not `Sendable`, not safe in another isolation domain.
/// Returning live rows would mean these types get written anyway — later, in a
/// task whose review gate is about prompt construction rather than about the
/// shape of the report payload.
///
/// It is also half of FR-4's side-effect guarantee expressed as a type rather
/// than as a convention: a caller holding a `GatheredWindow` has nothing it
/// *could* mutate.
public struct GatheredWindow: Sendable, Equatable {
    /// M2-03 writes this to `StandupReport.projectID`.
    public let projectID: UUID

    /// D17 selects the section set (M2-02) and the output schema (M3-03).
    public let cadence: ReportCadence

    /// `StandupReport.windowStart` / `windowEnd`. Never inverted — see
    /// `ReportWindow.bounds`.
    public let start: Date
    public let end: Date

    public let tasks: [GatheredTask]

    public init(
        projectID: UUID,
        cadence: ReportCadence,
        start: Date,
        end: Date,
        tasks: [GatheredTask]
    ) {
        self.projectID = projectID
        self.cadence = cadence
        self.start = start
        self.end = end
        self.tasks = tasks
    }
}

/// One task as the report sees it.
public struct GatheredTask: Sendable, Equatable {
    /// M2-03 appends `standupReported` here; §7.3 sends it as `task_id`.
    public let id: UUID
    public let title: String
    public let status: Status

    /// Every `jiraIssue` ref on the task, sorted.
    ///
    /// **Plural, where §7.3 says "ticket key" singular.** FR-1.5's extractor
    /// creates one ref per key it finds, so a task whose notes mention two
    /// tickets carries two. Keeping only one would silently drop a key the user
    /// has to say out loud — the exact failure §7.3's "preserve verbatim"
    /// constraint exists to prevent. Sorted so the output is deterministic.
    public let ticketKeys: [String]

    /// The most recent non-redacted `blockedReason` event's body, for a task
    /// currently `.blocked`. `nil` for any other status.
    ///
    /// **Sourced independent of the window, for the reason `ticketKeys` is.**
    /// FR-4's own report structure needs it: "**Blockers** — BLOCKED tasks
    /// with reasons" describes a task blocked last week, still blocked, with
    /// nothing new said since — which is exactly `events` empty. Reading the
    /// reason only when it happens to fall inside the window would hand M2-02
    /// a blocked task it cannot render a reason for, in the common case.
    ///
    /// **One accepted gap:** if a task was blocked, unblocked, and re-blocked
    /// without a fresh reason, this surfaces the earlier reason rather than
    /// nothing. That is what a person recalling the task from memory would
    /// say too, and better than the alternative of silently going blank.
    public let blockedReason: String?

    /// This task's non-redacted events inside the window, oldest first.
    ///
    /// **May be empty**, and a renderer must handle that honestly rather than
    /// emit a blank bullet: a task included because it is currently
    /// `inProgress` or `blocked` has said nothing during the window, and that
    /// is precisely the task Monday's stand-up is about.
    public let events: [GatheredEvent]

    public init(
        id: UUID,
        title: String,
        status: Status,
        ticketKeys: [String],
        blockedReason: String?,
        events: [GatheredEvent]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.ticketKeys = ticketKeys
        self.blockedReason = blockedReason
        self.events = events
    }
}

/// One event as the report sees it (§7.3: "all events … with timestamps").
///
/// **Carries no `id`.** An earlier draft had one, justified as what M2-04 would
/// use to find the events it redacts — which was false, because M2-04 redacts
/// `standupReported` events and `ReportGatherer` never returns that kind. With
/// that justification gone nothing reads it, and an unused `public` field on a
/// type M2-02, M2-03 and M3-03 all depend on only gets harder to remove. A task
/// that needs event identity can add it alongside the consumer that wants it.
public struct GatheredEvent: Sendable, Equatable {
    public let timestamp: Date
    public let kind: EventKind
    public let body: String

    public init(timestamp: Date, kind: EventKind, body: String) {
        self.timestamp = timestamp
        self.kind = kind
        self.body = body
    }
}
