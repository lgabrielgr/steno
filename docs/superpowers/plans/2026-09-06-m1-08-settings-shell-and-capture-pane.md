# M1-08 Settings Shell & Capture Pane — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Settings window, its pane registry, and FR-6's Capture pane — hotkey binding,
launch at login, default project — wired to the three capabilities M1-03 and M1-04 shipped
without callers.

**Architecture:** A `SettingsPane` enum in `StenoKit` is the registry; `SettingsView` in `Steno/`
switches over it exhaustively, so a new case cannot compile into a tab that renders nothing. One
`SettingsModel` holds the shell's state, reaching the hotkey through a three-member
`HotkeyBinding` protocol rather than through `QuickCaptureModel` itself. `AppSettings` becomes the
single `UserDefaults` facade. The only code needing a window server is the chord recorder's event
plumbing — every rule it applies lives in `HotkeyChordValidator`, in the headless bundle.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Swift Testing, XcodeGen, SwiftLint (`--strict`),
swift-format. macOS 14.0 floor.

**Spec:** [`docs/superpowers/specs/2026-09-06-m1-08-settings-shell-and-capture-pane-design.md`](../specs/2026-09-06-m1-08-settings-shell-and-capture-pane-design.md)

## Global Constraints

- **Never commit to `main`.** Branch `feat/settings-shell-capture-pane` is already created, with
  the design committed on it as `af3e49b`. One PR; **do not merge it** (CLAUDE.md, §9.5).
- **`make build && make test && make lint` must all pass before the PR.** Verify, don't assert.
- **Nothing in this task writes an `Event` or adds a field to a domain model.** Every setting here
  is configuration and lives in `UserDefaults`; §10's export deliberately does not carry it.
- **Capture latency is untouched.** `defaultProjectID` is read once per `commit()`, never in
  `refreshChip()`. If a change puts a settings read on the per-keystroke path, that is the finding.
- **SwiftLint runs `--strict`** — every warning is an error. `file_length` caps files at **400
  lines**. `identifier_name` needs 3+ characters. `force_unwrapping` is enabled: use `try #require`,
  never `!`. `large_tuple` caps tuples at 2 members — hence the `Fixture` structs.
- **`function_parameter_count` ignores defaulted parameters.** Every parameter this plan adds to an
  existing initializer has a default, which is what keeps those initializers under the limit.
- **The loop is `make format && make lint`.** swift-format owns layout, SwiftLint owns semantics
  (D-013). When lint fails after formatting, restructure the code — do not add a disable comment.
- **Tests use `ModelContext(container)`, never `container.mainContext`.**
- **A `@Test` function taking a `private` type as a parameter must itself be `private`.**
- `make test` hides parameterized-test cases; the absence of per-case rows is not a failure.

All code in this plan was written into the real tree, built against all three targets, run, and
linted. **`make build` succeeded, `make test` reported 274 passing tests (37 of them new), and
`swiftlint --strict` reported 0 violations across 127 files, format-stable.** Where a step says
something compiles, it was built — not predicted.

---

## What changed from the spec, and why

Seven changes, all found by building the code rather than describing it.

1. **The spec missed modifier masking entirely, and it is the most serious thing here.**
   `NSEvent.modifierFlags` reports `.capsLock`, `.function` and `.numericPad` alongside the four
   modifiers a chord may carry — a laptop's arrow and function keys set `.function`, and caps lock
   sets `.capsLock` whenever it is on. `HotkeyChord` compares modifiers for **exact equality**,
   both against `SystemHotkeys`' reserved table and across its `Codable` round-trip. An unmasked
   recorded chord therefore never matches a system shortcut, so **FR-1.1's conflict warning would
   simply stop firing** — silently — and the chord would convert to a Carbon mask the user did not
   press. `HotkeyChordValidator.supported` masks; `extraneousFlagsAreStripped` guards it.
2. **`HotkeyChordValidator.Rejection` must conform to `Error`.** `Result`'s failure type requires
   it. Caught as a compile failure; nothing throws it, and the type's comment says so.
3. **`rebind(to:)` before `start(onPress:)` now registers nothing.** Without the guard the stored
   action is `nil` and the chord binds in front of a no-op — a live system-wide shortcut that
   swallows the keystroke and does nothing, which is worse than the unbound state it replaces.
4. **`HotkeyBinding` was not in the spec.** The spec had `SettingsModel` observe the app's
   `QuickCaptureModel` directly. A three-member protocol is a narrower seam — Settings has no
   business with the panel's capture field or project list — and it makes the test double four
   lines. `QuickCaptureModel` conforms with no additional code.
5. **`MainWindowModel` does not build its `CaptureFieldModel`; `NewTaskSheet` does, in `Steno/`.**
   So the main window is threaded through a new `defaultProjectIDForCapture` property, and the
   headless test asserts that property rather than a capture. The other two surfaces build their
   own field and are tested end-to-end through a real store.
6. **`FakeLoginItem` is internal, not private.** `SettingsModelTests` needs it, and a `private`
   type would also force every `@Test` taking it to be private.
7. **swift-format moves `[weak self] event in` onto its own line, which SwiftLint's
   `closure_parameter_position` then rejects** — the exact D-013 loop. Keep the closure signature
   on the brace line; at 98 characters it fits under the 100-column cap.

Two measured facts to carry into implementation:

- **`Project.isArchived` is `private(set)`.** Archive through `setArchived(_:at:)`, which is
  `internal` and reachable from the test bundle via `@testable`.
- **`HotkeyChord.keyNames` is built from sub-arrays through `Dictionary(uniqueKeysWithValues:)`,
  not one literal.** Both trap on a duplicate key; the literal form does not type-check in
  reasonable time at eighty entries.

---

## File structure

| File | Task | Responsibility |
|---|---|---|
| `StenoKit/Settings/AppSettings.swift` | 1 | **Create.** The single `UserDefaults` facade |
| `StenoKit/Features/Capture/QuickCaptureModel.swift` | 1, 2, 5 | **Amend.** Takes `AppSettings`; `rebind(to:)`; conforms to `HotkeyBinding` |
| `StenoKit/Support/LoginItem.swift` | 3 | **Amend.** `LoginItemStatus` replaces `isEnabled` |
| `StenoKit/Capture/HotkeyChord.swift` | 4 | **Amend.** `keyNames` grown to what a recorder emits |
| `StenoKit/Features/Settings/HotkeyChordValidator.swift` | 4 | **Create.** Masking and the two rejection rules |
| `StenoKit/Features/Settings/SettingsPane.swift` | 5 | **Create.** The pane registry |
| `StenoKit/Features/Settings/HotkeyBinding.swift` | 5 | **Create.** The three-member seam onto the hotkey |
| `StenoKit/Features/Settings/SettingsModel.swift` | 5 | **Create.** The shell model |
| `StenoKit/Features/Capture/CaptureFieldModel.swift` | 6 | **Amend.** `defaultProjectID` closure |
| `StenoKit/Features/MenuBar/MenuBarModel.swift` | 6 | **Amend.** Passes the default through |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | 6 | **Amend.** Holds `AppSettings` |
| `StenoKit/Features/MainWindow/MainWindowModel+Projects.swift` | 6 | **Amend.** `defaultProjectIDForCapture` |
| `Steno/Features/Capture/CaptureFieldView.swift` | 6 | **Amend.** `NewTaskSheet` passes the default |
| `Steno/Features/Settings/SettingsView.swift` | 7 | **Create.** `TabView` over the registry |
| `Steno/Features/Settings/CaptureSettingsPane.swift` | 7 | **Create.** The three controls |
| `Steno/Features/Settings/HotkeyRecorderView.swift` | 7 | **Create.** Event plumbing only |
| `Steno/Features/Capture/QuickCaptureController.swift` | 7 | **Amend.** Exposes `hotkeyBinding` |
| `Steno/App/StenoApp.swift` | 7 | **Amend.** Builds the model, adds the `Settings` scene |
| `StenoTests/Settings/AppSettingsTests.swift` | 1 | **Create.** 6 tests |
| `StenoTests/Features/Capture/QuickCaptureModelTests.swift` | 1, 2 | **Amend.** 3 new tests |
| `StenoTests/Support/LoginItemTests.swift` | 3 | **Amend.** `FakeLoginItem` + the approval test |
| `StenoTests/Capture/HotkeyChordTests.swift` | 4 | **Amend.** 2 table tests |
| `StenoTests/Settings/HotkeyChordValidatorTests.swift` | 4 | **Create.** 7 tests |
| `StenoTests/Settings/SettingsModelTests.swift` | 5 | **Create.** 13 tests |
| `StenoTests/Settings/DefaultProjectThreadingTests.swift` | 6 | **Create.** 5 tests |

`StenoKit/Settings/` is a new directory rather than a file under `Support/`. `Support/` holds
things with no feature of their own; Settings is a feature with four more panes coming.

XcodeGen picks the new directories up with no `project.yml` change — the targets use
`path: StenoKit` / `path: Steno` / `path: StenoTests` and take everything beneath.

**But run `make generate` (or `make test`) after creating the first file in a new directory,
before `make build`.** `test:` depends on `generate` unconditionally, so it always regenerates;
`build:` depends on the `.pbxproj` file target and only regenerates when `project.yml` is newer.
A new source file whose directory is not yet in the generated project is silently not compiled —
which looks like the file having no effect rather than like a build-system problem.

---

### Task 1: `AppSettings`, and the chord key moves into it

**Files:**
- Create: `StenoKit/Settings/AppSettings.swift`
- Modify: `StenoKit/Features/Capture/QuickCaptureModel.swift`
- Test: `StenoTests/Settings/AppSettingsTests.swift`, `StenoTests/Features/Capture/QuickCaptureModelTests.swift`

**Interfaces:**
- Produces: `AppSettings.init(defaults: UserDefaults = .standard)`; `AppSettings.hotkeyChord: HotkeyChord?`
  and `AppSettings.defaultProjectID: UUID?`, both with `nonmutating set`;
  `AppSettings.hotkeyChordKey` and `AppSettings.defaultProjectIDKey`.
  `QuickCaptureModel.init` takes `settings: AppSettings = AppSettings()` in place of
  `defaults: UserDefaults`. `QuickCaptureModel.chordKey` is **removed**.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Settings/AppSettingsTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import StenoKit

@MainActor
private func scratch() throws -> (AppSettings, UserDefaults) {
    // `try #require`, never `!` — `force_unwrapping` is an enabled opt-in rule
    // and `--strict` promotes it to a build failure.
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return (AppSettings(defaults: defaults), defaults)
}

@Test("an unset store reports both settings as absent")
@MainActor
func anUnsetStoreReportsAbsent() throws {
    let (settings, _) = try scratch()

    #expect(settings.hotkeyChord == nil)
    #expect(settings.defaultProjectID == nil)
}

@Test("the hotkey chord round-trips")
@MainActor
func theChordRoundTrips() throws {
    let (settings, _) = try scratch()
    let chord = HotkeyChord(keyCode: 40, modifiers: NSEvent.ModifierFlags.command.rawValue)

    settings.hotkeyChord = chord

    #expect(settings.hotkeyChord == chord)
}

@Test("the default project round-trips")
@MainActor
func theDefaultProjectRoundTrips() throws {
    let (settings, _) = try scratch()
    let projectID = UUID()

    settings.defaultProjectID = projectID

    #expect(settings.defaultProjectID == projectID)
}

@Test("clearing the default project removes it")
@MainActor
func clearingTheDefaultProjectRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.defaultProjectID = UUID()

    settings.defaultProjectID = nil

    #expect(settings.defaultProjectID == nil)
    #expect(defaults.string(forKey: AppSettings.defaultProjectIDKey) == nil)
}

