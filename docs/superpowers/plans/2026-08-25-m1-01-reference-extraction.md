# M1-01 Passive Reference Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure, dependency-free function that scans text and returns the external references it mentions, as value types — no UI, no store, no network.

**Architecture:** Four small files in a new `StenoKit/Capture/` directory. `NSDataDetector` finds `http(s)` link spans; each span is classified into a `SourceRefKind` by URL *path shape* (never by hostname, so self-hosted Jira works); FR-1.5's regex then finds ticket keys in the text *outside* those spans. Results are ordered by first occurrence and deduped on `(kind, identifier)`. Nothing touches SwiftData except a one-line adapter that M1-02 calls.

**Tech Stack:** Swift 6 (strict concurrency), Foundation (`NSDataDetector`, `URLComponents`), Swift Testing for the tables, XCTest for the one `measure` case (D-011).

**Spec:** [`docs/superpowers/specs/2026-08-25-m1-01-reference-extraction-design.md`](../specs/2026-08-25-m1-01-reference-extraction-design.md)

## Global Constraints

- **Branch:** `feat/reference-extraction`. Never commit to `main`; open a PR and stop without merging (CLAUDE.md non-negotiable 1, §9.5).
- **Verification gate:** `make build && make test && make lint` must all pass before the PR (§9.5 step 4, §13). Run `make format` before `make lint`.
- **Swift 6 strict concurrency.** `NSDataDetector` and `NSRegularExpression` are `Sendable` and may be `static let`. **`Regex` is NOT `Sendable`** — a `static let` of a regex literal fails to compile. Every regex in this plan is a computed `static var`.
- **No `try!` and no force-unwrapping.** `make lint` runs `--strict` with `force_unwrapping` opted in and `force_try` on by default. Both are build failures.
- **swift-format and SwiftLint disagree in two shapes** (D-013), and the code below is already written to avoid both: never put closure parameters on their own line (`closure_parameter_position`), and never write a multi-clause `if let` long enough that swift-format moves its opening brace to a new line (`opening_brace`). If you restructure the given code, re-run `make format && make lint` before assuming it is fine.
- **Purity.** No I/O, no store access, no clock, no config reads anywhere in `StenoKit/Capture/`. `make test` runs with networking denied (D-012).
- **`project.yml` needs no change.** The `StenoKit` and `StenoTests` targets glob whole directories, so a new subdirectory is picked up automatically. `.swiftlint.yml` and the `Makefile` `format` target list only *top-level* directories — also no change.
- **FR-1.5's regex is used verbatim: `\b[A-Z][A-Z0-9]{1,9}-\d+\b`.** Do not "improve" it. It matches `UTF-8`, `COVID-19`, `ISO-8601`, and `M1-01`; that is known, accepted for this task, and reported in the PR body (spec §7).

## File Structure

| File | Responsibility |
|---|---|
| `StenoKit/Capture/ExtractedRef.swift` | The `Sendable` value type, its `DedupKey`, and the `sourceRef(taskID:)` adapter to the SwiftData model |
| `StenoKit/Capture/JiraKey.swift` | FR-1.5's pattern, in one place, named |
| `StenoKit/Capture/SourceURLClassifier.swift` | One `URL` → one `ExtractedRef`, by path shape |
| `StenoKit/Capture/ReferenceExtractor.swift` | Scan, overlap-filter, order, merge — the public entry point |
| `StenoTests/Capture/ExtractedRefTests.swift` | Value semantics and the adapter |
| `StenoTests/Capture/SourceURLClassifierTests.swift` | Table over literal `URL`s |
| `StenoTests/Capture/ReferenceExtractorTests.swift` | Table over literal strings — the acceptance criteria |
| `StenoTests/Capture/ExtractionPerformanceTests.swift` | The one XCTest `measure` case |

Every code block below has been compiled, formatted with the repo's `.swift-format`, linted clean under `swiftlint --strict` with the repo's config, and executed — the expected values in the tests are recorded program output, not predictions.

---

### Task 1: `ExtractedRef` — the value type extraction returns

**Files:**
- Create: `StenoKit/Capture/ExtractedRef.swift`
- Create: `StenoTests/Capture/ExtractedRefTests.swift`

