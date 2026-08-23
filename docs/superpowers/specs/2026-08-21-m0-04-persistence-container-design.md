# M0-04 — Persistence Container — Design

**Task:** [`docs/tasks/M0-04-persistence-container.md`](../../tasks/M0-04-persistence-container.md)
**Requirements:** [§6](../../REQUIREMENTS.md#6-data--sync),
[§6.1](../../REQUIREMENTS.md#61-apple-developer-program-not-required),
[§8](../../REQUIREMENTS.md#8-security--privacy),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[D1, D2](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/persistence-container`
**Date:** 2026-08-21

## Goal

One local SwiftData store, wired into the app, that survives relaunch — plus the in-memory
container tests use instead. The persistence surface is `StenoKit/Persistence/StenoStore.swift`
and nothing else; every later task reaches the store through it.

Two things beyond the container itself land here because they are cheap now and expensive later:
the store's **location is decided and named in code** (O-3), and M0-03's **two parallel model
lists collapse into one**.

---

## 1. O-3, closed: where the store lives

```
~/Library/Application Support/Steno/Steno.store
```

Set explicitly through `ModelConfiguration(url:)` rather than left to SwiftData's default.

The path is real rather than a container path: the app is deliberately unsandboxed
(`Steno/Steno.entitlements`, §6.1), so `.applicationSupportDirectory` in the user domain resolves
to `~/Library/Application Support` and the store is findable in Finder.

**Why explicit, when passing no URL is less code.** Two later tasks need to name this path:
M2.5-03's Replace mode wipes the store before importing, and §8's "delete my data" purges it. An
implicit default means each of them re-derives a location that SwiftData chose — and that Apple is
free to change between OS releases. Pinning it costs one URL expression and turns both of those
into a one-line call against a documented constant.

### 1.1 The unit of deletion is the directory, not the file

A SwiftData store is three files, confirmed empirically (§2):

```
Steno.store  Steno.store-shm  Steno.store-wal
```

Deleting `Steno.store` alone leaves a write-ahead log and a shared-memory file behind — the exact
shape of bug that produces "Replace mode left some of my old data" months from now.

So `StenoStore` exposes **`storeDirectory` as a public, documented member**, and its doc comment
says plainly that it is what M2.5-03 and §8 delete. The directory holds nothing but this store,
which is what makes deleting the whole thing safe.

---

## 2. The parent directory is created by us, not by Core Data's recovery path

**Finding.** A probe (Swift 6 mode, `-target arm64-apple-macos14.0`) pointed a
`ModelConfiguration` at a store inside a directory that did not exist. The container *is* built
successfully — but only after Core Data's error-recovery path runs, and that path logs roughly
200 lines to stderr first, including:

```
CoreData: error: Failed to stat path '…/Steno.store', errno 2 / No such file or directory.
CoreData: error:   Sandbox access to file-write-create denied
CoreData: error: addPersistentStoreWithType:… returned error NSCocoaErrorDomain (512)
CoreData: error: Recovery attempt while adding <NSPersistentStoreDescription: …> was successful!
```

Nothing is wrong, and the app works. But `make run` streams stdout and stderr to the terminal
(§9.2), so **first launch on a clean machine would look like a catastrophic failure** to the
person reading it — including to an agent debugging something unrelated.

**Response:** `live(at:)` calls `FileManager.createDirectory(withIntermediateDirectories: true)`
on the store's parent before constructing the container. If that throws, `live` throws, and §4's
failure scene reports it.

This is a legibility fix, not a correctness one, and it is recorded as such — see §9 R1 for why no
test can guard it.

---

## 3. The API

```swift
public enum StenoStore {
    /// The shipped schema — the single declaration of which models exist.
    public static func models() -> [any PersistentModel.Type]

    /// ~/Library/Application Support/Steno.
    /// The unit M2.5-03's Replace mode and §8's "delete my data" remove (§1.1).
    public static var storeDirectory: URL { get throws }

    /// storeDirectory/Steno.store.
    public static var defaultURL: URL { get throws }

    /// The application's store. `nil` means `defaultURL`; tests pass a temp directory.
    public static func live(at url: URL? = nil) throws -> ModelContainer

    /// A store that exists only for the lifetime of the container. Tests only.
    public static func inMemory() throws -> ModelContainer
}
```

A caseless `enum` for the same reason M0-03 made its model list a function rather than a global
`let`: there is no instance state, and nothing here for strict concurrency to reason about. Views
receive the container through SwiftUI's own `.modelContainer(_:)` and read it back via
`@Environment(\.modelContext)` — no bespoke injection mechanism, and no `Store` protocol.
ARCHITECTURE rule 4 scopes protocol doubles to *external calls*; an in-memory `ModelContainer` is
already headless, fast, and truer than a fake would be.

**Three signature details that are decisions, not style:**

- `storeDirectory` and `defaultURL` are **throwing computed properties**. `FileManager`'s
  directory lookup can fail, and a non-throwing property would have to trap or invent a fallback
  path — the second being how a user's data quietly ends up somewhere nobody looks.
- `live(at:)` therefore takes `URL?`, not `URL = defaultURL`: a default argument cannot be a
  throwing expression. `nil` resolves to `defaultURL` inside the function.
- Both factories pass **`cloudKitDatabase: .none`** explicitly. Sync is cancelled (D1, §14) and
  the app has no CloudKit entitlement; stating it at the configuration means enabling one later
  cannot silently opt the store in. This argument cannot be asserted from the outside —
  `ModelConfiguration.CloudKitDatabase` is not `Equatable`, and its description exposes private
  stored properties (`CloudKitDatabase(_automatic: false, _none: true, _privateDBName: nil)`) that
  are not a stable contract. AC-4 is therefore tested one level up, against the entitlements file
  (§7 test 5), which is what the criterion actually says.

`models()` returns the five types registered in one `Schema`, built through a single
configuration. That shape is what keeps a future `VersionedSchema` purely additive — no migration
plan now, nothing here that makes one awkward.

---

## 4. App wiring and the failure scene

`StenoApp.init` builds the container once into a `Result<ModelContainer, Error>` and logs the
resolved path on success (`Log.app`). A store path is not a secret, so §8's redaction rule is not
engaged; knowing where the data went is worth a line in the unified log.

```swift
var body: some Scene {
    WindowGroup {
        switch container {
        case .success(let container): ContentView().modelContainer(container)
        case .failure(let error):     StoreFailureView(path: resolvedPath, error: error)
        }
    }
}
```

**Why a failure scene rather than `fatalError`, and rather than a fallback.** Apple's
`.modelContainer(for:)` traps on failure; that reads as a crash to anyone not watching stderr, and
a store that cannot open is exactly the situation where the reason matters most — a wrong path, a
permissions problem, a schema the file no longer matches. `StoreFailureView` names the path and
the underlying error on screen, with a Quit button, in about fifteen lines.

The tempting third option — fall back to `inMemory()` so the app still launches — is rejected. For
a capture tool, accepting writes that evaporate at quit is worse than not launching (§1.1): the
user would only discover the loss at the next stand-up, which is the one moment the product exists
to survive. §13's "degradation ships with the feature" is scoped to network-dependent features
(§7.4); it does not ask for a store that pretends to persist.

M0-05 inherits a root scene that is conditional on container construction. That is deliberate —
the alternative is M0-05 discovering the condition and retrofitting it.

---

## 5. Proving AC-1

The task's first acceptance criterion — "run the app, add a record, quit, relaunch" — cannot be
performed today: `ContentView` is a placeholder and all UI belongs to M0-05. Both halves ship:

**An automated round-trip** (`StoreDurability`) exercises the app's own code path: `live(at:)`
against a unique temp directory, insert a `Project`, `save()`, release the container, reopen at
the same URL, fetch, assert, remove the directory in teardown. The probe confirms this ordering
works — a released container's writes are visible to a fresh one.

**A throwaway affordance** in `ContentView`: a button inserting a sample `Project` and a count of
what is stored, enough to do the literal quit-and-relaunch check by hand. It carries a comment
naming M0-05 as its deletion point, it is listed in the PR body as temporary, and M0-05's task
already replaces this file wholesale.

> **Friction with AC-2, flagged rather than absorbed.** The criterion says "tests use an in-memory
> container and leave no artifacts on disk". A durability test necessarily writes a real file —
> that is the property under test. It is scoped to a unique temp directory and removed in
> teardown, so no artifact outlives the run and the user's real store is never opened. This reads
> AC-2's intent as "never touch the user's store", and says so in the PR body per CLAUDE.md's
> "when the spec is wrong" rule.

---

## 6. Closing M0-03's two-list drift

The task file inherits a defect: `stenoModelTypes()` in `StenoTests/Models/TestContainer.swift`
and `entityNames` in `StenoTests/Models/SchemaConformanceTests.swift` are two hard-coded lists
with nothing cross-checking them. A sixth model added to the first but not the second silently
skips every §6 and §3 conformance gate.

M0-03 could not fix this: the shipped list did not exist yet, and the fixture says so in a comment.
Now it does, so the fix is to delete both hard-coded lists:

- `stenoModelTypes()` is **deleted**; `inMemoryContainer()` becomes a thin call to
  `StenoStore.inMemory()`, and every conformance test builds its `Schema` from `StenoStore.models()`.
- `entityNames` becomes `Schema(StenoStore.models()).entities.map(\.name)`, with
  `#expect(Set(entityNames) == Set(expectedAttributes.keys))` asserting the transcribed §3 tables
  still describe exactly the shipped entities.

The result is one declaration of the schema, in the framework, checked against the spec tables.
A sixth model now either appears in both gates or fails the set-equality assertion.

---

## 7. Test plan

Swift Testing (D-011), in `StenoTests/Persistence/StenoStoreTests.swift` unless noted.

| # | Asserts | Substrate |
|---|---|---|
| 1 | **Durability (AC-1):** written → saved → container released → reopened at the same URL → record found | `live(at:)`, temp directory, removed in teardown |
| 2 | **Every model is registered:** the entity names of a container built by `live` equal the names of `models()`, and cover all five types | live container over a temp directory |
| 3 | **O-3 holds:** `defaultURL` resolves under `.applicationSupportDirectory` and ends in `Steno/Steno.store` | pure, no I/O beyond the lookup |
| 4 | **In-memory is in-memory (AC-2):** the test container's configuration reports `isStoredInMemoryOnly`, and its url is `/dev/null` | `inMemory()` |
| 5 | **No CloudKit entitlement (AC-4):** `Steno/Steno.entitlements` contains no `com.apple.developer.icloud…` key | the file itself, located from `#filePath` |
| 6 | **A missing parent directory is handled:** `live(at:)` succeeds when the parent does not exist, and the directory exists afterwards | temp path, one level deep |
| 7 | **Schema lists agree (§6):** `Set(entityNames) == Set(expectedAttributes.keys)` | `SchemaConformanceTests.swift` |

Tests 1, 2 and 6 write to disk. Each builds its own directory under `NSTemporaryDirectory()` keyed
by a fresh UUID and removes it in teardown; none reads `defaultURL` for anything but test 3's
assertion, so no test can open the user's store. Test 5 reads a repo file, which the `make test`
sandbox permits — D-012's profile denies outbound network, not filesystem reads.

### 7.1 What the tests do not cover

**Test 6 does not protect what §2 is actually about.** Core Data recovers from a missing parent
directory on its own, so deleting the `createDirectory` call leaves test 6 green — and produces
200 lines of stderr on first launch. What a test can see is that the container opens; what it
cannot see is how loudly. The guard is the code comment, the DECISIONS entry, and review.

Stated rather than glossed, following D-012's precedent of describing what a mechanism covers
rather than what a green run appears to prove.

**Nothing here tests migration**, because there is no live data and no second schema version. The
first real migration risk arrives when a field is added after the user has data (task file, and
§3's field tables are fresh as of M0-03).

---

## 8. Layout

| File | Change |
|---|---|
| `StenoKit/Persistence/StenoStore.swift` | **new** — §3 in full, ~80 lines |
| `Steno/App/StenoApp.swift` | builds the container in `init`, switches in `body` (§4) |
| `Steno/App/StoreFailureView.swift` | **new** — path, error, Quit |
| `Steno/App/ContentView.swift` | throwaway affordance (§5), deleted by M0-05 |
| `StenoTests/Persistence/StenoStoreTests.swift` | **new** — tests 1–6 |
| `StenoTests/Models/TestContainer.swift` | `stenoModelTypes()` deleted; delegates to `StenoStore` (§6) |
| `StenoTests/Models/SchemaConformanceTests.swift` | `entityNames` derived; set-equality assertion (§6) |

`Persistence/` matches ARCHITECTURE §5's declared layout. No `project.yml` change is needed —
both targets take whole directories as sources.

---

## 9. Risks, with responses decided in advance

**R1 — the `createDirectory` call looks redundant and gets deleted.** It is: Core Data recovers
without it. Response: the code comment states what it prevents and points at the probe evidence in
§2; DECISIONS carries the same. No test can catch its removal (§7.1).

**R2 — the durability test is flaky if the write has not landed when the store reopens.** Response:
an explicit `context.save()`, and the container reference dropped before the reopen. The probe
exercised exactly this ordering and the record was found. If it ever does flake, the finding is
about SwiftData's flush semantics and belongs in DECISIONS, not in a retry.

**R3 — the throwaway affordance survives into M0-05.** Response: a deletion note in the code, a
line in the PR body, and M0-05's task file already replaces `ContentView` entirely.

**R4 — a later task wants a second store (previews, a scratch import).** `live(at:)` already takes
a URL, so this needs no new API. Adding a second *stored* configuration would; that is a decision
for whoever needs it.

---

## 10. Out of scope

Per the task file, repeated because each is a plausible drift:

- **Any UI beyond §4's failure scene and §5's affordance** — M0-05.
- **Export, import, Replace mode** — M2.5. This task only names the directory they will wipe.
- **"Delete my data"** — §8, a later task; `storeDirectory` is its hook.
- **A migration plan** — deferred deliberately, with §3's single-schema shape keeping it additive.
- **CRUD helpers.** The task allows them "where the model layer needs them"; it does not. M0-03's
  mutation API plus `ModelContext` covers everything M0-05 needs, and helpers written before a
  caller exists are guesses.
- **Any CloudKit container or entitlement** (D1, §14) — actively asserted against by test 5.

---

## 11. What this lands beyond code

- **DECISIONS.md:** an entry closing **O-3** with §1's location and §1.1's directory rule, and an
  entry recording §4's fail-visible choice over `fatalError` and over an in-memory fallback. O-3
  leaves the open-questions table.
- **ARCHITECTURE.md:** `Persistence/` marked as landed.
- **`docs/tasks/README.md`:** M0-04 ticked, and M0-03's row — which shipped unticked — corrected.
- **PR body:** the AC-2 friction in §5; the temporary `ContentView` affordance; the §2 stderr
  finding, which is the kind of thing the next person will otherwise rediscover the hard way.