/// The read must not trap on a value it did not write. `UserDefaults` is a
/// shared, user-editable store — `defaults write` is a supported thing for a
/// person to do — so a force-unwrapped `UUID(uuidString:)` here is a crash on
/// launch that no test of the happy path would ever find.
@Test("an unparseable default project reads as absent")
@MainActor
func anUnparseableDefaultProjectReadsAsAbsent() throws {
    let (settings, defaults) = try scratch()
    defaults.set("not-a-uuid", forKey: AppSettings.defaultProjectIDKey)

    #expect(settings.defaultProjectID == nil)
}

/// The posture M1-03 established for the chord and this type keeps: report a
/// bad value as absent, leave the bytes alone. The caller falls back to
/// `HotkeyChord.default` and the pane can still show what is really stored.
@Test("an undecodable chord reads as absent without being erased")
@MainActor
func anUndecodableChordIsNotErased() throws {
    let (settings, defaults) = try scratch()
    defaults.set(Data([0x01, 0x02]), forKey: AppSettings.hotkeyChordKey)

    #expect(settings.hotkeyChord == nil)
    #expect(defaults.data(forKey: AppSettings.hotkeyChordKey) == Data([0x01, 0x02]))
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `make test`
Expected: FAIL — `cannot find 'AppSettings' in scope`.

- [ ] **Step 3: Create `StenoKit/Settings/AppSettings.swift`**

```swift
import Foundation

/// Every `UserDefaults`-backed setting, declared in one place.
///
/// **`UserDefaults`, not SwiftData**, for the reason D-024 gives: these are
/// configuration, not domain data, so §10's export deliberately does not carry
/// them and M2.5-02's merge never has to reason about them.
///
/// **One type rather than a key per model.** M1-03 declared its own
/// `chordKey` on `QuickCaptureModel`, which was right when there was one
/// setting; FR-6 lists five Settings areas and four of them arrive with later
/// milestones. A codebase where every model declares its own key is one where
/// §10.3's "secrets are never exported" audit has no single place to look.
///
/// A `struct` with `nonmutating` setters, so an owner can hold it as a `let`
/// and still write through it — the store behind it is a reference type.
public struct AppSettings {
    /// FR-1.1's chord. Moved here from `QuickCaptureModel.chordKey`.
    public static let hotkeyChordKey = "com.lgabrielgr.steno.hotkeyChord"

    /// FR-6's default project — rung 4 of FR-1.4's ladder.
    public static let defaultProjectIDKey = "com.lgabrielgr.steno.defaultProjectID"

    private let defaults: UserDefaults

    /// - Parameter defaults: injected so tests use a scratch suite rather than
    ///   the developer's own preferences (§9.4).
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored chord, or `nil` when absent or undecodable.
    ///
    /// **A bad stored value is reported as absent, never overwritten.** The
    /// caller falls back to `HotkeyChord.default`, and the original bytes stay
    /// on disk so the Settings pane can still show what is actually in there —
    /// the posture M1-03's `storedChord()` already took.
    public var hotkeyChord: HotkeyChord? {
        get {
            guard let data = defaults.data(forKey: Self.hotkeyChordKey),
                let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue, let encoded = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.hotkeyChordKey)
                return
            }
            defaults.set(encoded, forKey: Self.hotkeyChordKey)
        }
    }

    /// FR-6's configured default project, or `nil` when unset or unparseable.
    ///
    /// Stored as a string rather than as `Data`: it is a single UUID, and a
    /// readable `defaults read` is worth more here than symmetry with the
    /// chord.
    ///
    /// **Whether the project still exists is not this type's question.**
    /// `ProjectRouter.route` already guards the rung with `live.contains`, so
    /// an archived or deleted default degrades to the next rung with no
    /// validation here and none at the call sites.
    public var defaultProjectID: UUID? {
        get {
            guard let raw = defaults.string(forKey: Self.defaultProjectIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.defaultProjectIDKey)
                return
            }
            defaults.set(newValue.uuidString, forKey: Self.defaultProjectIDKey)
        }
    }
}
```

- [ ] **Step 4: Point `QuickCaptureModel` at it**

Three edits, all inside Task 2's diff of the same file — apply that whole diff if you are doing
both tasks in one pass, or just these if not:

- `private let defaults: UserDefaults` → `private let settings: AppSettings`
- the initializer parameter `defaults: UserDefaults = .standard` → `settings: AppSettings = AppSettings()`
- `chord = storedChord()` → `chord = settings.hotkeyChord ?? .default`, then delete
  `storedChord()` and `public static let chordKey` entirely.

- [ ] **Step 5: Update `QuickCaptureModelTests` to the new spelling**

Five edits: `QuickCaptureModel.chordKey` → `AppSettings.hotkeyChordKey` (three occurrences), and
`defaults: defaults` → `settings: AppSettings(defaults: defaults)` (two initializer calls). The
scratch `UserDefaults(suiteName:)` suites stay exactly as they are — they are what `AppSettings`
now wraps.

- [ ] **Step 6: Run the tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Settings/AppSettings.swift StenoKit/Features/Capture/QuickCaptureModel.swift \
  StenoTests/Settings/AppSettingsTests.swift StenoTests/Features/Capture/QuickCaptureModelTests.swift
git commit -m "feat: one UserDefaults facade for FR-6's settings (M1-08)"
```

---

### Task 2: `rebind(to:)` keeps the hotkey working

**Files:**
- Modify: `StenoKit/Features/Capture/QuickCaptureModel.swift`
- Test: `StenoTests/Features/Capture/QuickCaptureModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings` from Task 1.
- Produces: `QuickCaptureModel.rebind(to: HotkeyChord)` — **no `onPress` parameter**.
  `start(onPress:)` stores the closure; the private `bind()` reuses it.

- [ ] **Step 1: Make the fake monitor keep the action**

In `StenoTests/Features/Capture/QuickCaptureModelTests.swift`, `FakeHotkeyMonitor` currently
discards `onPress`. Without keeping it, "rebinding keeps the hotkey working" is unprovable.

```swift
    /// Kept so a test can fire the action the model registered. Without this,
    /// "rebinding keeps the hotkey working" is unprovable here.
    var onPress: (() -> Void)?

    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        if let failure { throw failure }
        registered = chord
        self.onPress = onPress
    }
```

- [ ] **Step 2: Write the failing tests**

Append to the same file the three tests below, and change the existing
`rebindingReplacesTheChord`'s call from `model.rebind(to: replacement) {}` to
`model.rebind(to: replacement)`.

```swift
/// M1-08's first acceptance criterion, as far as a headless test reaches:
/// rebinding takes effect with no relaunch, and the action survives it.
///
/// The action surviving is the half that could silently break. `rebind(to:)`
/// re-registers using the closure `start` stored; drop that and the chord
/// still changes, the monitor still reports the new binding, and pressing it
/// does nothing.
@Test("rebinding keeps the registered action live")
@MainActor
func rebindingKeepsTheActionLive() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    var presses = 0
    model.start { presses += 1 }
    monitor.onPress?()
    #expect(presses == 1)

    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(monitor.registered == replacement)
    monitor.onPress?()
    #expect(presses == 2, "the action stored by start() must survive a rebind")
}

/// A chord bound in front of no action is worse than no chord: it swallows the
/// keystroke system-wide and does nothing.
@Test("rebinding before start registers nothing and says so")
@MainActor
func rebindingBeforeStartRegistersNothing() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(monitor.registered == nil)
    #expect(model.registrationProblem != nil)
}

/// The chord is persisted before registration is attempted, so a failure
/// leaves the user's choice recorded rather than silently reverting it.
@Test("a rebind that fails to register still persists the chosen chord")
@MainActor
func aFailedRebindStillPersistsTheChord() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    let monitor = FakeHotkeyMonitor()
    let model = QuickCaptureModel(
        context: ModelContext(try StenoStore.inMemory()), monitor: monitor, reserved: { [] },
        settings: settings, now: { epoch })
    model.start {}

    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement)

    #expect(model.registrationProblem == "That shortcut is already registered.")
    #expect(settings.hotkeyChord == replacement)
}
```

- [ ] **Step 3: Run and watch them fail**

Run: `make test`
Expected: FAIL — `extra trailing closure passed in call` on the old two-argument `rebind`.

- [ ] **Step 4: Apply the model change**

The full diff for `StenoKit/Features/Capture/QuickCaptureModel.swift`, Tasks 1 and 2 together:

```diff
@@ -11,73 +11,86 @@ import SwiftData
 /// it: `CaptureService` posts `.stenoDidWrite`, and any open main window
 /// reloads itself.
 @Observable
 @MainActor
