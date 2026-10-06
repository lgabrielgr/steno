# M4-05 — Scheduled Background Refresh: design

**Date:** 2026-10-06 · **Task:** [`M4-05`](../../tasks/M4-05-background-refresh.md) ·
**Requirements:** §5.5, FR-6, §7.4, §9.4, §13, D-121, D-167, D-176, D-178, D-179, D-183, D-184,
D-194, D-215, D-216 ·
**Branch:** `feat/background-refresh`

## What this builds

A third trigger over a refresh path that is already finished. M4-01 shipped `SourceConnector`,
`RefreshPolicy`, `SourceRefreshService` and the gate that serializes passes; M4-02 and M4-03
filled the registry; M4-04 gave the user somewhere to put the credential and a switch per
integration. §5.5 names three triggers and two of them exist — app launch and "Prepare
Stand-up". This is the third: **a pass at a user-set time, 08:00 by default, so the morning view
is instant rather than waiting on the network.**

Nothing about fetching changes. No connector gains a method, `SourceConnector` is untouched, and
the pass this schedules is the same `refreshDue()` the launch path already calls. What is new is
a clock, a rule about that clock, two settings and a stamp.

**The purpose is narrow, and the narrowness is the design constraint.** §5.5 calls this a latency
optimization — the launch-time and report-time passes already guarantee correctness, so a
scheduled pass that does not run is a non-event, not a data-integrity failure. Every decision
below falls out of taking that literally: one attempt per occurrence, silence on failure, and a
missed window that expires rather than accumulating.

## What this task decides

| | Decision |
|---|---|
| D-221 | A polling tick over a pure due rule, not a timer armed at the occurrence |
| D-222 | The most recent occurrence, a four-hour grace window, then the day is skipped |
| D-223 | `lastRun` is stamped at dispatch, not at success — one attempt per occurrence |
| D-224 | Launch runs exactly one pass; the schedule only decides whether it counts |
| D-225 | `TimeOfDay`, three settings keys, and a toggle whose absence means on |
| D-226 | The scheduled pass keeps the 30-minute staleness rule |

The numbering continues from **D-220**, which is `DECISIONS.md`'s current maximum — read out of
that file rather than inferred from this spec's predecessor, which is how a duplicate D-140
shipped once already.

---

## D-221 — A polling tick over a pure due rule

```swift
// StenoKit/Integrations/ScheduledRefreshDue.swift
public enum ScheduledRefreshDue {
    public static let defaultTime = TimeOfDay(hour: 8, minute: 0)
    public static let grace: TimeInterval = 4 * 60 * 60

    public static func isDue(
        now: Date, at time: TimeOfDay, lastRun: Date?,
        grace: TimeInterval = grace, calendar: Calendar
    ) -> Bool
}

// StenoKit/Integrations/ScheduledRefreshController.swift
@MainActor public final class ScheduledRefreshController {
    public static let tickInterval: TimeInterval = 5 * 60
    public init(
        settings: AppSettings, now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        refresh: @escaping @MainActor () async -> Void)
    public func start(interval: TimeInterval = tickInterval)
    public func stop()
}
```

A repeating five-minute `Timer`, and every tick asks the pure rule whether a pass is warranted.
This is `AutoExportController`'s shape (D-121) for `AutoExportController`'s reason: everything
decidable lives in a function with no clock of its own, so the class that owns the timer has
almost no branches and the rule gets a test table instead of a wait.

**The alternative was a single-shot timer armed at the next occurrence**, which fires on the
minute instead of up to five minutes late. Rejected because precision is not what §5.5 asks for
and the re-arming is where the bugs would live: the armed fire date has to be recomputed when the
toggle changes, when the time changes, when the machine wakes, and when the time zone moves, and
a stale armed timer is silent — the failure mode nobody notices, because a refresh that never
happens looks exactly like a refresh with nothing to report. The polling shape has no state to go
stale. Sleep, a closed app, a daylight-saving boundary, a time-zone change and a clock dragged
backwards all reduce to the same sentence: *the next tick re-asks*.

**`NSBackgroundActivityScheduler` was also rejected**, despite being the API Apple points at for
exactly this acceptance criterion. It schedules by *interval*, not by time of day, so it cannot
express "08:00", and its whole value is the right to defer — including past the morning this
exists to make fast.

