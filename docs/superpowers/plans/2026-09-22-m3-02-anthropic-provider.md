# M3-02 Anthropic Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `AnthropicProvider` behind M3-01's seam — a runtime-fetched model list, one `POST /v1/messages`, a 20-second budget §7.4 can wait on, and every vendor failure mapped onto `AIError`.

**Architecture:** The provider is a `Sendable` struct over three injected dependencies: an `HTTPTransport` (plain request/response values, so `make test` needs no network), a `CredentialStore` (M3-01's), and a `Configuration` holding D-144's budgets. Vendor JSON lives in `StenoKit/AI/Anthropic/` as `internal` types that no public signature mentions. Error mapping and model ranking are pure functions, which is what makes them table tests rather than fixture exercises.

**Tech Stack:** Swift 6 (`SWIFT_VERSION: 6.0`), macOS 14 floor, Swift Testing, `URLSession` behind one adapter, `JSONSerialization` for the request body and `JSONDecoder` for responses.

**Spec:** [`docs/superpowers/specs/2026-09-22-m3-02-anthropic-provider-design.md`](../specs/2026-09-22-m3-02-anthropic-provider-design.md) — the plan argues from D-140 through D-146; read both.

## Provenance of the code in this plan

**Every code block below was generated from a tree that passed `make build && make test && make lint`**, and every load-bearing test was run against a stated mutation and seen to fail.

**Regenerated after review (PR #35).** The blocks first written here came from the pre-review
tree, and six review findings then changed six of the files — so following the plan would have
reintroduced the very defects this PR fixed. That is a real failure mode for a plan that doubles
as a verification record, and Copilot caught it. The blocks below are taken from the tree as
merged; the mutation table covers both rounds.

| Mutation applied | Test that turned red |
|---|---|
| `URLError.cancelled` maps to `.network` instead of `.timedOut` | `cancellationIsATimeout` |
| `withDeadline` drops its `catch is CancellationError` | `cancellationStaysInsideTheContract` |
| `validated(against:)` dropped from the draft path | `hallucinatedIDsFailLoudly` |
| `familyRank` returns 2 for sonnet instead of 0 | 3 tests, in `ModelRankingTests` and `AnthropicProviderBudgetTests` |
| `backoff(for:)` returns `nil` for `.providerUnavailable` | `overloadIsRetried` |
| `DraftFailure` carries `usage: nil` | `failedDraftsKeepTheirUsage` |
| `.sortedKeys` dropped from the request body | `theBodyIsDeterministic` |
| `.daily` decoded regardless of cadence | `periodicCadenceRoundTrips`, `periodicDraftsAreValidated` |
| `seen.insert` dedupe filter dropped from `ModelRanking.ordered` | `duplicatesAreCollapsed`, `aRepeatedCursorTerminates` |

This matters because standalone type-checking of a snippet has shipped real defects in this repo — it proves syntax, not module-scope correctness, and `#expect` macros hide errors until they are compiled inside the test bundle. The blocks here are not transcriptions of intent; they compiled.

Two consequences for the executor:

1. **The `Testing` / `StenoKit` "no such module" diagnostics your editor shows for new files are stale project state**, not errors. `make test` regenerates `Steno.xcodeproj` (D-014) and picks the files up.
2. **`make format` owns layout (D-013).** Run it before each commit; a dirty tree after formatting is your change to commit, not a surprise (D-075).

## Global Constraints

- **Never commit to `main`.** Branch `feat/anthropic-provider`, one PR, do not merge (§9.5).
- **Swift version 6.0**, deployment target **macOS 14.0** — `Mutex` needs 15, so doubles are actors (D2).
- **Tests run with outbound networking denied** by `Scripts/test-sandbox.sb` (§9.4, D-012). No test may reach the network.
- **§8: metadata only.** No prompt, draft, response body, or API error message may reach a log line. `AIMetricsLog.record` is the only emitter; do not add a second, not even behind `#if DEBUG` (D-137).
- **The event log is append-only** (§3.3). Nothing in this task writes to the store at all.
- **`AIProvider` throws `AIError` and nothing else.** A `URLError` or `DecodingError` escaping the provider is a defect (M3-01's contract).
- **SwiftLint caps type nesting at one level** and files at 400 lines; identifiers must be ≥3 characters; force-unwrapping is rejected in test code.
- **Anthropic API facts:** `anthropic-version: 2023-06-01`; `GET /v1/models` uses `limit` + `after_id` and returns `has_more`/`last_id`; structured output is `output_config.format = {"type": "json_schema", "schema": …}`; 429 carries `retry-after`; 529 is "overloaded".

---

### Task 1: `AIError` grows three cases

**Files:**
- Modify: `StenoKit/AI/AIError.swift`
- Test: `StenoTests/AI/AIErrorTests.swift`

**Interfaces:**
- Consumes: M3-01's `AIError`, `InvalidResponseReason`, `metricsLabel`, `errorDescription`.
- Produces: `AIError.invalidRequest`, `InvalidResponseReason.refused`, `InvalidResponseReason.truncated`. Every later task maps onto these.

This is a D-132 extension, not a spec amendment: REQUIREMENTS.md never names `AIError` — §7.1 prints the protocol. No version bump.

- [ ] **Step 1: Extend the existing audit to the new cases**

In `StenoTests/AI/AIErrorTests.swift`, add to `AIError.everyCase`:

```swift
        .notConfigured,
        .invalidCredential,
        .invalidRequest,
        .network,
```

and, after `.invalidResponse(.emptyDraft)`:

```swift
        .invalidResponse(.emptyDraft),
        .invalidResponse(.refused),
        .invalidResponse(.truncated),
        .unknownTaskIDs(count: 3),
```

and raise the label count:

```swift
    // Nine, not eight, since M3-02's `.invalidRequest` (D-143). The two new
    // `InvalidResponseReason` cases share the `invalidResponse` label by
    // design — the label names the case, and the reason is what §8's line
    // deliberately does not carry.
    #expect(Set(AIError.everyCase.map(\.metricsLabel)).count == 9)
```

- [ ] **Step 2: Run the tests and watch them fail to compile**

Run: `make test`
Expected: compile failure — `type 'AIError' has no member 'invalidRequest'`.

- [ ] **Step 3: Add the cases**

In `StenoKit/AI/AIError.swift`, after `case invalidCredential`:

```swift
    /// The provider rejected the *request*: a 400 it would not parse, a 404 for
    /// a model id retired since the user picked it, or a 413 for a window too
    /// large to send (D-143).
    ///
    /// **Separate from `.providerUnavailable`, which is where the obvious
    /// mapping would put a 404.** These failures are ours, not Anthropic's, and
    /// "the provider is unavailable right now" would send a user whose selected
    /// model no longer exists to a status page instead of the picker. Carries
    /// nothing: the API's `error.message` can quote the request that provoked
    /// it, which on the draft path is the user's event log (§8).
    ///
    /// Because it spans all of those, its message names no single cause — see
    /// `errorDescription`.
    case invalidRequest
```

In `InvalidResponseReason`, after `case emptyDraft`:

```swift
    /// The model declined the request (`stop_reason: "refusal"`).
    ///
    /// Distinct from `.undecodable`, which is where a refusal lands without
    /// this case — a well-formed answer that is not a draft would otherwise be
    /// reported as garbage from the provider, and §8's metrics would stop
    /// distinguishing a decline from a broken response.
    case refused

    /// The answer was cut off by `max_tokens`.
    ///
    /// Distinct from `.schemaViolation` for the same reason in the other
    /// direction: truncated JSON breaks §7.3's schema, but the cause is a
    /// budget the app set, not a model that invented a shape. Filing it under
    /// `.schemaViolation` would make a real hallucination indistinguishable
    /// from the app under-provisioning `maxOutputTokens`.
    case truncated
```

In `errorDescription`, after the `.invalidCredential` arm:

```swift
        case .invalidRequest:
            // **Names no single cause on purpose.** This one case covers 400,
            // 404, 413 and 422, so "the selected model may no longer exist"
            // — true only of the 404 — gave model-picker advice for a window
            // too large to send. The case carries nothing that could tell them
            // apart, and inventing a distinction the value does not hold is
            // worse than naming both possibilities.
            return
                "The provider couldn't accept this request. The selected model may be unavailable, "
                + "or the window may be too large to send."
```

In `metricsLabel`, after the `.invalidCredential` arm:

```swift
        case .invalidRequest: return "invalidRequest"
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS. The audit now covers 13 values across 9 labels.

- [ ] **Step 5: Commit**

```bash
make format
git add StenoKit/AI/AIError.swift StenoTests/AI/AIErrorTests.swift
git commit -m "feat: AIError gains invalidRequest, refused and truncated

D-143. Without these a 404 for a retired model id reads as 'the provider
is unavailable', sending the user to a status page instead of the model
picker; and a refusal or a truncated answer reads as .undecodable, which
files two provider-side outcomes under the label §7.3 reserves for a
model that broke the schema.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: The transport seam and the deadline

**Files:**
- Create: `StenoKit/AI/HTTPTransport.swift`
- Create: `StenoKit/AI/URLSessionTransport.swift`
- Create: `StenoKit/AI/Deadline.swift`
- Create: `StenoTests/AI/StubHTTPTransport.swift`
- Test: `StenoTests/AI/DeadlineTests.swift`

**Interfaces:**
- Consumes: `AIError` (Task 1).
- Produces: `protocol HTTPTransport { func send(_ request: HTTPRequest) async throws -> HTTPResponse }`; `HTTPRequest(method:url:headers:body:)` with `Method.get`/`.post`; `HTTPResponse(status:headers:body:)`; `URLSessionTransport(session:)`; `withDeadline(_ duration: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T`; `actor StubHTTPTransport` with `Answer.respond`/`.fail`, `init(answers:fallback:delay:)`, `.returning(_:status:)`, and `received: [HTTPRequest]`.

`HTTPRequest`/`HTTPResponse` carry **lowercased header names** — HTTP header names are case-insensitive, and a test asserting `X-Api-Key` against a provider sending `x-api-key` would fail for a reason that is not a defect.

- [ ] **Step 1: Write the failing deadline tests**

Create `StenoTests/AI/DeadlineTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

// D-145. §7.4's fallback waits on this, so the two things asserted are that the
// clock actually wins and that losing it is `.timedOut` — never `.network`.

@Test("work that finishes inside the budget returns its value")
func fastWorkSurvivesTheDeadline() async throws {
    let value = try await withDeadline(.seconds(30)) { 42 }
    #expect(value == 42)
}

@Test("work that overruns the budget throws .timedOut")
func slowWorkLosesTheRace() async {
    // A minute of work against a millisecond of budget. Mutation: return the
    // operation's result without racing the sleeper — the test then hangs
    // rather than failing, which is itself the signal.
    await #expect(throws: AIError.timedOut) {
        try await withDeadline(.milliseconds(10)) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
    }
}

@Test("the deadline does not swallow the operation's own error")
func realFailuresPropagate() async {
    // A timeout that masked every failure as `.timedOut` would tell the user
    // the provider was slow when their key was rejected.
    await #expect(throws: AIError.invalidCredential) {
        try await withDeadline(.seconds(30)) {
            throw AIError.invalidCredential
        }
    }
}

@Test("a cancelled deadline surfaces .timedOut, never a raw CancellationError")
func cancellationStaysInsideTheContract() async {
    // M3-01's contract: a provider throws `AIError` and nothing else, because
    // §7.4 "cannot switch on an error type it has never heard of". Cancelling
    // the caller cancels both children of the race, and a cancelled
    // `Task.sleep` throws `CancellationError` — from the deadline task before
    // it reaches its own `throw`, and from anything inside the operation that
    // sleeps. Either can win.
    //
    // The operation here does no mapping of its own, so this fails the moment
    // `withDeadline` stops mapping. Mutation: remove its `catch is
    // CancellationError`. Red.
    let task = Task {
        try await withDeadline(.seconds(60)) {
            try await Task.sleep(for: .seconds(60))
            return 1
        }
    }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected the cancelled deadline to fail")
    } catch is AIError {
        // The contract held.
    } catch {
        Issue.record("escaped as \(type(of: error)), which §7.4 cannot classify")
    }
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make test`
Expected: compile failure — `cannot find 'withDeadline' in scope`.

- [ ] **Step 3: Create the transport value types**

Create `StenoKit/AI/HTTPTransport.swift`:

```swift
import Foundation

/// The seam every network call in this module goes through (D-142).
///
/// **One method over plain values, rather than a `URLSession` the provider
/// holds.** `make test` denies outbound IP entirely (§9.4, D-012), so a
/// provider that reached for `URLSession` directly could not be tested at all.
/// This is the same shape `CredentialStore` uses so tests never touch the login
/// keychain, and `StubFilePanels` uses so tests never open an `NSOpenPanel`.
///
/// **Values, not `URLRequest`/`HTTPURLResponse`.** Foundation's networking
/// types are classes whose `Sendable` status is a poor thing to bet a Swift 6
/// module on, and — more usefully — error mapping over `(status, headers)` is a
/// pure function, which is what makes `AnthropicErrors` a table test rather
/// than a fixture exercise.
public protocol HTTPTransport: Sendable {
    /// **Must be cancellation-aware.** `withDeadline` enforces D-144's budget by
    /// cancelling this call and returning, but Swift cancellation is
    /// cooperative and a task group waits for its children: an implementation
    /// that ignores cancellation keeps the deadline blocked past its budget,
    /// and §7.4's fallback is what arrives late. `URLSession` honours it;
    /// anything built on blocking I/O must check `Task.isCancelled` (PR #35
    /// review).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// One outbound request, fully described.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let method: Method
    public let url: URL

    /// Lowercased field names — **enforced by the initializer, not promised by
    /// this comment.** HTTP header names are case-insensitive, and a test that
    /// asserted `X-Api-Key` against a provider that sent `x-api-key` would fail
    /// for a reason that is not a defect.
    public let headers: [String: String]

    public let body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = HTTPHeaders.normalized(headers)
        self.body = body
    }
}

/// One inbound response, reduced to what this module reads.
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int

    /// Lowercased field names, for the reason `HTTPRequest.headers` gives, and
    /// enforced here for a sharper one: `AnthropicErrors` looks `retry-after`
    /// up by that exact key, so a transport returning `Retry-After` would
    /// silently lose the server's retry interval and fall back to the default
    /// backoff — a wrong wait with nothing to notice it (PR #35 review).
    public let headers: [String: String]

    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = HTTPHeaders.normalized(headers)
        self.body = body
    }
}

