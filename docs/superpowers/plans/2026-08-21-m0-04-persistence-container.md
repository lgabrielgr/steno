# M0-04 Persistence Container — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local SwiftData store wired into the app that survives relaunch, plus the in-memory
container tests use instead of it.

**Architecture:** One caseless enum, `StenoKit/Persistence/StenoStore.swift`, owns the schema, the
store location, and both container factories. The app builds a container once in `StenoApp.init`
and either injects it or shows a readable failure scene. Tests build their own containers —
in-memory, or on disk under a temp directory — and never open the user's store.

**Tech Stack:** Swift 6 language mode, SwiftData (macOS 14 floor), SwiftUI, Swift Testing (D-011),
XcodeGen, SwiftLint + swift-format.

**Spec:** [`docs/superpowers/specs/2026-08-21-m0-04-persistence-container-design.md`](../specs/2026-08-21-m0-04-persistence-container-design.md)

**Task file:** [`docs/tasks/M0-04-persistence-container.md`](../../tasks/M0-04-persistence-container.md)

## Global Constraints

- **Never commit to `main`.** This work is on `feat/persistence-container`; open a PR and stop, do
  not merge (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR** (§9.5 step 4). `make lint`
  runs `--strict`, so warnings are errors.
- **Line length 100**, 4-space indent (`.swift-format`). Run `make format` before committing.
- **`force_unwrapping` is an enabled SwiftLint rule** — no `!` unwrapping anywhere, tests included.
- **No CloudKit container or entitlement.** Sync is cancelled (D1, §14).
- **The store path is `~/Library/Application Support/Steno/Steno.store`**, verified to resolve to
  `/Users/<user>/Library/Application Support/Steno/Steno.store`.
- **No test may open `StenoStore.defaultURL`.** Tests use `inMemory()` or `live(at:)` against a
  unique temp directory they remove themselves.
- **Every model list lives in `StenoStore.models()`** after Task 3 — do not reintroduce a second.
- All code below was compile-checked under
  `xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`; it builds as written.

### How to run one test

Swift Testing's free-function tests do not filter reliably through
`xcodebuild -only-testing:`. Run the whole suite with `make test` and read the xcbeautify output
for the test's display name (the string in `@Test("…")`). It is a few seconds either way.

### What "the test fails first" means here

Swift is compiled, so a test written against a type that does not exist yet **fails to build**.
That is the red state — it is expected and sufficient. Each task names the compiler error to
expect.

---

## File Structure

| File | Responsibility |
|---|---|
| `StenoKit/Persistence/StenoStore.swift` | **new.** The entire persistence surface: schema, store location, `live`, `inMemory` |
| `StenoTests/Persistence/StenoStoreTests.swift` | **new.** Location, isolation, registration, directory creation, durability, entitlements |
| `StenoTests/Models/TestContainer.swift` | **modify.** Loses its own model list; delegates to `StenoStore` |
| `StenoTests/Models/SchemaConformanceTests.swift` | **modify.** Derives `entityNames`; asserts it against the §3 tables |
| `Steno/App/StenoApp.swift` | **modify.** Builds the container once; switches the root scene on the result |
| `Steno/App/StoreFailureView.swift` | **new.** Path, error, Quit |
| `Steno/App/ContentView.swift` | **modify.** Temporary add-a-record affordance, deleted by M0-05 |
| `docs/DECISIONS.md` | **modify.** D-017 (closes O-3), D-018 (failure scene); O-3 leaves the open table |
| `docs/ARCHITECTURE.md` | **modify.** `Persistence/` marked as landed |
| `docs/tasks/README.md` | **modify.** M0-03 and M0-04 ticked |

No `project.yml` change is required: both targets take whole directories as sources, so new
subdirectories are picked up by `make generate`.

---

## Task 1: `StenoStore` — location, schema, and the in-memory factory

Delivers the type, its store location (closing O-3), and the factory tests use. `live(at:)` lands
in Task 2 so this task's gate is exactly "the location is right and the test container touches no
file".

**Files:**
- Create: `StenoKit/Persistence/StenoStore.swift`
- Create: `StenoTests/Persistence/StenoStoreTests.swift`

**Interfaces:**
- Consumes: `Project`, `TaskItem`, `Event`, `SourceRef`, `StandupReport` from `StenoKit/Models/`.
- Produces:
  - `StenoStore.models() -> [any PersistentModel.Type]`
  - `StenoStore.storeDirectory: URL { get throws }`
  - `StenoStore.defaultURL: URL { get throws }`
  - `StenoStore.inMemory() throws -> ModelContainer`

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Persistence/StenoStoreTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

// §1 (design): the location is pinned rather than left to SwiftData, because
// M2.5-03's Replace mode and §8's "delete my data" both have to name it.
@Test("§1: the store is pinned to Application Support, under Steno/")
func defaultURLIsPinnedToApplicationSupport() throws {
    let url = try StenoStore.defaultURL

    #expect(url.lastPathComponent == "Steno.store")
    #expect(url.deletingLastPathComponent().lastPathComponent == "Steno")
    #expect(try url.deletingLastPathComponent() == StenoStore.storeDirectory)

    let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    #expect(url.path.hasPrefix(applicationSupport.path))
}

// AC-2. Asserting the url is /dev/null is stronger than the boolean alone: it
// says no file path is involved at all.
@Test("AC-2: the test container touches no file")
func inMemoryContainerIsNotOnDisk() throws {
    let container = try StenoStore.inMemory()

    #expect(container.configurations.allSatisfy(\.isStoredInMemoryOnly))
    #expect(container.configurations.allSatisfy { $0.url.path == "/dev/null" })
}

// AC-4. The configuration cannot carry this assertion —
// ModelConfiguration.CloudKitDatabase is not Equatable, and its description
// exposes private stored properties that are not a stable contract — so the
// criterion is tested where it is actually stated: the entitlements file.
@Test("AC-4: the app declares no CloudKit entitlement")
func theAppDeclaresNoCloudKitEntitlement() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)  // …/StenoTests/Persistence/<this file>
        .deletingLastPathComponent()  // Persistence
        .deletingLastPathComponent()  // StenoTests
        .deletingLastPathComponent()  // repository root
    let entitlements = try String(
        contentsOf: repositoryRoot.appendingPathComponent("Steno/Steno.entitlements"),
        encoding: .utf8
    )

    #expect(!entitlements.contains("com.apple.developer.icloud"))
    #expect(!entitlements.contains("com.apple.developer.ubiquity"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: a **build failure**, `cannot find 'StenoStore' in scope`. That is the red state.