-public final class QuickCaptureModel {
+public final class QuickCaptureModel: HotkeyBinding {
     /// The shared capture field — the same type the main window's sheet uses,
     /// so the FR-1.4 chip cannot drift between surfaces.
     public let field: CaptureFieldModel
 
     /// The chord currently bound.
     public private(set) var chord: HotkeyChord
 
-    /// A conflict or a registration failure, in words. M1-08's rebinding pane
-    /// renders this; M1-03 has no settings UI to put it in, so the property
-    /// *is* the attachment point (design §3.4).
+    /// A conflict or a registration failure, in words. M1-08's Capture pane
+    /// renders this; M1-03 had no settings UI to put it in, so the property
+    /// *was* the attachment point (design §3.4).
     public private(set) var registrationProblem: String?
 
-    /// Where the user's chord is stored. `UserDefaults`, not SwiftData: it is
-    /// configuration, not domain data, and §10's export carries the domain.
-    public static let chordKey = "com.lgabrielgr.steno.hotkeyChord"
+    /// What the hotkey does. Stored by `start` so `rebind(to:)` can re-register
+    /// without the caller having to supply it again.
+    ///
+    /// **This is why `rebind` takes a chord and nothing else.** The Settings
+    /// pane's business is *which chord*, not what pressing it does; had it
+    /// been obliged to pass the action, the settings layer would have to know
+    /// how `QuickCaptureController` toggles its panel, and the next pane
+    /// driving a controller would copy that. No retain cycle: the controller
+    /// passes `{ [weak self] in self?.toggle() }`.
+    private var onPress: (() -> Void)?
 
     private let context: ModelContext
     private let monitor: any GlobalHotkeyMonitor
     private let reserved: () -> [ReservedHotkey]
-    private let defaults: UserDefaults
+    private let settings: AppSettings
     private let projectBox: ProjectBox
 
     public init(
         context: ModelContext,
         monitor: any GlobalHotkeyMonitor,
         reserved: @escaping () -> [ReservedHotkey] = {
             SystemHotkeys.reserved(in: SystemHotkeys.systemDomain())
         },
-        defaults: UserDefaults = .standard,
+        settings: AppSettings = AppSettings(),
         now: @escaping () -> Date = Date.init,
         onCaptured: @escaping () -> Void = {}
     ) {
         let box = ProjectBox()
         self.projectBox = box
         self.context = context
         self.monitor = monitor
         self.reserved = reserved
-        self.defaults = defaults
+        self.settings = settings
         self.chord = .default
         self.field = CaptureFieldModel(
             service: CaptureService(context: context, now: now),
             projects: { box.projects },
             // The panel has no surface context to prefer — routing falls to
             // the ticket key, then last-used. `CaptureService`'s own
             // documentation specifies `nil` for exactly this surface.
             preferred: { nil },
+            // FR-6's configured default, rung 4 of FR-1.4's ladder. Read per
+            // commit, never per keystroke: `refreshChip` does not consult it,
+            // because the chip only ever displays a ticket-key match.
+            defaultProjectID: { settings.defaultProjectID },
             onCaptured: { _ in onCaptured() }
         )
     }
 
     /// Read the stored chord, check it, and bind it.
     public func start(onPress: @escaping () -> Void) {
-        chord = storedChord()
-        bind(onPress: onPress)
+        self.onPress = onPress
+        chord = settings.hotkeyChord ?? .default
+        bind()
     }
 
-    /// M1-08's entry point. Deliberately present from day one so that task
-    /// adds a pane rather than redesigning this type.
-    public func rebind(to replacement: HotkeyChord, onPress: @escaping () -> Void) {
+    /// M1-08's entry point: bind a different chord, with no relaunch.
+    ///
+    /// Persist first, then register, so a registration that fails still leaves
+    /// the user's choice recorded — the pane shows the problem and the chord
+    /// they picked rather than silently reverting to the old one.
+    public func rebind(to replacement: HotkeyChord) {
         chord = replacement
-        if let encoded = try? JSONEncoder().encode(replacement) {
-            defaults.set(encoded, forKey: Self.chordKey)
-        }
-        bind(onPress: onPress)
+        settings.hotkeyChord = replacement
+        bind()
     }
 
     /// Called on every open.
     ///
@@ -97,11 +110,21 @@ public final class QuickCaptureModel {
         // it re-derives here rather than waiting for the next character.
         field.refreshChip()
     }
 
-    private func bind(onPress: @escaping () -> Void) {
+    private func bind() {
         registrationProblem = nil
 
+        // Nothing has told this model what the hotkey does yet, so there is no
+        // action to register. Binding anyway would put a live system-wide
+        // chord in front of a no-op — a hotkey that swallows the keystroke and
+        // does nothing, which is worse than the unbound state it replaces.
+        guard let onPress else {
+            Log.app.error("hotkey bind requested before start(); nothing was registered")
+            registrationProblem = "The shortcut could not be registered."
+            return
+        }
+
         // Warn, then register anyway. Refusing to bind guarantees a dead
         // hotkey; binding a claimed chord leaves the user with one that may
         // still work plus an explanation if it does not. The failure FR-1.1
         // exists to prevent is silence, not registration.
@@ -125,17 +148,8 @@ public final class QuickCaptureModel {
                 "hotkey registration failed: \(String(describing: error), privacy: .public)")
         }
     }
 
-    /// A bad stored value falls back without being overwritten — M1-08's pane
-    /// will want to show the user what is actually in there.
-    private func storedChord() -> HotkeyChord {
-        guard let data = defaults.data(forKey: Self.chordKey),
-            let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data)
-        else { return .default }
-        return decoded
-    }
-
     private func liveProjects() -> [Project] {
         let descriptor = FetchDescriptor<Project>(
             predicate: #Predicate { !$0.isArchived },
             sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
```

> The `: HotkeyBinding` conformance in that diff belongs to Task 5. Working task-by-task, leave it
> off here — the file does not compile with it until `HotkeyBinding.swift` exists.

- [ ] **Step 5: Run the tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Features/Capture/QuickCaptureModel.swift \
  StenoTests/Features/Capture/QuickCaptureModelTests.swift
git commit -m "feat: rebind the hotkey without relaunch, reusing the stored action (M1-08)"
```

---

### Task 3: `LoginItem` reports a status, not a `Bool`

**Files:**
- Modify: `StenoKit/Support/LoginItem.swift`
- Test: `StenoTests/Support/LoginItemTests.swift`

**Interfaces:**
- Produces: `LoginItemStatus` (`.enabled`, `.notRegistered`, `.requiresApproval`, `.notFound`);
  `LoginItem.status: LoginItemStatus` replacing `isEnabled: Bool`; `FakeLoginItem` becomes
  **internal**, with a settable `statusAfterEnabling` that Task 5's tests use.

**Why:** `SMAppService.mainApp.register()` can succeed and leave the service at
`.requiresApproval` — macOS lists Steno under Login Items with its switch off, waiting for the
user. Read through a `Bool` that is indistinguishable from "off", with nothing thrown, so the
Settings toggle would flip itself back and say nothing.

- [ ] **Step 1: Rewrite the tests first**

```swift
import Testing

@testable import StenoKit

/// The double M1-08's Capture pane codes against.
///
/// The real `SystemLoginItem` is not exercised here: `SMAppService` registers
/// the *test runner's* bundle from an unhosted bundle, which is a side effect
/// on the developer's machine and not something a headless suite may do.
@MainActor
final class FakeLoginItem: LoginItem {
    private(set) var status: LoginItemStatus = .notRegistered
    var failure: (any Error)?

    /// What `status` becomes after a successful `enable()`.
    ///
    /// Settable so a test can reproduce the case this type exists for: macOS
    /// accepting the registration and then waiting for the user to approve it.
    var statusAfterEnabling: LoginItemStatus = .enabled

    func enable() throws {
        if let failure { throw failure }
        status = statusAfterEnabling
    }

    func disable() throws {
        if let failure { throw failure }
        status = .notRegistered
    }
}

@MainActor
@Test("the launch-at-login hook round-trips")
func theLoginItemHookRoundTrips() throws {
    let item: any LoginItem = FakeLoginItem()
    #expect(item.status == .notRegistered)

    try item.enable()
    #expect(item.status == .enabled)

    try item.disable()
    #expect(item.status == .notRegistered)
}

@MainActor
@Test("a failing registration throws rather than reporting success")
func aFailingLoginItemRegistrationThrows() throws {
    struct Denied: Error {}
    let item = FakeLoginItem()
    item.failure = Denied()

    #expect(throws: Denied.self) { try item.enable() }
    #expect(item.status == .notRegistered)
}

/// The state a `Bool` could not express, and the reason this protocol changed.
///
/// `register()` returns without throwing, and macOS still will not launch the
/// app until the user approves it in System Settings. Read as a `Bool` this is
/// indistinguishable from "off".
@MainActor
@Test("a registration awaiting approval is neither enabled nor a failure")
func aRegistrationCanAwaitApproval() throws {
    let item = FakeLoginItem()
    item.statusAfterEnabling = .requiresApproval

    try item.enable()

    #expect(item.status == .requiresApproval)
    #expect(item.status != .enabled)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `make test`
Expected: FAIL — `cannot find type 'LoginItemStatus' in scope`.

- [ ] **Step 3: Rewrite `StenoKit/Support/LoginItem.swift`**

```swift
import Foundation
import ServiceManagement

/// Where the app stands with macOS's login-item registry.
///
/// **This is an enum rather than the `Bool` D-041 shipped, and the difference
/// is a silent failure.** `SMAppService.mainApp.register()` can succeed and
/// leave the service at `.requiresApproval`: macOS lists Steno under Login
/// Items with its switch off, waiting for the user. Read through a
/// `isEnabled: Bool` that state is indistinguishable from "off", with nothing
/// thrown — so the Settings toggle would flip itself back and say nothing,
/// which is the failure §13 exists to design out and the same one FR-1.1's
/// conflict warning prevents for the hotkey.
public enum LoginItemStatus: Equatable, Sendable {
    /// Registered and live: Steno will launch at login.
    case enabled
    /// Not registered. The ordinary "off" state.
    case notRegistered
    /// Registered, but macOS is waiting for the user to approve it in
    /// System Settings › General › Login Items.
    case requiresApproval
    /// macOS cannot find the bundle to register — a relocated or deleted app.
    case notFound
}

/// FR-6's "launch at login", as a capability M1-08's Capture pane drives.
///
/// `@MainActor` because the only thing that drives it is a settings toggle,
/// and an isolated protocol lets the test double be a plain class with mutable
/// state.
@MainActor
public protocol LoginItem {
    /// What macOS currently reports. Re-read after every `enable()`/`disable()`
    /// rather than inferred from the call returning — see `LoginItemStatus`.
    var status: LoginItemStatus { get }
    func enable() throws
    func disable() throws
}

/// `LoginItem` over `SMAppService`, which is the supported route on macOS 13+.
///
/// A failure — an unsigned or relocated bundle, which a debug build run out of
/// `.build/` may well be — is thrown, never trapped, and the Capture pane
/// reports the thrown error verbatim rather than a generic message. That is
/// what lets a manual check tell "this build cannot register" apart from "this
/// feature is broken" (D-041).
public struct SystemLoginItem: LoginItem {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        // `SMAppService.Status` is an Objective-C enum, so a future OS may add
        // a case. Reporting it as "not registered" is the honest degradation:
        // the toggle reads off, and `enable()` remains available.
        @unknown default: return .notRegistered
        }
    }

    public func enable() throws {
        try SMAppService.mainApp.register()
    }

    public func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: PASS. Nothing else in the app referenced `isEnabled` — D-041 shipped this protocol with
no callers, which is exactly what makes the change cheap now.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Support/LoginItem.swift StenoTests/Support/LoginItemTests.swift
git commit -m "fix: report the login-item status so approval-pending is not silence (M1-08)"
```

---

### Task 4: The recorder's rules, and a key-name table worth showing

**Files:**
- Create: `StenoKit/Features/Settings/HotkeyChordValidator.swift`
- Modify: `StenoKit/Capture/HotkeyChord.swift`
- Test: `StenoTests/Settings/HotkeyChordValidatorTests.swift`, `StenoTests/Capture/HotkeyChordTests.swift`

**Interfaces:**
- Produces: `HotkeyChordValidator.validate(keyCode: UInt16, modifiers: UInt) -> Result<HotkeyChord, Rejection>`;
  `HotkeyChordValidator.isCancel(keyCode: UInt16) -> Bool`;
  `HotkeyChordValidator.Rejection` (`.noModifiers`, `.shiftOnly`, each with `.message`);
  `HotkeyChord.namedKeyCodes: [UInt16]`.

- [ ] **Step 1: Write the failing validator tests**

Create `StenoTests/Settings/HotkeyChordValidatorTests.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import Testing

@testable import StenoKit

@Test("a chord with a real modifier is accepted")
func aModifiedChordIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.option.rawValue)

    let chord = try #require(try? result.get())
    #expect(chord.keyCode == UInt16(kVK_ANSI_K))
    #expect(chord.displayString == "⌥K")
}

/// FR-1.1's own default must survive its validator.
@Test("the default chord is accepted")
func theDefaultChordIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: HotkeyChord.default.keyCode, modifiers: HotkeyChord.default.modifiers)

    #expect((try? result.get()) == HotkeyChord.default)
}

/// A bare key bound system-wide is swallowed in every application — including
/// whatever the user would type to get back to this pane and undo it.
@Test("a bare key is refused")
func aBareKeyIsRefused() {
    let result = HotkeyChordValidator.validate(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)

    #expect(result == .failure(.noModifiers))
}

@Test("shift alone is refused")
func shiftAloneIsRefused() {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.shift.rawValue)

    #expect(result == .failure(.shiftOnly))
}

@Test("shift with a real modifier is accepted")
func shiftWithARealModifierIsAccepted() throws {
    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_ANSI_K),
        modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)

    let chord = try #require(try? result.get())
    #expect(chord.displayString == "⇧⌘K")
}