/// Where the lowercasing actually happens.
///
/// A free function rather than a rule each initializer restates: the promise
/// "these keys are lowercased" was a doc comment on two types and true of
/// neither, which is the defect class this repo keeps meeting.
enum HTTPHeaders {
    /// Lowercased keys. A collision — `Retry-After` and `retry-after` in one
    /// dictionary — keeps the last value, which is what HTTP means by treating
    /// the two as the same header.
    static func normalized(_ headers: [String: String]) -> [String: String] {
        guard headers.contains(where: { $0.key != $0.key.lowercased() }) else { return headers }
        return Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { _, last in last }
    }
}
```

- [ ] **Step 4: Create the `URLSession` adapter**

Create `StenoKit/AI/URLSessionTransport.swift`:

```swift
import Foundation

/// The one place in this module where Foundation's networking types appear.
///
/// **`send` is deliberately uncovered by `make test`** (D-142) — though
/// `RedirectBlocker`, below, is not. Its only branch is the
/// `as? HTTPURLResponse` cast, and covering it means a `URLProtocol`
/// stub — a process-global registry, `@unchecked Sendable`, and ordering care
/// under parallel Swift Testing runs — standing between the suite and a file
/// whose only untested behaviour is "Foundation does what Foundation does".
/// If this file grows a branch, that is the moment to pay for the harness.
///
/// **Who closes it: M3-04**, whose task file carries `make verify-models` — a
/// hidden `models-selftest` subcommand on `make verify-keychain`'s pattern
/// (D-138) that runs this adapter against the real API. Until then the first
/// thing to execute this code is a human clicking "Test connection".
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// **No timeout is set on the session**, and that is not an omission.
    /// `URLSessionConfiguration.timeoutIntervalForRequest` is an inactivity
    /// timer that can outlast any budget while bytes trickle; D-144's budget is
    /// a wall clock, and `withDeadline` is what enforces it.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        // **The delegate is what stops the API key travelling.** `URLSession`
        // follows redirects by default and carries custom headers across them,
        // so a 302 to another host — or to plain HTTP — would re-send
        // `x-api-key` to wherever it pointed (PR #35 review). Refusing every
        // redirect is the blunt answer and the right one here: this module
        // talks to exactly one endpoint, and a redirect from it is already
        // something to distrust.
        let (data, response) = try await session.data(
            for: urlRequest, delegate: RedirectBlocker.shared)

        guard let http = response as? HTTPURLResponse else {
            // Not reachable over HTTPS, and `.network` rather than a crash
            // because §7.4 must be able to degrade on *any* failure.
            throw AIError.network
        }

        return HTTPResponse(
            status: http.statusCode,
            headers: Self.lowercasedHeaders(of: http),
            body: data
        )
    }

    private static func lowercasedHeaders(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (field, value) in response.allHeaderFields {
            guard let name = field as? String, let text = value as? String else { continue }
            result[name.lowercased()] = text
        }
        return result
    }
}

/// Refuses every HTTP redirect, so a credential never follows one.
///
/// Returning `nil` from this delegate method hands the 3xx back as the
/// response rather than chasing it, which is why `AnthropicErrors` maps a
/// redirect to `.providerUnavailable(status:)` — and why D-144's retry gate
/// checks for 5xx rather than matching that case, so the request is not
/// repeated either.
///
/// `@unchecked Sendable` is safe because the type has no stored properties:
/// `NSObject` simply is not `Sendable`, and a stateless subclass of it cannot
/// say so any other way.
final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
```

- [ ] **Step 5: Create the deadline**

Create `StenoKit/AI/Deadline.swift`:

```swift
import Foundation

/// Run `operation` against a wall clock, throwing `AIError.timedOut` if the
/// clock wins (D-145).
///
/// **A wall clock, not `URLSession`'s request timeout.** §7.4's fallback waits
/// on this: "if the API is slow, the user is standing in a meeting". The
/// retry loop runs *inside* the deadline, which is what makes D-144's budget
/// cover backoff rather than resetting it on the second attempt.
///
/// **What this cannot do is return while the operation refuses to stop.**
/// `withThrowingTaskGroup` awaits its children before leaving scope and Swift
/// cancellation is cooperative, so an `HTTPTransport` that ignores cancellation
/// keeps this blocked past the budget — §7.4's fallback would then arrive late
/// rather than promptly (PR #35 review). The shipped transport is
/// `URLSession`, which honours cancellation, and `HTTPTransport.send` now says
/// in its own doc comment that an implementation must. That is the contract
/// rather than an enforcement: making the deadline return independently means
/// abandoning a live task, which trades a late answer for a leaked request.
///
/// **That limit is deliberately not unit-tested, after a test for it flaked in
/// CI.** An operation that ignores cancellation has to block its thread to do
/// so, and blocking a cooperative-pool thread can starve the very timer the
/// test is waiting on: the operation then finishes first and no timeout is
/// thrown. It passed locally and failed on a constrained runner, on the same
/// commit that passed a second time — the definition of a flake, and a flaky
/// test is worse than none because it teaches people to re-run. The property
/// belongs to Swift's task-group semantics rather than to this function, so it
/// is stated here and required of `HTTPTransport.send` instead.
///
/// **The subtle part is which error the loser throws.** Cancelling an in-flight
/// `URLSession` task surfaces as `URLError.cancelled`, which sits in the same
/// error domain as the genuine connectivity failures — so mapping it by domain,
/// the obvious mapping, reports `.network` for a request that timed out and
/// tells the user they are offline while their connection is fine. The deadline
/// branch throws `.timedOut` itself, and `AnthropicErrors.error(forTransport:)`
/// maps a stray cancellation the same way, because nothing else here cancels.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await race(duration, operation: operation)
    } catch is CancellationError {
        // **Cancelling the caller cancels both children**, and a cancelled
        // `Task.sleep` throws `CancellationError` — from the deadline task
        // before it reaches its `throw`, and from anything inside `operation`
        // that sleeps. Either can win the race, so a mapping applied at one
        // call site is a coin flip: M3-02's first attempt caught this in
        // `availableModels` and a mutation survived, because the test happened
        // to hit the path the transport had already mapped (PR #35 review).
        //
        // Mapping it here covers every caller and makes the contract
        // deterministic: `withDeadline` throws `AIError` and nothing else.
        throw AIError.timedOut
    }
}

private func race<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw AIError.timedOut
        }

        guard let first = try await group.next() else {
            throw AIError.timedOut
        }
        // The loser is cancelled and its result discarded: a `URLError`
        // cancelled task and a `CancellationError` from the sleeper are both
        // noise once the race is settled.
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 6: Create the test double**

Create `StenoTests/AI/StubHTTPTransport.swift`:

```swift
import Foundation

@testable import StenoKit

/// The D-142 test double: an `HTTPTransport` that answers from a script.
///
/// **Recording the request is half its job.** `make test` denies outbound IP
/// (§9.4, D-012), so this is the only way to assert what the provider *sent* —
/// that the body carries exactly D-141's five keys, that the schema arrives as
/// the value M3-03 authored, that `x-api-key` is present, and that no request
/// is made at all when the credential store is empty.
///
/// An `actor` for the reason `StubAIProvider` is one: `HTTPTransport` is
/// `Sendable`, `send` is `async`, and `Mutex` needs macOS 15 where this
/// project's floor is 14 (D2).
actor StubHTTPTransport: HTTPTransport {
    /// One scripted answer.
    enum Answer: Sendable {
        case respond(HTTPResponse)
        case fail(any Error)
    }

    private var answers: [Answer]

    /// Returned once the script runs out, so a test that under-scripts fails
    /// with a clear 500 rather than an index-out-of-range crash.
    private let fallback: Answer

    /// Held before answering, so a caller's deadline can be exercised.
    private let delay: Duration?

    /// Every request this transport was asked to send, in order.
    private(set) var received: [HTTPRequest] = []

    init(
        answers: [Answer] = [],
        fallback: Answer = .respond(HTTPResponse(status: 500)),
        delay: Duration? = nil
    ) {
        self.answers = answers
        self.fallback = fallback
        self.delay = delay
    }

    /// The common case: one successful JSON body.
    static func returning(_ json: String, status: Int = 200) -> StubHTTPTransport {
        StubHTTPTransport(answers: [
            .respond(HTTPResponse(status: status, body: Data(json.utf8)))
        ])
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Recorded **before** it can fail or hang, so a test of a failing
        // transport can still assert what reached it.
        received.append(request)

        if let delay {
            try await Task.sleep(for: delay)
        }

        let answer = answers.isEmpty ? fallback : answers.removeFirst()
        switch answer {
        case .respond(let response):
            return response
        case .fail(let error):
            throw error
        }
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `make test`
Expected: PASS, including the three new `DeadlineTests`.

- [ ] **Step 8: Commit**

```bash
make format && make lint
git add StenoKit/AI/HTTPTransport.swift StenoKit/AI/URLSessionTransport.swift \
        StenoKit/AI/Deadline.swift StenoTests/AI/StubHTTPTransport.swift \
        StenoTests/AI/DeadlineTests.swift
git commit -m "feat: an HTTP seam tests can drive, and a wall-clock deadline

D-142 and D-145. make test denies outbound IP, so the provider cannot
hold a URLSession directly; plain request/response values also make the
error mapping a pure function rather than a fixture exercise.

The deadline is a race rather than URLSession's timeoutIntervalForRequest,
which is an inactivity timer and can outlast any budget while bytes
trickle — and §7.4's fallback is waiting on it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Vendor failures become `AIError`

**Files:**
- Create: `StenoKit/AI/Anthropic/AnthropicErrors.swift`
- Test: `StenoTests/AI/AnthropicErrorMappingTests.swift`

**Interfaces:**
- Consumes: `AIError` (Task 1).
- Produces: `AnthropicErrors.error(forStatus:headers:) -> AIError?` (`nil` on success), `AnthropicErrors.error(forTransport:) -> AIError`, `AnthropicErrors.retryAfter(in:) -> Duration?`.

- [ ] **Step 1: Write the failing mapping tests**

