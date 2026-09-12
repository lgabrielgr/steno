import Foundation

/// A status change, as a value.
///
/// Free-standing rather than a method on `Status` or on `StatusService`,
/// because `eventBody` is the one string in this feature that lands in an
/// append-only log — it is worth asserting against literals with no container
/// and no clock, which is the argument `TaskGrouping` makes for being a free
/// function.
public struct StatusTransition: Equatable, Sendable {
    public let from: Status

    /// Named `into` rather than `to` because SwiftLint's `identifier_name`
    /// rejects a two-character name and `--strict` makes that a build failure.
    public let into: Status

    public init(from: Status, into: Status) {
        self.from = from
        self.into = into
    }

    /// §3.3's spelling: `"IN-PROGRESS → BLOCKED"`.
    ///
    /// The arrow is U+2192 — the character §3.3's example table uses, checked
    /// at the byte level. An ASCII `->` would diverge silently from the spec
    /// in every event ever written, and events are never edited (§3.3).
    public var eventBody: String {
        "\(from.displayName)\(Self.arrow)\(into.displayName)"
    }

    /// The inverse of `eventBody`, and **the reason this type owns both.**
    ///
    /// §10.1 requires import to derive `TaskItem.status` from the newest
    /// `statusChanged` event rather than copying the cached field, and
    /// `StatusService` writes `eventBody` with a `nil` payload. So this string
    /// is the only machine-readable record of a transition that exists, and
    /// every event already in every store is written in it — there is no
    /// retrofitting a structured payload onto history.
    ///
    /// Both directions live in one type so that a change to the spelling is a
    /// change to a single pair. Split across two files they would drift, and
    /// the symptom would be a task's status quietly reverting after an import.
    ///
    /// `nil` rather than a throw: §10.2 chose JSON partly so a file could be
    /// read and edited by hand before import, and a person who retypes an arrow
    /// should not have the whole import refused. M2.5-02 falls back to the
    /// record's own `statusChangedAt` and reports the event in its plan.
    public init?(eventBody: String) {
        let halves = eventBody.components(separatedBy: Self.arrow)
        guard halves.count == 2,
            let from = Status(displayName: halves[0]),
            let into = Status(displayName: halves[1])
        else { return nil }
        self.init(from: from, into: into)
    }

    /// U+2192 with a space either side, declared once so `eventBody` and
    /// `init?(eventBody:)` cannot disagree about the separator.
    private static let arrow = " → "
}

extension Status {
    /// What the Cycle Status shortcut walks through (D-034).
    ///
    /// **`blocked` is deliberately absent.** Cycling all four would make
    /// `.todo` → `.done` a three-press walk appending two `statusChanged` events for
    /// states the user never meant to be in, and M2-02 renders that log into a
    /// stand-up. `blocked` is the one status §3.3 pairs with a reason; it stays
    /// a deliberate act, reachable from the status control and from ⌘⇧B.
    public static let cycle: [Status] = [.todo, .inProgress, .done]

    /// The next status in `cycle`, wrapping at the end.
    ///
    /// `blocked` is not in `cycle` and so has no successor there; cycling out
    /// of it goes to `inProgress`, because the thing you do once you are
    /// unblocked is the work.
    public var next: Status {
        guard let index = Self.cycle.firstIndex(of: self) else { return .inProgress }
        return Self.cycle[(index + 1) % Self.cycle.count]
    }
}

extension Status {
    /// FR-3's spelling, used for group headers and the detail pane — **and
    /// persisted**, which is what moved it here.
    ///
    /// It lived in `StenoKit/Features/MainWindow/Status+Display.swift` until
    /// M2.5-02. It stopped being display text the moment a merge read it back:
    /// `StatusTransition.eventBody` writes these four strings into the
    /// append-only log, and §10.1's import derives a task's status by parsing
    /// them. A rename in a view-adjacent file would therefore break every
    /// import on every machine, and the only symptom would be a status that
    /// reverts after a transfer. Its neighbour `menuOrder` is genuinely UI and
    /// stayed behind.
    ///
    /// In `StenoKit` rather than in a view so the strings are assertable, and
    /// so M1-04's popover and M1-05's status control cannot invent a second
    /// spelling of the same four statuses.
    public var displayName: String {
        switch self {
        case .todo: "TODO"
        case .inProgress: "IN-PROGRESS"
        case .blocked: "BLOCKED"
        case .done: "DONE"
        }
    }

    /// The inverse of `displayName`, over `allCases`.
    ///
    /// Derived from `allCases` rather than written as a second `switch`: a
    /// `switch` here would compile with a case missing from one direction, and
    /// the missing case would be an unparseable transition rather than a build
    /// error.
    public init?(displayName: String) {
        guard let match = Self.allCases.first(where: { $0.displayName == displayName })
        else { return nil }
        self = match
    }
}