The tick is cheap and must be allowed to stay cheap: `tolerance = 60` so the system can coalesce
it, `.common` run-loop mode so a tracking menu does not pause it (the bug D-121's controller
already fixed), and **no store access and no `Task` on a tick that is not due** — the rule is two
date comparisons. `start()` calls `stop()` first, because a scheduled `Timer` is retained by the
run loop and reassigning the property leaves the old one firing forever; that exact defect was
found by Copilot in PR #32 against this file's ancestor.

`calendar` is a closure read per tick, not a stored value. That is what makes a time-zone change
take effect without re-arming — the same reason `SourceRegistry` reads enablement per dispatch
rather than at construction (D-216).

## D-222 — The most recent occurrence, a four-hour grace window, then the day is skipped

The rule, in order:

```
candidate = the time applied to startOfDay(now)
if candidate > now  -> candidate = the time applied to startOfDay(now - 1 day)
due iff  now - candidate < grace
     and (lastRun == nil || lastRun > now || lastRun < candidate)
```

**The most recent occurrence, not today's.** Today's is the obvious reading and it is wrong at
the edge the user is most likely to hit on a laptop: with the time set to 23:00, a Mac that sleeps
at 23:30 and wakes at 01:00 computes *tomorrow's* 23:00, finds `now` before it, and concludes
nothing is owed — silently dropping the one occurrence the grace window exists to catch. Walking
back a day when the candidate is in the future costs one branch and removes the whole class.

**`startOfDay` makes the day explicit.** `Calendar.date(bySettingHour:minute:second:of:)` takes a
`direction` that defaults to `.forward`, which reads as though applying 08:00 to a 14:00 `now`
would return tomorrow morning. Probed on 2026-10-06, it does not: it returns the same day's 08:00,
already in the past. The anchor is kept anyway, because a rule whose correctness rests on which
reading of `direction` is right is a rule the next reader has to re-derive — and because anchoring
is what lets the walk-back below be a plain "subtract one day".

**Four hours, then the day is skipped.** Past the window the pass buys nothing: §5.5's launch rule
refreshes anything older than thirty minutes, and "Prepare Stand-up" refreshes the report window
unconditionally, so correctness is already covered and the only thing a 19:00 catch-up optimizes
is a morning that has gone. The task's second acceptance criterion asks for "a catch-up on next
launch rather than a skipped day or a thundering herd of requests" — the grace window is how both
halves of that sentence hold at once.

**A `lastRun` in the future is treated as never having run**, which is `AutoExportDue`'s posture
and for its reason: a clock dragged backwards, usually by a stored date crossing a time-zone
change, would otherwise disable the schedule until real time caught up — for a mis-set year,
never.

Boundaries are strict and pinned in both directions, matching `RefreshPolicy.due`: `now ==
candidate` is due, and `now - candidate == grace` is **not**. Which side the boundary falls on
matters less than a test holding it still.

**Daylight saving, measured rather than predicted** (probe, `America/Los_Angeles`, 2026-10-06):

| Input | `matchingPolicy: .nextTime` (the default) |
|---|---|
| 02:30 on 2026-03-08, an hour that does not exist | `03:00` the same day |
| 08:00 on the same day | `08:00`, unremarkable |
| 01:30 on 2026-11-01, an hour that happens twice | the first instance (`-07:00`); `.last` gives `-08:00` |

So a skipped hour moves the occurrence forward by minutes rather than losing the day, and a
repeated hour fires once because the stamp from the first instance covers the second.
`matchingPolicy: .strict` was rejected on the evidence: it answers the skipped 02:30 with *the
next day's* 02:30, which would silently skip a day.

A `nil` candidate is therefore unreachable for a well-formed `TimeOfDay`, and the `guard` that
returns "not due" on one is deliberately untested — there is no input that reaches it, and a test
that cannot fail is worse than an honest comment saying so.

## D-223 — `lastRun` is stamped at dispatch, not at success

The stamp is written when the pass is dispatched, before it is awaited. **This is the opposite of
`AutoExportDue`, which measures from the last success, and the inversion is deliberate.**

Auto-export measures from success so a missing folder keeps re-announcing itself — its failure is
the user's problem and must stay visible. A failed background refresh is not the user's problem:
§5.5 makes it best-effort, and the stand-up draft already labels stale data (D-176). Stamping on
success would make the controller retry every five minutes until noon — forty-eight passes at a
source that is, most likely, down. That is the "thundering herd" the task names.

One attempt per occurrence also removes the need for an in-flight guard. The stamp makes the next
tick not-due, so a second dispatch while the first is still fetching is unreachable rather than
prevented. The code says so, so that the next reader does not add the flag back.