Create `StenoTests/AI/AnthropicErrorMappingTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

// D-143's table, asserted row by row. §7.4 switches on these, and M3-04 shows
// them, so a status mapped to the wrong case is a sentence in front of the user
// telling them to fix the wrong thing.

private struct StatusCase: Sendable {
    let status: Int
    let expected: AIError
}

private let statusCases: [StatusCase] = [
    StatusCase(status: 401, expected: .invalidCredential),
    StatusCase(status: 403, expected: .invalidCredential),
    StatusCase(status: 400, expected: .invalidRequest),
    StatusCase(status: 404, expected: .invalidRequest),
    StatusCase(status: 413, expected: .invalidRequest),
    StatusCase(status: 422, expected: .invalidRequest),
    StatusCase(status: 429, expected: .rateLimited(retryAfter: nil)),
    StatusCase(status: 500, expected: .providerUnavailable(status: 500)),
    StatusCase(status: 503, expected: .providerUnavailable(status: 503)),
    StatusCase(status: 529, expected: .providerUnavailable(status: 529)),
]

@Test("every mapped status", arguments: statusCases)
private func statusesMapToTheirError(testCase: StatusCase) {
    // Mutation: move 404 into the `default` arm so it becomes
    // `.providerUnavailable`. Red on the 404 row.
    #expect(AnthropicErrors.error(forStatus: testCase.status, headers: [:]) == testCase.expected)
}

@Test("a success is not an error", arguments: [200, 201, 204])
func successesMapToNothing(status: Int) {
    #expect(AnthropicErrors.error(forStatus: status, headers: [:]) == nil)
}

@Test("retry-after is carried when it is integer seconds")
func rateLimitCarriesItsInterval() {
    let error = AnthropicErrors.error(forStatus: 429, headers: ["retry-after": "30"])
    #expect(error == .rateLimited(retryAfter: .seconds(30)))
}

@Test("a retry-after this module cannot read becomes nil, not zero")
func unreadableRetryAfterIsAbsent() {
    // The HTTP-date form is ignored rather than parsed (D-143). `nil` means
    // "use the default backoff"; a zero would mean "retry immediately", which
    // is the opposite of what the header asked for.
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"]) == nil)
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "-5"]) == nil)
    #expect(AnthropicErrors.retryAfter(in: [:]) == nil)
    #expect(AnthropicErrors.retryAfter(in: ["retry-after": "0"]) == .seconds(0))
}

@Test("a cancelled request timed out; it is not an offline device")
func cancellationIsATimeout() {
    // The load-bearing row (D-145). `URLError.cancelled` sits in the same
    // domain as the genuine connectivity failures, so mapping the domain — the
    // obvious mapping — tells a user with a working connection that they are
    // offline. Mutation: return `.network` for `.cancelled`. Red.
    #expect(AnthropicErrors.error(forTransport: URLError(.cancelled)) == .timedOut)
    #expect(AnthropicErrors.error(forTransport: CancellationError()) == .timedOut)
}

@Test("genuine connectivity failures are .network")
func connectivityFailuresAreNetwork() {
    #expect(AnthropicErrors.error(forTransport: URLError(.notConnectedToInternet)) == .network)
    #expect(AnthropicErrors.error(forTransport: URLError(.cannotFindHost)) == .network)
    #expect(AnthropicErrors.error(forTransport: URLError(.secureConnectionFailed)) == .network)
}

@Test("an AIError passes through rather than being re-wrapped")
func mappedErrorsSurviveTheMapper() {
    // `send` maps transport throws, and the deadline throws an `AIError`
    // through the same path. Re-wrapping it as `.network` would report a
    // timeout as an offline device.
    #expect(AnthropicErrors.error(forTransport: AIError.timedOut) == .timedOut)
    #expect(AnthropicErrors.error(forTransport: AIError.invalidRequest) == .invalidRequest)
}

@Test("a Retry-After sent in any casing is still found")
func headerLookupIsCaseInsensitive() {
    // `AnthropicErrors` looks the header up by the exact key `retry-after`, so
    // before `HTTPResponse` normalised its keys a transport returning
    // `Retry-After` lost the server's interval silently and fell back to the
    // default backoff — a wrong wait with nothing to notice it (PR #35 review).
    // Mutation: drop `HTTPHeaders.normalized` from `HTTPResponse.init`. Red.
    let response = HTTPResponse(status: 429, headers: ["Retry-After": "45"])

    #expect(response.headers["retry-after"] == "45")
    #expect(
        AnthropicErrors.error(forStatus: response.status, headers: response.headers)
            == .rateLimited(retryAfter: .seconds(45)))
}

@Test("a request's header names are normalised too")
func requestHeadersAreNormalised() {
    let request = HTTPRequest(
        method: .get, url: URL(fileURLWithPath: "/x"), headers: ["X-Api-Key": "k"])

    #expect(request.headers["x-api-key"] == "k")
}

@Test("a redirect is refused rather than followed, so the API key stays put")
func redirectsAreNotFollowed() async throws {
    // `URLSession` follows redirects by default and carries custom headers
    // across them, so a 302 to another host would re-send `x-api-key` to
    // wherever it pointed (PR #35 review). `RedirectBlocker` returns nil,
    // which hands the 3xx back as the response instead of chasing it.
    //
    // Mutation: return `request` instead of `nil`. Red.
    let origin = URL(fileURLWithPath: "/v1/models")
    let elsewhere = URL(fileURLWithPath: "/somewhere-else")
    let redirect = try #require(
        HTTPURLResponse(
            url: origin, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": elsewhere.absoluteString]))

    let followed = await RedirectBlocker.shared.urlSession(
        URLSession.shared,
        task: URLSession.shared.dataTask(with: origin),
        willPerformHTTPRedirection: redirect,
        newRequest: URLRequest(url: elsewhere))

    #expect(followed == nil)
}
```

Note the `private func` on the parameterized test: a `@Test` function whose parameter type is `private` must itself be `private`, or the build fails.

- [ ] **Step 2: Run and watch it fail**

Run: `make test`
Expected: compile failure — `cannot find 'AnthropicErrors' in scope`.

- [ ] **Step 3: Write the mapping**

Create `StenoKit/AI/Anthropic/AnthropicErrors.swift`:

```swift
import Foundation

/// Every vendor failure, mapped onto `AIError` and nothing else (D-143).
///
/// **Pure functions over a status code and a header dictionary.** No response
/// body reaches this file, which is what makes §8's "never full payloads" a
/// property of the shape rather than a rule each branch has to remember — there
/// is no parameter here that could carry a draft, a prompt, or the API's own
/// `error.message`.
enum AnthropicErrors {
    /// `nil` when the status is a success. Anything else is an `AIError` the
    /// caller must throw.
    static func error(forStatus status: Int, headers: [String: String]) -> AIError? {
        switch status {
        case 200..<300:
            return nil
        case 401, 403:
            // §7.1's acceptance criterion: "Test connection" must distinguish a
            // rejected key from an unreachable network.
            return .invalidCredential
        case 429:
            return .rateLimited(retryAfter: retryAfter(in: headers))
        case 400..<500:
            // 404 belongs here rather than with `.providerUnavailable`: the two
            // 404s this app can provoke are a model id that was retired since
            // the user picked it and a typo'd path. Both are ours. Routing them
            // to "the provider is unavailable right now" would send the user to
            // a status page instead of the picker.
            return .invalidRequest
        default:
            // 5xx, 529, and anything else that is not a success — including the
            // redirects HTTPS to this API should never produce.
            return .providerUnavailable(status: status)
        }
    }

    /// Map an error thrown by the transport itself.
    ///
    /// `URLError.cancelled` is `.timedOut`, not `.network`: the only thing that
    /// cancels a request in this module is `withDeadline` (D-145), and telling
    /// a user with a working connection that they are offline sends them to fix
    /// the wrong thing.
    static func error(forTransport error: any Error) -> AIError {
        if let aiError = error as? AIError { return aiError }
        if error is CancellationError { return .timedOut }

        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .timedOut : .network
        }

        // An unrecognised error is reported as `.network` because that is the
        // reading §7.4 degrades most usefully from: it produces the raw-event
        // report and tells the user to check their connection, which is wrong
        // less often than any other guess available here.
        return .network
    }

    /// `retry-after`, when it is the integer-seconds form.
    ///
    /// The HTTP-date form is ignored rather than parsed. It would need a
    /// formatter and a clock to become a `Duration`, and this header's only
    /// consumer is D-144's retry gate, which treats a missing value as "use the
    /// default backoff" — a correct outcome for a header shape this API does
    /// not use in practice.
    static func retryAfter(in headers: [String: String]) -> Duration? {
        guard let value = headers["retry-after"], let seconds = Int(value), seconds >= 0 else {
            return nil
        }
        return .seconds(seconds)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS. Note `xcbeautify` does not print parameterized table cases — their absence from the output is not failure.

- [ ] **Step 5: Verify the table can fail**

Apply this mutation, run `make test`, confirm red, then revert it:

```swift
        if let urlError = error as? URLError {
            return .network          // was: urlError.code == .cancelled ? .timedOut : .network
        }
```

Expected red: "a cancelled request timed out; it is not an offline device".

- [ ] **Step 6: Commit**

```bash
make format && make lint
git add StenoKit/AI/Anthropic/AnthropicErrors.swift StenoTests/AI/AnthropicErrorMappingTests.swift
git commit -m "feat: map Anthropic's failures onto AIError

D-143. Pure functions over a status code and a header dictionary, which
is how §8's 'never full payloads' becomes a property of the shape: there
is no parameter here that could carry the API's error.message, and that
message can quote the request — on the draft path, the user's event log.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The wire types and the model ranking

**Files:**
- Create: `StenoKit/AI/Anthropic/AnthropicWire.swift`
- Create: `StenoKit/AI/Anthropic/ModelRanking.swift`
- Test: `StenoTests/AI/ModelRankingTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest` (Task 2), `AIError` (Task 1), M3-01's `StandupRequest`, `AIOutputSchema`, `AIModel`.
- Produces: `AnthropicWire.apiVersion`, `.StopReason.refusal`/`.maxTokens`, `.modelsRequest(baseURL:apiKey:after:)`, `.messagesRequest(baseURL:apiKey:body:)`, `.messagesBody(for:) throws -> Data`, `.timestamp(_:) -> Date?`; the types `AnthropicModelsPage`, `AnthropicModel`, `AnthropicCapabilities`, `AnthropicCapabilityFlag`, `AnthropicMessagesResponse`, `AnthropicContentBlock`, `AnthropicUsage`; and `ModelRanking.ordered(_: [AnthropicModel]) -> [AIModel]`, `ModelRanking.familyRank(_: String) -> Int`.

The response types are **top-level with an `Anthropic` prefix, not nested inside `AnthropicWire`** — each needs its own `CodingKeys`, and SwiftLint's `nesting` rule caps types at one level deep. They stay `internal`, which is the acceptance criterion.

- [ ] **Step 1: Write the failing ranking tests**