- [ ] **Step 3: Write the minimal implementation**

Create `StenoKit/Persistence/StenoStore.swift`:

```swift
import Foundation
import SwiftData

/// The application's persistence surface: one schema, one store location, and
/// the two containers anything in this project should ever build
/// (REQUIREMENTS.md §6, D2).
///
/// A caseless `enum` rather than a struct or a singleton: there is no instance
/// state here, so there is nothing for strict concurrency to reason about — the
/// same reasoning that made M0-03's model list a function rather than a global.
public enum StenoStore {
    /// The shipped schema — the single declaration of which models exist.
    ///
    /// A function rather than a `let` so there is no shared mutable state.
    /// **Adding a model means adding it here and nowhere else**: the test
    /// bundle derives its list from this one, so a type missing here is missing
    /// from every §6 and §3 conformance gate too.
    public static func models() -> [any PersistentModel.Type] {
        [Project.self, TaskItem.self, Event.self, SourceRef.self, StandupReport.self]
    }

    /// `~/Library/Application Support/Steno` — closing open question O-3.
    ///
    /// **This directory is the unit of deletion.** M2.5-03's Replace mode and
    /// §8's "delete my data" remove *this*, not `defaultURL`: a SwiftData store
    /// is three files (`Steno.store`, `-shm`, `-wal`), and deleting only the
    /// first strands the write-ahead log.
    ///
    /// A real path rather than a container path, because the app is
    /// deliberately unsandboxed (§6.1). `create: false` keeps this side-effect
    /// free — `live(at:)` creates the directory when it actually opens a store.
    public static var storeDirectory: URL {
        get throws {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).appendingPathComponent("Steno", isDirectory: true)
        }
    }

    /// The store file itself. Throwing, because resolving Application Support
    /// can fail and the alternative — trapping, or inventing a fallback path —
    /// is how a user's data quietly ends up somewhere nobody looks.
    public static var defaultURL: URL {
        get throws { try storeDirectory.appendingPathComponent("Steno.store") }
    }

    /// A store that exists only for the lifetime of the container.
    ///
    /// **Tests only.** Its configuration reports `/dev/null` as its url, which
    /// is what makes "this test touched no file" assertable.
    public static func inMemory() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(models()),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, including the three display names above.

- [ ] **Step 5: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Persistence/StenoStore.swift StenoTests/Persistence/StenoStoreTests.swift
git commit -m "feat: pin the store location and add the in-memory container

Closes O-3: the store is ~/Library/Application Support/Steno/Steno.store, set
explicitly rather than left to SwiftData, because M2.5-03's Replace mode and
§8's delete both have to name a path an implicit default would leave free to
change between OS releases. storeDirectory is public and documented as the
deletion unit — the store is three files, and removing only Steno.store would
strand the WAL.

AC-4 is asserted against the entitlements file rather than the configuration:
ModelConfiguration.CloudKitDatabase is not Equatable, and its description leaks
private stored properties that are not a stable contract.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: `live(at:)` — the real store, and the durability guarantee

Delivers the container the app ships and the AC-1 regression guard.

**Files:**
- Modify: `StenoKit/Persistence/StenoStore.swift`
- Modify: `StenoTests/Persistence/StenoStoreTests.swift`

**Interfaces:**
- Consumes: `StenoStore.models()`, `StenoStore.defaultURL` (Task 1).
- Produces: `StenoStore.live(at url: URL? = nil) throws -> ModelContainer` — `nil` means
  `defaultURL`; every test passes a temp URL.

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Persistence/StenoStoreTests.swift`:

```swift
/// A unique store directory per test. Swift Testing has no teardown hook for
/// free functions, so each test calls `remove()` from a `defer`.
private struct TemporaryStore {
    /// The directory this test owns outright and deletes.
    ///
    /// Stored, never derived by walking up from `directory` — `..` from a
    /// non-nested store directory is the shared temp directory itself, and
    /// `remove()` would take the whole thing with it.
    let root: URL

    /// Where the store file sits. Neither variant exists on disk until
    /// `live(at:)` creates it.
    let directory: URL

    var url: URL { directory.appendingPathComponent("Steno.store") }

    init(nested: Bool = false) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("steno-tests-\(UUID().uuidString)", isDirectory: true)
        directory = nested ? root.appendingPathComponent("Steno", isDirectory: true) : root
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

// AC-1, and the reason this task exists. Exercises the application's own code
// path: same factory, same configuration, only the URL differs.
@Test("AC-1: a record written through one container is readable from the next")
func dataSurvivesAContainerRestart() throws {
    let store = TemporaryStore()
    defer { store.remove() }
    let identifier = UUID()

    // Scoped so the container is released before the store is reopened.
    do {
        let container = try StenoStore.live(at: store.url)
        let context = ModelContext(container)
        context.insert(
            Project(
                id: identifier,
                name: "Payments Platform",
                colorHex: "#3B82F6",
                modifiedAt: Date(timeIntervalSince1970: 0)
            )
        )
        try context.save()
    }

    let reopened = ModelContext(try StenoStore.live(at: store.url))
    let stored = try reopened.fetch(FetchDescriptor<Project>())

    #expect(stored.count == 1)
    #expect(stored.first?.id == identifier)
    #expect(stored.first?.name == "Payments Platform")
}

// The check M0-03's TestContainer.swift says M0-04 owes: nothing in M0-03
// catches a model type missing from the *shipped* list.
@Test("§6: the shipped container registers every model")
func liveContainerRegistersEveryModel() throws {
    let store = TemporaryStore()
    defer { store.remove() }

    let container = try StenoStore.live(at: store.url)

    let registered = Set(container.schema.entities.map(\.name))
    let declared = Set(StenoStore.models().map { String(describing: $0) })
    #expect(registered == declared)
    #expect(registered.count == 5)
}

// §2 (design): Core Data recovers from a missing parent on its own, but only
// after ~200 lines of "CoreData: error:" on stderr — including "Sandbox access
// to file-write-create denied" — which is what first launch would look like
// under `make run`. This test sees that the container opens; it cannot see how
// loudly, so the comment in live(at:) is the real guard. See design §7.1.
@Test("§2: live() creates a missing store directory itself")
func liveCreatesAMissingStoreDirectory() throws {
    let store = TemporaryStore(nested: true)
    defer { store.remove() }
    #expect(!FileManager.default.fileExists(atPath: store.directory.path))

    _ = try StenoStore.live(at: store.url)

    #expect(FileManager.default.fileExists(atPath: store.directory.path))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: a **build failure**, `type 'StenoStore' has no member 'live'`.

- [ ] **Step 3: Write the minimal implementation**

Add to `StenoKit/Persistence/StenoStore.swift`, after `defaultURL` and before `inMemory()`:

```swift
    /// The application's store, at `defaultURL` unless a URL is given.
    ///
    /// `URL?` rather than `URL = defaultURL` because a default argument cannot
    /// be a throwing expression. Tests pass a temp directory; the app passes
    /// nothing.
    ///
    /// **The `createDirectory` call is not redundant.** SwiftData does open a
    /// store whose parent directory is missing — but by way of Core Data's
    /// error-recovery path, which first logs roughly 200 lines to stderr,
    /// including `Sandbox access to file-write-create denied` and
    /// `NSCocoaErrorDomain (512)`. Nothing is broken, and the app works; but
    /// `make run` streams stderr to the terminal (§9.2), so first launch on a
    /// clean machine would look like a catastrophic failure. Removing this call
    /// leaves every test green. See DECISIONS.md D-017.
    public static func live(at url: URL? = nil) throws -> ModelContainer {
        let storeURL = try url ?? defaultURL
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try ModelContainer(
            for: Schema(models()),
            configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: .none)
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, all six tests in the file.

- [ ] **Step 5: Confirm no test left anything behind**

Run: `ls ~/Library/Application\ Support/ | grep -i steno; ls /tmp | grep steno-tests`
Expected: **no output from either.** `Steno/` in Application Support must not exist yet — no test
opens `defaultURL`, and the app has not been run. If it does exist, a test is writing to the real
store and that is a bug in the test, not a tolerable side effect (AC-2).

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add StenoKit/Persistence/StenoStore.swift StenoTests/Persistence/StenoStoreTests.swift
git commit -m "feat: add the on-disk container, with a durability test

live(at:) creates the store's parent directory rather than leaning on Core
Data's recovery path. Both open the store; only one of them does it without
logging ~200 lines of CoreData errors — including a Sandbox-denied line — which
is what first launch would otherwise look like in \`make run\` output.

The durability test exercises the application's own code path (same factory,
same configuration, temp URL) rather than a hand-rolled container, so a change
to the shipped configuration cannot pass it.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: Collapse M0-03's two model lists into one

The defect this task inherits: `stenoModelTypes()` in `TestContainer.swift` and `entityNames` in
`SchemaConformanceTests.swift` are two hard-coded lists with nothing cross-checking them. A sixth
model added to one but not the other silently skips every §6 and §3 conformance gate. M0-03 could
not fix it — the shipped list did not exist. Task 1 created it.

**Files:**
- Modify: `StenoTests/Models/TestContainer.swift`
- Modify: `StenoTests/Models/SchemaConformanceTests.swift`

**Interfaces:**
- Consumes: `StenoStore.models()`, `StenoStore.inMemory()` (Task 1).
- Produces: nothing new. `inMemoryContainer()` keeps its name and signature, so
  `PersistedInvariantsTests.swift` (three call sites) is untouched.

- [ ] **Step 1: Write the failing test**

Add to `StenoTests/Models/SchemaConformanceTests.swift`, immediately after the
`expectedRelationships` table:

```swift
// The gate M0-04 adds. Before this, `entityNames` was a second hard-coded list:
// a model present in one list and absent from the other skipped every check in
// this file silently. Now the names are derived from the shipped schema and
// checked against the transcribed §3 tables, so a new model either appears in
// both or fails here.
@Test("§6: the shipped entities are exactly the ones §3's tables describe")
func shippedEntitiesMatchTheSpecTables() {
    #expect(Set(entityNames) == Set(expectedAttributes.keys))
    #expect(Set(entityNames) == Set(expectedRelationships.keys))
}
```

- [ ] **Step 2: Run it to verify it passes for the wrong reason**

Run: `make test`
Expected: **PASS** — both lists are currently correct, so this test cannot fail yet. That is the
point: the assertion is a guard against future drift, not a bug fix. Steps 3–4 remove the
duplication it guards.

- [ ] **Step 3: Derive `entityNames` and delete the fixture's list**

In `StenoTests/Models/SchemaConformanceTests.swift`, replace line 7:

```swift
private let entityNames = ["Project", "TaskItem", "Event", "SourceRef", "StandupReport"]
```

with:

```swift
// Derived, not transcribed: the shipped schema is the only declaration of which
// models exist (StenoStore.models()). `shippedEntitiesMatchTheSpecTables` below
// checks this list against the §3 tables in this file.
private let entityNames = Schema(StenoStore.models()).entities.map(\.name)
```

In the same file, change `entity(named:)` to build its schema from the shipped list and to name
the right function in its failure message:

```swift
private func entity(named name: String) throws -> Schema.Entity {
    let schema = Schema(StenoStore.models())
    return try #require(
        schema.entities.first { $0.name == name },
        "no entity named \(name) — is it missing from StenoStore.models()?"
    )
}
```

Replace the whole of `StenoTests/Models/TestContainer.swift` with:

```swift
import Foundation
import SwiftData

