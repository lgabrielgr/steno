import Foundation

/// FR-1.5's ticket-key pattern, in one place.
public enum JiraKey {
    /// The regex from FR-1.5, verbatim.
    ///
    /// A regex literal rather than `NSRegularExpression` because it is checked
    /// at compile time and so needs no `try!`, which `make lint --strict`
    /// rejects. A computed property rather than a `static let` because `Regex`
    /// is not `Sendable` and cannot be stored in a global under Swift 6.
    ///
    /// **Known false positives, accepted deliberately:** this matches `UTF-8`,
    /// `COVID-19`, `ISO-8601`, and `M1-01`. The task file requires the pattern
    /// as written and the deviation reported rather than silently fixed; a
    /// phantom key costs one stray ref card and cannot misroute a task,
    /// because FR-1.4 routes only on a configured `Project.jiraProjectKeys`
    /// prefix.
    public static var pattern: Regex<Substring> { /\b[A-Z][A-Z0-9]{1,9}-\d+\b/ }
}