Create `StenoTests/AI/ModelRankingTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

// D-140. The ranking is the whole of §7.1's "mid-tier default" and the whole of
// its "not hardcoded", so it is tested as a pure function over inputs whose
// order disagrees with the expected order — a fixture already sorted the way
// the assertion expects proves only that `sorted(by:)` exists.

private func model(
    _ id: String,
    created: String? = nil,
    structuredOutputs: Bool? = nil
) -> AnthropicModel {
    AnthropicModel(
        id: id,
        displayName: id,
        createdAt: AnthropicWire.timestamp(created),
        supportsStructuredOutputs: structuredOutputs
    )
}

@Test("sonnet outranks everything, and the input arrives in the opposite order")
func sonnetIsTheDefault() {
    // Deliberately reversed: opus first, sonnet last. Mutation: invert
    // `familyRank`'s sonnet/haiku returns. Red.
    let ordered = ModelRanking.ordered([
        model("claude-opus-5", created: "2026-04-01T00:00:00Z"),
        model("claude-haiku-4-5", created: "2025-10-01T00:00:00Z"),
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"])
}

@Test("within a family the newest wins, and a string sort would get it wrong")
func recencyBeatsLexicographicOrder() {
    // `claude-sonnet-10` sorts *below* `claude-sonnet-5` as a string, so this
    // fails the moment ranking stops reading `created_at`. Mutation: drop the
    // date comparison and fall through to the id tiebreak. Red.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
        model("claude-sonnet-10", created: "2026-06-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-10", "claude-sonnet-5"])
}

@Test("a model that cannot do structured outputs is dropped")
func structuredOutputsAreRequired() {
    // §7.3 needs a schema-constrained response; a model that cannot give one
    // would fail every draft with a 400.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-legacy", created: "2026-01-01T00:00:00Z", structuredOutputs: false),
        model("claude-sonnet-5", created: "2025-01-01T00:00:00Z", structuredOutputs: true),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5"])
}

@Test("an unknown capabilities shape drops nothing")
func silenceIsNotRefusal() {
    // The filter is on an explicit `false` only. A vendor response that renames
    // the capability, or omits it, must cost ranking quality at most — never
    // the user's whole picker.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z", structuredOutputs: nil)
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5"])
}

@Test("a model with no timestamp still ranks, below one that has it")
func missingTimestampsAreTotallyOrdered() {
    // Order must be total, or the result depends on the sort's stability.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-b"),
        model("claude-sonnet-a"),
        model("claude-sonnet-dated", created: "2020-01-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-dated", "claude-sonnet-a", "claude-sonnet-b"])
}

@Test("the same input ranks the same way regardless of how it arrived")
func rankingIsIndependentOfInputOrder() {
    let models = [
        model("claude-haiku-4-5", created: "2025-10-01T00:00:00Z"),
        model("claude-opus-5", created: "2026-04-01T00:00:00Z"),
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
    ]

    #expect(
        ModelRanking.ordered(models).map(\.id) == ModelRanking.ordered(models.reversed()).map(\.id))
}

@Test("a model offered twice is listed once")
func duplicatesAreCollapsed() {
    // Overlapping pages are a thing cursor schemes do, and the provider's loop
    // cannot un-append a page it has already collected. The picker must not
    // offer the same model twice (PR #35 review).
    //
    // The two records differ in `display_name` so the assertion also says
    // *which* survives: the first seen, taken before the sort.
    let ordered = ModelRanking.ordered([
        model("claude-sonnet-5", created: "2026-01-01T00:00:00Z"),
        AnthropicModel(id: "claude-sonnet-5", displayName: "A Later Page"),
        model("claude-haiku-4-5", created: "2025-10-01T00:00:00Z"),
    ])

    #expect(ordered.map(\.id) == ["claude-sonnet-5", "claude-haiku-4-5"])
    #expect(ordered.first?.displayName == "claude-sonnet-5")
}

@Test("a timestamp with fractional seconds still parses")
func timestampsToleratePrecision() {
    // Two formatters, because `ISO8601DateFormatter` fails outright on
    // fractional seconds without the option and on their absence with it.
    #expect(AnthropicWire.timestamp("2026-01-01T00:00:00Z") != nil)
    #expect(AnthropicWire.timestamp("2026-01-01T00:00:00.123Z") != nil)
    #expect(AnthropicWire.timestamp("the first of January") == nil)
    #expect(AnthropicWire.timestamp(nil) == nil)
}

// MARK: - Decoding (the path the ranking tests above do not take)

@Test("structured_outputs is read out of the nested capabilities tree")
func capabilitiesDecodeFromTheWire() throws {
    // The tests above build `AnthropicModel` through its memberwise init, so
    // the custom `init(from:)` — where all the defensiveness lives — was never
    // exercised (PR #35 review). This is the decode path a vendor response
    // actually takes.
    let json = """
        {"data":[
          {"id":"a","display_name":"Model A","created_at":"2026-01-01T00:00:00Z",
           "capabilities":{"structured_outputs":{"supported":false}}},
          {"id":"b","display_name":"Model B",
           "capabilities":{"structured_outputs":{"supported":true}}},
          {"id":"c"},
          {"id":"d","capabilities":{"something_else":{"supported":false}}}
        ],"has_more":false}
        """

    let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(json.utf8))

    // Only an explicit `false` is a refusal; a missing or unrecognised shape
    // says nothing, and D-140 drops nothing on "nothing".
    #expect(page.data.map(\.supportsStructuredOutputs) == [false, true, nil, nil])
    // `display_name` falls back to the id rather than failing the page.
    #expect(page.data.map(\.displayName) == ["Model A", "Model B", "c", "d"])
    #expect(page.data[0].createdAt != nil)
    #expect(page.data[2].createdAt == nil)
    #expect(page.hasMore == false)
}

@Test("a model whose timestamp will not parse still decodes")
func aBadTimestampCostsRankingQualityAndNothingElse() throws {
    // Returning `nil` rather than throwing is the whole point: the model still
    // belongs in the picker, it just ranks by id within its family.
    let json = #"{"data":[{"id":"a","created_at":"yesterday"}]}"#
    let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(json.utf8))

    #expect(page.data.count == 1)
    #expect(page.data[0].createdAt == nil)
    #expect(page.hasMore == nil)
}
```

- [ ] **Step 2: Run and watch it fail**

Run: `make test`
Expected: compile failure — `cannot find type 'AnthropicModel' in scope`.

- [ ] **Step 3: Create the wire file**

Create `StenoKit/AI/Anthropic/AnthropicWire.swift` exactly as follows:

```swift
import Foundation

/// The Anthropic HTTP surface: the requests this module builds, and the shapes
/// it reads back (§7.1's "no vendor type escapes").
///
/// Everything in this file is `internal`. `AnthropicProvider` is the only
/// reader, no signature on it mentions one of these types, and §14 keeps
/// `AIProvider` for exactly this reason.
///
/// **The response types are top-level rather than nested inside this enum**,
/// only because each needs its own `CodingKeys` and SwiftLint caps nesting at
/// one level (`nesting`). The `Anthropic` prefix does the namespacing the
/// nesting would have.
///
/// **There is no type here for the API's error envelope, and that is a §8
/// decision rather than an omission.** `error.message` can quote the request
/// that provoked it — which, on the draft path, is the user's event log. The
/// status code and `retry-after` are everything `AnthropicErrors` needs, so the
/// body of a failed response is never decoded, never stored, and therefore
/// cannot reach a log line.
enum AnthropicWire {
    /// `anthropic-version`, the only value this module has ever sent.
    static let apiVersion = "2023-06-01"

    /// `stop_reason` values this module acts on (D-143).
    enum StopReason {
        static let refusal = "refusal"
        static let maxTokens = "max_tokens"
    }

    // MARK: - Requests

    /// `GET /v1/models`, one page (D-140).
    static func modelsRequest(baseURL: URL, apiKey: String, after cursor: String?) -> HTTPRequest {
        let endpoint = baseURL.appendingPathComponent("v1/models")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "limit", value: "1000")]
        if let cursor {
            query.append(URLQueryItem(name: "after_id", value: cursor))
        }
        components?.queryItems = query

        return HTTPRequest(
            method: .get,
            url: components?.url ?? endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
            ]
        )
    }

    /// `POST /v1/messages` (D-141).
    static func messagesRequest(baseURL: URL, apiKey: String, body: Data) -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: baseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": apiVersion,
                "content-type": "application/json",
            ],
            body: body
        )
    }

    /// §7.3's request body, and nothing else (D-141).
    ///
    /// Five keys: `model`, `max_tokens`, `system`, `messages`,
    /// `output_config`. No `thinking`, no `effort`, no sampling parameters, no
    /// `anthropic-beta` — the model id comes from a runtime list, so a
    /// parameter that is fine on one model and a 400 on another would make that
    /// model unusable from a picker that offers it, with an error the user
    /// cannot act on.
    ///
    /// **The schema is transmitted as the JSON value M3-03 authored.** It is
    /// parsed once — which is also how a schema that is not a JSON object is
    /// caught here, before a network call — and re-serialized as part of the
    /// body. Keys are sorted so that two calls with equal inputs produce equal
    /// bytes; `JSONSerialization`'s unsorted order is hash order, which differs
    /// between processes and would make a body assertion flake.
    static func messagesBody(for request: StandupRequest) throws -> Data {
        let parsed = try? JSONSerialization.jsonObject(with: request.outputSchema.json)
        guard let schema = parsed as? [String: Any] else {
            throw AIError.invalidRequest
        }

        let envelope: [String: Any] = [
            "model": request.modelID,
            "max_tokens": request.maxOutputTokens,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]],
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
        ]

        guard
            let body = try? JSONSerialization.data(
                withJSONObject: envelope, options: [.sortedKeys])
        else {
            throw AIError.invalidRequest
        }
        return body
    }

    // MARK: - Helpers

    /// Parse an API timestamp, tolerating the presence or absence of fractional
    /// seconds.
    ///
    /// Two formatters rather than one: `ISO8601DateFormatter` fails outright on
    /// fractional seconds unless `.withFractionalSeconds` is set, and fails
    /// outright on their *absence* when it is. Returning `nil` rather than
    /// throwing is the point — a model whose timestamp will not parse still
    /// belongs in the picker, it just ranks by id within its family.
    static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

// MARK: - Responses

/// One page of `GET /v1/models`.
///
/// The Models endpoint uses the `after_id`/`before_id` cursor scheme and
/// reports `has_more`/`first_id`/`last_id`. Both paging fields are optional
/// here: a response that omits them ends the loop, which is the behaviour this
/// module wants from a shape it does not recognise.
struct AnthropicModelsPage: Decodable {
    let data: [AnthropicModel]
    let hasMore: Bool?
    let lastID: String?

    private enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastID = "last_id"
    }
}

/// One model, reduced to the three things D-140 ranks on.
///
/// **Decoded defensively, field by field.** A vendor response that grows a
/// field, renames one inside `capabilities`, or returns a timestamp in a shape
/// `ISO8601DateFormatter` does not accept must cost at most the ranking quality
/// of one model — never the user's whole picker. Only `id` is required.
struct AnthropicModel: Decodable, Equatable, Sendable {
    let id: String
    let displayName: String
    let createdAt: Date?

    /// `nil` when the response said nothing about it. D-140 filters on an
    /// explicit `false` only, so an unrecognised `capabilities` shape drops
    /// nothing.
    let supportsStructuredOutputs: Bool?

    init(
        id: String,
        displayName: String,
        createdAt: Date? = nil,
        supportsStructuredOutputs: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.supportsStructuredOutputs = supportsStructuredOutputs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName =
            (try? container.decodeIfPresent(String.self, forKey: .displayName)).flatMap { $0 } ?? id
        createdAt = AnthropicWire.timestamp(
            (try? container.decodeIfPresent(String.self, forKey: .createdAt)).flatMap { $0 })
        let capabilities =
            (try? container.decodeIfPresent(AnthropicCapabilities.self, forKey: .capabilities))
            .flatMap { $0 }
        supportsStructuredOutputs = capabilities?.structuredOutputs?.supported
    }
}

/// The subtree of `capabilities` D-140 reads, and no more.
struct AnthropicCapabilities: Decodable {
    let structuredOutputs: AnthropicCapabilityFlag?

    private enum CodingKeys: String, CodingKey {
        case structuredOutputs = "structured_outputs"
    }
}

/// One `{"supported": Bool}` leaf. Optional, so a leaf that grows a different
/// shape reads as "said nothing" rather than failing the page.
struct AnthropicCapabilityFlag: Decodable {
    let supported: Bool?
}

/// `POST /v1/messages`, reduced to what §7.3 and §8 read.
struct AnthropicMessagesResponse: Decodable {
    let content: [AnthropicContentBlock]
    let stopReason: String?
    let usage: AnthropicUsage?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }
}

/// One block of a response's `content` array.
struct AnthropicContentBlock: Decodable {
    let type: String
    let text: String?
}

/// §8's "token counts".
///
/// Both optional: a response that reported no usage and one that reported zero
/// are different facts (D-137).
struct AnthropicUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
```

- [ ] **Step 4: Create the ranking**

Create `StenoKit/AI/Anthropic/ModelRanking.swift`:

```swift
import Foundation

/// §7.1's mid-tier default, chosen from a list that is fetched rather than
/// compiled in (D-140).
///
/// §7.1 sets two rules that pull against each other: the list "must be fetched
/// at runtime … not hardcoded", and the default should be "a mid-tier model …
/// this is not a reasoning-heavy workload, and cost per stand-up should stay
/// negligible." The wire response carries `id`, `display_name`, `created_at`,
/// `max_input_tokens`, `max_tokens` and a `capabilities` tree — no tier and no
/// pricing. Nothing on the wire distinguishes mid-tier from top-tier.
///
/// **So the list is returned ordered, and element zero is the default.** No
/// model id is compiled in as the source of the picker's contents, and a
/// `claude-sonnet-6` is preferred the day it appears, with no release. What is
/// compiled in is a preference among *family words*, which is the honest
/// description of what §7.1 asks for: it names a tier, and the tier is not on
/// the wire.
///
/// **Ranking runs on the wire records, not on `AIModel`.** `AIModel` is two
/// fields by D-129's reasoning and carries no `created_at`, and sorting ids as
/// strings puts `claude-sonnet-10` below `claude-sonnet-5`.
enum ModelRanking {
    /// Rank, filter, and map one fetched page-set into what §7.1's picker shows.
    ///
    /// **Deduplicated by id, because paging can hand the same model twice.**
    /// The provider's loop appends a page before it can know the page repeats —
    /// so if the API ignores `after_id`, or simply returns overlapping pages as
    /// cursor schemes are allowed to, the picker would offer the same model
    /// twice. The cursor guard upstream stops the *loop*; it cannot un-append
    /// what it has already collected (PR #35 review).
    ///
    /// First occurrence wins, and it is taken before the sort, so "first" means
    /// the earlier page rather than something the ordering decided.
    static func ordered(_ models: [AnthropicModel]) -> [AIModel] {
        var seen: Set<String> = []
        return
            models
            .filter { $0.supportsStructuredOutputs != false }
            .filter { seen.insert($0.id).inserted }
            .sorted(by: precedes)
            .map { AIModel(id: $0.id, displayName: $0.displayName) }
    }

    /// 0 for sonnet, 1 for haiku, 2 for everything else.
    ///
    /// Haiku ranks *above* the rest rather than below: the fallback from "no
    /// sonnet exists" should move toward §7.1's cost sentence, not away from
    /// it. Summarizing a factual log is the workload Haiku is for.
    static func familyRank(_ identifier: String) -> Int {
        let lowered = identifier.lowercased()
        if lowered.contains("sonnet") { return 0 }
        if lowered.contains("haiku") { return 1 }
        return 2
    }

    /// `(familyRank, createdAt descending, id ascending)`.
    ///
    /// The id tiebreak makes the order total, so the result does not depend on
    /// the sort's stability when two models share a timestamp — or, more often
    /// in practice, when neither carries one.
    private static func precedes(_ lhs: AnthropicModel, _ rhs: AnthropicModel) -> Bool {
        let lhsRank = familyRank(lhs.id)
        let rhsRank = familyRank(rhs.id)
        if lhsRank != rhsRank { return lhsRank < rhsRank }

        switch (lhs.createdAt, rhs.createdAt) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (.some, .none):
            // A model that reported a timestamp outranks one that did not: the
            // API sends `created_at` for everything it currently serves, so a
            // missing one means a shape this module did not recognise.
            return true
        case (.none, .some):
            return false
        default:
            return lhs.id < rhs.id
        }
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `make test`
Expected: PASS, including the seven `ModelRankingTests`.

- [ ] **Step 6: Verify the ranking can fail**

Apply this mutation, run `make test`, confirm red, then revert it:

```swift
        if lowered.contains("sonnet") { return 2 }   // was: return 0