@testable import StenoKit

/// An in-memory store for tests that need a live context.
///
/// A thin alias for the shipped factory, kept because three files call it. The
/// model list that used to live here is gone: M0-04 shipped
/// `StenoStore.models()`, and a second list here would be a second declaration
/// of the schema that the application's container could silently disagree with.
func inMemoryContainer() throws -> ModelContainer {
    try StenoStore.inMemory()
}
```

- [ ] **Step 4: Run the tests to verify they still pass**

Run: `make test`
Expected: PASS, with no change in the number of tests run other than the one added in Step 1. In
particular `PersistedInvariantsTests` still passes — it calls `inMemoryContainer()`, whose
signature did not change.

- [ ] **Step 5: Verify the drift gate actually bites**

Temporarily comment out `StandupReport.self` in `StenoStore.models()`
(`StenoKit/Persistence/StenoStore.swift`) to simulate the drift the gate exists to catch.

Run: `make test`
Expected: **FAIL** — `shippedEntitiesMatchTheSpecTables` reports the set mismatch, and
`liveContainerRegistersEveryModel` (Task 2) fails its count of 5. Restore the line and re-run to
confirm green. This is the only proof that the gate is wired to something.

- [ ] **Step 6: Format, lint, commit**

```bash
make format && make lint
git add StenoTests/Models/TestContainer.swift StenoTests/Models/SchemaConformanceTests.swift
git commit -m "test: derive the conformance entity list from the shipped schema

