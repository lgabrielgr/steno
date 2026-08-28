# M1-03 — Global Hotkey & Floating Capture Window — Design

**Task:** [`docs/tasks/M1-03-global-hotkey.md`](../../tasks/M1-03-global-hotkey.md)
**Requirements:** [FR-1.1](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-1.4](../../REQUIREMENTS.md#fr-1-quick-capture-p0),
[FR-6](../../REQUIREMENTS.md#fr-6-settings-p0),
[§1.1](../../REQUIREMENTS.md#11-primary-risk),
[§9.3](../../REQUIREMENTS.md#93-signing-from-the-command-line),
[§13](../../REQUIREMENTS.md#13-guidance-for-implementing-agents),
[D15](../../REQUIREMENTS.md#2-decisions-made-locked)
**Branch:** `feat/global-hotkey-capture`
**Date:** 2026-08-27

## Goal

The first of D15's two remaining capture surfaces: a system-wide chord that puts a focused text
field above whatever the user is doing, without moving them out of it.

M1-02 built the code path. This task builds a window over it and a way to summon that window
from any application. Nothing here re-implements routing, extraction, or the write — if this
design introduces a second way to create a task, it is wrong.

The budget is §1.1's: hotkey to persisted task in under three seconds, no mouse, no modal. The
part of that budget this task can actually lose is the part between the keypress and the caret
appearing, and the part between dismissal and the user's own app being usable again.

---

## 1. The finding that changes an acceptance criterion

**The task file requires Accessibility (TCC) permission handling. The feature does not need
Accessibility permission.**

Three mechanisms can deliver a system-wide chord on macOS. Two are TCC-gated:
`NSEvent.addGlobalMonitorForEvents` and `CGEvent.tapCreate` both require the app to be trusted
for Accessibility, and both fail silently until it is. The third,
Carbon's `RegisterEventHotKey`, is not gated: the WindowServer dispatches the registered chord
to the owning process directly, which is why launcher applications bind hotkeys on first run
with no permission dialog. This design uses `RegisterEventHotKey`.

Verified at compile level against this project's exact toolchain — `RegisterEventHotKey`,
`InstallEventHandler`, `GetEventDispatcherTarget`, and the `kEventHotKeyPressed` dispatch all
type-check under `-swift-version 6 -target arm64-apple-macos14.0`, EXIT=0. Runtime confirmation
is manual check 6 in §7, and it is the *evidence* for this section rather than a formality:
if a permission dialog ever appears, this section is wrong.

**Consequences.**

- The task file's fifth acceptance criterion — "denying or revoking Accessibility permission
  produces a clear explanation, not a dead hotkey" — has no code behind it. Building a
  permissions branch to satisfy it would mean writing an explanation for a state that cannot
  occur, and, worse, a `AXIsProcessTrusted()`-driven banner on the launch path of a feature
  whose whole argument is that it interrupts nothing. The criterion is rewritten, not
  implemented.
- **REQUIREMENTS.md §9.3 is factually wrong** where it says "FR-1's global hotkey requires
  macOS Accessibility permission, which is granted by TCC against the app's code signature."
  §9.3's *conclusion* — use a stable Personal Team identity, never ad-hoc — stands, and the
  guidance is unchanged. Only its stated reason is wrong. Amended in this PR with a version bump
  and a changelog line, per CLAUDE.md's "when the spec is wrong."

This is deliberately the first section of this document. An agent implementing M1-03 without
reading it will build a TCC subsystem for nothing.

---

## 2. The units

Split by what each can be tested *without* — the same test ARCHITECTURE §5 applies to target
membership.

| File | Responsibility | Tested against |
|---|---|---|
| `StenoKit/Capture/HotkeyChord.swift` | Key code + modifiers; `Codable`; Carbon conversion; display string | Literal values |
| `StenoKit/Capture/SystemHotkeys.swift` | Decode the `symbolichotkeys` domain into reserved chords | Fixture dictionaries |
| `StenoKit/Capture/HotkeyConflictChecker.swift` | Chord + reserved → `HotkeyConflict?` | Literal values |
| `StenoKit/Capture/GlobalHotkeyMonitor.swift` | The protocol, its error type, and `CarbonHotkeyMonitor` | Fake monitor; error mapping |
| `StenoKit/Features/Capture/QuickCaptureModel.swift` | The panel's field model, project refresh, registration state | Container + fake monitor |
| `Steno/Features/Capture/CapturePanel.swift` | The non-activating `NSPanel` | Not testable (D-010) |
| `Steno/Features/Capture/QuickCaptureController.swift` | Wiring: monitor → panel → model | Not testable (D-010) |
| `Steno/Features/Capture/CaptureFieldView.swift` | Gains a `style` parameter (existing file) | Not testable (D-010) |
| `StenoKit/Capture/CaptureService.swift` | Posts `.stenoDidCapture` (existing file) | Container |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | Observes it (existing file) | Container |

### 2.1 An architecture line that needs widening

ARCHITECTURE §5 says `Steno/` holds "SwiftUI views and `@main`, nothing else." D-010's actual
test is narrower and better: *if it cannot be tested without a window server, it does not belong
in `Steno/`.*

Carbon hotkey registration has no window-server dependency, so `CarbonHotkeyMonitor` stays in
`StenoKit` — where the protocol it conforms to, its `OSStatus` mapping, and every consumer of it
are reachable by the headless bundle. An `NSPanel` is a window and cannot be, so it does not.

§5's prose is therefore widened in this PR to admit windows alongside views. This is a
correction to a sentence that was always slightly narrower than the rule it summarised, not a
new dispensation: the D-010 test is unchanged and still decides every case.

---

## 3. Conflict detection, and the limit of it

FR-1.1 requires the hotkey to "detect and warn on conflicts." Exactly one class of conflict is
detectable through public API, and the design says so rather than implying broader coverage.

**Detectable — system-reserved chords.** macOS records its own shortcuts in the
`com.apple.symbolichotkeys` defaults domain, shaped as:

```
AppleSymbolicHotKeys = {
  "<id>": { enabled: Bool,
            value: { parameters: (asciiCode, keyCode, cocoaModifierMask),
                     type: "standard" } }
}
```

**Detectable — our own registration failing.** A non-`noErr` `OSStatus` from
`RegisterEventHotKey` (notably `eventHotKeyExistsErr`) means the chord genuinely did not bind.

**Not detectable — another third-party application's claim.** There is no public API that
enumerates hotkeys owned by other processes. `RegisterEventHotKey` typically returns `noErr`
in this case and the other application simply wins the chord. Private SPI in the
`CGSGetSymbolicHotKeyValue` family gets marginally closer and still does not cover third
parties. **This is documented as a limitation, not simulated.** A checker that implied it had
covered third-party conflicts would be worse than one that admits it has not.

### 3.1 The plist records deviations, not state

This is the trap, and it was found by reading the real domain rather than assuming its shape.

On the development machine the domain holds 19 ids. Spotlight (64), Finder search (65), Mission
Control (32) and App windows (33) are **absent from it entirely** — and are nonetheless live at
their system defaults. Ids 79 and 81 are present as bare `{ enabled: true }` with **no `value`
key at all**, meaning "enabled, at a default chord this file does not record."

A checker that reads only the plist therefore reports `⌘Space` as **free**, which is the single
likeliest conflict any user of this feature will ever attempt.

`SystemHotkeys` resolves each id three ways:

| Plist state | Resolution |
|---|---|
| `value.parameters` present | Use the recorded chord |
| `enabled` present, no `value` | Look the id up in the static default table |
| Id absent entirely | Enabled at its default; look it up in the static default table |

The static table covers the ids a user could plausibly collide with — Spotlight, Finder search,
Mission Control, application windows, space switching, input-source switching, screenshots,
Dock hiding, Help. It is data, not logic, and it is the thing to extend if a gap turns up.

`⌘Space` reporting reserved **from a fixture that omits id 64** is the regression test for this
whole section (§6).

### 3.2 Two modifier encodings, and the conversion between them

The `symbolichotkeys` masks are Cocoa `NSEvent.ModifierFlags` raw values; `RegisterEventHotKey`
takes Carbon constants. They are unrelated bit layouts and confusing them yields a chord that
binds to something other than what the user chose.

| Modifier | Cocoa | Carbon |
|---|---|---|
| Shift | `1 << 17` = 131072 | `shiftKey` = 512 |
| Control | `1 << 18` = 262144 | `controlKey` = 4096 |
| Option | `1 << 19` = 524288 | `optionKey` = 2048 |
| Command | `1 << 20` = 1048576 | `cmdKey` = 256 |

`HotkeyChord` stores the **Cocoa** form — it is what the plist speaks and what a future
key-recorder control in M1-08 will hand over — and converts to Carbon at the registration call
only. Round-tripping both directions is unit-tested (§6).

### 3.3 The default chord

`⌥Space`: key code 49, Cocoa mask 524288. Checked against the real domain on the development
machine and free — the only Space-key chords claimed there are `⌃Space` (id 60) and `⌃⌥Space`
(id 61), both input-source switching. So the out-of-the-box experience does not open on a
warning.

### 3.4 Where the warning goes

M1-08 owns the rebinding pane, so M1-03 has no settings UI to render a warning in. A conflict
sets `QuickCaptureModel.registrationProblem: String?` and logs a fault. M1-08 renders that
string; the property is the attachment point, and it exists now so that task adds a pane rather
than redesigning this one.

**A reserved chord is warned about and registered anyway.** Refusing to bind guarantees a dead
hotkey; binding it leaves the user with a chord that may still work, plus an explanation if it
does not. The failure this criterion exists to prevent is *silence*, not registration.

---

## 4. The window: a non-activating panel

The task file makes returning focus "part of the 3-second budget, not polish." The design meets
that by never taking focus away in the first place.

`CapturePanel` is an `NSPanel` subclass with `.nonactivatingPanel` in its style mask,
`isFloatingPanel = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary, .transient]`, `canBecomeKey` overridden to `true` and `canBecomeMain` to
`false`. Its `contentView` is an `NSHostingView` over `CaptureFieldView`.

Showing it is `makeKeyAndOrderFront(nil)` **with no `NSApp.activate`**. The panel becomes key
and receives typing; at the `NSWorkspace` level the user's own application never stops being
frontmost. Dismissal is `orderOut`. There is no restore step, so there is no restore step to
get wrong. `.canJoinAllSpaces` with `.fullScreenAuxiliary` is what puts the panel over a
full-screen application.

Compile-verified: the subclass above, including the `NSHostingView` `contentView` assignment,
type-checks under Swift 6 mode at the macOS 14 target, EXIT=0.

**Rejected alternatives.**

*Activate and restore* — stash `NSWorkspace.shared.frontmostApplication`, call
`NSApp.activate(ignoringOtherApps:)`, restore on dismiss. Conventional, and focus is guaranteed.
But Steno visibly becomes frontmost: the menu bar swaps, the Dock icon marks active, and the
restore is an asynchronous cross-process call that can lose a race to whatever else activates.
That is the "steals the user's place" the task file warns against, and it puts a round trip
inside the budget.

*Toggling activation policy* — flip to `.accessory` around show and hide. Gets some of the
discretion without `.nonactivatingPanel`, but mutates global application state on the
latency-critical path and pre-empts M1-04, which will have its own view on activation policy for
the menu bar item.

### 4.1 The residual risk, stated plainly

Whether SwiftUI's `@FocusState` reliably takes the caret inside a non-activating panel is a
runtime question that no compile probe settles, and GUI automation is unavailable in this
environment. It is **manual check 1** and it is first in the list for that reason. If it does
not hold, the fallback is the activate-and-restore approach above, and that outcome should be
recorded in `DECISIONS.md` rather than quietly patched around.

### 4.2 Lifecycle: built once, at launch

The panel, its hosting view and `QuickCaptureModel` are constructed in `StenoApp.init` and stay
resident. Showing is `orderFront` plus a field reset plus a project refetch.

Lazy construction would put `NSPanel` creation, `NSHostingView` instantiation and a SwiftData
fetch inside the *first* press of every launch — the press most likely to be the one §1.1
actually cares about, and the hardest to measure. One panel and one hosting view resident for
the process lifetime is not a cost worth that.

The show path is wrapped in a `hotkeyShow` `OSSignposter` interval on the existing
`Log.captureSignposter`, read with the recipe `StenoKit/Support/Logging.swift` already
documents. CLAUDE.md's non-negotiable #4 requires the capture path measured rather than
assumed, and D-025 is the entry recording what happens when a latency claim is asserted instead.

---

## 5. Data flow

**Launch.** `StenoApp.init` builds the container, then `QuickCaptureController`: model, panel,
hosting view; chord read from `UserDefaults` (default `⌥Space`); conflict check; register.

**Press.** `hotkeyShow` interval begins → `model.prepareForShow()` refetches live projects →
`panel.makeKeyAndOrderFront(nil)` → interval ends. The user's application remains frontmost
throughout.

`prepareForShow()` deliberately does **not** clear the draft. Clearing is a *dismissal*
responsibility, not a show responsibility — see §8.1, which turns on exactly this distinction.
Opening a panel that already holds text is the intended behaviour after a blur, and the field is
otherwise already empty because the previous dismissal emptied it.

**Type.** Into the existing `CaptureFieldModel.text`, whose `didSet` drives `refreshChip()` and
FR-1.4's chip. Unchanged from M1-02 — that it is unchanged is the point.

**`Return`.** `CaptureFieldModel.commit()` → `CaptureService.capture(text:preferred:)` with
`preferred: nil`, because the panel has no surface context — which is what `CaptureService`'s own
doc comment already specifies for this surface → on success `CaptureService` posts
`.stenoDidCapture` → any open `MainWindowModel` reloads → panel `orderOut`.

**`Esc`.** `orderOut`. Nothing written; field reset.

Focus returns in both cases by never having been taken.

### 5.1 `.stenoDidCapture`, and the hole it closes

D-019 flagged this task by name: view models fetch manually and do not refresh, so *"M1-03's
floating window and M1-04's popover must add a refresh or the main window will silently miss
tasks captured elsewhere."*

`CaptureService` posts `.stenoDidCapture` on every successful write; `MainWindowModel` observes
it and reloads. One post site covers all three D15 surfaces and M1-05's and M1-06's future
writes for free.

The alternative D-019 itself suggested — reloading on
`NSApplication.didBecomeActiveNotification` — is near-zero code but leaves two holes. A main
window visible on a second display and never re-activated stays stale, and M1-04's popover,
which also will not activate the application, has the identical problem. Solving it once, at
the write, is cheaper than solving it per surface.

The post is synchronous on the main actor so that tests can assert it deterministically rather
than waiting on delivery.

### 5.2 `QuickCaptureModel` does not reach for `MainWindowModel`

The panel must open, route and write correctly when no main window exists at all — that is most
of the point of a global hotkey. So `QuickCaptureModel` owns its own `CaptureFieldModel` over
`container.mainContext` and its own fetch of live projects, refreshed on each open. It shares
the *code path* with the main window, per D15, not the main window's state.

---

## 6. Testing

Headless, in `StenoTests`, per §9.4:

- **`HotkeyChord`** — `Codable` round-trip; Cocoa↔Carbon conversion in both directions for each
  modifier and for combinations; display string.
- **`SystemHotkeys`** — all three resolution cases of §3.1 against fixture dictionaries:
  `value` present, `enabled` with no `value`, id absent entirely.
- **`HotkeyConflictChecker`** — **`⌘Space` reports reserved from a fixture that omits id 64.**
  That single case is the regression test for §3.1 and is the one to check still exists if this
  file is ever refactored. Plus `⌥Space` clean against the real-world shape, and `⌃Space`
  reserved.
- **`QuickCaptureModel`** over a fake `GlobalHotkeyMonitor` — failed registration sets
  `registrationProblem`; a reserved chord sets it; success clears it; an undecodable stored
  chord falls back to `⌥Space`.
- **`QuickCaptureModel.prepareForShow()` preserves a non-empty draft** and refetches projects.
  §8.1's rule is a design commitment, so it gets a test rather than a comment; the blur that
  triggers it is panel-level and manual, but the model half is not.
- **`CaptureService`** — posts `.stenoDidCapture` exactly once on success, and **not** on
  empty-after-trim text nor on a failed save.
- **`MainWindowModel`** — reloads on receiving it.
- **`CapturePerformanceTests` re-run unchanged.** M1-03 does not touch the write path, so an
  unchanged pass is the evidence for the "no regression against the M1-02 measurement" half of
  the acceptance criteria. Note the file's own warning: `make test` compresses `measure` output
  and hides the worst-of-ten the assertions gate on.

**Not testable here, and stated rather than papered over:** panel focus, ordering above a
full-screen application, and focus return. These are §7's manual checks. Per the memory of
M1-02, absence of a parameterized-test line in `make test` output is not evidence of failure —
xcbeautify does not print table cases.

---

## 7. Manual verification

Agents cannot drive the GUI in this environment (TCC blocks screen capture; Screen Recording is
denied), so these are the user's, and the PR does not claim the acceptance criteria without them.

1. **From a full-screen application: `⌥Space` → the panel appears above it, the caret is already
   in the field, and typed characters land.** §4.1's residual risk. If this fails, stop here and
   report it — the fallback is a different activation approach, not a tweak.
2. `Return` → the task is created, the panel disappears, and focus and caret are back where they
   were, in the same application.
3. `Esc` → nothing saved, focus returns.
4. Type a ticket key matching a configured `Project.jiraProjectKeys` → the chip appears and is
   identical to the main window's.
5. With the main window open on another display, capture via the hotkey → the list updates
   without a click. (§5.1.)
6. **No Accessibility prompt ever appears, and Steno is absent from System Settings → Privacy &
   Security → Accessibility.** This is the evidence for §1.
7. `/usr/bin/log show --last 5m --signpost --predicate 'subsystem == "com.lgabrielgr.steno" AND
   category == "capture"'` → read the `hotkeyShow` interval. Spell out `/usr/bin/log`; zsh has a
   builtin that shadows it.
8. Rebuild and press again — still bound, no re-prompt (§9.3's signing stability, for its
   corrected reason).

---

## 8. Error handling

| Failure | Behaviour |
|---|---|
| `RegisterEventHotKey` returns non-`noErr` | `registrationProblem` set from the mapped error; `Log.app.fault`. Application fully functional; main-window capture unaffected |
| Chord is system-reserved | Warn **and register anyway** (§3.4) |
| Stored `UserDefaults` chord will not decode | Fall back to `⌥Space`, log; **do not overwrite** the stored value — M1-08 will want to show it |
| Store failed to open | `StenoApp.store` is already a `Result`; the controller is built only on `.success`, so the `StoreFailureView` path has no hotkey and no crash |
| Capture fails (`noProjectAvailable`, save error) | Panel **stays open**, `lastError` inline, text intact — `CaptureFieldView`'s existing contract, unchanged |
| Hotkey pressed while the panel is open | Toggle: dismiss. FR-1.1 does not specify; this matches the platform idiom |

### 8.1 Which dismissals clear the draft

Three things dismiss the panel and they do not agree, deliberately:

| Dismissal | Clears the draft? |
|---|---|
| `Return` (successful commit) | Yes — `CaptureFieldModel.reset()` already does this |
| `Esc` | Yes — an explicit "never mind" |
| Losing key focus (`windowDidResignKey`) | **No** |
| Hotkey pressed while open (§8's toggle) | **No** — it is a blur, not a cancel |

The last two are the judgement call, and it is recorded because the obvious alternative —
Spotlight's discard-on-blur — throws away typed capture text, which `CaptureFieldView`'s own
comment already calls "the single worst thing a capture tool can do." The user clicked away
mid-thought or fumbled the chord; the next press restores what they had. `Esc` remains the way
to actually discard, which is what FR-1.1 assigns it.

---

## 9. The view: one file, two styles

`CaptureFieldView` gains a `style` parameter with cases `.sheet` (today's behaviour: fixed
width, padding, a Cancel/Add button row) and `.bar` (the panel: no button row, panel chrome).

Everything else — the chip, the error row, the `isBlank` rule, and the guarded `onSubmit` — stays
literally shared. That is what makes M1-04's acceptance criterion, "the auto-routing chip
behaving identically to the main window," hold by construction rather than by diffing two files.
The view's own doc comment already commits to this: it says M1-03 "embeds this view rather than
rebuilding it."

`.bar` drops the button row deliberately. Cancel and Add duplicate `Esc` and `Return` on a
surface whose stated requirement is no mouse use.

---

## 10. Scope

**In:** hotkey registration and the default chord; conflict detection per §3; the non-activating
panel; `Return`/`Esc`; the `style` parameter; `.stenoDidCapture` and its observer; the signpost.

**Out, and left attachable:**

- **The rebinding UI is M1-08's.** `HotkeyChord`, `registrationProblem` and a `rebind(to:)`
  method all exist after this task, so M1-08 attaches a pane rather than redesigning.
- **The menu bar item is M1-04's.** No activation-policy changes here, deliberately, so that
  task inherits an unmade decision rather than an awkward one.
- **Launch at login is M1-08's.**
- **The capture logic is M1-02's.** This task is a surface over that path. If it grows a second
  way to write a task, it has gone wrong.

**Not decided here:** whether the hotkey chord is carried by §10's export. M2.5-01 owns that,
and it is the same shape as open question O-7 (integration configuration). Raised, not resolved.

---

## 11. Documents amended by this PR

Declared in the PR body per CLAUDE.md's "when the spec is wrong," not smuggled.

- **`REQUIREMENTS.md` §9.3** — the Accessibility claim corrected (§1). Version bump to v1.12 and
  a changelog line.
- **`ARCHITECTURE.md`** — §5's "views and `@main`, nothing else" widened to admit windows
  (§2.1); the file tree gains the new `Capture/` entries.
- **`DECISIONS.md`** — entries for: no-TCC via Carbon; the non-activating panel and its rejected
  alternatives; `.stenoDidCapture`; and the `symbolichotkeys` deviations-only trap.
- **`docs/tasks/M1-03-global-hotkey.md`** — acceptance criterion 5 rewritten against §1, and the
  "Notes for the spec/plan phase" paragraph on signing corrected to keep its advice and drop its
  reasoning.
- **`docs/tasks/README.md`** — checked; no rows are outstanding. M1-03's row gets ` — PR #N`.