```

Expected red: "sonnet outranks everything, and the input arrives in the opposite order", plus two more once Task 6 lands.

- [ ] **Step 7: Commit**

```bash
make format && make lint
git add StenoKit/AI/Anthropic/AnthropicWire.swift StenoKit/AI/Anthropic/ModelRanking.swift \
        StenoTests/AI/ModelRankingTests.swift
git commit -m "feat: the Anthropic wire shapes, and a default chosen from them

D-140 and D-141. §7.1 forbids a compiled-in model id and asks for a
mid-tier default, and the list endpoint reports no tier and no pricing —
so the list is returned ordered by family word and element zero is the
default. Nothing about the picker's contents is compiled in.

The request body is five keys. A thinking or effort parameter is fine on
one model and a 400 on another, which would make that model unusable
from a picker that offers it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `AnthropicProvider` — credentials, body, draft path

**Files:**
- Create: `StenoKit/AI/Anthropic/AnthropicProvider.swift`
- Create: `StenoKit/AI/Anthropic/AnthropicProvider+Draft.swift`
- Create: `StenoTests/AI/AnthropicFixture.swift`
- Test: `StenoTests/AI/AnthropicProviderTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4, plus M3-01's `CredentialStore`, `Credential`, `StandupDraft.decode(_:cadence:)`, `StandupDraft.validated(against:)`, `AIRequestMetrics`, `AIMetricsLog`.
- Produces: `public struct AnthropicProvider: AIProvider` with `init(transport:credentials:configuration:)`, `Configuration(baseURL:settingsTimeout:retryBackoff:retryHeadroom:)`, `Configuration.standard`, and `static let recommendedDraftTimeout: Duration` (what M3-03 puts in `StandupRequest.timeout`). `AnthropicFixture` for Task 6's tests.

**`recommendedDraftTimeout` is a static constant, not a `Configuration` field.** M3-01 deliberately left `StandupRequest.timeout` without a default so this task would choose it; a field on `Configuration` would be one the provider never reads, which is a bug filed against whoever next changes it and finds the value ignored.

- [ ] **Step 1: Write the shared fixture**

Create `StenoTests/AI/AnthropicFixture.swift`:

```swift
import Foundation

@testable import StenoKit

/// The fixtures `AnthropicProviderTests` and `AnthropicProviderBudgetTests`
/// share.
///
/// Its own file because both suites need it and neither owns it — the same
/// reason `AIError.everyCase` lives in `AIErrorTests` rather than being copied
/// into `AISecretsTests`.
enum AnthropicFixture {
    static let key = "sk-ant-test-key"

    /// Fixed ids so a failure message names the same value twice in a row.
    /// Generated rather than parsed from a literal: `UUID(uuidString:)` returns
    /// an optional, and unwrapping it is a force-unwrap SwiftLint rejects for a
    /// value that has no meaning beyond "not the other one".
    static let taskID = UUID()
    static let otherID = UUID()

    /// A configuration whose waits are short enough for a test to sit through.
    static let configuration = AnthropicProvider.Configuration(
        baseURL: URL(fileURLWithPath: "/api.example.test"),
        settingsTimeout: .seconds(5),
        retryBackoff: .milliseconds(1),
        retryHeadroom: .milliseconds(1)
    )

    static func store(_ credential: Credential? = .apiKey(key)) -> InMemoryCredentialStore {
        let store = InMemoryCredentialStore()
        if let credential {
            try? store.store(credential, for: "anthropic")
        }
        return store
    }

    static func provider(
        _ transport: StubHTTPTransport,
        credentials: InMemoryCredentialStore = store()
    ) -> AnthropicProvider {
        AnthropicProvider(
            transport: transport, credentials: credentials, configuration: configuration)
    }

    static func request(
        timeout: Duration = .seconds(5),
        allowed: Set<UUID> = [taskID],
        schema: String = #"{"type":"object"}"#,
        cadence: ReportCadence = .daily
    ) -> StandupRequest {
        StandupRequest(
            modelID: "claude-sonnet-5",
            cadence: cadence,
            systemPrompt: "system",
            userPrompt: "user",
            outputSchema: AIOutputSchema(name: "daily", json: Data(schema.utf8)),
            allowedTaskIDs: allowed,
            maxOutputTokens: 1024,
            timeout: timeout
        )
    }

    /// A `/v1/messages` response whose text block is §7.3's `daily` JSON.
    static func draftResponse(
        taskID: UUID = taskID,
        stopReason: String = "end_turn",
        status: Int = 200
    ) -> HTTPResponse {
        let draft = """
            {"since_last_standup":[{"task_id":"\(taskID.uuidString)",\
            "text":"fixed the flaky auth test"}],"today":[],"blockers":[]}
            """
        // The text block holds §7.3's JSON *as a string*, so the envelope is
        // serialized rather than hand-written: escaping it by hand is one
        // backslash away from a fixture that tests the decoder's error path
        // while claiming to test its success path.
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": draft]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": 120, "output_tokens": 45],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(status: status, body: body)
    }

    /// A `/v1/messages` response whose text block is §7.3's `periodic` JSON.
    ///
    /// D17's two cadences "are not cosmetic variants of each other" (§7.3):
    /// the sections differ and so does the cardinality of the task reference,
    /// so the provider's cadence switch needs both sides exercised.
    static func periodicDraftResponse(taskIDs: [UUID] = [taskID]) -> HTTPResponse {
        let ids = taskIDs.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
        let draft = """
            {"completed":[{"task_ids":[\(ids)],"text":"shipped the export encoder"}],\
            "in_flight":[],"blockers_and_risks":[]}
            """
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": draft]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 900, "output_tokens": 120],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return HTTPResponse(status: 200, body: body)
    }

    /// One page of `/v1/models`.
    static func modelsResponse(
        ids: [String],
        hasMore: Bool = false,
        lastID: String? = nil
    ) -> HTTPResponse {
        let models = ids.map { identifier in
            [
                "id": identifier,
                "display_name": identifier,
                "created_at": "2026-01-01T00:00:00Z",
            ]
        }
        var page: [String: Any] = ["data": models, "has_more": hasMore]
        if let lastID { page["last_id"] = lastID }

        let body = (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
        return HTTPResponse(status: 200, body: body)
    }
}
```

The `draftResponse` envelope is **serialized, not hand-written**. An earlier hand-escaped version of this fixture produced invalid JSON and made five tests exercise the decoder's error path while claiming to test its success path — they failed loudly, but a subtler escape bug would not have.

- [ ] **Step 2: Write the failing provider tests**

Create `StenoTests/AI/AnthropicProviderTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

// D-140 through D-146, end to end over `StubHTTPTransport`. `make test` denies
// outbound IP (§9.4, D-012), so every assertion here is about what the provider
// sent and what it made of what came back.

// D-143 and D-141: what the provider sends, and what it makes of the answer.

// MARK: - Credentials

@Test("no stored credential is .notConfigured, and nothing is sent")
func anEmptyStoreNeverReachesTheNetwork() async {
    // §7.4's "is not configured". Mutation: read the key after building the
    // request instead of before. Red on `received`.
    let transport = StubHTTPTransport()
    let provider = AnthropicFixture.provider(transport, credentials: AnthropicFixture.store(nil))

    await #expect(throws: AIError.notConfigured) {
        try await provider.generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.isEmpty)
}

@Test("an OAuth credential is .notConfigured — §7.2 ships the API key path only")
func oauthIsNotYetACredential() async {
    let store = AnthropicFixture.store(
        .oauth(TokenSet(accessToken: "token", refreshToken: nil, expiresAt: nil)))
    let provider = AnthropicFixture.provider(StubHTTPTransport(), credentials: store)

    await #expect(throws: AIError.notConfigured) { try await provider.testConnection() }
}

@Test("the key is sent as x-api-key, with the API version")
func requestsCarryTheirHeaders() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"]))
    ])

    _ = try await AnthropicFixture.provider(transport).availableModels()

    let sent = try #require(await transport.received.first)
    #expect(sent.headers["x-api-key"] == AnthropicFixture.key)
    #expect(sent.headers["anthropic-version"] == "2023-06-01")
    #expect(sent.url.path.hasSuffix("/v1/models"))
}

// MARK: - The request body (D-141)

@Test("the body carries exactly five keys, and no tuning parameters")
func theBodyIsMinimal() async throws {
    // D-141: the model id comes from a runtime list, so a parameter that 400s
    // on one model would make that model unusable from a picker offering it.
    // Mutation: add `"temperature": 0` to the envelope. Red.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())

    let body = try #require(await transport.received.first?.body)
    let json = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any])

    #expect(
        Set(json.keys) == ["model", "max_tokens", "system", "messages", "output_config"])
    #expect(json["model"] as? String == "claude-sonnet-5")
    #expect(json["max_tokens"] as? Int == 1024)
}

@Test("the schema reaches the API as the value M3-03 authored")
func theSchemaIsTransmittedWhole() async throws {
    let schema = #"{"type":"object","properties":{"today":{"type":"array"}},"required":["today"]}"#
    var request = AnthropicFixture.request()
    request = StandupRequest(
        modelID: request.modelID,
        cadence: request.cadence,
        systemPrompt: request.systemPrompt,
        userPrompt: request.userPrompt,
        outputSchema: AIOutputSchema(name: "daily", json: Data(schema.utf8)),
        allowedTaskIDs: request.allowedTaskIDs,
        maxOutputTokens: request.maxOutputTokens,
        timeout: request.timeout
    )

    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(request)

    let body = try #require(await transport.received.first?.body)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    let format = (json?["output_config"] as? [String: Any])?["format"] as? [String: Any]
    let sent = try #require(format?["schema"] as? [String: Any])

    #expect(format?["type"] as? String == "json_schema")
    #expect(sent["required"] as? [String] == ["today"])
    #expect((sent["properties"] as? [String: Any])?.keys.contains("today") == true)
}

@Test("a schema that is not a JSON object fails before any request is sent")
func aBrokenSchemaIsCaughtLocally() async {
    let request = StandupRequest(
        modelID: "claude-sonnet-5",
        cadence: .daily,
        systemPrompt: "system",
        userPrompt: "user",
        outputSchema: AIOutputSchema(name: "daily", json: Data("not a schema".utf8)),
        allowedTaskIDs: [AnthropicFixture.taskID],
        maxOutputTokens: 1024,
        timeout: .seconds(5)
    )
    let transport = StubHTTPTransport()

    await #expect(throws: AIError.invalidRequest) {
        try await AnthropicFixture.provider(transport).generateStandup(request)
    }
    #expect(await transport.received.isEmpty)
}

@Test("the body is serialized with its keys in sorted order")
func theBodyIsDeterministic() async throws {
    // **An exact byte sequence, not two serializations compared.** The earlier
    // version of this test ran `messagesBody` twice in one process and compared
    // the results — which cannot detect a missing `.sortedKeys` at all, because
    // unsorted dictionary iteration is stable *within* a process and both calls
    // produce the same order either way (PR #35 review). It was a test that
    // could not fail for the mutation its own comment named.
    //
    // §10.2 already pays for this lesson once: hash order differs between
    // processes, so a body that is not explicitly sorted is not reproducible.
    // Mutation: drop `.sortedKeys`. Red — the nested objects reorder too.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())

    let body = try #require(await transport.received.first?.body)
    let expected = """
        {"max_tokens":1024,"messages":[{"content":"user","role":"user"}],\
        "model":"claude-sonnet-5",\
        "output_config":{"format":{"schema":{"type":"object"},"type":"json_schema"}},\
        "system":"system"}
        """

    // The failable initializer rather than `String(decoding:)`, per SwiftLint's
    // `optional_data_string_conversion` — which is the better assertion anyway:
    // a body that is not valid UTF-8 fails here rather than becoming replacement
    // characters that then compare unequal for an unrelated-looking reason.
    #expect(String(bytes: body, encoding: .utf8) == expected)
}