M0-03 left two hard-coded model lists with nothing cross-checking them, because
the shipped list did not exist yet. It does now, so both are gone: entityNames
is derived from Schema(StenoStore.models()), the test fixture delegates to
StenoStore.inMemory(), and a set-equality assertion ties the derived names to
the §3 tables transcribed in this file.

Verified by removing a model from the shipped list and watching the gate fail.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 4: Wire the app, and make failure readable

**Files:**
- Modify: `Steno/App/StenoApp.swift`
- Create: `Steno/App/StoreFailureView.swift`
- Modify: `Steno/App/ContentView.swift`

**Interfaces:**
- Consumes: `StenoStore.live()`, `StenoStore.defaultURL` (Tasks 1–2); `Log.app` from
  `StenoKit/Support/Logging.swift`; `Project` from `StenoKit/Models/`.
- Produces: `StoreFailureView(path: String, error: Error)`.

There is no unit test in this task: everything here needs a window server, which is exactly what
§9.4 keeps out of `StenoTests` (D-010). It is verified by Step 5's manual run, which is what
acceptance criterion 1 asks for in the first place.

- [ ] **Step 1: Create the failure scene**

Create `Steno/App/StoreFailureView.swift`:

```swift
import AppKit
import SwiftUI

/// Shown when the store cannot be opened.
///
/// Deliberately not a `fatalError`, which reads as a crash to anyone not
/// watching stderr — and this is the one situation where the reason matters
/// most. Deliberately not an in-memory fallback either: for a capture tool,
/// accepting writes that evaporate at quit is worse than not launching (§1.1),
/// because the loss would surface at the next stand-up. See DECISIONS.md D-018.
struct StoreFailureView: View {
    let path: String
    let error: Error

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steno could not open its data store.")
                .font(.headline)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Text(String(describing: error))
                .font(.callout)
                .textSelection(.enabled)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320, alignment: .topLeading)
    }
}
```