/// The defect this masking exists to prevent is silent. `NSEvent` reports
/// `.function` on a laptop's arrow and function keys and `.capsLock` whenever
/// caps lock is on; `HotkeyChord` compares modifiers for exact equality, both
/// against `SystemHotkeys`' reserved table and across a `Codable` round-trip.
/// An unmasked chord therefore never matches a system shortcut — so FR-1.1's
/// conflict warning would simply stop firing — and converts to a Carbon mask
/// the user did not press.
@Test("device and lock flags are stripped")
func extraneousFlagsAreStripped() throws {
    let noisy = NSEvent.ModifierFlags([.option, .function, .capsLock, .numericPad])

    let result = HotkeyChordValidator.validate(
        keyCode: UInt16(kVK_Space), modifiers: noisy.rawValue)

    #expect((try? result.get()) == HotkeyChord.default)
}

@Test("escape cancels rather than binding")
func escapeCancels() {
    #expect(HotkeyChordValidator.isCancel(keyCode: UInt16(kVK_Escape)))
    #expect(!HotkeyChordValidator.isCancel(keyCode: UInt16(kVK_Space)))
}
```

- [ ] **Step 2: Write the failing table tests**

Append to `StenoTests/Capture/HotkeyChordTests.swift`, and add `import Carbon.HIToolbox` at the
top — the existing file imports only `AppKit`, `Foundation` and `Testing`:

```swift
/// The table M1-08's recorder made load-bearing.
///
/// Two properties, and both can break silently. A dropped row degrades that
/// key to `"Key 40"` in the pane the user just pressed it in; a duplicated
/// name makes two different chords read identically, so a conflict message
/// names a shortcut the user cannot find. Constructing `keyNames` also traps
/// on a duplicate *key*, so reaching the table at all is part of the check.
@Test("every named key code renders as itself, uniquely")
func namedKeyCodesRenderUniquely() {
    let names = HotkeyChord.namedKeyCodes.map { HotkeyChord.keyName(for: $0) }

    #expect(!names.isEmpty)
    for name in names {
        #expect(!name.isEmpty)
        #expect(!name.hasPrefix("Key "), "\(name) fell through to the unmapped fallback")
    }
    #expect(Set(names).count == names.count, "two key codes share a name")
}

/// The recorder can emit any code on the keyboard, and the letters and digits
/// are what a person actually picks.
@Test("the keys a person would choose all have names")
func theOrdinaryKeysAreNamed() {
    let named = Set(HotkeyChord.namedKeyCodes)
    for letter in [kVK_ANSI_A, kVK_ANSI_K, kVK_ANSI_Z] {
        #expect(named.contains(UInt16(letter)))
    }
    for digit in [kVK_ANSI_0, kVK_ANSI_9] {
        #expect(named.contains(UInt16(digit)))
    }
    #expect(named.contains(UInt16(kVK_F1)))
    #expect(named.contains(UInt16(kVK_Tab)))
}
```

- [ ] **Step 3: Run and watch them fail**

Run: `make test`
Expected: FAIL — `cannot find 'HotkeyChordValidator' in scope`, and
`type 'HotkeyChord' has no member 'namedKeyCodes'`.

- [ ] **Step 4: Create the validator**

```swift
import AppKit
import Carbon.HIToolbox
import Foundation

/// Whether a chord the user just pressed can be bound, and if not, why.
///
/// **All of the recorder's judgment lives here, in `StenoKit`.** The control
/// itself is an `NSView` with a local event monitor and cannot run in the
/// headless bundle (D-010); everything it decides can, so the only untestable
/// part left is the event plumbing.
public enum HotkeyChordValidator {
    /// Why a recorded chord was refused. Each case carries the sentence the
    /// pane shows — written for a person, the way
    /// `HotkeyRegistrationError.message` is.
    /// Conforms to `Error` because `Result`'s failure type must — not because
    /// a refused chord is an error condition. Nothing throws it.
    public enum Rejection: Error, Equatable, Sendable {
        /// A bare key with no modifiers.
        case noModifiers
        /// Shift and nothing else.
        case shiftOnly

        public var message: String {
            switch self {
            case .noModifiers:
                return "Add ⌃, ⌥ or ⌘ to make this a shortcut."
            case .shiftOnly:
                return "Shift on its own is not enough. Add ⌃, ⌥ or ⌘."
            }
        }
    }

    /// The four modifiers a chord may carry.
    ///
    /// **Masking is not cosmetic.** `NSEvent.modifierFlags` also reports
    /// `.capsLock`, `.function`, `.numericPad` and device-dependent left/right
    /// bits — an `⌥Space` pressed on a laptop can arrive with `.function` set.
    /// `HotkeyChord` compares modifiers for exact equality, both against
    /// `SystemHotkeys`' reserved table and in `Codable` round-trips, so an
    /// unmasked chord would silently never match a system shortcut and would
    /// convert to a different Carbon mask than the one the user pressed.
    static let supported: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    /// `Esc` cancels recording rather than binding.
    ///
    /// A consequence worth stating: no `Esc` chord is bindable at all. That is
    /// the platform norm, and `Esc` is the cancel affordance everywhere else
    /// in this app — `CaptureFieldView` and the note composer both use it.
    public static func isCancel(keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Escape)
    }

    /// Turn a recorded key press into a bindable chord.
    ///
    /// - Parameters:
    ///   - keyCode: the event's `keyCode`, a layout-independent virtual code.
    ///   - modifiers: the event's raw `modifierFlags.rawValue`, unmasked —
    ///     masking is this function's job, not its caller's.
    public static func validate(keyCode: UInt16, modifiers: UInt)
        -> Result<HotkeyChord, Rejection>
    {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers).intersection(supported)

        // A bare key bound globally is swallowed in every application, which
        // would make the user's keyboard unusable until they found this pane
        // again — and they would be typing without that key to reach it.
        guard !flags.isEmpty else { return .failure(.noModifiers) }

        // `⇧K` is not distinguishable from typing a capital K.
        guard flags != [.shift] else { return .failure(.shiftOnly) }

        return .success(HotkeyChord(keyCode: keyCode, modifiers: flags.rawValue))
    }
}
```

> `Rejection` conforms to `Error` because `Result`'s failure type must. Without it the build fails
> with `type 'HotkeyChordValidator.Rejection' does not conform to protocol 'Error'` — which is how
> this was found.

- [ ] **Step 5: Grow the key-name table**

```diff
@@ -57,26 +57,76 @@ public struct HotkeyChord: Equatable, Hashable, Codable, Sendable {
         if flags.contains(.command) { text += "⌘" }
         return text + Self.keyName(for: keyCode)
     }
 
-    /// Covers the keys the default chord and the conflict table actually use.
+    /// Every key a chord can name.
     ///