// MARK: - The draft path (D-143)

@Test("a valid draft decodes and is returned")
func aGoodResponseBecomesADraft() async throws {
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.draftResponse())])
    let draft = try await AnthropicFixture.provider(transport).generateStandup(
        AnthropicFixture.request())

    guard case .daily(let daily) = draft else {
        Issue.record("expected a daily draft")
        return
    }
    #expect(daily.sinceLastStandup.first?.text == "fixed the flaky auth test")
    #expect(daily.sinceLastStandup.first?.taskID == AnthropicFixture.taskID)
}

@Test("a task id the app never sent is rejected inside the provider")
func hallucinatedIDsFailLoudly() async {
    // §7.3: "a hallucinated ID is the clearest possible signal the model
    // invented a fact, and it should fail loudly into the §7.4 fallback rather
    // than render." Mutation: drop the `validated(against:)` call. Red.
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(taskID: AnthropicFixture.otherID))
    ])

    await #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a refusal is its own reason, not undecodable")
func refusalsAreNamed() async {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(stopReason: "refusal"))
    ])

    await #expect(throws: AIError.invalidResponse(.refused)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a truncated answer is its own reason, not a schema violation")
func truncationIsNamed() async {
    // Blaming `.schemaViolation` would make a real hallucination
    // indistinguishable from the app under-provisioning `maxOutputTokens`.
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.draftResponse(stopReason: "max_tokens"))
    ])

    await #expect(throws: AIError.invalidResponse(.truncated)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a response with no text block is an empty draft, not a silent success")
func emptyResponsesFail() async {
    let empty = HTTPResponse(
        status: 200, body: Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8))
    let transport = StubHTTPTransport(answers: [.respond(empty)])

    await #expect(throws: AIError.invalidResponse(.emptyDraft)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a body that is not JSON is undecodable")
func garbageIsUndecodable() async {
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 200, body: Data("<html>502</html>".utf8)))
    ])

    await #expect(throws: AIError.invalidResponse(.undecodable)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

@Test("a periodic window decodes into the periodic draft, not the daily one")
func periodicCadenceRoundTrips() async throws {
    // §7.3: the two cadences "are not cosmetic variants of each other — the
    // sections differ, and so does the cardinality of the task reference." The
    // provider switches on cadence to pick the decode, and only `.daily` was
    // covered (PR #35 review). Mutation: decode `.daily` regardless of cadence.
    // Red — a periodic body has no `since_last_standup`.
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.periodicDraftResponse())])

    let draft = try await AnthropicFixture.provider(transport)
        .generateStandup(AnthropicFixture.request(cadence: .periodic))

    guard case .periodic(let periodic) = draft else {
        Issue.record("expected a periodic draft")
        return
    }
    #expect(periodic.completed.first?.text == "shipped the export encoder")
    #expect(periodic.completed.first?.taskIDs == [AnthropicFixture.taskID])
    #expect(periodic.inFlight.isEmpty)
}

@Test("a hallucinated id in a periodic bullet is rejected too")
func periodicDraftsAreValidated() async {
    // `task_ids` is plural here and `allTaskIDs` flattens it — a guard that
    // only walked the daily shape would let a themed bullet smuggle one in.
    let transport = StubHTTPTransport(answers: [
        .respond(
            AnthropicFixture.periodicDraftResponse(
                taskIDs: [AnthropicFixture.taskID, AnthropicFixture.otherID]))
    ])

    await #expect(throws: AIError.unknownTaskIDs(count: 1)) {
        try await AnthropicFixture.provider(transport)
            .generateStandup(AnthropicFixture.request(cadence: .periodic))
    }
}

// MARK: - The contract, and what §8 keeps when it breaks

@Test("cancelling a model-list fetch still surfaces an AIError")
func cancellationDoesNotEscapeTheContract() async {
    // M3-01's contract: an implementation throws `AIError` and nothing else,
    // because §7.4 "cannot switch on an error type it has never heard of".
    // Cancelling the caller cancels the deadline's child tasks, and `Task.sleep`
    // then throws a bare `CancellationError` past every mapping inside the
    // group — `generateStandup` caught that and `availableModels` did not
    // (PR #35 review). Mutation: drop the catch in `availableModels`. Red.
    let transport = StubHTTPTransport(
        answers: [.respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"]))],
        delay: .seconds(60))
    let provider = AnthropicFixture.provider(transport)

    let task = Task { try await provider.availableModels() }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("expected the cancelled fetch to fail")
    } catch is AIError {
        // The contract held.
    } catch {
        Issue.record("escaped as \(type(of: error)), which §7.4 cannot classify")
    }
}

@Test("a refusal keeps the token counts it was billed for")
func failedDraftsKeepTheirUsage() throws {
    // D-146: the metrics line keeps the token counts whenever the response
    // carried them. A refusal, a truncation and a hallucinated id are all
    // billed calls — the API reports `usage` and *then* the draft fails — so
    // recording `nil` would lose the numbers for the one class of failure that
    // actually cost the user money (PR #35 review).
    //
    // Mutation: return `nil` for `usage` in `DraftFailure`. Red.
    let body = AnthropicFixture.draftResponse(stopReason: "refusal").body

    do {
        _ = try AnthropicProvider.draft(
            from: body, cadence: .daily, allowed: [AnthropicFixture.taskID])
        Issue.record("expected a refusal to fail")
    } catch let failure as AnthropicProvider.DraftFailure {
        #expect(failure.error == .invalidResponse(.refused))
        #expect(failure.usage?.inputTokens == 120)
        #expect(failure.usage?.outputTokens == 45)
    }
}

@Test("a hallucinated id keeps its usage too, not just a refusal")
func validationFailuresKeepTheirUsage() throws {
    // The `StandupDraft.decode` / `validated(against:)` pair throws a plain
    // `AIError`, so it needs its own wrap — a fix applied to the `stop_reason`
    // branches alone would leave this path recording nothing.
    let body = AnthropicFixture.draftResponse(taskID: AnthropicFixture.otherID).body

    do {
        _ = try AnthropicProvider.draft(
            from: body, cadence: .daily, allowed: [AnthropicFixture.taskID])
        Issue.record("expected a hallucinated id to fail")
    } catch let failure as AnthropicProvider.DraftFailure {
        #expect(failure.error == .unknownTaskIDs(count: 1))
        #expect(failure.usage?.inputTokens == 120)
    }
}
```

- [ ] **Step 3: Run and watch it fail**

Run: `make test`
Expected: compile failure — `cannot find 'AnthropicProvider' in scope`.

- [ ] **Step 4: Write the provider**

Create `StenoKit/AI/Anthropic/AnthropicProvider.swift`. This task writes the whole file; Task 6 verifies the paging and retry behaviour it already contains.

```swift
import Foundation

/// §7.1's shipped provider: auth, budgets, retries, and error mapping.
///
/// **Transport and nothing else.** The prompt, the two schemas and §7.4's
/// fallback are M3-03's; the picker and the key field are M3-04's. What this
/// type owes them is the ordered model list (D-140), a timeout the fallback can
/// wait on (D-144), and the guarantee that every failure arrives as an
/// `AIError` — §7.4 cannot degrade on an error type it has never heard of.
///
/// **No signature here mentions an `AnthropicWire` type**, which is §7.1's
/// acceptance criterion: callers see only M3-01's neutral types.
///
/// A `struct` rather than an `actor`: nothing here is mutable, so there is no
/// state to protect, and `AIProvider: Sendable` (D-131) is satisfied by the
/// stored `Sendable` dependencies.
public struct AnthropicProvider: AIProvider {
    /// The numbers D-144 decided, in one place so M3-03 can read them and a
    /// test can shrink them.
    public struct Configuration: Sendable {
        public var baseURL: URL

        /// D-144: the tighter budget for `availableModels` and
        /// `testConnection`. A user who clicked "Test connection" is watching,
        /// and a fast honest `.network` beats a slow correct one.
        public var settingsTimeout: Duration

        /// Used when a retryable failure named no interval of its own.
        public var retryBackoff: Duration

        /// How much budget beyond the backoff a retry must have to be worth
        /// starting. A retry certain to be cancelled mid-flight is a slower
        /// failure, not a second chance.
        public var retryHeadroom: Duration

        public init(
            baseURL: URL,
            settingsTimeout: Duration,
            retryBackoff: Duration,
            retryHeadroom: Duration
        ) {
            self.baseURL = baseURL
            self.settingsTimeout = settingsTimeout
            self.retryBackoff = retryBackoff
            self.retryHeadroom = retryHeadroom
        }

        public static let standard = Configuration(
            // Force-unwrapped, and safe: the argument is a literal, so this
            // either works on every launch or on none, and a test would catch
            // it before a user could.
            baseURL: URL(string: "https://api.anthropic.com")!,
            settingsTimeout: .seconds(10),
            retryBackoff: .seconds(1),
            retryHeadroom: .seconds(2)
        )
    }

    /// D-144's draft budget: the wall clock M3-03 puts in
    /// `StandupRequest.timeout`, covering attempt, backoff and retry.
    ///
    /// **A published constant rather than a field on `Configuration`**, because
    /// the provider does not choose it — M3-01 put `timeout` on the request and
    /// left it without a default so that "a task that never made a network
    /// call" could not pre-empt this decision. A field here would be one
    /// nothing reads, which is a bug filed against whoever next tries to change
    /// it and finds the value ignored.
    ///
    /// Twenty seconds because a stand-up draft is not streamed (§7, M3-02's
    /// out-of-scope list) and a Sonnet-class summarization lands in 5–15s:
    /// twelve would cut off a legitimate periodic window, and thirty is most of
    /// the time the user has before they speak.
    public static let recommendedDraftTimeout: Duration = .seconds(20)

    /// Keys the Keychain item (`CredentialStore`), so it is stable across
    /// launches and must not be renamed.
    public let id = "anthropic"

    public let displayName = "Anthropic"

    let transport: any HTTPTransport
    let credentials: any CredentialStore
    let configuration: Configuration

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        credentials: any CredentialStore,
        configuration: Configuration = .standard
    ) {
        self.transport = transport
        self.credentials = credentials
        self.configuration = configuration
    }

    // MARK: - AIProvider

    /// Every model this key may use, ordered (D-140): element zero is the
    /// recommended default.
    public func availableModels() async throws -> [AIModel] {
        let key = try apiKey()
        let transport = self.transport
        let baseURL = configuration.baseURL

        // **The catch is not redundant with `send`'s.** Cancelling the *caller*
        // cancels this deadline's child tasks, and `Task.sleep` then throws a
        // bare `CancellationError` straight out of the group — past every
        // mapping inside it. `generateStandup` already had a catch-all for the
        // same reason; a mapping applied to one of two sibling paths is the
        // defect this repo keeps re-learning (PR #35 review).
        do {
            return try await Self.fetchModels(
                transport: transport,
                baseURL: baseURL,
                key: key,
                timeout: configuration.settingsTimeout
            )
        } catch {
            throw AnthropicErrors.error(forTransport: error)
        }
    }

    private static func fetchModels(
        transport: any HTTPTransport,
        baseURL: URL,
        key: String,
        timeout: Duration
    ) async throws -> [AIModel] {
        try await withDeadline(timeout) {
            var collected: [AnthropicModel] = []
            var cursor: String?

            // **No page cap, and the deadline is the bound — but only because
            // the loop checks cancellation.** An earlier version stopped after
            // twenty pages, which turned a vendor that kept saying `has_more`
            // into a *silently truncated* list: a picker missing the user's
            // model, reported as success (PR #35 review).
            //
            // Removing the cap is only safe with the check below. Nothing else
            // in this loop suspends in a way that throws on cancellation — an
            // actor hop does not — so without it the deadline fires, the group
            // waits for a child that never notices, and the whole call hangs.
            // That is the same cooperative-cancellation trap `HTTPTransport`'s
            // doc comment warns implementers about, and this loop was quietly
            // an instance of it. A test that pages forever found it.
            while true {
                try Task.checkCancellation()

                let request = AnthropicWire.modelsRequest(
                    baseURL: baseURL, apiKey: key, after: cursor)
                let response = try await Self.send(request, on: transport)
                let page = try Self.decode(AnthropicModelsPage.self, from: response.body)
                collected.append(contentsOf: page.data)

                // Three ways to stop: the API said there is no more, it named
                // no cursor, or it named the cursor we just used.
                guard page.hasMore == true, let last = page.lastID, last != cursor else { break }
                cursor = last
            }

            return ModelRanking.ordered(collected)
        }
    }

    /// Verify the stored credential (§7.1).
    ///
    /// The model list is the cheapest call that separates a rejected key (401,
    /// `.invalidCredential`) from an unreachable host (`.network`), and it
    /// inherits this type's whole mapping rather than re-deriving it.
    public func testConnection() async throws {
        _ = try await availableModels()
    }

    // MARK: - Plumbing

    static func send(
        _ request: HTTPRequest, on transport: any HTTPTransport
    ) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AnthropicErrors.error(forTransport: error)
        }

        if let failure = AnthropicErrors.error(
            forStatus: response.status, headers: response.headers)
        {
            throw failure
        }
        return response
    }

    /// Decode a wire type, reporting anything unreadable as `.undecodable`.
    ///
    /// The `DecodingError` is dropped rather than described: its message quotes
    /// the coding path and, for a type mismatch, the value that failed — which
    /// on the draft path is the user's stand-up (§8, D-132).
    static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw AIError.invalidResponse(.undecodable)
        }
    }

    /// The stored API key, or `.notConfigured` (§7.4's "is not configured").
    ///
    /// `.oauth` resolves to `.notConfigured` too: §7.2 ships the API key path
    /// only, and a token this provider cannot send is indistinguishable, from
    /// the user's side, from no credential at all.
    func apiKey() throws -> String {
        let stored: Credential?
        do {
            stored = try credentials.credential(for: id)
        } catch {
            // A Keychain read that fails is reported as "not configured"
            // rather than surfaced: there is no `AIError` case for it, and
            // every remedy the user has — re-enter the key — is the same one
            // `.notConfigured` already asks for.
            throw AIError.notConfigured
        }

        guard case .apiKey(let key) = stored, !key.isEmpty else {
            throw AIError.notConfigured
        }
        return key
    }

    /// §8's one metrics line, emitted for a draft and for nothing else (D-146).
    func record(
        _ request: StandupRequest,
        started: ContinuousClock.Instant,
        inputTokens: Int?,
        outputTokens: Int?,
        outcome: AIRequestMetrics.Outcome
    ) {
        AIMetricsLog.record(
            AIRequestMetrics(
                providerID: id,
                modelID: request.modelID,
                latency: started.duration(to: ContinuousClock.now),
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                outcome: outcome
            )
        )
    }
}
```

- [ ] **Step 5: Create the draft path**

SwiftLint caps a file at 400 lines and the provider crosses it, so the draft path is its own
extension file. The boundary is a real one even so: everything here turns one `StandupRequest`
into one validated `StandupDraft`, while the main file owns the model list, the credential and
the shared plumbing. Note that this is why `transport`, `credentials`, `configuration`, `send`,
`decode`, `apiKey` and `record` are `internal` rather than `private` — `private` does not reach
an extension in another file.

Create `StenoKit/AI/Anthropic/AnthropicProvider+Draft.swift`:

```swift
import Foundation