- [ ] **Step 2: Build the container in the app and switch the root scene**

Replace `Steno/App/StenoApp.swift` with:

```swift
import Darwin  // fflush/stdout — explicit rather than transitively via SwiftUI
import StenoKit
import SwiftData
import SwiftUI

@main
struct StenoApp: App {
    /// Built once, here, rather than by `.modelContainer(for:)` — which traps
    /// on failure. See `StoreFailureView` for why this is a `Result`.
    private let store: Result<ModelContainer, Error>
    private let storePath: String

    init() {
        // os.Logger writes to the unified log, never to stdio — this line is
        // what makes `make run` self-evidencing that it execs the binary and
        // inherits the terminal's stdout rather than detaching via `open`
        // (REQUIREMENTS.md §9.2). The flush matters: stdout is fully buffered
        // when it is not a TTY, and the app is killed by a signal rather than
        // exiting, so without it the line is discarded whenever output is
        // redirected — which is how it gets verified.
        print("Steno launched")
        fflush(stdout)
        Log.app.info("Steno launched")

        let path = (try? StenoStore.defaultURL.path) ?? "<could not resolve Application Support>"
        storePath = path
        store = Result { try StenoStore.live() }

        // A store path is not a secret, so §8's redaction rule is not engaged —
        // and knowing where the data went is worth a line in the log.
        switch store {
        case .success:
            Log.app.info("store opened at \(path, privacy: .public)")
        case .failure(let error):
            Log.app.fault(
                "store failed to open at \(path, privacy: .public): "
                    + "\(String(describing: error), privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                ContentView().modelContainer(container)
            case .failure(let error):
                StoreFailureView(path: storePath, error: error)
            }
        }
    }
}
```

- [ ] **Step 3: Add the temporary capture affordance**

Replace `Steno/App/ContentView.swift` with:

```swift
import StenoKit
import SwiftData
import SwiftUI

/// Placeholder window contents. M0-05 replaces this with the three-column shell.
struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query private var projects: [Project]

    var body: some View {
        VStack(spacing: 12) {
            Text("Steno")

            // TEMPORARY — M0-04 only. The sole way to exercise acceptance
            // criterion 1 ("add a record, quit, relaunch") before M0-05 builds
            // real UI. **Delete this with the rest of the placeholder in
            // M0-05**, which replaces this file wholesale.
            Text("\(projects.count) projects stored")
            Button("Add sample project") {
                context.insert(
                    Project(
                        name: "Sample \(projects.count + 1)",
                        colorHex: "#3B82F6",
                        modifiedAt: .now
                    )
                )
                try? context.save()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
```

- [ ] **Step 4: Build**

Run: `make build && make test && make lint`
Expected: all three green. `make test` still passes headless with networking denied — nothing in
this task is reachable from the test bundle.

- [ ] **Step 5: Verify acceptance criterion 1 by hand**

```bash
ls ~/Library/Application\ Support/Steno 2>/dev/null   # expect: no such directory
make run                                              # expect "Steno launched" on stdout
```

In the window: click **Add sample project** twice, confirm the count reads `2 projects stored`,
then quit the app (⌘Q). Then:

```bash
ls ~/Library/Application\ Support/Steno    # expect Steno.store, Steno.store-shm, Steno.store-wal
make run
```

Expected: the window opens reading **`2 projects stored`**. That is AC-1 satisfied.

Also confirm the first launch produced **no wall of `CoreData: error:` lines** in the `make run`
output — that is Task 2's `createDirectory` call doing its job.

- [ ] **Step 6: Verify the failure scene**