A pass that is cut short by its own budget (D-178) is not retried either. It is best-effort by
construction: the refs that got their turn are cached, the rest are stale, and `SourceNotice` is
what tells the user.

## D-224 — Launch runs exactly one pass; the schedule only decides whether it counts

`StenoApp.startLaunchRefresh` (`Steno/App/StenoApp.swift:241`, whose comment already says M4-05
replaces it) becomes the controller's `start()`. At launch:

1. Ask the rule once.
2. If due, stamp `lastRun`.
3. Dispatch exactly one `refreshDue()` either way.

**Not two passes.** Asking the rule *and* keeping the old unconditional launch pass would run the
launch pass, then immediately run a second pass that finds nothing stale and fetches nothing — a
zero-network no-op, but one that logs an empty pass and invites a reader to wonder which trigger
owns the launch. One dispatch, one log line, and the only thing the schedule decides at launch is
whether this morning's occurrence has now been served.

The pass stays where it is for D-179's reason — the CLI bundle builds a store too, and
`steno export` must not open a socket — and keeps using `mainContext`, because the window's own
model reads that context.

The controller is injected with `refresh: @MainActor () async -> Void` rather than a
`SourceRefreshService`, because the service needs a `ModelContext` only the composition root has,
and because a spy closure is what makes "dispatched once, not twice" assertable without a
container or a connector.

No `NSWorkspace.didWakeNotification` observation. A sleep spanning the window is
indistinguishable from the app having been closed, and both end in the same catch-up; whether the
run loop fires a missed tick immediately on wake or at the next five-minute boundary changes the
latency by minutes, not the outcome. An observation would be a second path to test for a
difference the user cannot perceive.

## D-225 — `TimeOfDay`, three settings keys, and a toggle whose absence means on

```swift
// StenoKit/Settings/TimeOfDay.swift
public struct TimeOfDay: Sendable, Equatable {   // not Codable — see the note below
    public let hour: Int       // 0..<24
    public let minute: Int     // 0..<60
    public var minutesSinceMidnight: Int
    public init?(minutesSinceMidnight: Int)
}

// AppSettings
public static let scheduledRefreshEnabledKey = "com.lgabrielgr.steno.scheduledRefresh.enabled"
public static let scheduledRefreshTimeKey    = "com.lgabrielgr.steno.scheduledRefresh.time"
public static let scheduledRefreshLastRunKey = "com.lgabrielgr.steno.scheduledRefresh.lastRun"

public var scheduledRefreshEnabled: Bool          { get nonmutating set }
public var scheduledRefreshTime: TimeOfDay        { get nonmutating set }
public var scheduledRefreshLastRun: Date?         { get nonmutating set }
```

