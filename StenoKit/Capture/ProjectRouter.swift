import Foundation

/// FR-1.4's project assignment, as a pure function.
///
/// No store, no clock, no I/O — so every rule below is testable against
/// literal arrays, the same property that makes M1-01's extractor cheap to
/// reason about. `projects` is always the caller's **live** (non-archived)
/// list, in `sortOrder`; a rung naming anything outside it is stale and is
/// skipped rather than honoured.
public enum ProjectRouter {
    /// The first ticket key in `text` whose prefix names a live project.
    ///
    /// **This deliberately does not call `ReferenceExtractor`,** for two
    /// independent reasons (design §2.3).
    ///
    /// *Cost.* The chip re-derives on every keystroke, and `NSDataDetector` is
    /// the expensive half of extraction — 180 µs on a capture string but
    /// ~180 ms on a 250 KB paste, which would then be paid per keystroke. A
    /// bare regex scan with an early exit has no such cliff.
    ///
    /// *Correctness.* M1-01's overlap rule suppresses keys sitting inside
    /// links so that a browse URL yields one ref rather than two. That is
    /// right for extraction and wrong for routing:
    /// `https://acme.atlassian.net/browse/PAY-421` should route to Payments.
    /// Routing wants every key the text mentions; extraction wants each one
    /// once. Different questions, different scans.
    public static func ticketKeyMatch(text: String, projects: [Project]) -> KeyMatch? {
        guard !text.isEmpty else { return nil }
        let byPrefix = prefixTable(projects)
        guard !byPrefix.isEmpty else { return nil }

        // `firstMatch` in a loop rather than `matches(of:)`, which is eager:
        // the common case is a key in the first few words, and this returns
        // there instead of scanning to the end of a paste.
        var remainder = Substring(text)
        while let match = remainder.firstMatch(of: JiraKey.pattern) {
            let key = String(match.output)
            if let prefix = prefix(of: key), let projectID = byPrefix[prefix] {
                return KeyMatch(key: key, projectID: projectID)
            }
            // `JiraKey.pattern` cannot match empty, so `upperBound` always
            // advances and this terminates.
            remainder = remainder[match.range.upperBound...]
        }
        return nil
    }

    /// FR-1.4's ladder: ticket key, then the surface's own preference, then
    /// the last-used project, then FR-6's configured default, then the first
    /// project — and only then nothing.
    ///
    /// `defaultProjectID` is a parameter from day one and stays `nil` until
    /// M1-08 builds the setting. Its acceptance criterion is then met by
    /// passing an argument rather than by editing this function.
    ///
    /// Defaulted to `nil` — matching that "stays `nil` until M1-08" — rather
    /// than left required: six required parameters trips SwiftLint's
    /// `function_parameter_count` under `--strict`, and D-013 reserves
    /// `swiftlint:disable` for genuine false positives, which a function that
    /// truly takes six arguments is not. This is the one rung callers
    /// legitimately have nothing to pass yet, so it is the one that defaults.
    public static func route(
        text: String,
        projects: [Project],
        preferred: UUID?,
        lastUsed: UUID?,
        defaultProjectID: UUID? = nil,
        ignoringTicketKey: Bool
    ) -> RoutingDecision {
        if !ignoringTicketKey, let match = ticketKeyMatch(text: text, projects: projects) {
            return RoutingDecision(projectID: match.projectID, source: .ticketKey(match.key))
        }

        let live = Set(projects.map(\.id))
        if let preferred, live.contains(preferred) {
            return RoutingDecision(projectID: preferred, source: .preferred)
        }
        if let lastUsed, live.contains(lastUsed) {
            return RoutingDecision(projectID: lastUsed, source: .lastUsed)
        }
        if let defaultProjectID, live.contains(defaultProjectID) {
            return RoutingDecision(projectID: defaultProjectID, source: .configuredDefault)
        }
        if let first = projects.min(by: { $0.sortOrder < $1.sortOrder }) {
            return RoutingDecision(projectID: first.id, source: .firstProject)
        }
        return RoutingDecision(projectID: nil, source: .none)
    }

    /// Prefix → project, with the lowest `sortOrder` winning a contested one.
    ///
    /// Two projects claiming `PAY` is a configuration mistake, but it has to
    /// resolve the same way every time rather than by fetch order.
    private static func prefixTable(_ projects: [Project]) -> [String: UUID] {
        var table: [String: UUID] = [:]
        for project in projects.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            for key in project.jiraProjectKeys {
                let normalised = key.trimmingCharacters(in: .whitespaces).uppercased()
                guard !normalised.isEmpty, table[normalised] == nil else { continue }
                table[normalised] = project.id
            }
        }
        return table
    }

    /// `"PAY-421"` → `"PAY"`.
    ///
    /// `JiraKey.pattern` is `\b[A-Z][A-Z0-9]{1,9}-\d+\b`, so a match always
    /// has exactly one separating hyphen — but this does not assume its only
    /// caller passes a match.
    private static func prefix(of key: String) -> String? {
        guard let separator = key.lastIndex(of: "-") else { return nil }
        return String(key[key.startIndex..<separator]).uppercased()
    }
}
