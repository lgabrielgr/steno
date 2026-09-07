# M1-08 — Settings Shell & Capture Pane — Design

**Task:** [`docs/tasks/M1-08-settings-shell-and-capture-pane.md`](../../tasks/M1-08-settings-shell-and-capture-pane.md)
**Requirements:** [FR-6](../../REQUIREMENTS.md#fr-6-settings-p0),
[FR-1.1, FR-1.4](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[§1.1](../../REQUIREMENTS.md#11-primary-risk),
[§9.4](../../REQUIREMENTS.md#94-test-constraints),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents)
**Branch:** `feat/settings-shell-capture-pane`
**Date:** 2026-09-06

## Goal

The Settings window, its pane structure, and the **Capture** pane — hotkey binding, launch at
login, default project.

Most of the *capability* already exists. M1-03 and M1-04 deliberately shipped three hooks with
no caller — `QuickCaptureModel.rebind`, `HotkeyConflictChecker`, `LoginItem` — precisely so
that this task would wire a UI to reviewed code rather than design the code under a UI's
deadline. The work here is therefore the shell, the recorder, and three pieces of wiring; the
design's job is to get the shell's seam right, because three later tasks attach to it and
nothing after this PR will make that seam cheaper to change.

---

## 1. What this task inherits, and must not rebuild

| Inherited | From | Why it is reused rather than rebuilt |
|---|---|---|
| `QuickCaptureModel.rebind(to:onPress:)` — persists the chord and re-registers | M1-03 | Its doc comment names this task: "M1-08's entry point. Deliberately present from day one so that task adds a pane rather than redesigning this type" |
| `HotkeyConflictChecker` + `SystemHotkeys.reserved(in:)` | M1-03 | Conflict detection is already wired into `bind()`; the pane renders `registrationProblem`, it does not re-derive it |
| `HotkeyChord.displayString` and its `keyNames` table | M1-03 | Written for "M1-08's rebinding pane". The table is extended here (§4.3), not replaced |
| `HotkeyRegistrationError.message` | M1-03 | "M1-08's rebinding pane shows this string verbatim" |
| `LoginItem` + `SystemLoginItem` | M1-04 (D-041) | Shipped unused so this task wires a reviewed `SMAppService` wrapper. Amended here (§5.1), not rewritten |
| `ProjectRouter.route(defaultProjectID:)` and `CaptureService.capture(defaultProjectID:)` | M1-02 | Both parameters exist and are always `nil`. "Its acceptance criterion is then met by passing an argument rather than by editing this function" |
| `CaptureFieldModel`'s closure-injection idiom (`projects`, `preferred`) | M1-02 | `defaultProjectID` joins it as a fourth closure, not as a stored value |
| The "logic in `StenoKit`, layout in `Steno/`" split | D-010 | The recorder is the case that makes the line visible: validation is testable, `NSEvent` plumbing is not |

**Nothing in this task touches the append-only log, the status service, or the note path.** No
`Event` is written and no domain model gains a field. Every setting here is configuration, and
configuration lives in `UserDefaults` (D-024's reasoning, applied a second time): it is not
domain data, so §10's export deliberately does not carry it.

---

## 2. The units

| File | What it is | Testable headless |
|---|---|---|
| `StenoKit/Settings/AppSettings.swift` | **Create.** The single `UserDefaults` facade — one declared key per setting | Pure — injected `UserDefaults` |
| `StenoKit/Features/Settings/SettingsPane.swift` | **Create.** `CaseIterable` pane registry: id, title, symbol, order | Pure |
| `StenoKit/Features/Settings/SettingsModel.swift` | **Create.** The shell model: settings, login item, projects, hotkey | Container |
| `StenoKit/Features/Settings/HotkeyChordValidator.swift` | **Create.** Is a recorded chord bindable, and if not, why | Pure |
| `StenoKit/Support/LoginItem.swift` | **Amend.** `status` replaces `isEnabled` (§5.1) | Pure — fake double |
| `StenoKit/Capture/HotkeyChord.swift` | **Amend.** `keyNames` extended to what a recorder can emit (§4.3) | Pure |
| `StenoKit/Features/Capture/QuickCaptureModel.swift` | **Amend.** `rebind(to:)`; takes `AppSettings` (§4.4, §3.2) | Container |
| `StenoKit/Features/Capture/CaptureFieldModel.swift` | **Amend.** `defaultProjectID` closure (§6.2) | Container |
| `StenoKit/Features/MenuBar/MenuBarModel.swift` | **Amend.** Passes `defaultProjectID` through | Container |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | **Amend.** Passes `defaultProjectID` through | Container |
| `Steno/Features/Settings/SettingsView.swift` | **Create.** `TabView` over `SettingsPane.allCases` | No — view |
| `Steno/Features/Settings/CaptureSettingsPane.swift` | **Create.** The three controls | No — view |
| `Steno/Features/Settings/HotkeyRecorderView.swift` | **Create.** `NSViewRepresentable` + local event monitor | No — window server |
| `Steno/App/StenoApp.swift` | **Amend.** A `Settings` scene and the model that feeds it | No — scene |
| `Steno/Features/Capture/QuickCaptureController.swift` | **Amend.** Exposes its model for the pane to observe (§4.4) | No — panel |

`StenoKit/Settings/` is a new directory rather than a file under `Support/`. `Support/` holds
things with no feature of their own — logging, the palette, notification names. Settings is a
feature with four more panes coming, and `AppSettings` is its persistence layer.

---

## 3. The shell

### 3.1 The scene

A SwiftUI `Settings` scene in `StenoApp.body`.

**Why not a second `Window` scene.** `Settings` is what puts "Steno › Settings…" in the
application menu at the correct position with ⌘, bound, and macOS treats its window as a
settings window — single-instance, non-restorable, correct in Mission Control. A `Window` scene
would need all of that reconstructed by hand and would still be in the wrong menu.

**⌘, is the only entry point,** by decision. The application menu is reachable only while Steno
is frontmost, and `AppDelegate` keeps the process alive with no windows open — so on paper
there is a state with no route to Settings. In practice there is not: `MenuBarController.show()`
calls `NSApp.activate(ignoringOtherApps:)` before showing the popover, so clicking the menu bar
icon makes Steno frontmost and the application menu available. FR-1.2's popover is therefore
left exactly as M1-04 built it.

*Alternative considered:* a "Settings…" row in the menu bar popover. Rejected — it edits
another task's reviewed surface to solve a problem that does not occur.

### 3.2 The pane registry

```swift
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case capture
    // case ai           — M3-04
    // case integrations — M4-04
    // case stale        — M6-01
    // case data         — M2.5
}
```

with `title` and `systemImage` as properties on the enum, and `allCases` order as display
order. `SettingsView` is a `TabView(selection:)` over `allCases`, applying `.tabItem` and
`.tag`, with one `switch` mapping a case to its pane view.

**This is acceptance criterion 4.** Adding M3-04's pane is: one enum case, one `switch` arm,
one new file under `Steno/Features/Settings/`. No existing pane is opened, and no pane knows
another exists. The criterion asks this be verified by sketching where M3-04 attaches — the
commented cases above are that sketch, and the PR body will state it as the check it is.

The `switch` carries **no `default` arm**, deliberately. An exhaustive switch means adding a
case fails to compile until its pane view exists, so the registry cannot silently acquire a tab
that renders nothing — the one failure mode a registry of this shape actually has.

**The enum is in `StenoKit`, the `switch` is in `Steno/`.** D-010's test decides: pane titles,
symbols and ordering are data a test can read; `TabView` construction is not. It also means a
later pane's *identity* is testable even though its view is not.

**The one-tab appearance is accepted, not worked around.** With a single case, `TabView` draws
a toolbar with one segment, which reads oddly until M3-04 lands. A `count == 1` special case
would be dead code from the day the second pane arrives, and the shape here is the shape all
five panes use. Left alone deliberately.

### 3.3 `SettingsModel`

`@Observable`, `@MainActor`, built once in `StenoApp.init` and held for the process — the
posture `QuickCaptureController` and `MenuBarController` already establish.

It holds `AppSettings`, a `LoginItem`, a `() -> [Project]` live-project source, and an optional
reference to the app's `QuickCaptureModel`. Everything is injected; nothing is constructed
internally, so the whole model is exercisable from the headless bundle with fakes.

*Alternative considered:* `@AppStorage` in the views. Rejected — it puts state in `Steno/`,
where no test reaches it, against ARCHITECTURE §2 rule 2, and each of the four later panes would
inherit the mistake.

*Alternative considered:* one model per pane and no shell model. Reasonable, and worth
revisiting if the Capture pane's model grows past roughly 150 lines — but it leaves the registry
and the store-failure state with no owner.

### 3.4 `AppSettings`

One type, one declared key per setting, an injected `UserDefaults` so tests use a scratch suite:

| Key | Type | Owner |
|---|---|---|
| `com.lgabrielgr.steno.hotkeyChord` | `HotkeyChord` (JSON) | moved here from `QuickCaptureModel.chordKey` |
| `com.lgabrielgr.steno.defaultProjectID` | `UUID?` (string) | new |

**The chord key moves.** M3-04, M4-04 and M6-01 each add settings, and a codebase where every
model declares its own key is a codebase where the export audit (§10.3, "secrets never
persisted") has no single place to look. The move costs one initializer parameter on
`QuickCaptureModel` and three lines in `QuickCaptureModelTests`.

**Reads are off the per-keystroke path.** `AppSettings` is read at bind time and once per
`capture()` call — never in `refreshChip()`, which is the function §1.1 constrains. See §6.3.

---

## 4. The hotkey

### 4.1 The control

`HotkeyRecorderView` is an `NSViewRepresentable` over a custom `NSView` that becomes first
responder on click and, while recording, installs
`NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`. The monitor consumes
the event and reports `(keyCode, modifierFlags)` upward as a candidate chord.

A local monitor, not a global one: recording only needs events delivered to this app, and a
global monitor would require Accessibility permission — the exact dependency
`CarbonHotkeyMonitor`'s doc comment explains M1-03 avoided. **If recording ever prompts for a
permission, that is a defect in this design, not a step to add to onboarding.**

### 4.2 Validation

All judgment lives in `HotkeyChordValidator` in `StenoKit`, so the part that cannot be tested is
only the event plumbing.

| Recorded | Outcome | Why |
|---|---|---|
| No modifiers (`K`) | Rejected | A bare global hotkey swallows that key in every application |
| `⇧` only (`⇧K`) | Rejected | Shift alone does not distinguish a chord from typing |
| Modifiers with no key | Ignored, recording continues | That is a `flagsChanged`, not a chord |
| `Esc` | Cancels recording, current binding kept | `Esc` is the cancel affordance everywhere else in this app |
| Anything else | Accepted | Including `⌥Space`, the FR-1.1 default |

Rejection is explained in place — "Add ⌃, ⌥ or ⌘ to make this a shortcut" — and does not
change the binding. The pane also carries **Reset to default**, restoring `HotkeyChord.default`.

### 4.3 `keyNames` has to grow

`HotkeyChord.keyName(for:)` maps twelve virtual key codes today and degrades to `"Key 200"` for
the rest. That degradation is right as a fallback and wrong as the answer for a chord the user
has just pressed, and a recorder can emit any code — so the table is extended to the ANSI
letter and digit keys, the function keys, and the named specials (arrows, Return, Tab, Space,
Delete, Home/End/Page keys).

This is what the table's own comment asks for: "This is **data, not logic** — extend it if a gap
turns up rather than adding special cases." A recorder is the gap.

**Stated limitation:** the names are ANSI-layout names, so on a non-ANSI layout a key can
display under an ANSI name. The *stored* chord is unaffected — `HotkeyChord` holds
layout-independent virtual key codes, which is already correct — so this is a labelling
imprecision, not a binding bug.

*Alternative considered:* resolving names through `TISCopyCurrentKeyboardLayoutInputSource` and
`UCKeyTranslate`. Correct on every layout, but its result depends on the machine running the
suite, which §9.4 rules out for a headless deterministic test. A layout-correct name is not
worth an untestable function here.

### 4.4 Rebinding without relaunch

`QuickCaptureModel.rebind(to:onPress:)` becomes `rebind(to:)`, with `start(onPress:)` storing
the closure for reuse.

**Why the signature changes.** The pane's business is *which chord*, not *what the chord does*.
Under the current signature the settings layer would have to supply
`{ quickCaptureController.toggle() }`, which means Settings knows how the capture panel works —
a dependency that buys nothing and would be copied by the next pane that drives a controller.
`start` already receives the closure it needs; storing it is three lines. There is one caller,
so the change is contained. Retain cycles are not a risk: `QuickCaptureController` passes
`{ [weak self] in self?.toggle() }`.

This is also what makes acceptance criterion 1 testable headlessly: rebind against
`FakeHotkeyMonitor`, then assert the new chord is registered *and* the stored `onPress` still
fires. Without the stored closure, "takes effect without relaunch" would be verifiable only by
hand.

**Conflicts warn, they do not block** — `bind()`'s existing order is preserved exactly. A chord
colliding with a reserved shortcut sets `registrationProblem` and is registered anyway, because,
as M1-03's comment puts it, "the failure FR-1.1 exists to prevent is silence, not registration."
The pane renders `registrationProblem` beneath the recorder; it does not re-derive the conflict.

**Observation.** `QuickCaptureController` exposes its `QuickCaptureModel` read-only so
`SettingsModel` can observe `chord` and `registrationProblem` directly. The model is
`@Observable` and lives in `StenoKit`, so this crosses no layer boundary — the alternative,
mirroring both values into `SettingsModel`, would introduce two copies of state that must agree.

---

## 5. Launch at login

### 5.1 `LoginItem` gains a status

D-041 shipped:

```swift
var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
```

**This is a silent-failure hole and it is fixed here.** `SMAppService.mainApp.register()` can
succeed and leave the status at `.requiresApproval` — macOS lists the app under Login Items with
its switch off, waiting for the user. Under a `Bool`, that is `false` with nothing thrown: the
toggle flips back on its own and the pane says nothing. A control that silently undoes itself is
the same class of defect FR-1.1's conflict warning exists to prevent, and §13 makes silence the
thing to design out.

So `isEnabled: Bool` becomes a status — `enabled`, `notRegistered`, `requiresApproval`,
`notFound` — mapped from `SMAppService.Status`. The protocol has no callers, so the cost is the
type change plus updating the fake in `LoginItemTests`.

### 5.2 The control

A `Toggle` whose setter calls `enable()`/`disable()` and then **re-reads the status** rather
than trusting the toggle's own value, so the switch always shows what is actually true.

| Status after the attempt | The pane says |
|---|---|
| `enabled` | Nothing — the toggle is on |
| `requiresApproval` | Steno is registered, but macOS needs approval in System Settings › General › Login Items |
| `notRegistered` after `enable()` | The registration did not take effect |
| A thrown error | The thrown error's description, verbatim |

**The thrown case is the likely one on a development machine,** and D-041 already flagged it: a
debug build launched out of `.build/` is a relocated bundle, and `register()` refuses for it.
Reporting the specific error rather than a generic failure is what makes the manual check in
§8 able to tell "this build cannot register" apart from "this feature is broken".

---

## 6. Default project

### 6.1 Semantics — deliberately a backstop

FR-1.4's ladder is ticket key → surface preference → last-used → **configured default** → first
project. The configured default is therefore consulted only when no ticket key matches and there
is no last-used task in a live project: a fresh install, or a store whose every prior task sits
in an archived project.

**That is the intent and it is kept.** M1-08's third acceptance criterion states exactly this
ordering, and no requirement is amended. What follows from it is a wording obligation, not a
code one: the picker's empty option reads *"None — capture follows the most recent task's
project"*, and the help text says the default applies only when nothing else matches. Building a
setting that is usually inert is fine; implying it is usually consulted is not.

*Alternatives considered and rejected:* promoting the default above last-used (contradicts
FR-1.4 and would need a spec amendment); an opt-in "always capture here unless a ticket key says
otherwise" pin (more UI, larger amendment, and a recall tool's settings should stay small —
"time spent in configuration is time not spent capturing").

### 6.2 Storage and staleness

`AppSettings.defaultProjectID: UUID?`.

**A stale value is not overwritten.** If the chosen project is archived or gone, the picker
shows "None" but the stored ID stays put, so unarchiving restores the setting. This matches the
posture `QuickCaptureModel.storedChord()` already takes with an undecodable chord — "a bad
stored value falls back without being overwritten".

**Validation is already written.** `ProjectRouter.route` guards the rung with
`live.contains(defaultProjectID)`, so an archived or deleted default degrades to the next rung
with no new code and no special case anywhere. The only new obligation is the picker rendering
"None" for an ID it cannot resolve, rather than an empty row.

### 6.3 Threading it to the three surfaces

`CaptureFieldModel` gains `defaultProjectID: () -> UUID? = { nil }` — the closure idiom it
already uses for `projects` and `preferred`, and for the same reason: the value changes under a
field that is already open. It is passed to `service.capture(defaultProjectID:)`. Three
construction sites update: `QuickCaptureModel`, `MenuBarModel`, `MainWindowModel`.

Two properties this preserves, stated because they are what could go wrong:

- **No chip/route divergence.** The chip is derived from `ticketKeyMatch` alone and never
  displays a configured default, so there is no path where the UI promises one project and the
  save writes another — the failure M1-02 and M1-03 both wrote comments guarding.
- **Nothing lands on the per-keystroke path.** `defaultProjectID()` is read once inside
  `capture()`, never in `refreshChip()`. §1.1's constraint and
  `CapturePerformanceTests`' coverage are untouched.

---

## 7. Degradation

`StenoApp.init` builds `quickCapture` and `menuBar` only when the store opened; on failure both
are `nil`. Settings must still work for what does not need a store.

| Section | Store failed |
|---|---|
| Hotkey | Disabled, with the reason stated. There is no capture panel to bind to |
| Launch at login | **Fully functional.** It has no store dependency |
| Default project | Disabled, with the reason stated. There is no project list to choose from |

This ships in this PR, not after it — every feature lands with its fallback (§13).

---

## 8. Verification

### Headless tests

Each is listed with the mutation that must break it; each will be confirmed to fail under that
mutation before the PR opens.

| Test | Breaks when |
|---|---|
| `AppSettings` round-trips a chord and a project ID | a key is renamed, or encode/decode is asymmetric |
| `AppSettings` returns `nil` for an unparseable project ID | a `UUID(uuidString:)` force-unwrap creeps in |
| `AppSettings` returns `nil` for a corrupt chord without clearing it | the read starts overwriting bad values |
| `rebind(to:)` registers the new chord on the fake monitor | rebinding persists but skips registration |
| `rebind(to:)` keeps the stored `onPress` live | `start`'s closure is not retained across a rebind |
| `rebind(to:)` to a reserved chord sets `registrationProblem` and registers anyway | warn-then-bind flips to refuse-on-conflict |
| `rebind(to:)` surfaces `HotkeyRegistrationError.message` | a registration failure is swallowed |
| Validator rejects bare keys, `⇧`-only, and modifier-only | any one predicate is inverted |
| Validator accepts `⌥Space` | the rules tighten past FR-1.1's own default |
| `keyName(for:)` covers every code the recorder can emit, with no duplicate names | a table entry is dropped or duplicated |
| Capture routes to the configured default with no ticket key and no last-used | `defaultProjectID` is not threaded through some surface |
| Capture ignores the default when a last-used exists | the rung order is reordered |
| Capture ignores an archived or unknown default | the `live.contains` guard is removed |
| A throwing `enable()` leaves the status unregistered and sets a message | the thrown error is swallowed |
| `requiresApproval` produces the approval message | the new status collapses back to a `Bool` |
| `SettingsModel` disables hotkey and project sections with no store | the store-failure path is dropped |

Deliberately **not** written: an assertion on `SettingsPane.allCases.count`. It would pass
today, fail on the day M3-04 legitimately adds a case, and detect nothing in between.

### Manual checks (GUI verification is unavailable to the implementing agent)

1. ⌘, opens Settings; the Capture pane is shown.
2. Record `⌃⌥K` → the capture panel opens on `⌃⌥K` with no relaunch, `⌥Space` no longer opens
   it, and the new chord survives a restart. *(Acceptance criterion 1.)*
3. Record `⌘Space` → a warning naming "Spotlight search"; binding is still attempted.
4. Record a bare `K` → rejected in place, binding unchanged.
5. `Esc` while recording cancels and keeps the current chord.
6. **Reset to default** restores `⌥Space`.
7. Launch-at-login toggle → either Steno appears in System Settings › General › Login Items, or
   the pane names the specific failure. Survives a reboot. *(Acceptance criterion 2.)*
8. Default project persists across a restart, and shows "None" if its project is archived.

Acceptance criterion 3 — that the default is what M1-02 falls back to — is covered by the
headless routing tests rather than by hand: reproducing "no ticket key and no last-used task"
manually requires an empty store.

---

## 9. Out of scope

Named by the task file, and each one attaches to this shell in its own milestone: the AI pane
(M3-04), Integrations (M4-04), stale threshold (M6-01), Data (M2.5). No pane here anticipates
them beyond the four commented enum cases.

Also out of scope: any change to FR-1.4's rung order; any Settings entry point other than ⌘,;
persisting which pane was last open (meaningless with one pane).

## 10. Spec amendments

**None.** FR-1.4's order is kept as written, FR-6's Capture area is built as specified, and the
`LoginItem` change is an implementation detail below the requirements layer — it will be
recorded in `DECISIONS.md`, amending D-041.

## 11. Documentation this PR carries

- `DECISIONS.md` — new entries for the `Settings` scene choice, the pane registry, the
  `AppSettings` facade, the `LoginItem` status change (amending D-041), and the `rebind(to:)`
  signature change.
- `ARCHITECTURE.md` §5 — `StenoKit/Settings/`, `StenoKit/Features/Settings/` and
  `Steno/Features/Settings/` rows.
- `docs/tasks/README.md` — tick M1-08, and tick **M1-07**, which merged as PR #18 without its
  row being ticked.