**Not `Codable`, corrected after review.** The first version conformed, and a synthesized
`init(from:)` assigns the stored property directly — so `{"minutesSinceMidnight":1440}` decodes to
an hour of 24, which the type's own initializer refuses. Nothing serializes a `TimeOfDay`: the
setting is an `Int` in `UserDefaults`, and §10's export deliberately does not carry settings
(D-024). The conformance bought nothing and cost the invariant (Copilot, PR #46).

**A `TimeOfDay`, not a `Date`.** SwiftUI's `DatePicker(displayedComponents: .hourAndMinute)` binds
a `Date`, so without a value type the stored setting is a 1970 instant whose date component is
noise that every reader has to know to ignore — and whose meaning changes with the time zone it
was written in. Stored as minutes since midnight: one small integer, legible in
`defaults read com.lgabrielgr.steno`, and a representation with no second meaning. The failing
initializer is what keeps an out-of-range stored value from reaching the calendar; a bad value
reads back as the 08:00 default rather than trapping, which is `hotkeyChord`'s posture and for its
reason — a hand-written `defaults write` must not be able to break the app.

**Absence means enabled.** §5.5 states the schedule as policy rather than as an option, so a fresh
install schedules; the toggle exists because unattended network activity deserves an off switch
that is not "turn the integration off entirely", which would also kill the launch and Prepare
passes. This uses `AppSettings.flag(_:)`, which already exists precisely because
`UserDefaults.bool(forKey:)` answers `false` for a key never written and that is the wrong
default here — in the direction nobody notices, because a schedule that never fires looks exactly
like one with nothing to fetch.

`scheduledRefreshLastRun` is state rather than preference, and lives here anyway, next to
`autoExportStatus` which is also state. All three keys go in `AppSettings.allKeys`, which §8's
audit reads and `AISecretsTests` asserts the count of — so omitting one turns the suite red rather
than quietly shrinking the audit.

## D-226 — The scheduled pass keeps the 30-minute staleness rule

The scheduled pass calls `refreshDue()` with its default — `RefreshPolicy.launchStaleness`, thirty
minutes — not an unconditional sweep.

Unconditional is the tempting reading of "make the morning instant", and it is how a herd starts:
a Mac woken at 07:58 runs the launch pass, and an unconditional 08:00 pass then refetches every
ref it just fetched. A ref read at 07:45 does not need rereading at 08:00 for the view to be warm.
`RefreshPolicy.launchStaleness` is documented as not user-configurable precisely because "M4-05's
scheduled pass is the setting the user gets" — the setting is *when*, not *how stale*.

The resume window is unaffected: `since` comes from the event-log watermark less D-185's overlap,
computed inside the service, which is what `SourceConnector.fetch`'s documentation means by "M4-05's
catch-up pass needs to pass something else". A catch-up at 11:30 still asks the source about
everything since the log's watermark, however long ago that was. **No connector-facing change.**

---

## Layout

| File | Change |
|---|---|
| `StenoKit/Settings/TimeOfDay.swift` | new — the value type |
| `StenoKit/Integrations/ScheduledRefreshDue.swift` | new — the rule (D-221, D-222) |
| `StenoKit/Integrations/ScheduledRefreshController.swift` | new — the timer (D-221, D-223) |
| `StenoKit/Settings/AppSettings.swift` | three keys, three accessors, `allKeys` (D-225) |
| `StenoKit/Features/Settings/IntegrationsSettingsModel+Schedule.swift` | new — the pane's two bindings |
| `Steno/Features/Settings/ScheduledRefreshSection.swift` | new — toggle, time picker, one sentence |
| `Steno/Features/Settings/IntegrationsSettingsPane.swift` | one line: the section |
| `Steno/App/StenoApp.swift` | `startLaunchRefresh` becomes the controller (D-224) |
| `docs/DECISIONS.md` | D-221…D-226 |
| `docs/tasks/README.md` | tick M4-05 |

**The section is its own file because the pane is 387 lines** and SwiftLint's default
`file_length` warning is 400, which `--strict` reports as a failure. The same arithmetic puts the
model's two bindings in a `+Schedule.swift` extension beside the existing `+Credential.swift`
rather than in the 387-line model.

### What the pane says

The Integrations pane rather than Capture: FR-6 permits either, and what this setting governs is
when integrations fetch, not how capture behaves.

- **"Refresh integrations in the background"** — the toggle.
- **"At [ 08:00 ]"** — `DatePicker(displayedComponents: .hourAndMinute)`, disabled when the
  toggle is off.
- One explanatory line, in the register the rest of the pane uses: *"Fetches ticket and page
  updates at this time so your stand-up is ready without waiting. Skipped if your Mac is asleep;
  Steno catches up when it next wakes, within a few hours of the time you set."*

That sentence is the user-facing statement of D-222, so if D-222's grace changes the sentence is
part of the change. It names the limitation rather than implying a guarantee the mechanism cannot
make — the app has to be running, and a Mac asleep until the afternoon simply refreshes on the
next launch.

Both controls get explicit accessibility labels. Nothing in an automated check reaches VoiceOver,
so the manual pass below is the only verification they have.

### Silence, and where the user does see a problem

The pass discards its `RefreshOutcome`, as the launch pass does today (D-176). This is the task's
"failures are silent to the user but visible in logs", and it needs no new plumbing — traced
rather than assumed:

- An expired or rejected token reaches the user at the next "Prepare Stand-up", through
  `StandupDraftModel.sourceNotice` and `SourceNotice.message(for:)` (D-193).
- The Integrations pane's own warning, `IntegrationsSettingsModel.expiryWarning`, derives from the
  stored credential's recorded expiry, not from any refresh outcome — so it is already correct
  when the pane opens, whether or not a background pass ran.

No modal, no permission prompt, no auth dialog, and no banner: there is no UI surface on this
path to raise one from. `SourceRefreshService`'s two refresh methods do not throw at all (D-167),
so there is also no error for the controller to swallow by mistake.

Degradation ships here, as non-negotiable #6 requires, by already being in place: a failed
scheduled pass leaves the cache exactly as it was, the next report reads that cache, and
`SourceNotice` labels its age. A test pins that a failing pass neither surfaces anything nor
blocks the next occurrence.

### Capture latency

Nothing on this path touches quick-add. The tick is a `Timer` on the main run loop that, when not
due, performs two date comparisons and returns — no store access, no `Task`, no allocation worth
naming. When due, it starts one unstructured `Task`; the fetches themselves are already
`nonisolated` and off the main actor (D-178). Non-negotiable #4 asks for measurement rather than
assertion, and the measurement that matters here is that the quick-add path is unchanged, which
the diff shows: no file under `Capture/` is touched.

## Verification

`make build && make test && make lint`, all three green, before the PR (§9.5 step 4).

**Automated:**

| Suite | Pins |
|---|---|
| `ScheduledRefreshDueTests` | the table: before the window; inside it; `now == candidate`; `now - candidate == grace`; past grace; already run this occurrence; never run; `lastRun` in the future; a 23:00 time crossed by midnight; a spring-forward day; a repeated hour; a time-zone shift between two calls |
| `ScheduledRefreshControllerTests` | due → one dispatch and one stamp; not due → neither; two ticks inside one occurrence → one dispatch; toggle off → never dispatches and never stamps; `start()` twice → one timer; a failing pass → the stamp still advances and the next occurrence still runs |
| `AppSettingsTests` | absent toggle reads `true`; absent time reads 08:00; round-trip; an out-of-range stored time reads as the default; `allKeys` carries all three |
| `TimeOfDayTests` | `minutesSinceMidnight` both ways; the failing initializer's bounds |

Every new test is mutation-checked before the PR: a test that cannot fail is the defect this
repository has shipped most often, and a rule about clocks is where it hides best. In particular,
both boundary tests must be shown to go red when the comparison is flipped, and the
"already run" test must go red when the stamp is removed.

**Manual, because nothing automated can reach it** — an agent cannot click the pane or watch a
timer fire in a running app, so the log is the only observation available: open Settings →
Integrations, set the time to a minute or two ahead, leave the app running, and read the log —

```
log show --last 10m --info --predicate 'subsystem == "com.lgabrielgr.steno"' | grep -i schedul
```

The controller logs one line per decision at info level, which is what makes this checkable at
all: the tick is five minutes, so the pass starts within five minutes of the configured time.
Then VoiceOver (⌘F5) across the toggle and the picker.

## The plan document

The implementation plan is written from a built tree, not from this spec — generating plan blocks
from code that already compiles found seven defects that review missed on M1-03, and a plan's
value is spent before the first commit. Anything in this document that the build contradicts is
this document's error, and the plan says so.

## Out of scope

- **The refresh mechanics.** M4-01 owns them; this task adds no connector method, no new
  `SourceError`, and no change to `since`, the gate, the budget or the cache.
- **Push or webhook updates.** Not in §5 anywhere.
- **Waking the machine.** No `IOPMSchedulePowerEvent`, no `NSBackgroundActivityScheduler`, no
  `beginActivity`. The fourth acceptance criterion is satisfied by not reaching for any of them.
- **A per-project or per-integration schedule.** One time, one toggle. FR-6 asks for a setting,
  not a matrix.
- **Catching up more than one occurrence.** Missed days expire; they are not queued.
- **Surfacing the schedule's own state** — a "last refreshed at" line in the pane. Tempting next
  to the toggle, and it is a staleness indicator, which §5.2 already places on the stand-up draft
  where the user is deciding how much to trust what they are about to say.

## Risks

**App Nap can throttle a timer in a backgrounded app.** The honest statement of the mechanism is
that the tick may fire late, by minutes or more, in an app the user has not touched for hours.
The rule is what absorbs it: a late tick still finds the occurrence inside its grace window and
still dispatches. The fix that would remove the throttling — `ProcessInfo.beginActivity` —
contradicts the acceptance criterion about not spinning the machine, so it is rejected rather
than deferred.

**The app has to be running at all.** With "Launch Steno at login" off and the app closed
overnight, the schedule never fires and the catch-up happens at the next launch — which is the
launch pass the user was getting anyway. This is a property of an in-process scheduler, not a
bug, and the pane's explanatory sentence is where the user is told.

**The DST behaviour was probed, not assumed**, and the table in D-222 records what Foundation
actually answered on 2026-10-06. The same probe disproved this document's first explanation of why
`startOfDay` is needed, which is the argument for probing: an assumed return value becomes a test
that passes for the wrong reason, and a plausible explanation becomes a comment asserting a false
property — the two defects this repository ships most often.