**Interfaces:**
- Consumes: `SourceRefKind` and `SourceRef` from `StenoKit/Models/` (already exist).
- Produces: `ExtractedRef(kind:identifier:url:)` with `url` defaulting to `nil`; `ExtractedRef.DedupKey`; `ExtractedRef.dedupKey`; `ExtractedRef.sourceRef(taskID:) -> SourceRef`. Tasks 2 and 3 construct `ExtractedRef` values; M1-02 calls `sourceRef(taskID:)`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/ExtractedRefTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

@Test("the adapter carries every field onto the SwiftData model")
func adapterCarriesFields() {
    let taskID = UUID()
    let extracted = ExtractedRef(
        kind: .githubPR, identifier: "acme/api#421",
        url: "https://github.com/acme/api/pull/421")

    let ref = extracted.sourceRef(taskID: taskID)

    #expect(ref.taskID == taskID)
    #expect(ref.kind == .githubPR)
    #expect(ref.identifier == "acme/api#421")
    #expect(ref.url == "https://github.com/acme/api/pull/421")
}

@Test("url defaults to nil, for a bare key with no link to attach")
func urlDefaultsToNil() {
    let extracted = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")

    #expect(extracted.url == nil)
    #expect(extracted.sourceRef(taskID: UUID()).url == nil)
}

@Test("dedupKey ignores url, so the same ref found twice collapses")
func dedupKeyIgnoresURL() {
    let bare = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")
    let linked = ExtractedRef(
        kind: .jiraIssue, identifier: "PAY-421",
        url: "https://acme.atlassian.net/browse/PAY-421")

    #expect(bare.dedupKey == linked.dedupKey)
    #expect(bare != linked)
}