/// `AnthropicProvider`'s draft path: §7.3's call, D-144's retry, and the
/// failure wrapper that keeps §8's token counts.
///
/// **Split from the main file only because SwiftLint caps a file at 400 lines**
/// — the provider crossed it once the review fixes landed. The boundary is a
/// real one even so: everything here is about turning one `StandupRequest`
/// into one validated `StandupDraft`, while the main file owns the model list,
/// the credential, and the shared plumbing.
extension AnthropicProvider {

    /// Summarize a window (§7.3), already validated against the ids the app
    /// sent.
    public func generateStandup(_ request: StandupRequest) async throws -> StandupDraft {
        let started = ContinuousClock.now
        do {
            let (draft, usage) = try await attemptDraft(request)
            record(
                request,
                started: started,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens,
                outcome: .succeeded
            )
            return draft
        } catch {
            // `DraftFailure` never escapes this method: it is unwrapped here
            // for the usage it carries, and what leaves is an `AIError`, which
            // is the contract §7.4 relies on.
            let failure = error as? DraftFailure
            let mapped = AnthropicErrors.error(forTransport: failure?.error ?? error)
            record(
                request,
                started: started,
                inputTokens: failure?.usage?.inputTokens,
                outputTokens: failure?.usage?.outputTokens,
                outcome: .failed(label: mapped.metricsLabel)
            )
            throw mapped
        }
    }
    // MARK: - The draft path

    private func attemptDraft(
        _ request: StandupRequest
    ) async throws -> (StandupDraft, AnthropicUsage?) {
        let key = try apiKey()
        let body = try AnthropicWire.messagesBody(for: request)
        let httpRequest = AnthropicWire.messagesRequest(
            baseURL: configuration.baseURL, apiKey: key, body: body)
        let transport = self.transport
        let configuration = self.configuration
        let cadence = request.cadence
        let allowed = request.allowedTaskIDs

        // Captured before the race starts, so the retry gate measures the
        // budget the caller asked for rather than the time left in a clock the
        // deadline task owns.
        let deadline = ContinuousClock.now.advanced(by: request.timeout)

        return try await withDeadline(request.timeout) {
            var retried = false
            while true {
                do {
                    let response = try await Self.send(httpRequest, on: transport)
                    return try Self.draft(from: response.body, cadence: cadence, allowed: allowed)
                } catch let error as AIError {
                    // D-144: one retry, on 429/529/5xx only, and only when
                    // `backoff + headroom` still fits in the budget. A
                    // `retry-after` that cannot fit fails immediately with
                    // `.rateLimited` so M3-03 can say something specific,
                    // rather than after a wait it already knows is futile.
                    guard !retried,
                        let backoff = Self.backoff(for: error, configuration: configuration),
                        ContinuousClock.now.advanced(by: backoff + configuration.retryHeadroom)
                            < deadline
                    else { throw error }

                    retried = true
                    try await Task.sleep(for: backoff)
                }
            }
        }
    }

    /// How long to wait before the one permitted retry, or `nil` for a failure
    /// that must not be retried.
    private static func backoff(
        for error: AIError, configuration: Configuration
    ) -> Duration? {
        switch error {
        case .rateLimited(let retryAfter):
            return retryAfter ?? configuration.retryBackoff
        case .providerUnavailable(let status) where (500..<600).contains(status):
            // **Gated on 5xx, not on the case.** `AnthropicErrors` files every
            // non-2xx, non-4xx status here, which includes the 3xx a custom
            // transport might surface without following it — and retrying a
            // redirect means sending the same POST twice for a response that
            // will never change. D-144 permits a retry for 429, 529 and 5xx,
            // and this is that list rather than its enclosing case (PR #35
            // review).
            return configuration.retryBackoff
        default:
            // Everything else is either ours to fix (`.invalidRequest`,
            // `.invalidCredential`), already out of time (`.timedOut`), a
            // status no retry can change (3xx), or a failure a second
            // identical request cannot change.
            return nil
        }
    }

    /// An `AIError` plus the usage the response reported before it failed.
    ///
    /// **Internal to the draft path and never thrown past `generateStandup`.**
    /// A refusal, a truncation and a hallucinated id are all billed calls: the
    /// API reports `usage` and then the draft fails. D-146 says the metrics
    /// line keeps the token counts whenever the response carried them, and
    /// without this wrapper the catch has nothing to keep — it would record
    /// `nil` for the one class of failure that actually cost the user money
    /// (PR #35 review).
    ///
    /// `internal` rather than `private`, with `draft(from:cadence:allowed:)`,
    /// so that "the token counts survive the failure" is a test rather than a
    /// claim: `record` writes to the unified log and cannot be read back
    /// in-process, so the only way to assert D-146's rule is to assert the
    /// value the catch is handed.
    struct DraftFailure: Error {
        let error: AIError
        let usage: AnthropicUsage?
    }

    static func draft(
        from body: Data, cadence: ReportCadence, allowed: Set<UUID>
    ) throws -> (StandupDraft, AnthropicUsage?) {
        let response = try decode(AnthropicMessagesResponse.self, from: body)
        let usage = response.usage

        switch response.stopReason {
        case AnthropicWire.StopReason.refusal:
            // A distinct reason, not `.undecodable`: the model declined, which
            // says nothing about whether it can produce §7.3's schema.
            throw DraftFailure(error: .invalidResponse(.refused), usage: usage)
        case AnthropicWire.StopReason.maxTokens:
            // The JSON is cut off mid-object, so decoding it would report
            // `.undecodable` and blame the model for a budget the app set.
            throw DraftFailure(error: .invalidResponse(.truncated), usage: usage)
        default:
            break
        }

        guard
            let text = response.content.first(where: { $0.type == "text" })?.text,
            !text.isEmpty
        else {
            throw DraftFailure(error: .invalidResponse(.emptyDraft), usage: usage)
        }

        do {
            let draft = try StandupDraft.decode(Data(text.utf8), cadence: cadence)
            // §7.3's hallucinated-id rejection runs here, inside the provider,
            // so the next provider inherits it rather than re-deriving it
            // (D-133).
            return (try draft.validated(against: allowed), usage)
        } catch let error as AIError {
            throw DraftFailure(error: error, usage: usage)
        }
    }
}
```

- [ ] **Step 6: Add the ordering contract to the protocol**

In `StenoKit/AI/AIProvider.swift`, replace the one-line doc on `availableModels()` with:

```swift
    /// §7.1: fetched at runtime, never hardcoded, so a new model needs no release.
    ///
    /// **Ordered by the provider's own preference, and element zero is its
    /// recommended default.** §7.1 asks for a mid-tier default *and* forbids a
    /// compiled-in model id, and no vendor's list endpoint reports a tier — so
    /// the choice has to live with whoever knows that vendor's naming. Putting
    /// it in the order rather than in a second method keeps `AIModel` at two
    /// fields (D-129) and gives M3-04 a picker it can render top-down and
    /// preselect at index zero.
    ///
    /// An empty result is legitimate — a key with access to nothing — and is
    /// not an error.
    func availableModels() async throws -> [AIModel]
```

- [ ] **Step 7: Run the tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 8: Verify the hallucination guard can fail**

Apply this mutation in `draft(from:cadence:allowed:)`, run `make test`, confirm red, then revert it:

```swift
        return (draft, response.usage)   // was: (try draft.validated(against: allowed), …)
```

Expected red: "a task id the app never sent is rejected inside the provider".

- [ ] **Step 9: Commit**

```bash
make format && make lint
git add StenoKit/AI/Anthropic/AnthropicProvider.swift \
        StenoKit/AI/Anthropic/AnthropicProvider+Draft.swift StenoKit/AI/AIProvider.swift \
        StenoTests/AI/AnthropicFixture.swift StenoTests/AI/AnthropicProviderTests.swift
git commit -m "feat: AnthropicProvider, behind M3-01's seam

Auth from the Keychain layer, D-141's five-key body, §7.3's draft decode,
and D-133's hallucinated-id rejection run inside the provider so the next
provider inherits it rather than re-deriving it.

availableModels() gains a documented ordering contract: element zero is
the recommended default. §7.1 asks for a mid-tier default and forbids a
compiled-in model id, and no list endpoint reports a tier — so the choice
lives with whoever knows the vendor's naming, expressed as order rather
than as a second method.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The budget, the retry, and the model list

**Files:**
- Test: `StenoTests/AI/AnthropicProviderBudgetTests.swift` (create)

**Interfaces:**
- Consumes: `AnthropicProvider`, `AnthropicFixture`, `StubHTTPTransport` (Tasks 2 and 5).
- Produces: nothing new. This task proves the behaviour Task 5's file already contains, in its own file because SwiftLint caps a file at 400 lines and the two suites together exceed it.

- [ ] **Step 1: Write the budget tests**

