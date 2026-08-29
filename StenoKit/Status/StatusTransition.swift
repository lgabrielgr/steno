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
        "\(from.displayName) → \(into.displayName)"
    }
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