-    /// A table rather than a `switch`: twelve cases put the function over
-    /// SwiftLint's `cyclomatic_complexity` threshold of 10, which `--strict`
-    /// makes a build failure. It is also the better shape — this is data.
-    private static let keyNames: [Int: String] = [
-        kVK_Space: "Space",
-        kVK_Return: "Return",
-        kVK_LeftArrow: "←",
-        kVK_RightArrow: "→",
-        kVK_DownArrow: "↓",
-        kVK_UpArrow: "↑",
-        kVK_ANSI_3: "3",
-        kVK_ANSI_4: "4",
-        kVK_ANSI_5: "5",
-        kVK_ANSI_D: "D",
-        kVK_ANSI_Slash: "/",
-    ]
+    /// **Grown for M1-08's recorder.** Until then this covered only the
+    /// default chord and `SystemHotkeys`' conflict table — eleven codes, with
+    /// everything else degrading to `"Key 200"`. That degradation is right as
+    /// a fallback and wrong as the answer for a chord the user has just
+    /// pressed, and a recorder can emit any code on the keyboard. Extending
+    /// the table is what this type's shape was chosen for: **this is data, not
+    /// logic** — add a row rather than a special case in `keyName(for:)`.
+    ///
+    /// A table rather than a `switch` because a `switch` of this size is far
+    /// past SwiftLint's `cyclomatic_complexity` threshold of 10, which
+    /// `--strict` makes a build failure.
+    ///
+    /// `Dictionary(uniqueKeysWithValues:)` rather than a dictionary literal:
+    /// both trap on a duplicate key, but this one type-checks in reasonable
+    /// time at eighty entries where the literal does not. The trap is the
+    /// point — a duplicated row is a mistake, and `HotkeyChordTests` reaches
+    /// this table so the trap fires in the suite rather than in the app.
+    ///
+    /// **The names are ANSI-layout names.** On a non-ANSI layout a key can
+    /// display under its ANSI name. The *stored* chord is unaffected —
+    /// `keyCode` is a layout-independent virtual key code — so this is a
+    /// labelling imprecision, not a binding bug. Resolving names through
+    /// `UCKeyTranslate` would fix it and would make the result depend on the
+    /// machine running the suite, which §9.4 rules out.
+    private static let keyNames: [Int: String] = {
+        let letters: [(Int, String)] = [
+            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
+            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
+            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
+            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
+            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
+            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
+            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
+        ]
+        let digits: [(Int, String)] = [
+            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
+            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
+            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
+        ]
+        let punctuation: [(Int, String)] = [
+            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
+            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"),
+            (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","),
+            (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"), (kVK_ANSI_Grave, "`"),
+        ]
+        // Symbols where macOS's own menus use one, words where they do not.
+        let specials: [(Int, String)] = [
+            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"),
+            (kVK_ForwardDelete, "⌦"), (kVK_Escape, "⎋"), (kVK_Home, "↖"), (kVK_End, "↘"),
+            (kVK_PageUp, "⇞"), (kVK_PageDown, "⇟"), (kVK_Help, "Help"),
+            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"),
+            (kVK_DownArrow, "↓"),
+        ]
+        let functionKeys: [(Int, String)] = [
+            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
+            (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
+            (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"),
+            (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"),
+            (kVK_F19, "F19"), (kVK_F20, "F20"),
+        ]
+        return Dictionary(
+            uniqueKeysWithValues: letters + digits + punctuation + specials + functionKeys)
+    }()
+
+    /// Every key code the table names, for the test that guards it.
+    static var namedKeyCodes: [UInt16] { keyNames.keys.map { UInt16($0) } }
 
     /// An unmapped code degrades to a readable label rather than to empty
     /// text: a rebinding pane showing a bare `⌘` is worse than one showing
     /// `⌘Key 200`.
```

- [ ] **Step 6: Run the tests**

Run: `make test`
Expected: PASS. The existing `#expect(chord.displayString == "⌘Key 200")` still passes — every
`kVK_` constant is below 128, so code 200 stays unmapped and the fallback is still exercised.

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Features/Settings/HotkeyChordValidator.swift StenoKit/Capture/HotkeyChord.swift \
  StenoTests/Settings/HotkeyChordValidatorTests.swift StenoTests/Capture/HotkeyChordTests.swift
git commit -m "feat: validate and name recorded chords, masking device flags (M1-08)"
```

---

### Task 5: The pane registry and the shell model

**Files:**
- Create: `StenoKit/Features/Settings/SettingsPane.swift`,
  `StenoKit/Features/Settings/HotkeyBinding.swift`,
  `StenoKit/Features/Settings/SettingsModel.swift`
- Modify: `StenoKit/Features/Capture/QuickCaptureModel.swift` (one line: the conformance)
- Test: `StenoTests/Settings/SettingsModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (Task 1), `rebind(to:)` (Task 2), `LoginItemStatus` and `FakeLoginItem`
  (Task 3), `HotkeyChordValidator` (Task 4).
- Produces: `SettingsPane` (`.capture`, with `id`, `title`, `systemImage`);
  `HotkeyBinding` (`chord`, `registrationProblem`, `rebind(to:)`);
  `SettingsModel.init(settings:loginItem:hotkey:context:)` and its surface — `chord`,
  `hotkeyProblem`, `recorderRejection`, `record(keyCode:modifiers:)`, `resetHotkeyToDefault()`,
  `loginStatus`, `loginProblem`, `launchesAtLogin`, `setLaunchAtLogin(_:)`, `projects`,
  `defaultProjectID`, `resolvedDefaultProjectID`, `setDefaultProject(_:)`, `storeFailureNote`.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Settings/SettingsModelTests.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// The seam `SettingsModel` codes against, as four lines — which is the
/// argument for `HotkeyBinding` existing at all.
@MainActor
private final class FakeHotkeyBinding: HotkeyBinding {
    var chord: HotkeyChord = .default
    var registrationProblem: String?
    private(set) var rebindCount = 0

    func rebind(to chord: HotkeyChord) {
        self.chord = chord
        rebindCount += 1
    }
}

@MainActor
private struct Fixture {
    let model: SettingsModel
    let hotkey: FakeHotkeyBinding
    let login: FakeLoginItem
    let settings: AppSettings
    let context: ModelContext
    let payments: Project
    let hiring: Project
}

@MainActor
private func makeFixture() throws -> Fixture {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    let hotkey = FakeHotkeyBinding()
    let login = FakeLoginItem()
    let model = SettingsModel(
        settings: settings, loginItem: login, hotkey: hotkey, context: context)
    return Fixture(
        model: model, hotkey: hotkey, login: login, settings: settings, context: context,
        payments: payments, hiring: hiring)
}

// MARK: - Hotkey

@Test("recording a valid chord rebinds")
@MainActor
func recordingAValidChordRebinds() throws {
    let fixture = try makeFixture()

    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.control.rawValue)

    #expect(fixture.hotkey.rebindCount == 1)
    #expect(fixture.model.chord.displayString == "⌃K")
    #expect(fixture.model.recorderRejection == nil)
}

/// A refused chord must leave the working binding alone. Reporting the problem
/// *and* unbinding would take the user's shortcut away for a mistake.
@Test("recording a bare key changes nothing and explains why")
@MainActor
func recordingABareKeyChangesNothing() throws {
    let fixture = try makeFixture()

    fixture.model.record(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)

    #expect(fixture.hotkey.rebindCount == 0)
    #expect(fixture.model.chord == .default)
    #expect(fixture.model.recorderRejection == HotkeyChordValidator.Rejection.noModifiers.message)
}

@Test("a later valid recording clears the rejection")
@MainActor
func aValidRecordingClearsTheRejection() throws {
    let fixture = try makeFixture()
    fixture.model.record(keyCode: UInt16(kVK_ANSI_K), modifiers: 0)
    #expect(fixture.model.recorderRejection != nil)

    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.command.rawValue)

    #expect(fixture.model.recorderRejection == nil)
}

@Test("reset restores the FR-1.1 default")
@MainActor
func resetRestoresTheDefault() throws {
    let fixture = try makeFixture()
    fixture.model.record(
        keyCode: UInt16(kVK_ANSI_K), modifiers: NSEvent.ModifierFlags.command.rawValue)

    fixture.model.resetHotkeyToDefault()

    #expect(fixture.model.chord == .default)
}

/// One copy of the problem, read through the binding rather than mirrored —
/// so a conflict raised by a rebind cannot go stale here.
@Test("the binding's registration problem is what the pane shows")
@MainActor
func theRegistrationProblemComesFromTheBinding() throws {
    let fixture = try makeFixture()
    #expect(fixture.model.hotkeyProblem == nil)

    fixture.hotkey.registrationProblem = "That shortcut is already registered."

    #expect(fixture.model.hotkeyProblem == "That shortcut is already registered.")
}

// MARK: - Launch at login

@Test("enabling launch at login registers")
@MainActor
func enablingLaunchAtLoginRegisters() throws {
    let fixture = try makeFixture()

    fixture.model.setLaunchAtLogin(true)

    #expect(fixture.model.launchesAtLogin)
    #expect(fixture.model.loginProblem == nil)
}

/// D-041's untested case, and the reason `LoginItem` stopped being a `Bool`:
/// the call returns without throwing and the app still will not launch.
@Test("a registration awaiting approval is reported rather than shown as on")
@MainActor
func approvalPendingIsReported() throws {
    let fixture = try makeFixture()
    fixture.login.statusAfterEnabling = .requiresApproval

    fixture.model.setLaunchAtLogin(true)

    #expect(!fixture.model.launchesAtLogin)
    let problem = try #require(fixture.model.loginProblem)
    #expect(problem.contains("System Settings"))
}

/// The likely failure on a development machine: a debug build run out of
/// `.build/` is a relocated bundle and `SMAppService` refuses it (D-041).
/// Reporting the thrown error verbatim is what tells a manual check "this
/// build cannot register" apart from "this feature is broken".
@Test("a thrown registration failure is reported and the toggle stays off")
@MainActor
func aThrownRegistrationFailureIsReported() throws {
    struct Denied: LocalizedError {
        var errorDescription: String? { "the bundle has moved" }
    }
    let fixture = try makeFixture()
    fixture.login.failure = Denied()

    fixture.model.setLaunchAtLogin(true)

    #expect(!fixture.model.launchesAtLogin)
    let problem = try #require(fixture.model.loginProblem)
    #expect(problem.contains("the bundle has moved"))
}

@Test("a successful disable clears an earlier problem")
@MainActor
func aSuccessfulDisableClearsTheProblem() throws {
    let fixture = try makeFixture()
    fixture.login.statusAfterEnabling = .requiresApproval
    fixture.model.setLaunchAtLogin(true)
    #expect(fixture.model.loginProblem != nil)

    fixture.login.statusAfterEnabling = .enabled
    fixture.model.setLaunchAtLogin(false)

    #expect(fixture.model.loginProblem == nil)
    #expect(!fixture.model.launchesAtLogin)
}

// MARK: - Default project

@Test("the picker lists live projects and persists a choice")
@MainActor
func theDefaultProjectPersists() throws {
    let fixture = try makeFixture()
    #expect(fixture.model.projects.count == 2)

    fixture.model.setDefaultProject(fixture.hiring.id)

    #expect(fixture.model.resolvedDefaultProjectID == fixture.hiring.id)
    #expect(fixture.settings.defaultProjectID == fixture.hiring.id)
}

/// Archiving the chosen project must not silently discard the setting:
/// unarchiving it restores the choice. The picker shows "None" meanwhile,
/// which is what `resolvedDefaultProjectID` is for.
@Test("a default whose project is archived resolves to none without being erased")
@MainActor
func anArchivedDefaultResolvesToNone() throws {
    let fixture = try makeFixture()
    fixture.model.setDefaultProject(fixture.hiring.id)

    fixture.hiring.setArchived(true, at: epoch)
    try fixture.context.save()
    NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

    #expect(fixture.model.resolvedDefaultProjectID == nil)
    #expect(fixture.model.defaultProjectID == fixture.hiring.id)
    #expect(fixture.settings.defaultProjectID == fixture.hiring.id)
}

/// A project created in the main window while Settings is open reaches the
/// picker through `.stenoDidWrite`, without either type knowing the other.
@Test("a project created elsewhere appears in the picker")
@MainActor
func aProjectCreatedElsewhereAppears() throws {
    let fixture = try makeFixture()

    fixture.context.insert(
        Project(
            name: "Platform", colorHex: "#10B981", jiraProjectKeys: ["PLAT"],
            sortOrder: 2, modifiedAt: epoch))
    try fixture.context.save()
    NotificationCenter.default.post(name: .stenoDidWrite, object: nil)

    #expect(fixture.model.projects.count == 3)
}

// MARK: - Degradation

/// §13: a feature's degradation ships with it. With no store there is no panel
/// to bind a chord to and no project list — but launch at login has no store
/// dependency and must keep working.
@Test("with no store the pane degrades but launch at login still works")
@MainActor
func withNoStoreLaunchAtLoginStillWorks() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let login = FakeLoginItem()
    let model = SettingsModel(
        settings: AppSettings(defaults: defaults), loginItem: login, hotkey: nil, context: nil)

    #expect(model.storeFailureNote != nil)
    #expect(model.projects.isEmpty)
    #expect(model.chord == .default)

    model.setLaunchAtLogin(true)

    #expect(model.launchesAtLogin)
    #expect(model.loginProblem == nil)
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `make test`
Expected: FAIL — `cannot find type 'HotkeyBinding' in scope`.

- [ ] **Step 3: Create the registry**

```swift
import Foundation

/// The Settings window's panes, in display order.
///
/// **This enum is the extensibility mechanism M1-08 exists to build.** FR-6
/// lists five Settings areas that land across four milestones; building the
/// shell once, here, is what stops M3-04, M4-04 and M6-01 from each inventing
/// a window structure. Adding a pane is one case below, one arm in
/// `SettingsView`'s switch, and one new view file. **No existing pane is
/// opened, and no pane knows another exists.**
///
/// The commented cases are not a wish list — they are the sketch M1-08's
/// fourth acceptance criterion asks for, naming the task that adds each one.
///
/// It lives in `StenoKit` rather than beside the views because pane titles,
/// symbols and ordering are data a headless test can read, while `TabView`
/// construction is not (D-010).
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case capture
    // case ai           — M3-04: provider, Keychain-backed key, model picker
    // case integrations — M4-04: Atlassian site, credentials, MCP servers
    // case stale        — M6-01: the global default N in days
    // case data         — M2.5: export as JSON, purge cached external data

    public var id: String { rawValue }

    /// The tab's label.
    public var title: String {
        switch self {
        case .capture: return "Capture"
        }
    }

    /// The tab's SF Symbol.
    public var systemImage: String {
        switch self {
        case .capture: return "keyboard"
        }
    }
}
```

- [ ] **Step 4: Create the seam**

```swift
import Foundation

/// What Settings needs from whatever owns the global hotkey.
///
/// **Three members, deliberately.** `SettingsModel` could hold a
/// `QuickCaptureModel` directly — both are view models in the same module —
/// but then the Settings layer would depend on the capture panel's state, its
/// project list and its capture field, none of which it has any business
/// knowing about. This is the seam, and it is narrow enough that a test double
/// is four lines.
///
/// `QuickCaptureModel` conforms with no additional code: it already has all
/// three.
@MainActor
public protocol HotkeyBinding: AnyObject {
    /// The chord currently bound.
    var chord: HotkeyChord { get }

    /// A conflict or registration failure, in words, or `nil`.
    var registrationProblem: String? { get }

    /// Bind a different chord, taking effect immediately.
    func rebind(to chord: HotkeyChord)
}
```

- [ ] **Step 5: Conform `QuickCaptureModel`**

One line — it already has all three members:

```swift
public final class QuickCaptureModel: HotkeyBinding {
```

- [ ] **Step 6: Create the shell model**

```swift
import Foundation
import SwiftData

/// What the Settings window's Capture pane binds to.
///
/// **Everything the pane decides lives here, in `StenoKit`.** ARCHITECTURE §2
/// rule 2 puts view models between views and the store on testability grounds,
/// and `@AppStorage` in the pane would have put FR-6's state in `Steno/`, where
/// the headless bundle cannot reach it — a mistake each of the four later panes
/// would then have inherited.
///
/// **Built once in `StenoApp.init` and held for the process,** the posture
/// `QuickCaptureController` and `MenuBarController` already establish. The
/// `Settings` scene's content is rebuilt freely by SwiftUI; the state behind it
/// is not.
///
/// Every dependency is injected and nothing is constructed internally, so the
/// whole type is exercisable with fakes and a scratch defaults suite (§9.4).
@Observable
@MainActor
public final class SettingsModel {
    // MARK: Hotkey

    /// The chord currently bound, and any conflict or registration failure —
    /// both read straight from the binding rather than mirrored, so there is
    /// one copy of each.
    public var chord: HotkeyChord { hotkey?.chord ?? .default }
    public var hotkeyProblem: String? { hotkey?.registrationProblem }

    /// Why the last recorded chord was refused, if it was. Cleared by the next
    /// successful recording.
    public private(set) var recorderRejection: String?

    // MARK: Launch at login

    public private(set) var loginStatus: LoginItemStatus
    public private(set) var loginProblem: String?

    /// What the toggle shows. Derived from the status macOS reports, never
    /// from the fact that a call returned — see `LoginItemStatus`.
    public var launchesAtLogin: Bool { loginStatus == .enabled }

    // MARK: Default project

    /// Live, non-archived projects, for the picker.
    public private(set) var projects: [Project] = []

    /// The stored default. `nil` when unset.
    public private(set) var defaultProjectID: UUID?

    /// What the picker should show selected.
    ///
    /// A stored default whose project has been archived or deleted resolves to
    /// `nil` here, so the picker reads "None" rather than showing an empty row
    /// — **but the stored value is left alone**, so unarchiving the project
    /// restores the setting. That is the posture M1-03 took with an
    /// undecodable chord, and it is why `AppSettings` does no validation.
    public var resolvedDefaultProjectID: UUID? {
        guard let defaultProjectID,
            projects.contains(where: { $0.id == defaultProjectID })
        else { return nil }
        return defaultProjectID
    }

    // MARK: Availability

    /// Set when the store could not be opened, in which case there is no
    /// capture panel to bind a chord to and no project list to choose from.
    ///
    /// Launch at login is unaffected and stays live — it has no store
    /// dependency, and §13 requires a feature's degradation to ship with it
    /// rather than after it.
    public var storeFailureNote: String? {
        hotkey == nil
            ? "Steno could not open its data store, so the shortcut and the default project are unavailable."
            : nil
    }

    private let settings: AppSettings
    private let loginItem: any LoginItem
    private let hotkey: (any HotkeyBinding)?
    private let context: ModelContext?
    private var writeObservation: WriteObservation?

    /// - Parameters:
    ///   - hotkey: `nil` when the store failed to open, because `StenoApp`
    ///     builds no `QuickCaptureController` in that case (D-018).
    ///   - context: `nil` for the same reason.
    public init(
        settings: AppSettings = AppSettings(),
        loginItem: any LoginItem = SystemLoginItem(),
        hotkey: (any HotkeyBinding)? = nil,
        context: ModelContext? = nil
    ) {
        self.settings = settings
        self.loginItem = loginItem
        self.hotkey = hotkey
        self.context = context
        self.loginStatus = loginItem.status
        self.defaultProjectID = settings.defaultProjectID
        reloadProjects()

        // Registered last: `self` may only be captured once every stored
        // property has a value. A project created in the main window while
        // Settings is open reaches the picker through this, without either
        // type knowing the other exists — the same route M1-03 and M1-04 use.
        writeObservation = WriteObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidWrite, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadProjects() }
            })
    }

    // MARK: - Hotkey

    /// Bind a chord the recorder produced.
    ///
    /// Validation happens here rather than in the recorder so the rules are
    /// testable without a window server. A rejected chord changes nothing —
    /// the old binding stays live while the message explains why.
    public func record(keyCode: UInt16, modifiers: UInt) {
        switch HotkeyChordValidator.validate(keyCode: keyCode, modifiers: modifiers) {
        case .success(let recorded):
            recorderRejection = nil
            hotkey?.rebind(to: recorded)
        case .failure(let rejection):
            recorderRejection = rejection.message
        }
    }

    /// Restore FR-1.1's `⌥Space`.
    public func resetHotkeyToDefault() {
        recorderRejection = nil
        hotkey?.rebind(to: .default)
    }

    // MARK: - Launch at login

    /// Register or unregister, then report what macOS actually says.
    ///
    /// **The status is re-read rather than assumed from the call returning.**
    /// `register()` can succeed into `.requiresApproval`, and a toggle that
    /// trusted the call would show "on" for an app that will not launch.
    public func setLaunchAtLogin(_ enabled: Bool) {
        loginProblem = nil
        do {
            if enabled {
                try loginItem.enable()
            } else {
                try loginItem.disable()
            }
        } catch {
            // Verbatim, not a generic message. On a development machine the
            // likely failure is a relocated bundle run out of `.build/`, and
            // saying so is what tells a manual check "this build cannot
            // register" apart from "this feature is broken" (D-041).
            loginProblem = "macOS refused: \(error.localizedDescription)"
        }

        loginStatus = loginItem.status
        if loginProblem == nil {
            loginProblem = note(for: loginStatus, afterEnabling: enabled)
        }
    }

    /// The sentence a status deserves once the call itself did not throw.
    private func note(for status: LoginItemStatus, afterEnabling enabled: Bool) -> String? {
        switch status {
        case .requiresApproval:
            return
                "Steno is registered, but macOS needs you to approve it in System Settings › General › Login Items."
        case .notFound:
            return "macOS could not find Steno to register. Move it to Applications and try again."
        case .notRegistered where enabled:
            return "macOS did not register Steno for launch at login."
        case .enabled, .notRegistered:
            return nil
        }
    }

    // MARK: - Default project

    public func setDefaultProject(_ projectID: UUID?) {
        defaultProjectID = projectID
        settings.defaultProjectID = projectID
    }

    /// Refetch the picker's options.
    ///
    /// A failure leaves the list empty and is logged rather than surfaced: an
    /// empty picker offering only "None" is a legible degradation, and
    /// Settings is not a place to report a store problem the main window is
    /// already reporting.
    private func reloadProjects() {
        guard let context else { return }
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        do {
            projects = try context.fetch(descriptor)
        } catch {
            projects = []
            Log.app.error(
                "could not load projects for Settings: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add StenoKit/Features/Settings/ StenoKit/Features/Capture/QuickCaptureModel.swift \
  StenoTests/Settings/SettingsModelTests.swift
git commit -m "feat: Settings pane registry and shell model (M1-08)"
```

---

### Task 6: FR-6's default project reaches all three capture surfaces

**Files:**
- Modify: `StenoKit/Features/Capture/CaptureFieldModel.swift`,
  `StenoKit/Features/MenuBar/MenuBarModel.swift`,
  `StenoKit/Features/MainWindow/MainWindowModel.swift`,
  `StenoKit/Features/MainWindow/MainWindowModel+Projects.swift`,
  `Steno/Features/Capture/CaptureFieldView.swift`
- Test: `StenoTests/Settings/DefaultProjectThreadingTests.swift`

**Interfaces:**
- Consumes: `AppSettings` (Task 1).
- Produces: `CaptureFieldModel.init(..., defaultProjectID: @escaping () -> UUID? = { nil }, ...)`;
  `MenuBarModel.init(..., settings: AppSettings = AppSettings())`;
  `MainWindowModel.init(..., settings: AppSettings = AppSettings())`;
  `MainWindowModel.defaultProjectIDForCapture: UUID?`.

**What is already covered, and what is not.** `ProjectRouterTests` proves the ladder as a pure
function, including `configuredDefaultIsRungFour` and a default naming a vanished project. What
nothing covers is the **wiring** — that each surface actually passes the setting down. That is
this task's whole subject, and it is what M1-02 left as a `nil` argument.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Settings/DefaultProjectThreadingTests.swift`:

```swift
import AppKit
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

/// FR-1.4's ladder is already covered as a pure function by
/// `ProjectRouterTests`. **What these tests cover is the wiring**: that each
/// capture surface actually passes FR-6's configured default down to
/// `CaptureService`, which is the thing M1-02 left as a `nil` argument and
/// M1-08 fills in.
///
/// The fixture is built so the default is the only thing that can decide the
/// outcome. Two live projects, no ticket key in the text, no prior task — so
/// rung 1 (ticket key), rung 2 (surface preference) and rung 3 (last-used) all
/// miss. Drop the `defaultProjectID:` argument from any one surface and that
/// surface routes to Payments, the lowest `sortOrder`, by rung 5.
@MainActor
private struct Surfaces {
    let context: ModelContext
    let settings: AppSettings
    let payments: Project
    let hiring: Project
}

@MainActor
private func makeSurfaces(defaultProject: (Project) -> UUID?) throws -> Surfaces {
    let context = ModelContext(try StenoStore.inMemory())
    let payments = Project(
        name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
        sortOrder: 0, modifiedAt: epoch)
    let hiring = Project(
        name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
        sortOrder: 1, modifiedAt: epoch)
    context.insert(payments)
    context.insert(hiring)
    try context.save()

    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    settings.defaultProjectID = defaultProject(hiring)
    return Surfaces(context: context, settings: settings, payments: payments, hiring: hiring)
}

@MainActor
private func onlyTask(in context: ModelContext) throws -> TaskItem {
    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    return try #require(tasks.first)
}

@Test("the floating panel captures to the configured default")
@MainActor
func theFloatingPanelUsesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.hiring.id)
}

@Test("the menu bar popover captures to the configured default")
@MainActor
func theMenuBarPopoverUsesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = MenuBarModel(
        context: surfaces.context, now: { epoch }, settings: surfaces.settings)
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.hiring.id)
}

/// The main window builds its `CaptureFieldModel` in `NewTaskSheet`, which is
/// a view — so what a headless test can reach is the property that view reads.
@Test("the main window exposes the configured default to its capture sheet")
@MainActor
func theMainWindowExposesTheConfiguredDefault() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    let model = MainWindowModel(
        context: surfaces.context, now: { epoch }, settings: surfaces.settings)

    #expect(model.defaultProjectIDForCapture == surfaces.hiring.id)
}

/// With no default configured the ladder falls through to the first project,
/// which is what makes the three tests above discriminating rather than
/// tautological: this is the answer they would give if the wiring were absent.
@Test("with no configured default the capture falls through to the first project")
@MainActor
func withNoDefaultTheCaptureFallsThrough() throws {
    let surfaces = try makeSurfaces(defaultProject: { _ in nil })
    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.payments.id)
}

/// A default pointing at an archived project must not strand the capture:
/// `ProjectRouter` drops the rung and the next one answers.
@Test("a default naming an archived project falls through rather than routing there")
@MainActor
func anArchivedDefaultFallsThrough() throws {
    let surfaces = try makeSurfaces(defaultProject: { $0.id })
    surfaces.hiring.setArchived(true, at: epoch)
    try surfaces.context.save()

    let model = QuickCaptureModel(
        context: surfaces.context, monitor: NullHotkeyMonitor(), reserved: { [] },
        settings: surfaces.settings, now: { epoch })
    model.prepareForShow()

    model.field.text = "write the migration note"
    model.field.commit()

    #expect(try onlyTask(in: surfaces.context).projectID == surfaces.payments.id)
}

/// Registers nothing: these tests are about routing, not about the hotkey.
@MainActor
private final class NullHotkeyMonitor: GlobalHotkeyMonitor {
    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {}
    func unregister() {}
}
```

> The fixture is built so the configured default is the only thing that can decide the outcome:
> two live projects, no ticket key in the text, no prior task. `withNoDefaultTheCaptureFallsThrough`
> is what makes the others discriminating rather than tautological — it pins the answer they would
> give if the wiring were absent.

- [ ] **Step 2: Run and watch them fail**

Run: `make test`
Expected: FAIL — `extra argument 'settings' in call` on `MenuBarModel` and `MainWindowModel`.

- [ ] **Step 3: Apply the four model changes**

```diff
@@ -41,19 +41,30 @@ public final class CaptureFieldModel {
 
     private let service: CaptureService
     private let projects: () -> [Project]
     private let preferred: () -> UUID?
+    private let defaultProjectID: () -> UUID?
     private let onCaptured: (TaskItem) -> Void
 
+    /// - Parameter defaultProjectID: FR-6's configured default — rung 4 of
+    ///   FR-1.4's ladder, below last-used. A closure like its neighbours,
+    ///   because the setting can change while a field is open: the Settings
+    ///   window and a capture surface can both be on screen at once.
+    ///
+    ///   Defaulted to `{ nil }` so a surface that has no settings to consult —
+    ///   every test that does not care, and any future surface — is not forced
+    ///   to invent one.
     public init(
         service: CaptureService,
         projects: @escaping () -> [Project],
         preferred: @escaping () -> UUID? = { nil },
+        defaultProjectID: @escaping () -> UUID? = { nil },
         onCaptured: @escaping (TaskItem) -> Void = { _ in }
     ) {
         self.service = service
         self.projects = projects
         self.preferred = preferred
+        self.defaultProjectID = defaultProjectID
         self.onCaptured = onCaptured
     }
 
     /// Decline the auto-assignment the chip is showing.
@@ -79,11 +90,17 @@ public final class CaptureFieldModel {
     /// Never throws: a capture surface has nowhere useful to propagate an
     /// error to, so a failure becomes `lastError` and the text is kept.
     public func commit() {
         do {
+            // Read once, here, and deliberately not in `refreshChip()`. The
+            // chip is derived from a ticket-key match alone and never displays
+            // a configured default, so there is no path where the UI promises
+            // one project and the save writes another — and §1.1's
+            // per-keystroke budget is untouched.
             if let task = try service.capture(
                 text: text,
                 preferred: preferred(),
+                defaultProjectID: defaultProjectID(),
                 ignoringTicketKey: isCurrentMatchDismissed()
             ) {
                 onCaptured(task)
             }
@@ -88,9 +88,10 @@ public final class MenuBarModel {
     public init(
         context: ModelContext,
         now: @escaping () -> Date = Date.init,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() },
-        failFetch: @escaping () throws -> Void = {}
+        failFetch: @escaping () throws -> Void = {},
+        settings: AppSettings = AppSettings()
     ) {
         let box = ProjectBox()
         self.projectBox = box
         self.context = context
@@ -102,9 +103,12 @@ public final class MenuBarModel {
             projects: { box.projects },
             // The popover has no surface context to prefer, so FR-1.4's ladder
             // falls through to the ticket key and then to last-used.
             // `CaptureService.capture` names this surface explicitly.
-            preferred: { nil }
+            preferred: { nil },
+            // FR-6's configured default, rung 4. Read per commit, not per
+            // keystroke — see `CaptureFieldModel.commit`.
+            defaultProjectID: { settings.defaultProjectID }
             // No `onCaptured:` hook. Nothing here needs one: the list refresh
             // arrives through the `.stenoDidWrite` observer below, and the
             // popover is closed by `CaptureFieldView.commit()` calling its
             // `onDismiss`, which is the controller's own closure.
@@ -89,8 +89,14 @@ public final class MainWindowModel: MainWindowActions {
     let context: ModelContext
     let now: () -> Date
     let save: (ModelContext) throws -> Void
 
+    /// FR-6's settings, reached by the capture sheet through
+    /// `defaultProjectIDForCapture`. Held rather than read at the call site so
+    /// a test can supply a scratch suite instead of the developer's own
+    /// preferences (§9.4).
+    let settings: AppSettings
+
     /// Kept alive so the observation lives exactly as long as this model. See
     /// `WriteObservation` for why the token is not a plain stored property.
     private var writeObservation: WriteObservation?
 
@@ -99,13 +105,15 @@ public final class MainWindowModel: MainWindowActions {
     /// — a real `ModelContext` cannot be made to fail its save on demand.
     public init(
         context: ModelContext,
         now: @escaping () -> Date = Date.init,
-        save: @escaping (ModelContext) throws -> Void = { try $0.save() }
+        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
+        settings: AppSettings = AppSettings()
     ) {
         self.context = context
         self.now = now
         self.save = save
+        self.settings = settings
         self.noteComposer = NoteComposerModel(
             service: NoteService(context: context, now: now, save: save), now: now)
         reload()
 
@@ -17,8 +17,16 @@ extension MainWindowModel {
 
     /// FR-1.4 rung 2, exposed for the capture sheet. See `preferredProjectID`.
     public var preferredProjectIDForCapture: UUID? { preferredProjectID() }
 
+    /// FR-1.4 rung 4 — FR-6's configured default — exposed for the same sheet.
+    ///
+    /// A computed property rather than a stored value: `NewTaskSheet` builds
+    /// its `CaptureFieldModel` once per presentation and reads through this on
+    /// commit, so a default changed in Settings while the sheet is open is the
+    /// one that applies.
+    public var defaultProjectIDForCapture: UUID? { settings.defaultProjectID }
+
     public func createProject(named name: String) {
         let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
         guard !trimmed.isEmpty else { return }
 
```

- [ ] **Step 4: Thread the main window's sheet**

```diff
@@ -183,8 +183,9 @@ struct NewTaskSheet: View {
             initialValue: CaptureFieldModel(
                 service: model.captureService(),
                 projects: { model.projects },
                 preferred: { model.preferredProjectIDForCapture },
+                defaultProjectID: { model.defaultProjectIDForCapture },
                 onCaptured: { _ in model.reload() }
             )
         )
     }
```

- [ ] **Step 5: Run the tests**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Features/Capture/CaptureFieldModel.swift StenoKit/Features/MenuBar/MenuBarModel.swift \
  StenoKit/Features/MainWindow/MainWindowModel.swift \
  StenoKit/Features/MainWindow/MainWindowModel+Projects.swift \
  Steno/Features/Capture/CaptureFieldView.swift StenoTests/Settings/DefaultProjectThreadingTests.swift
git commit -m "feat: FR-6's default project reaches all three capture surfaces (M1-08)"
```

---

### Task 7: The window, the pane, and the recorder

**Files:**
- Create: `Steno/Features/Settings/SettingsView.swift`,
  `Steno/Features/Settings/CaptureSettingsPane.swift`,
  `Steno/Features/Settings/HotkeyRecorderView.swift`
- Modify: `Steno/Features/Capture/QuickCaptureController.swift`, `Steno/App/StenoApp.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `QuickCaptureController.hotkeyBinding: any HotkeyBinding`; a `Settings` scene.

**No unit tests in this task, and that is the design working.** Everything these files decide was
decided and tested in `StenoKit`; what remains is `TabView` construction and `NSEvent` plumbing,
which D-010 puts beyond the headless bundle. The manual checklist at the end covers them.

- [ ] **Step 1: The recorder**

```swift
import AppKit
import Carbon.HIToolbox
import StenoKit
import SwiftUI

/// The click-then-press control that captures a chord.
///
/// **All of its judgment is elsewhere.** `HotkeyChordValidator` decides what a
/// recorded press means and `SettingsModel.record` acts on it; this type is
/// only the event plumbing, which is the part D-010 puts beyond the headless
/// bundle. Keeping the split that sharp is what makes "a bare key is refused"
/// a unit test rather than a manual check.
struct HotkeyRecorderView: NSViewRepresentable {
    /// The current chord, as `HotkeyChord.displayString` renders it.
    let display: String

    /// Raw `keyCode` and unmasked `modifierFlags.rawValue`. Masking is the
    /// validator's job — see `HotkeyChordValidator.supported`.
    let onRecord: (UInt16, UInt) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderControl {
        let control = HotkeyRecorderControl()
        control.onRecord = onRecord
        control.display = display
        return control
    }

    func updateNSView(_ nsView: HotkeyRecorderControl, context: Context) {
        nsView.onRecord = onRecord
        nsView.display = display
    }
}

/// A button that, while armed, swallows the next key press and reports it.
///
/// **A *local* monitor, not a global one.** Recording only needs events
/// delivered to this application, and a global monitor would require
/// Accessibility permission — the dependency `CarbonHotkeyMonitor`'s own
/// documentation explains M1-03 avoided, and the reason Steno ships no
/// permissions UI. If recording ever raises a permission prompt, that is a
/// defect here, not a step to add to onboarding.
final class HotkeyRecorderControl: NSButton {
    var onRecord: ((UInt16, UInt) -> Void)?

    var display: String = "" {
        didSet { refreshTitle() }
    }

    /// Holds the monitor while armed. Assigning `nil` removes it, because the
    /// token's `deinit` is what calls `NSEvent.removeMonitor`.
    private var recording: LocalMonitorToken? {
        didSet { refreshTitle() }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HotkeyRecorderControl is created in code, never from a nib")
    }

    private func refreshTitle() {
        title = recording == nil ? display : "Press a shortcut…"
    }

    @objc private func toggleRecording() {
        guard recording == nil else {
            recording = nil
            return
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording != nil else { return event }

            // `Esc` cancels rather than binding — so no `Esc` chord is
            // bindable at all, which is the platform norm and matches every
            // other `Esc` in this app.
            if HotkeyChordValidator.isCancel(keyCode: event.keyCode) {
                self.recording = nil
                return nil
            }

            self.onRecord?(event.keyCode, event.modifierFlags.rawValue)
            self.recording = nil

            // Swallowed: the press was a binding gesture, and letting it
            // through would also type into whatever has focus behind us.
            return nil
        }
        recording = monitor.map(LocalMonitorToken.init)
    }

    /// Disarm when the control leaves the screen, so a Settings window closed
    /// mid-recording does not leave a monitor swallowing every key press.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { recording = nil }
    }
}

/// Removes a local event monitor when its owner releases it.
///
/// The `WriteObservation` pattern, for the same Swift 6 reason: the `deinit`
/// of a `@MainActor` class is nonisolated and may not touch isolated stored
/// properties, so the monitor is held by a plain object whose own `deinit`
/// touches nothing isolated.
private final class LocalMonitorToken {
    private let monitor: Any

    init(_ monitor: Any) {
        self.monitor = monitor
    }

    deinit {
        NSEvent.removeMonitor(monitor)
    }
}
```

> **Keep `{ [weak self] event in` on the brace line.** swift-format will otherwise wrap it and
> SwiftLint's `closure_parameter_position` fails the build — the D-013 loop. The line is 98
> characters, under the 100-column cap.

- [ ] **Step 2: The shell**

```swift
import StenoKit
import SwiftUI

/// The Settings window's shell.
///
/// **The `switch` carries no `default` arm, deliberately.** An exhaustive
/// switch means adding a `SettingsPane` case fails to compile until its view
/// exists, so the registry cannot silently acquire a tab that renders nothing
/// — the one failure mode a registry of this shape has.
///
/// With a single case today the `TabView` draws a toolbar with one segment,
/// which reads a little oddly until M3-04 lands. Left alone on purpose: a
/// `count == 1` special case becomes dead code the day the second pane
/// arrives, and this is the shape all five panes use.
struct SettingsView: View {
    let model: SettingsModel
    @State private var selection: SettingsPane = .capture

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPane.allCases) { pane in
                content(for: pane)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        // A fixed width, as macOS settings windows are; the height follows the
        // pane, so a later, taller pane does not have to fight this frame.
        .frame(width: 460)
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .capture:
            CaptureSettingsPane(model: model)
        }
    }
}
```

- [ ] **Step 3: The Capture pane**

```swift
import StenoKit
import SwiftUI

/// FR-6's Capture area: hotkey binding, launch at login, default project.
///
/// Kept deliberately small. This is a recall tool, and time spent in
/// configuration is time not spent capturing — so each control gets one line
/// of explanation and no more.
struct CaptureSettingsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            if let note = model.storeFailureNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Shortcut") {
                LabeledContent("Global shortcut") {
                    HStack {
                        HotkeyRecorderView(
                            display: model.chord.displayString,
                            onRecord: { keyCode, modifiers in
                                model.record(keyCode: keyCode, modifiers: modifiers)
                            }
                        )
                        .frame(width: 130, height: 22)
                        .disabled(model.storeFailureNote != nil)

                        Button("Reset") { model.resetHotkeyToDefault() }
                            .disabled(model.storeFailureNote != nil)
                    }
                }

                // The rejection and the registration problem are different
                // failures and both can be live: a chord can be refused for
                // its modifiers, and the chord already bound can be in
                // conflict with a system shortcut.
                if let rejection = model.recorderRejection {
                    Text(rejection).font(.callout).foregroundStyle(.secondary)
                }
                if let problem = model.hotkeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle(
                    "Launch Steno at login",
                    isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                if let problem = model.loginProblem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Default project") {
                Picker(
                    "Capture to",
                    selection: Binding(
                        get: { model.resolvedDefaultProjectID },
                        set: { model.setDefaultProject($0) }
                    )
                ) {
                    Text("None — capture follows the most recent task's project")
                        .tag(UUID?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .disabled(model.storeFailureNote != nil)

                // FR-1.4's ladder puts this below last-used, so it is a
                // fresh-install backstop rather than a routing preference.
                // Saying so is the whole obligation the ordering creates.
                Text(
                    "Used only when the text has no matching ticket key and no task has been captured yet."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: Expose the binding and add the scene**

```diff
@@ -21,8 +21,15 @@ final class QuickCaptureController {
     /// controller is built once at launch and lives for the process, so this
     /// is a guard against a future call site rather than a live bug.
     private var hideObservation: (any NSObjectProtocol)?
 
+    /// The Settings pane's seam onto the hotkey (`HotkeyBinding`).
+    ///
+    /// Exposed as the protocol, not as `QuickCaptureModel`: Settings has no
+    /// business with the panel's capture field or project list, and the narrow
+    /// type is what keeps `SettingsModel` testable with a four-line double.
+    var hotkeyBinding: any HotkeyBinding { model }
+
     init(container: ModelContainer) {
         // `container.mainContext`, matching what `MainWindowView` reads, so a
         // capture from the panel and the window's own fetches agree without
         // relying on cross-context visibility.
@@ -17,8 +17,13 @@ struct StenoApp: App {
     /// FR-1.2's surface, held for the same reason: a released controller takes
     /// the status item out of the menu bar with it.
     private let menuBar: MenuBarController?
 
+    /// FR-6's surface. Built here for the reason the two controllers are: the
+    /// `Settings` scene's content is rebuilt freely by SwiftUI, and the state
+    /// behind it must not be.
+    private let settingsModel: SettingsModel
+
     /// Exists to keep the app alive when the last window closes, which is what
     /// makes "the icon is present without the main window open" true.
     @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
 
@@ -91,11 +96,18 @@ struct StenoApp: App {
             let controller = QuickCaptureController(container: container)
             controller.start()
             quickCapture = controller
             menuBar = MenuBarController(container: container)
+            settingsModel = SettingsModel(
+                hotkey: controller.hotkeyBinding, context: container.mainContext)
         } else {
             quickCapture = nil
             menuBar = nil
+            // Settings still opens. Launch at login has no store dependency
+            // and stays live; the hotkey and default-project controls disable
+            // themselves and say why (§13 — degradation ships with the
+            // feature, not after it).
+            settingsModel = SettingsModel()
         }
     }
 
     var body: some Scene {
@@ -120,6 +132,17 @@ struct StenoApp: App {
                 StoreFailureView(path: storePath, error: error)
             }
         }
         .commands { MainWindowCommands() }
+
+        // FR-6. A `Settings` scene rather than a second `Window`: this is what
+        // puts "Steno › Settings…" in the application menu at the right
+        // position with ⌘, bound, and makes macOS treat the window as a
+        // settings window. ⌘, is the only entry point by decision — clicking
+        // the menu bar icon activates the app (`MenuBarController.show` calls
+        // `NSApp.activate`), so the application menu is reachable even with no
+        // window open, and M1-04's popover is left as it was built.
+        Settings {
+            SettingsView(model: settingsModel)
+        }
     }
 }
```

- [ ] **Step 5: Build, format, lint**

Run: `make build && make format && make lint`
Expected: Build Succeeded; `Found 0 violations`.

- [ ] **Step 6: Run the app and walk the manual checklist**

Run: `make run`, then work through **Manual verification** below. Record the results in the PR
body — they are the only evidence for acceptance criteria 1 and 2.

- [ ] **Step 7: Commit**

```bash
git add Steno/Features/Settings/ Steno/Features/Capture/QuickCaptureController.swift Steno/App/StenoApp.swift
git commit -m "feat: the Settings window and FR-6's Capture pane (M1-08)"
```

---

### Task 8: Documentation, and the README ticks

**Files:**
- Modify: `docs/DECISIONS.md`, `docs/ARCHITECTURE.md`, `docs/tasks/README.md`

- [ ] **Step 1: Add the decision records**

Append to `docs/DECISIONS.md`, numbered from the last entry in the file. Six entries:

1. **The Settings window is a `Settings` scene, reached only by ⌘,.** Why: it is what puts
   "Steno › Settings…" in the application menu at the right position with ⌘, bound, and makes
   macOS treat the window as a settings window. ⌘, being the only entry point is safe because
   `MenuBarController.show()` calls `NSApp.activate`, so clicking the menu bar icon makes the
   application menu reachable with no window open. Alternative rejected: a "Settings…" row in
   FR-1.2's popover — it edits another task's reviewed surface to solve a state that does not occur.
2. **`SettingsPane` is the registry, and `SettingsView`'s switch is exhaustive.** Adding M3-04's
   pane is one case, one arm, one file. The missing `default` arm is the point: a new case fails to
   compile until its view exists, so the registry cannot acquire a tab that renders nothing. Record
   the accepted cost — with one case, `TabView` draws a one-segment toolbar until M3-04 lands.
3. **`AppSettings` is the single `UserDefaults` facade, and `QuickCaptureModel.chordKey` moved into
   it.** Why: four more panes are coming, and a key-per-model codebase leaves §10.3's "secrets are
   never exported" audit with no single place to look.
4. **`LoginItem` reports a status rather than `isEnabled` — amends D-041.** `register()` can succeed
   into `.requiresApproval`, which under a `Bool` is indistinguishable from "off" with nothing
   thrown. D-041's "what is not tested" note stands unchanged: the real `SystemLoginItem` is still
   not exercised in the suite.
5. **`rebind` takes a chord and nothing else, and refuses to bind before `start`.** The Settings
   layer's business is which chord, not what pressing it does. The guard exists because a chord
   registered in front of a `nil` action is a live system-wide shortcut that swallows the keystroke
   and does nothing.
6. **Recorded modifiers are masked to `⇧⌃⌥⌘` before a chord is built.** `NSEvent.modifierFlags`
   carries `.capsLock`, `.function` and `.numericPad`; `HotkeyChord` compares modifiers for exact
   equality against `SystemHotkeys`' table, so an unmasked chord would silently stop FR-1.1's
   conflict warning from ever firing and would convert to a Carbon mask the user did not press.

- [ ] **Step 2: Update the layer map**

In `docs/ARCHITECTURE.md` §5, add to the `StenoKit/` block:

```
  Settings/       AppSettings — the one UserDefaults facade        (exists, M1-08)
```

and extend the `Features/` lines under both `StenoKit/` and `Steno/` to name `Settings (M1-08)`.

- [ ] **Step 3: Tick the README rows**

In `docs/tasks/README.md`, tick **both**:

```diff
-- [ ] [M1-07](M1-07-ci-workflow.md) — GitHub Actions running build/test/lint on every PR (§9.6) — PR #18
-- [ ] [M1-08](M1-08-settings-shell-and-capture-pane.md) — Settings window plus the Capture pane
+- [x] [M1-07](M1-07-ci-workflow.md) — GitHub Actions running build/test/lint on every PR (§9.6) — PR #18
+- [x] [M1-08](M1-08-settings-shell-and-capture-pane.md) — Settings window plus the Capture pane
```

M1-07 merged as PR #18 without its row being ticked. CLAUDE.md's step 4 makes ticking it this
PR's job, because §9.5 forbids a direct commit to `main`.

- [ ] **Step 4: Commit**

```bash
git add docs/DECISIONS.md docs/ARCHITECTURE.md docs/tasks/README.md
git commit -m "docs: record M1-08's decisions and tick M1-07 and M1-08 (M1-08)"
```

---

## Manual verification

GUI automation is unavailable to the implementing agent, so these are the human's. Acceptance
criteria 1 and 2 have no other evidence.

- [ ] ⌘, opens Settings, showing the Capture pane.
- [ ] Record `⌃⌥K`: the capture panel opens on `⌃⌥K` **with no relaunch**, `⌥Space` no longer opens
      it, and the new chord survives quitting and relaunching. *(Acceptance criterion 1.)*
- [ ] Record `⌘Space`: a warning naming "Spotlight search" appears and the binding is still
      attempted. *(FR-1.1 warns, it does not refuse.)*
- [ ] Record a bare `K`: refused in place with "Add ⌃, ⌥ or ⌘ to make this a shortcut", and the
      working binding is unchanged.
- [ ] `Esc` while recording cancels and keeps the current chord.
- [ ] **Reset** restores `⌥Space`.
- [ ] Launch-at-login toggle: either Steno appears in System Settings › General › Login Items, or
      the pane names the specific failure. A debug build run out of `.build/` is a relocated bundle
      and is expected to fail here — record which you saw. Then reboot and confirm it survives.
      *(Acceptance criterion 2.)*
- [ ] Set a default project, quit, relaunch: the choice persists. Archive that project: the picker
      reads "None", and unarchiving restores the choice.
- [ ] Close the Settings window while the recorder is armed, then type: no keystrokes are
      swallowed. *(Guards the `viewDidMoveToWindow` disarm.)*

Acceptance criterion 3 — that the default is what M1-02 falls back to — is covered by
`DefaultProjectThreadingTests` rather than by hand: reproducing "no ticket key and no last-used
task" manually needs an empty store.

Acceptance criterion 4 — adding a pane touches no existing pane — is verified by the commented
cases in `SettingsPane` and the exhaustive switch. State that in the PR body as the check it is.

---

## Definition of done

- [ ] `make build && make test && make lint` all pass.
- [ ] 37 new tests, each confirmed to fail under a mutation of the behaviour it claims to cover.
      Six were verified that way while writing this plan: dropping `defaultProjectID:` from a
      surface, removing the modifier mask, returning `nil` for `.requiresApproval`, returning the
      unresolved default, dropping `start`'s stored action, and duplicating a key name. Each was
      caught by exactly the intended test and by no other.
- [ ] The PR body states: FR-6 and FR-1.1/FR-1.4 as the requirements; that `LoginItem` changed
      shape and why; that `rebind`'s signature changed; the manual checklist results; and that no
      REQUIREMENTS.md amendment was needed.
- [ ] **Do not merge.** The user reviews and merges (§9.5).