Create `StenoTests/AI/AnthropicProviderBudgetTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

// D-144, D-145 and D-140: the budget §7.4 waits on, the retry that is worth
// one attempt, and the runtime model list §7.1 forbids compiling in.

// MARK: - Budget and retries (D-144, D-145)

@Test("a transport that hangs loses the deadline, and it is not a network error")
func aHangIsATimeout() async {
    // The row that matters most to §7.4: the fallback must engage promptly,
    // and it must not tell a user with a working connection that they are
    // offline. Mutation: map `URLError.cancelled` to `.network`. Red.
    let transport = StubHTTPTransport(
        answers: [.respond(AnthropicFixture.draftResponse())], delay: .seconds(60))

    await #expect(throws: AIError.timedOut) {
        try await AnthropicFixture.provider(transport).generateStandup(
            AnthropicFixture.request(timeout: .milliseconds(20)))
    }
}

@Test("a 529 is retried once and then succeeds")
func overloadIsRetried() async throws {
    // A 529 is Anthropic briefly overloaded; dropping to raw events for
    // something a one-second wait would fix is a worse stand-up than the user
    // could have had. Mutation: return `nil` from `backoff(for:)` for
    // `.providerUnavailable`. Red.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 529)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    _ = try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    #expect(await transport.received.count == 2)
}

@Test("the retry happens once, not until the budget runs out")
func retriesAreNotALoop() async {
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 529)),
        .respond(HTTPResponse(status: 529)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.providerUnavailable(status: 529)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 2)
}

@Test("a redirect is not retried, though it lands in the same error case")
func onlyServerFailuresAreRetried() async {
    // `AnthropicErrors` files every non-2xx, non-4xx status under
    // `.providerUnavailable`, so gating the retry on the *case* retried 3xx
    // too — sending the same POST twice for a response no retry can change
    // (PR #35 review, found in code that had not changed since the first
    // round). D-144's list is 429, 529 and 5xx.
    //
    // Mutation: gate on `case .providerUnavailable` without the status range.
    // Red on the request count.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 302)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.providerUnavailable(status: 302)) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a 400 is never retried")
func ourOwnMistakesAreNotRetried() async {
    // Mutation: add `.invalidRequest` to `backoff(for:)`. Red on the count.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 400)),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.invalidRequest) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a retry-after longer than the budget fails immediately")
func futileWaitsAreNotTaken() async {
    // Waiting out a 60-second `retry-after` inside a 5-second budget is a
    // slower failure, not a second chance — and M3-03 can say something
    // specific with the interval in hand.
    let transport = StubHTTPTransport(answers: [
        .respond(HTTPResponse(status: 429, headers: ["retry-after": "60"])),
        .respond(AnthropicFixture.draftResponse()),
    ])

    await #expect(throws: AIError.rateLimited(retryAfter: .seconds(60))) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
    #expect(await transport.received.count == 1)
}

@Test("a transport failure arrives as an AIError, never as a URLError")
func transportErrorsAreMapped() async {
    // §7.4 "cannot switch on an error type it has never heard of" — the
    // contract M3-01 wrote into `AIProvider`'s doc comment.
    let transport = StubHTTPTransport(answers: [.fail(URLError(.notConnectedToInternet))])

    await #expect(throws: AIError.network) {
        try await AnthropicFixture.provider(transport).generateStandup(AnthropicFixture.request())
    }
}

// MARK: - The model list (D-140)

@Test("the list is fetched, ranked, and returned with the default first")
func theListIsOrdered() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-opus-5", "claude-sonnet-5"]))
    ])

    let models = try await AnthropicFixture.provider(transport).availableModels()
    #expect(models.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
}

@Test("paging accumulates across pages, and the cursor is sent")
func pagingFollowsTheCursor() async throws {
    let transport = StubHTTPTransport(answers: [
        .respond(
            AnthropicFixture.modelsResponse(
                ids: ["claude-opus-5"], hasMore: true, lastID: "claude-opus-5")),
        .respond(AnthropicFixture.modelsResponse(ids: ["claude-sonnet-5"])),
    ])

    let models = try await AnthropicFixture.provider(transport).availableModels()

    #expect(models.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
    let second = try #require(await transport.received.last)
    #expect(second.url.query?.contains("after_id=claude-opus-5") == true)
}

@Test("a page that repeats its cursor ends the loop and offers no duplicate")
func aRepeatedCursorTerminates() async throws {
    // Two separate properties, and the first version of this test asserted the
    // defect as if it were the second. Every termination condition depends on a
    // field the vendor controls, so a page reporting `has_more` forever would
    // burn the user's budget instead of answering — the cursor guard stops that
    // after two requests. But the loop appends each page *before* it can know
    // the page repeats, so stopping the loop does not un-append: this asserted
    // `models.count == 2` and pinned a duplicated picker entry as intended
    // behaviour (PR #35 review). `ModelRanking.ordered` now dedupes by id.
    //
    // Mutations: drop the `last != cursor` guard (the run then pages until the
    // settings deadline expires — see `endlessPagingIsATimeout` for why that
    // is the right outcome); drop the `seen.insert` filter (red on the model
    // list).
    let repeated = AnthropicFixture.modelsResponse(
        ids: ["claude-sonnet-5"], hasMore: true, lastID: "cursor")
    let transport = StubHTTPTransport(
        answers: [.respond(repeated), .respond(repeated), .respond(repeated)],
        fallback: .respond(repeated))

    let models = try await AnthropicFixture.provider(transport).availableModels()

    #expect(models.map(\.id) == ["claude-sonnet-5"])
    #expect(await transport.received.count == 2)
}

@Test("an invalid key is distinguishable from an unreachable network")
func testConnectionSeparatesItsFailures() async {
    // §7.1's acceptance criterion, and the reason `.invalidCredential` exists
    // separately from `.network` at all.
    let rejected = StubHTTPTransport(answers: [.respond(HTTPResponse(status: 401))])
    await #expect(throws: AIError.invalidCredential) {
        try await AnthropicFixture.provider(rejected).testConnection()
    }

    let offline = StubHTTPTransport(answers: [.fail(URLError(.notConnectedToInternet))])
    await #expect(throws: AIError.network) {
        try await AnthropicFixture.provider(offline).testConnection()
    }
}

@Test("a key with access to nothing is an empty list, not an error")
func anEmptyListIsLegitimate() async throws {
    let transport = StubHTTPTransport(answers: [.respond(AnthropicFixture.modelsResponse(ids: []))])
    #expect(try await AnthropicFixture.provider(transport).availableModels().isEmpty)
}

// MARK: - §8

@Test("the metrics line for a draft carries metadata and no payload")
func theMetricsLineIsMetadataOnly() {
    // D-146 emits one line per draft. `AIMetricsLog.line(for:)` is the string
    // `record` writes, and `AISecretsTests` pins it character for character;
    // this asserts the values M3-02 supplies reach it.
    let metrics = AIRequestMetrics(
        providerID: "anthropic",
        modelID: "claude-sonnet-5",
        latency: .milliseconds(1234),
        inputTokens: 120,
        outputTokens: 45,
        outcome: .failed(label: AIError.invalidRequest.metricsLabel)
    )

    let line = AIMetricsLog.line(for: metrics)
    #expect(
        line
            == "ai provider=anthropic model=claude-sonnet-5 ms=1234 in=120 out=45 outcome=invalidRequest"
    )
    #expect(CredentialPatterns.matches(in: line).isEmpty)
}

@Test("a vendor that pages forever times out rather than truncating")
func endlessPagingIsATimeout() async {
    // Every page carries a *different* cursor, so the repeat guard never
    // fires. The twenty-page cap this replaced would have returned whatever it
    // had collected and called it the model list — a picker missing the user's
    // model, reported as success. The deadline reports the truth instead
    // (PR #35 review).
    let provider = AnthropicProvider(
        transport: EndlessPagingTransport(),
        credentials: AnthropicFixture.store(),
        configuration: AnthropicProvider.Configuration(
            baseURL: URL(fileURLWithPath: "/api.example.test"),
            settingsTimeout: .milliseconds(50),
            retryBackoff: .milliseconds(1),
            retryHeadroom: .milliseconds(1)))

    await #expect(throws: AIError.timedOut) { _ = try await provider.availableModels() }
}

/// Answers every request with a page whose cursor has never been seen before.
private actor EndlessPagingTransport: HTTPTransport {
    private var page = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        page += 1
        return AnthropicFixture.modelsResponse(
            ids: ["claude-sonnet-\(page)"], hasMore: true, lastID: "cursor-\(page)")
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `make test`
Expected: PASS. Every behaviour here already exists in Task 5's file; if one fails, the defect is in that file, not in this one.

- [ ] **Step 3: Verify the retry gate can fail**

Apply this mutation in `backoff(for:configuration:)`, run `make test`, confirm red, then revert it:

```swift
        case .providerUnavailable:
            return nil                   // was: configuration.retryBackoff
```

Expected red: "a 529 is retried once and then succeeds".

- [ ] **Step 4: Commit**

```bash
make format && make lint
git add StenoTests/AI/AnthropicProviderBudgetTests.swift
git commit -m "test: the 20s budget, the single retry, and the paged model list

D-144 and D-140. Its own file because SwiftLint caps a file at 400 lines
and the two provider suites together exceed it.

The load-bearing row is the hang: §7.4's fallback must engage promptly,
and a cancelled URLSession task must not read as an offline device.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Decision records, the task README, and the PR

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/tasks/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: D-140 through D-146 as durable records; the M3-02 row ticked.

Nothing in REQUIREMENTS.md changes. `AIError` is a D-132 construct the spec never names, and the `availableModels()` ordering contract is a doc comment on a signature §7.1 prints unchanged. If review disagrees, amend §7.1 in this PR with a version bump and a changelog line — do not diverge silently (CLAUDE.md).

- [ ] **Step 1: Append the decision records**

Add to `docs/DECISIONS.md`, following the existing `### D-NNN — <title>` format, one section each. Each must state the decision, why the obvious alternative was rejected, and the requirement it serves:

- **D-140** — The model list is returned ordered; element zero is the default. Rejects a preferred-ID hint list (stale on §7.1's own schedule, and indistinguishable in review from a compiled-in id) and capability ranking (current models nearly all report 1M/128K, so "the middle" is arbitrary). Includes the `structured_outputs: false` filter and the explicit-`false`-only rule.
- **D-141** — The five-key body. No `thinking`, `effort`, or sampling parameters, because the model id comes from a runtime list and a parameter that 400s on one model makes it unusable from a picker that offers it.
- **D-142** — `HTTPTransport` over plain values; `URLSessionTransport` deliberately uncovered, with the condition that a new branch buys the `URLProtocol` harness.
- **D-143** — `.invalidRequest`, `.refused`, `.truncated`, and the full mapping table. Records that 404 is ours, not Anthropic's.
- **D-144** — 20s draft / 10s Settings, one retry on 429/529/5xx gated on `backoff + 2s` of remaining budget, `retry-after` honoured only when it fits.
- **D-145** — The racing deadline, and why `URLError.cancelled` maps to `.timedOut`.
- **D-146** — Only `generateStandup` emits §8's metrics line; the other two calls stay silent rather than log a fabricated `modelID`.

- [ ] **Step 2: Tick the task README**

In `docs/tasks/README.md`, change the M3-02 row to `- [x]` and append the PR number once the PR exists. Also check the rows above for anything that merged without being ticked and tick it here — §9.5 forbids a direct commit to `main`, so this PR is the only thing that can (CLAUDE.md's working-a-task step 4).

- [ ] **Step 3: Run the full gate**

```bash
make build && make test && make lint
```
Expected: all three pass. Note that `make test` regenerates `Steno.xcodeproj` every run by design (D-014), which can disturb an open Xcode session.

- [ ] **Step 4: Commit and open the PR**

```bash
git add docs/DECISIONS.md docs/tasks/README.md
git commit -m "docs: D-140 through D-146, and tick M3-02

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin feat/anthropic-provider
gh pr create --fill
```

The PR body must carry, per §9.5 and the spec's Verification section:

- The mutation results table — each test run against its stated mutation, with survivors reported as survivors.
- The deviation note: `AIProvider.availableModels()` gains an ordering contract that M3-04 depends on.
- The uncovered seam: `URLSessionTransport` has no test, and why.
- The claims this task cannot verify from the suite, and what became of them. **The `/v1/models`
  shape and cursor round-trip were confirmed by hand against the live API on 2026-09-22**, during
  review — field names, nesting, `limit=1000`, and `after_id` advancing the window — so that risk
  is closed rather than carried; what remains is drift, which is why `make verify-models` is filed
  against M3-04 as a repeatable check. **The 20-second budget is still reasoned, not measured**:
  nothing here can measure it, and M3-03's first real draft is where it gets timed.

- [ ] **Step 5: Work the review loop, then stop**

Run the Copilot fix / reply / resolve loop unasked; real findings often appear in the review body rather than the inline list. Report only when the PR is green. **Do not merge** — the user reviews and merges (§9.5).

---

## Self-Review

**Spec coverage:** D-140 → Task 4 (+6); D-141 → Task 4 (+5); D-142 → Task 2; D-143 → Tasks 1 and 3; D-144 → Tasks 5 and 6; D-145 → Tasks 2 and 6; D-146 → Task 5. The spec's Layout section maps one-to-one onto the files created. Its Verification table maps onto the tests in Tasks 2–6, and its "mutation-checked, not just green" requirement onto the explicit mutation steps in Tasks 3, 4, 5 and 6. Out-of-scope items are untouched: no prompt, no schema authoring, no fallback, no Settings UI, no streaming.

**Placeholder scan:** No "TBD", no "similar to Task N", no "add error handling". Every code step carries the code. Task 7's decision records are the one place describing content rather than showing it, because each D-entry is prose whose argument is already stated in full in the spec sections they cite.

**Type consistency:** `AnthropicModel` (not `AnthropicWire.Model`) is used in Tasks 4, 5 and 6; `AnthropicUsage`, `AnthropicMessagesResponse`, `AnthropicModelsPage` likewise. `AnthropicFixture` — not `Fixture` — is the name in both test suites. `Configuration` has four fields in every appearance; `recommendedDraftTimeout` is a static on the provider, never a field. `withDeadline` has one signature throughout.