@Test("dedupKey separates the same identifier under different kinds")
func dedupKeySeparatesKinds() {
    let issue = ExtractedRef(kind: .jiraIssue, identifier: "PAY-421")
    let link = ExtractedRef(kind: .url, identifier: "PAY-421")

    #expect(issue.dedupKey != link.dedupKey)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: compile failure — `cannot find 'ExtractedRef' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/ExtractedRef.swift`:

```swift
import Foundation

/// One external reference found in a piece of text (REQUIREMENTS.md FR-1.5).
///
/// A value type rather than a `SourceRef`, because extraction runs on the
/// capture path *before* the task exists — there is no `taskID` to give a
/// `@Model` yet. Keeping it a plain `Sendable` struct is also what lets
/// extraction be tested against literal arrays with no container.
public struct ExtractedRef: Hashable, Sendable {
    public let kind: SourceRefKind
    public let identifier: String

    /// The canonical link, when the reference came from one.
    ///
    /// `nil` only for a bare ticket key typed in prose: the overlap rule in
    /// `ReferenceExtractor` guarantees such a key had no link to attach.
    public let url: String?

    public init(kind: SourceRefKind, identifier: String, url: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.url = url
    }

    /// `SourceRef.DedupKey` (§3.4) minus the `taskID`, which is constant
    /// across a single extraction pass. `url` is deliberately excluded — the
    /// same reference written bare and written as a link is one reference.
    public struct DedupKey: Hashable, Sendable {
        public let kind: SourceRefKind
        public let identifier: String
    }

    public var dedupKey: DedupKey { DedupKey(kind: kind, identifier: identifier) }

    /// Bind this reference to a task, producing the persisted model.
    ///
    /// The one place `Capture/` touches SwiftData, called by M1-02 once the
    /// task it belongs to exists.
    public func sourceRef(taskID: UUID) -> SourceRef {
        SourceRef(taskID: taskID, kind: kind, identifier: identifier, url: url)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make format && make test && make lint
```

Expected: all tests pass, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/ExtractedRef.swift StenoTests/Capture/ExtractedRefTests.swift
git commit -m "feat: ExtractedRef, the value type extraction returns

Extraction runs before the task exists, so it cannot return SourceRef —
a @Model needs a taskID at init. ExtractedRef carries the same facts as a
Sendable value, with a one-line adapter for M1-02 to bind once the task is
real. dedupKey excludes url so a key written bare and written as a link
count as one reference.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: URL classification by path shape

**Files:**
- Create: `StenoKit/Capture/JiraKey.swift`
- Create: `StenoKit/Capture/SourceURLClassifier.swift`
- Create: `StenoTests/Capture/SourceURLClassifierTests.swift`

**Interfaces:**
- Consumes: `ExtractedRef(kind:identifier:url:)` from Task 1.
- Produces: `JiraKey.pattern` (a computed `static var` of type `Regex<Substring>`), used by Task 3 as well; `SourceURLClassifier.classify(_ link: URL) -> ExtractedRef`, which always returns a ref, falling back to `.url`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/SourceURLClassifierTests.swift`. Every expected value here is recorded output from running the finished implementation:

```swift
import Foundation
import Testing

@testable import StenoKit

private struct ClassifyCase: CustomTestStringConvertible {
    let link: String
    let kind: SourceRefKind
    let identifier: String

    var testDescription: String { "\(link) → \(kind.rawValue) \(identifier)" }
}

private let classifyCases: [ClassifyCase] = [
    // Jira: any host, because a self-hosted instance is still Jira
    .init(
        link: "https://acme.atlassian.net/browse/PAY-421", kind: .jiraIssue,
        identifier: "PAY-421"),
    .init(link: "https://jira.corp.net/browse/PAY-421", kind: .jiraIssue, identifier: "PAY-421"),
    // GitHub: host-anchored, repo-qualified identifier (§3.4 v1.10, D-022)
    .init(
        link: "https://github.com/acme/api/pull/421", kind: .githubPR,
        identifier: "acme/api#421"),
    .init(
        link: "https://github.com/acme/web/pull/421", kind: .githubPR,
        identifier: "acme/web#421"),
    .init(
        link: "https://github.com/acme/api/pull/421/files#diff-abc123", kind: .githubPR,
        identifier: "acme/api#421"),
    // Confluence: both URL shapes, identifier is the numeric page ID
    .init(
        link: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook",
        kind: .confluencePage, identifier: "1712834"),
    .init(
        link: "https://acme.atlassian.net/pages/viewpage.action?pageId=1712834",
        kind: .confluencePage, identifier: "1712834"),
]

@Test("each shape maps to its kind and identifier", arguments: classifyCases)
private func classifiesByShape(testCase: ClassifyCase) throws {
    let link = try #require(URL(string: testCase.link))

    let ref = SourceURLClassifier.classify(link)

    #expect(ref.kind == testCase.kind)
    #expect(ref.identifier == testCase.identifier)
    #expect(ref.url == testCase.link)
}

private let fallbackCases: [String] = [
    // No numeric page ID to use as an identifier, so not a confluencePage
    "https://acme.atlassian.net/display/ENG/Runbook",
    "https://acme.atlassian.net/wiki/pages/overview",
    "https://acme.atlassian.net/x?pageId=",
    // Not a PR path
    "https://github.com/acme/api/tree/PAY-421-fix",
    // Right shape, wrong host — /a/b/pull/n is too generic to claim
    "https://gitlab.example.com/acme/api/pull/421",
    // /browse/ segment that is not a ticket key
    "https://shop.example.com/browse/shoes",
    "https://example.com/a/b",
]

@Test("anything unrecognised is a plain url, identified by itself", arguments: fallbackCases)
private func fallsBackToURL(raw: String) throws {
    let link = try #require(URL(string: raw))

    let ref = SourceURLClassifier.classify(link)

    #expect(ref.kind == .url)
    #expect(ref.identifier == raw)
    #expect(ref.url == raw)
}

@Test("the FR-1.5 pattern is used verbatim")
private func patternIsVerbatim() {
    #expect("PAY-421".wholeMatch(of: JiraKey.pattern) != nil)
    #expect("ABCDEFGHIJ-9".wholeMatch(of: JiraKey.pattern) != nil)
    #expect("ABCDEFGHIJK-9".wholeMatch(of: JiraKey.pattern) == nil)
    #expect("pay-421".wholeMatch(of: JiraKey.pattern) == nil)
    #expect("A-1".wholeMatch(of: JiraKey.pattern) == nil)
    // Known false positives — FR-1.5's regex is used as written (spec §7)
    #expect("UTF-8".wholeMatch(of: JiraKey.pattern) != nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: compile failure — `cannot find 'SourceURLClassifier' in scope`.

- [ ] **Step 3: Write `JiraKey`**

Create `StenoKit/Capture/JiraKey.swift`:

```swift
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
```

- [ ] **Step 4: Write `SourceURLClassifier`**

Create `StenoKit/Capture/SourceURLClassifier.swift`:

```swift
import Foundation

/// Turns one link into the reference it points at (REQUIREMENTS.md §3.4).
///
/// Classification is by **path shape, not hostname**: a self-hosted
/// `jira.corp.net/browse/PAY-421` is as much a Jira issue as an Atlassian
/// one, and the extractor cannot read the user's configured hosts without
/// ceasing to be the pure function FR-1.5 requires. GitHub is the single host
/// check, because `/<a>/<b>/pull/<n>` alone is too generic to claim.
public enum SourceURLClassifier {
    /// Always returns a ref: an unrecognised link is a `.url`, identified by
    /// itself. Order matters only in that the fallback comes last.
    public static func classify(_ link: URL) -> ExtractedRef {
        let absolute = link.absoluteString
        let segments = link.pathComponents.filter { $0 != "/" }
        if let identifier = jiraKeyPath(segments) {
            return ExtractedRef(kind: .jiraIssue, identifier: identifier, url: absolute)
        }
        if let identifier = githubPullRequest(link, segments) {
            return ExtractedRef(kind: .githubPR, identifier: identifier, url: absolute)
        }
        if let identifier = confluencePageID(link, segments) {
            return ExtractedRef(kind: .confluencePage, identifier: identifier, url: absolute)
        }
        return ExtractedRef(kind: .url, identifier: absolute, url: absolute)
    }

    /// A non-empty all-digit string, or nil. Both Confluence forms and the PR
    /// number funnel through this so "empty is not a number" is decided once.
    private static func digits(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return value
    }

    private static func jiraKeyPath(_ segments: [String]) -> String? {
        guard let index = segments.firstIndex(of: "browse"), index + 1 < segments.count else {
            return nil
        }
        let candidate = segments[index + 1]
        guard candidate.wholeMatch(of: JiraKey.pattern) != nil else { return nil }
        return candidate
    }

    /// Repo-qualified per §3.4 (v1.10, D-022): a bare PR number collides
    /// across repositories under the `(taskID, kind, identifier)` dedup rule.
    /// Trailing segments (`/files`, a fragment) are ignored, so the same PR
    /// linked at different depths yields one identifier.
    private static func githubPullRequest(_ link: URL, _ segments: [String]) -> String? {
        let host = link.host()?.lowercased()
        guard host == "github.com" || host == "www.github.com" else { return nil }
        guard segments.count >= 4, segments[2] == "pull" else { return nil }
        guard let number = digits(segments[3]) else { return nil }
        return "\(segments[0])/\(segments[1])#\(number)"
    }

    /// A page with no numeric ID (the legacy `/display/SPACE/Title` form)
    /// deliberately returns nil and falls back to `.url`: §3.4 says the
    /// identifier *is* the page ID, and M4-03 needs one to fetch.
    private static func confluencePageID(_ link: URL, _ segments: [String]) -> String? {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let queryValue = items.first { $0.name == "pageId" }?.value
        if let pageID = digits(queryValue) {
            return pageID
        }
        guard let index = segments.firstIndex(of: "pages"), index + 1 < segments.count else {
            return nil
        }
        return digits(segments[index + 1])
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
make format && make test && make lint
```

Expected: all tests pass, 0 lint violations.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Capture/JiraKey.swift StenoKit/Capture/SourceURLClassifier.swift \
        StenoTests/Capture/SourceURLClassifierTests.swift
git commit -m "feat: classify source URLs by path shape, not hostname

Recognising Jira and Confluence by host would need the user's configured
base URLs, which extraction cannot read without ceasing to be pure — and
would silently downgrade a self-hosted instance to a plain link. Shape
does the job with no configuration. GitHub keeps a host check because
/a/b/pull/n is too generic to claim.

Identifiers are repo-qualified for GitHub per §3.4 v1.10: a bare PR
number collides across repositories under the dedup rule and drops the
second reference.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `ReferenceExtractor` — the public entry point

**Files:**
- Create: `StenoKit/Capture/ReferenceExtractor.swift`
- Create: `StenoTests/Capture/ReferenceExtractorTests.swift`

**Interfaces:**
- Consumes: `ExtractedRef` (Task 1), `JiraKey.pattern` and `SourceURLClassifier.classify(_:)` (Task 2).
- Produces: `ReferenceExtractor.extract(from text: String) -> [ExtractedRef]` — the entry point M1-02 calls on a task title and M1-06 calls on a note body. The parameter is deliberately named `text`, carrying no assumption that the input is a title.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/ReferenceExtractorTests.swift`. Every `expected` array below is recorded output from running the finished implementation:

```swift
import Foundation
import Testing

@testable import StenoKit

private struct ExtractCase: CustomTestStringConvertible {
    let name: String
    let text: String
    let expected: [ExtractedRef]

    var testDescription: String { name }
}

private let browseURL = "https://acme.atlassian.net/browse/PAY-421"

private let extractCases: [ExtractCase] = [
    .init(
        name: "a bare key",
        text: "PAY-421",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(
        name: "a key inside a sentence",
        text: "Fixed the retry bug in PAY-421 this morning",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(
        name: "multiple keys in one line, in text order",
        text: "PAY-421 and INFRA-7 both landed",
        expected: [
            .init(kind: .jiraIssue, identifier: "PAY-421"),
            .init(kind: .jiraIssue, identifier: "INFRA-7"),
        ]),
    .init(
        name: "a key at string start and a key at string end",
        text: "PAY-421 is blocked by INFRA-7",
        expected: [
            .init(kind: .jiraIssue, identifier: "PAY-421"),
            .init(kind: .jiraIssue, identifier: "INFRA-7"),
        ]),
    .init(name: "a lowercase key does not match", text: "pay-421 is not a key", expected: []),
    .init(
        name: "a hyphenated non-key word does not match",
        text: "a well-known trade-off, state-of-the-art",
        expected: []),
    .init(
        name: "a bare URL",
        text: "notes at https://example.com/a/b",
        expected: [
            .init(kind: .url, identifier: "https://example.com/a/b", url: "https://example.com/a/b")
        ]),
    .init(
        name: "a GitHub PR URL",
        text: "https://github.com/acme/api/pull/421",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "https://github.com/acme/api/pull/421")
        ]),
    .init(
        name: "a Confluence URL",
        text: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook",
        expected: [
            .init(
                kind: .confluencePage, identifier: "1712834",
                url: "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook")
        ]),
    .init(
        name: "a browse URL and its bare key yield one ref carrying the link",
        text: "Fixed PAY-421, see \(browseURL)",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421", url: browseURL)]),
    .init(
        name: "a key inside another host's URL is part of that URL, not a ticket",
        text: "https://github.com/acme/api/tree/PAY-421-fix",
        expected: [
            .init(
                kind: .url, identifier: "https://github.com/acme/api/tree/PAY-421-fix",
                url: "https://github.com/acme/api/tree/PAY-421-fix")
        ]),
    .init(
        name: "a slug shaped like a key does not become a phantom ticket",
        text: "See https://ex.com/reports/AWS-2024/q3",
        expected: [
            .init(
                kind: .url, identifier: "https://ex.com/reports/AWS-2024/q3",
                url: "https://ex.com/reports/AWS-2024/q3")
        ]),
    .init(
        name: "the same key twice yields one ref",
        text: "PAY-421 blocked, still PAY-421",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421")]),
    .init(name: "an email address is not a reference", text: "ping bob@example.com", expected: []),
    .init(
        name: "a scheme-less PR URL still classifies",
        text: "see github.com/acme/api/pull/421 please",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "http://github.com/acme/api/pull/421")
        ]),
    .init(
        name: "two PRs with the same number in different repos stay two refs",
        text: "https://github.com/acme/api/pull/421 and https://github.com/acme/web/pull/421",
        expected: [
            .init(
                kind: .githubPR, identifier: "acme/api#421",
                url: "https://github.com/acme/api/pull/421"),
            .init(
                kind: .githubPR, identifier: "acme/web#421",
                url: "https://github.com/acme/web/pull/421"),
        ]),
    .init(
        name: "a bare key followed by its link keeps the link",
        text: "PAY-421 — see \(browseURL)",
        expected: [.init(kind: .jiraIssue, identifier: "PAY-421", url: browseURL)]),
    .init(
        name: "trailing punctuation is not part of the URL",
        text: "see https://example.com/a/b.",
        expected: [
            .init(kind: .url, identifier: "https://example.com/a/b", url: "https://example.com/a/b")
        ]),
    .init(name: "a 10-character prefix matches", text: "ABCDEFGHIJ-9 matches", expected: [
        .init(kind: .jiraIssue, identifier: "ABCDEFGHIJ-9")
    ]),
    .init(name: "an 11-character prefix does not", text: "ABCDEFGHIJK-9 does not", expected: []),
    .init(name: "empty input", text: "", expected: []),
    .init(name: "whitespace-only input", text: "   \n  ", expected: []),
]

@Test("FR-1.5 extraction", arguments: extractCases)
private func extracts(testCase: ExtractCase) {
    #expect(ReferenceExtractor.extract(from: testCase.text) == testCase.expected)
}

@Test("keys and URLs interleave in first-occurrence order")
private func ordersByFirstOccurrence() {
    let text = "PAY-421 then https://example.com/a then INFRA-7"

    let refs = ReferenceExtractor.extract(from: text)

    #expect(refs.map(\.identifier) == ["PAY-421", "https://example.com/a", "INFRA-7"])
}

@Test("extraction is pure: the same input gives the same output")
private func isPure() {
    let text = "PAY-421 and \(browseURL) and https://github.com/acme/api/pull/421"

    #expect(ReferenceExtractor.extract(from: text) == ReferenceExtractor.extract(from: text))
}

@Test("the link detector is available, so URL refs are not silently lost")
private func detectorIsAvailable() {
    #expect(ReferenceExtractor.detector != nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
make test
```

Expected: compile failure — `cannot find 'ReferenceExtractor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/ReferenceExtractor.swift`:

```swift
import Foundation

/// Scans text for the external references it mentions (REQUIREMENTS.md FR-1.5).
///
/// Pure: no I/O, no store, no clock, no configuration. Extraction is passive
/// and silent — there is no `@project`, no `#tag`, and no command grammar of
/// any kind, because the user explicitly declined one (FR-1.5, §1.1).
///
/// The parameter is `text`, not `title`: FR-1.5 runs extraction over task
/// titles *and* note bodies, and M1-06 calls this same entry point.
public enum ReferenceExtractor {
    private struct LinkSpan {
        let range: Range<String.Index>
        let link: URL
    }

    /// `NSDataDetector` is `Sendable`, so this needs no isolation. Built with
    /// `try?` rather than `try!`, which `make lint --strict` rejects; a test
    /// asserts it is non-nil, so a silent total failure cannot ship.
    static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func extract(from text: String) -> [ExtractedRef] {
        guard !text.isEmpty else { return [] }
        let spans = linkSpans(in: text)
        var found: [(start: String.Index, ref: ExtractedRef)] = spans.map {
            ($0.range.lowerBound, SourceURLClassifier.classify($0.link))
        }
        // A key overlapping a link is part of that link. This is what turns a
        // browse URL into one ref instead of two, and what stops a slug like
        // /reports/AWS-2024/q3 from manufacturing a ticket that never existed.
        for match in text.matches(of: JiraKey.pattern) {
            guard !spans.contains(where: { $0.range.overlaps(match.range) }) else { continue }
            found.append(
                (
                    match.range.lowerBound,
                    ExtractedRef(kind: .jiraIssue, identifier: String(text[match.range]))
                ))
        }
        found.sort { $0.start < $1.start }
        return merged(found.map(\.ref))
    }

    /// `http(s)` links only. The detector synthesises a `mailto:` link from a
    /// bare email address, and an email address is not a `SourceRef`.
    private static func linkSpans(in text: String) -> [LinkSpan] {
        guard let detector else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var spans: [LinkSpan] = []
        for match in detector.matches(in: text, range: whole) {
            guard let link = match.url,
                let scheme = link.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                let range = Range(match.range, in: text)
            else { continue }
            spans.append(LinkSpan(range: range, link: link))
        }
        return spans
    }

    /// Dedup within one pass, first occurrence winning the position.
    ///
    /// `url` is filled from the first occurrence that *has* one, so
    /// "PAY-421 — see <browse URL>" keeps the link. Taking the first
    /// occurrence wholesale would hand M4 a ref with nothing to fetch.
    ///
    /// Dedup *across* saves is not this function's job: `SourceRef.newRefs`
    /// does that, and M1-02 calls it with what the store already holds.
    private static func merged(_ refs: [ExtractedRef]) -> [ExtractedRef] {
        var order: [ExtractedRef.DedupKey] = []
        var byKey: [ExtractedRef.DedupKey: ExtractedRef] = [:]
        for ref in refs {
            guard let existing = byKey[ref.dedupKey] else {
                byKey[ref.dedupKey] = ref
                order.append(ref.dedupKey)
                continue
            }
            if existing.url == nil, ref.url != nil {
                byKey[ref.dedupKey] = ExtractedRef(
                    kind: existing.kind, identifier: existing.identifier, url: ref.url)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
make format && make test && make lint
```

Expected: all tests pass, 0 lint violations. If a single row fails, re-run just this suite:

```bash
xcodebuild -project Steno.xcodeproj -scheme Steno -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS' -only-testing:StenoTests/extracts test | xcbeautify
```

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/ReferenceExtractor.swift StenoTests/Capture/ReferenceExtractorTests.swift
git commit -m "feat: passive reference extraction (FR-1.5)

Link spans are found first and treated as opaque, so a ticket key inside
a URL is part of that URL rather than a separate ref. That one rule gives
all three behaviours the task asks for: a browse URL collapses to a single
jiraIssue ref carrying its link, and a slug like /reports/AWS-2024/q3
stops manufacturing tickets that never existed — a ref card for a
nonexistent ticket is something the user has to read past at stand-up.

Refs come out in first-occurrence order, deduped on (kind, identifier),
with url filled from the first occurrence that has one so a bare key
followed by its link does not discard the link.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Latency measurement and the docs this lands

**Files:**
- Create: `StenoTests/Capture/ExtractionPerformanceTests.swift`
- Modify: `docs/ARCHITECTURE.md` — the `Capture/` line in §5
- Modify: `docs/tasks/README.md` — the M1-01 row

**Interfaces:**
- Consumes: `ReferenceExtractor.extract(from:)` (Task 3).
- Produces: nothing new in code. M1-02 reuses this file's shape for its own latency claim.

- [ ] **Step 1: Write the performance test**

This is XCTest, not Swift Testing — the single exception D-011 reserves, because Swift Testing has no `measure` equivalent and §1.1's budget is a non-negotiable that must be measured rather than asserted. D-011 requires the PR body to say why; Step 5 does.

Create `StenoTests/Capture/ExtractionPerformanceTests.swift`:

```swift
import XCTest

@testable import StenoKit

/// Extraction runs on the capture path, which §1.1 and §13 make
/// latency-critical: if capture exceeds ~3 seconds the user reverts to paper
/// and the product dies. XCTest rather than Swift Testing per D-011 — this is
/// the `measure` exception, and there is no Swift Testing equivalent.
///
/// The ceilings sit roughly an order of magnitude above measured values, so a
/// real regression fails while a loaded machine does not.
final class ExtractionPerformanceTests: XCTestCase {
    private static let realistic = """
        Debugged the retry handler for PAY-421, PR https://github.com/acme/api/pull/912, \
        notes in https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Retry
        """

    /// Measured at 91 µs. A task title is the input that must never be felt.
    func testRealisticCaptureStringIsWellUnderBudget() {
        let text = Self.realistic
        var elapsed = 0.0

        measure {
            let start = Date()
            for _ in 0..<100 {
                _ = ReferenceExtractor.extract(from: text)
            }
            elapsed = Date().timeIntervalSince(start) / 100
        }

        XCTAssertLessThan(elapsed, 0.001, "extraction of a capture string exceeded 1 ms")
    }

    /// Measured at 1.9 ms for ~7 KB. FR-1.5 runs extraction over note bodies
    /// too, so the longest realistic input gets its own ceiling.
    func testLongNoteBodyStaysFarInsideBudget() {
        let text = String(
            repeating:
                "Worked on PAY-421 and read "
                + "https://acme.atlassian.net/wiki/spaces/ENG/pages/1712834/Runbook today. ",
            count: 70)
        var elapsed = 0.0

        measure {
            let start = Date()
            for _ in 0..<10 {
                _ = ReferenceExtractor.extract(from: text)
            }
            elapsed = Date().timeIntervalSince(start) / 10
        }

        XCTAssertLessThan(elapsed, 0.020, "extraction of a long note body exceeded 20 ms")
    }
}
```

- [ ] **Step 2: Run it and record the real numbers**

```bash
make test
```

Expected: both pass. **Copy the two measured averages out of the output** — they go in the PR body, because §13 requires the number, not the claim. If either assertion fails on this machine, that is a finding to report, not a threshold to raise.

- [ ] **Step 3: Update `docs/ARCHITECTURE.md`**

In §5's directory tree, line 144 currently reads:

```
  Capture/        capture core, ref extraction           (M1-01, M1-02)
```

Change it to record what now exists:

```
  Capture/        ref extraction (exists, M1-01); capture core (M1-02)
```

- [ ] **Step 4: Update `docs/tasks/README.md`**

Tick the M1-01 row, adding the PR number once the PR is open:

```
- [x] [M1-01](M1-01-reference-extraction.md) — passive ref extraction (FR-1.5), pure and headless-tested — PR #<n>
```

Also re-check the rest of the list for any row that merged without being ticked (CLAUDE.md "Working a task" step 4). As of the start of this task there were none — M0-05's row was ticked by PR #10.

- [ ] **Step 5: Full verification, then open the PR**

```bash
make build && make test && make lint
```

All three must pass before the PR exists (§9.5 step 4). Then:

```bash
git add StenoTests/Capture/ExtractionPerformanceTests.swift docs/ARCHITECTURE.md docs/tasks/README.md
git commit -m "test: measure extraction latency, and record what M1-01 landed

§13 requires the capture path be measured rather than assumed, so the
numbers go in the PR body. XCTest rather than Swift Testing because
D-011 reserves exactly this exception: measure has no Swift Testing
equivalent, and §1.1's budget is not something to take on faith.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin feat/reference-extraction
gh pr create --fill
```

The PR body must cover, per §9.5 and the spec:

1. **The measured latency numbers** from Step 2 (§13).
2. **Why an XCTest case exists** — D-011's required justification.
3. **FR-1.5's regex has false positives** — `UTF-8`, `COVID-19`, `ISO-8601`, `M1-01` all match. Used verbatim per the task file; blast radius is one stray ref card, and FR-1.4 cannot misroute on it because routing needs a configured `Project.jiraProjectKeys` prefix. Spec §7 has the full text.
4. **`REQUIREMENTS.md` was amended to v1.10** (§3.4's `identifier`, recorded as D-022) — already committed on this branch, but call it out so the reviewer reads it.
5. **The deviation from the task file:** extraction returns `ExtractedRef`, not `SourceRef`. Spec §1 has the reasoning.

**Then stop. Do not merge** (CLAUDE.md non-negotiable 1).

---

## Out of scope

Named here because each is a boundary some later task owns, and crossing it makes this PR unreviewable:

- **Fetching anything.** M4 resolves refs; this task only finds them.
- **Project auto-routing from a matched key.** FR-1.4's rule belongs to M1-02.
- **Any command grammar** — no `@project`, no `#tag`, ever. The user explicitly declined one (FR-1.5); a proposal to add "just a little" syntax reintroduces the schema that made the paper notebook faster (§1.1).
- **Cross-save dedup or any persistence.** `SourceRef.newRefs` already exists; M1-02 calls it.
- **A stoplist for the regex's false positives.** A real behaviour change, and it belongs to a task that owns the tradeoff.