```bash
chmod 000 ~/Library/Application\ Support/Steno
make run          # expect the failure window, naming the path and the error
chmod 755 ~/Library/Application\ Support/Steno
make run          # expect the normal window, still reading "2 projects stored"
```

If the store opens anyway despite `chmod 000` (possible when running as the file's owner),
instead point the app at an unwritable path temporarily by editing `storeDirectory` to
`URL(fileURLWithPath: "/System/steno-should-fail")`, run, observe the failure scene, and revert
the edit before committing. Do not commit either variation.

- [ ] **Step 7: Commit**

```bash
make format && make lint
git add Steno/App/StenoApp.swift Steno/App/StoreFailureView.swift Steno/App/ContentView.swift
git commit -m "feat: inject the store, and show failures instead of trapping

The container is built once in StenoApp.init and the root scene switches on the
result: a working store gets ContentView, a broken one gets StoreFailureView
naming the path and the error. Apple's .modelContainer(for:) traps instead,
which reads as a crash in the one situation where the reason matters most.

An in-memory fallback was rejected deliberately — for a capture tool, accepting
writes that evaporate at quit is worse than not launching (§1.1); the user would
find out at the next stand-up.

ContentView gains a temporary add-a-record button so acceptance criterion 1 can
be exercised before M0-05 builds real UI. M0-05 replaces this file wholesale.

Verified: added two records, quit, relaunched, count survived.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 5: Record the decisions and close O-3

**Files:**
- Modify: `docs/DECISIONS.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/tasks/README.md`

- [ ] **Step 1: Add D-017 and D-018**

Append to the **Accepted** section of `docs/DECISIONS.md`, after D-016 and before the
`## Open — decided by the task that owns them` heading:

```markdown
### D-017 — The store is `~/Library/Application Support/Steno/`, closing O-3
**2026-08-21** · M0-04 · **Status:** accepted

`StenoStore.defaultURL` is `~/Library/Application Support/Steno/Steno.store`, set through an
explicit `ModelConfiguration(url:)`. `StenoStore.storeDirectory` — the *directory* — is public and
is the unit M2.5-03's Replace mode and §8's "delete my data" remove. `live(at:)` creates that
directory itself before opening the store.

**Why:** an implicit default is a path both M2.5-03 and §8 would have to re-derive, and one Apple
is free to change between releases. The directory rather than the file, because a SwiftData store
is three files — `Steno.store`, `Steno.store-shm`, `Steno.store-wal` — and deleting the first
alone strands the write-ahead log. The `createDirectory` call looks redundant and is not: Core
Data *does* recover from a missing parent, but only after logging roughly 200 lines to stderr,
including `Sandbox access to file-write-create denied` and `NSCocoaErrorDomain (512)`, which is
what first launch would look like under `make run` (§9.2). No test can catch its removal — the
container opens either way — so this entry is the guard.
**Alternatives:** SwiftData's default location (less code; leaves two later features re-deriving
an implicit path).

---

### D-018 — A store that will not open shows a failure scene, not a crash or a fallback
**2026-08-21** · M0-04 · **Status:** accepted

`StenoApp` builds the container into a `Result` and switches the root scene: success gets
`ContentView`, failure gets `StoreFailureView`, which names the store path and the underlying
error and offers Quit.

**Why:** Apple's `.modelContainer(for:)` traps, which reads as a crash to anyone not watching
stderr — and a store that cannot open is the situation where the reason matters most. Falling back
to an in-memory container was rejected outright: for a capture tool, accepting writes that
evaporate at quit is worse than refusing to launch (§1.1), because the loss surfaces at the next
stand-up. §13's "degradation ships with the feature" is scoped to network-dependent features
(§7.4); it does not ask for a store that pretends to persist.
**Alternatives:** `fatalError` with a logged reason (cheapest; invisible unless stderr is being
watched). M0-05 inherits a root scene conditional on container construction, which is deliberate.

---
```

- [ ] **Step 2: Remove O-3 from the open table**

In `docs/DECISIONS.md`, delete this row from the `## Open — decided by the task that owns them`
table:

```markdown
| O-3 | Where the SwiftData store file lives — needed by M2.5-03's Replace mode and §8's "delete my data" | `M0-04` |
```

- [ ] **Step 3: Mark `Persistence/` as landed**

In `docs/ARCHITECTURE.md` §5, change:

```
  Persistence/    container, store config                (M0-04)
```

to:

```
  Persistence/    StenoStore — schema, store location    (exists, M0-04)
```

- [ ] **Step 4: Tick the task rows**

In `docs/tasks/README.md`, change lines 51–52 from `- [ ]` to `- [x]`. M0-03's row shipped
unticked in PR #7; correcting it here is deliberate, not scope creep, and is called out in the PR
body.

- [ ] **Step 5: Verify and commit**

Run: `make build && make test && make lint`
Expected: all green (documentation only, but the PR gate is the gate).

```bash
git add docs/DECISIONS.md docs/ARCHITECTURE.md docs/tasks/README.md
git commit -m "docs: record D-017 and D-018, closing O-3

Also ticks M0-03's README row, which shipped unticked in #7.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 6: Open the PR

- [ ] **Step 1: Final verification**

Run: `make build && make test && make lint`
Expected: three green runs, pasted into the PR body. "This should compile" is not acceptable (§9,
§13).

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/persistence-container
```

Open the PR with the repository template. Beyond what the template asks, the body **must** carry:

1. **The AC-2 friction, stated not absorbed.** The criterion says tests use an in-memory container
   and leave no artifacts; the durability test necessarily writes a real file — that is the
   property under test. It is scoped to a unique temp directory and removed in a `defer`, so
   nothing outlives the run and the user's store is never opened. This reads AC-2's intent as
   "never touch the user's real store" (CLAUDE.md, "When the spec is wrong").
2. **The temporary `ContentView` affordance**, with M0-05 named as its deletion point.
3. **The stderr finding** from D-017 — the next person will otherwise rediscover it the hard way.
4. **O-3's answer**, since the DECISIONS table now points at this PR.
5. **The M0-03 checkbox correction**, so it does not read as an unrelated edit.
6. The manual AC-1 evidence from Task 4 Step 5: added two records, quit, relaunched, count
   survived.

- [ ] **Step 3: Stop**

Do not merge. The user reviews and merges (CLAUDE.md non-negotiable 1; `main` is protected
regardless).

---

## Self-Review

**Spec coverage.** Design §1 and §1.1 → Task 1 (`defaultURL`, `storeDirectory`, test 3) and
Task 5 (D-017). §2 → Task 2 (`createDirectory` plus its comment) and Task 5. §3 → Tasks 1–2, the
full API. §4 → Task 4. §5 → Task 2 (durability test) and Task 4 (affordance, manual check).
§6 → Task 3. §7's test table: test 1 → Task 2, test 2 → Task 2, test 3 → Task 1, test 4 → Task 1,
test 5 → Task 1, test 6 → Task 2, test 7 → Task 3. §11 → Tasks 5 and 6. No gaps.

**Acceptance criteria.** AC-1 → Task 2 Step 1 (automated) and Task 4 Step 5 (manual, as the
criterion words it). AC-2 → Task 1's `/dev/null` assertion plus Task 2 Step 5's filesystem check.
AC-3 → run at every task boundary. AC-4 → Task 1's entitlements test.

**Type consistency.** `StenoStore.models()`, `storeDirectory`, `defaultURL`, `live(at:)`,
`inMemory()` are spelled identically in Tasks 1, 2, 3 and 4. `inMemoryContainer()` keeps its M0-03
signature, so `PersistedInvariantsTests`' three call sites need no edit. `Project.init` is called
with `id:name:colorHex:modifiedAt:` in Task 2 and `name:colorHex:modifiedAt:` in Task 4 — both
match the initializer in `StenoKit/Models/Project.swift`, which has no default for `colorHex` or
`modifiedAt`.

**Verified, not assumed.** Every code block was compiled under
`xcrun swiftc -swift-version 6 -target arm64-apple-macos14.0`. This is where the plan's two
surprises came from: `ModelConfiguration.CloudKitDatabase` is not `Equatable` (so AC-4 moved to the
entitlements file), and an in-memory configuration reports `/dev/null` (so AC-2 gets a stronger
assertion than the boolean).