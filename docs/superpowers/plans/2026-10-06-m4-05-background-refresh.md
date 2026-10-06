# M4-05 Scheduled Background Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A refresh pass at a user-set time — 08:00 by default — so the morning view is instant rather than waiting on the network (§5.5, FR-6).

**Architecture:** A five-minute `Timer` asks a pure rule whether an occurrence is owed; the rule compares the most recent occurrence of the configured time against a stamp written when a pass is *dispatched*. Nothing about fetching changes — the pass is the `SourceRefreshService.refreshDue()` the launch path already called, and the launch path becomes this controller. Three `UserDefaults` keys, one value type, one observable model for the Settings control.

**Tech Stack:** Swift 6, SwiftUI (`DatePicker`), Foundation (`Timer`, `Calendar`), swift-testing, SwiftData only indirectly (through the existing refresh service).

**Spec:** [`docs/superpowers/specs/2026-10-06-m4-05-background-refresh-design.md`](../specs/2026-10-06-m4-05-background-refresh-design.md) — decisions D-221…D-226. The plan argues from the spec; read both.

## Global Constraints

- **Never commit to `main`.** Branch `feat/background-refresh`, one PR, do not merge (§9.5).
- **`make build && make test && make lint` all green before the PR** (§9.5 step 4). `make lint` runs `swiftlint --strict`, so a warning is a failure.
- **The event log is append-only.** Nothing in this task writes an `Event` directly; the `externalUpdate` events this schedule causes are written by `SourceRefreshService`, unchanged (§3.3).
- **Capture latency is untouchable** (§1.1). No file under `Steno/Features/Capture/` or `StenoKit/Capture/` is modified by this task; if one appears in the diff, something is wrong.
- **Degradation ships with the feature** (§13). A failed scheduled pass must leave the cache as it was and surface nothing.
- **This runs unattended**: no modal, no permission prompt, no auth dialog, ever (task file, "Notes for the spec/plan phase").
- **Minimum macOS 14.0**, bundle id `com.lgabrielgr.steno`, log subsystem `com.lgabrielgr.steno` (§9.1).
- **Identifiers of fewer than three characters fail lint**; `force_unwrapping` is an enabled rule, so tests use `try #require`, never `!`.
- **New `UserDefaults` keys must be listed in `AppSettings.allKeys`**, and `AISecretsTests` asserts that list's count.
- **Decision numbers continue from D-220.** Check `docs/DECISIONS.md` for the maximum before writing; do not infer it from this plan.

## Acceptance criteria, and what covers each

| Criterion (task file) | What covers it |
|---|---|
| A refresh runs at the configured time and populates caches before the user looks | Task 3 `theConfiguredMinuteIsDue`, `aPassIsDueInsideTheWindow`; Task 4 `aTickInsideTheWindowDispatches`, `aDispatchedPassReachesTheRefreshClosure` |
| Missing the window is handled gracefully — a catch-up, not a skipped day or a thundering herd | Task 3's whole window table plus `aLateEveningScheduleSurvivesMidnight`; Task 4 `twoTicksDispatchOnePass`, `aFailedPassIsNotRetried` |
| Failures are silent to the user but visible in logs | Task 4: the outcome is discarded and `Log.sources` carries the decision. `SourceRefreshService`'s methods cannot throw (D-167), so there is no error path to surface. Verified by reading, and by the manual log check in Task 6 |
| The refresh does not wake or spin the machine unnecessarily | Task 4: a five-minute `Timer` with `tolerance = 60` that does two date comparisons when not due. No `IOPMSchedulePowerEvent`, no `NSBackgroundActivityScheduler`, no `beginActivity` — see the spec's Out of scope |
| `externalUpdate` events created here appear correctly in the next report | Unchanged from M4-01: this task adds no write path. The pass is `refreshDue()`, whose event writing is already covered by `SourceRefreshServiceTests` |

## Review Focus

Five conditions the spec implies that no task's happy path exercises. Each has a test, named here and written in the task that owns the code.

1. **The schedule's toggle must not disable §5.5's launch pass.** The launch rule is fixed; the toggle governs the unattended pass only. A user who switches the schedule off and then finds launch no longer refreshes has lost a feature nobody meant to touch. → Task 4, `theLaunchPassIgnoresTheToggle`.
2. **An app left running past midnight must not re-serve yesterday's occurrence.** At 00:30 the most recent occurrence *is* yesterday's 08:00; only the stamp stops a nightly refetch. → Task 3, `aTickAfterMidnightDoesNotRepeatYesterday`.
3. **Midnight is a legitimate configured time.** `UserDefaults.integer(forKey:)` answers `0` for an absent key, so a reader written the obvious way makes 00:00 and "unset" the same value and the 08:00 default unreachable for anyone who chose midnight. → Task 2, `midnightIsARealSetting`.
4. **A time-zone change between two ticks must change the verdict.** This is the whole reason the calendar is read per tick rather than stored; nothing else would notice it was wrong. → Task 3, `theVerdictFollowsTheCalendar`.
5. **A store that failed to open must still let the schedule be edited.** No container means no pass, and the pane must neither crash nor hide its controls (§13). → Task 6, verified by reading the composition root and by the manual pass; `scheduledRefresh` is `nil` while `scheduleSettingsModel` is built unconditionally.

## Verifying (read before Task 1)

**`make test` prints a failed case as a yellow `⚠️`, not as a cross.** Grepping for `✘` reports a failing suite as clean — that is how a mutation sweep comes to report twelve false survivals. The reliable signal is the sentence xcbeautify prints:

```
Test "a tick inside the window dispatches and stamps" recorded an issue at ScheduledRefreshControllerTests.swift:58:5: Expectation failed: ...
```

So after every test run:

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # 0, or the run is red
grep "recorded an issue" /tmp/test.log | head
```

`make test` regenerates `Steno.xcodeproj` on every run, by design — expect that in `git status` only if the project file is somehow untracked (it is gitignored; §9.1).

**Parameterized cases are not printed**, so absence of a name in the log is not absence of a test. Every test below is a plain `@Test` for that reason.

**Mutation is not optional.** Each task ends with a mutation step naming the exact edit and the exact test that must go red. A test that cannot fail is the defect this repository has shipped most often, and a rule about clocks is where it hides best.

**A mutation that makes a run take minutes instead of seconds is a finding, not a slow machine.** An async test that waits on a continuation resumed by the code under test does not fail when a mutation stops that code running — it hangs, and the suite hangs with it. Both async tests here wait on a deadline for that reason. If a mutation run stops producing output, kill it, check `git status` for the mutation left behind, and read the partial log for which test never finished.

**Restore between mutations, and check that the restore happened.** Each sweep step must re-read `git status`: a sweep killed mid-run leaves the mutation on disk, and the next thing you measure is measuring that instead.

---

## Task 1: `TimeOfDay`, so a schedule is not a `Date`

**Files:**
- Create: `StenoKit/Settings/TimeOfDay.swift`
- Test: `StenoTests/Settings/TimeOfDayTests.swift`

**Interfaces:**
- Consumes: nothing. This is the first task.
- Produces, used by Tasks 2, 3 and 5:
  - `TimeOfDay.eightAM: TimeOfDay`
  - `TimeOfDay.minutesPerDay: Int`
  - `TimeOfDay.init?(minutesSinceMidnight: Int)`
  - `TimeOfDay.init?(hour: Int, minute: Int)`
  - `TimeOfDay.init(of: Date, calendar: Calendar)`
  - `var minutesSinceMidnight: Int`, `var hour: Int`, `var minute: Int`
  - `func instant(on day: Date, calendar: Calendar) -> Date?`

**Why this type exists:** a `DatePicker(displayedComponents: .hourAndMinute)` binds a `Date`, so a setting taken straight from the control is an instant whose date component is noise and whose meaning moves with the time zone it was written in. 08:00 in Berlin and 08:00 here are one setting and two instants.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Settings/TimeOfDayTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

/// A fixed calendar, so nothing here depends on the machine's time zone.
private func pacific() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    return calendar
}

private func instant(_ text: String, in calendar: Calendar) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return try #require(formatter.date(from: text))
}

@Test("minutes since midnight round-trip through hour and minute")
func minutesRoundTrip() throws {
    let time = try #require(TimeOfDay(minutesSinceMidnight: 8 * 60 + 35))

    #expect(time.hour == 8)
    #expect(time.minute == 35)
    #expect(time.minutesSinceMidnight == 8 * 60 + 35)
}

@Test("the default is 08:00")
func theDefaultIsEightAM() {
    #expect(TimeOfDay.eightAM.hour == 8)
    #expect(TimeOfDay.eightAM.minute == 0)
    #expect(TimeOfDay.eightAM.minutesSinceMidnight == 480)
}

/// The bound is what stops a hand-written `defaults write` from reaching
/// `Calendar`. Clamping was rejected: it would refresh at a time the user never
/// chose rather than at the default they can see in the pane.
@Test("a time outside the day is refused")
func aTimeOutsideTheDayIsRefused() {
    #expect(TimeOfDay(minutesSinceMidnight: -1) == nil)
    #expect(TimeOfDay(minutesSinceMidnight: 24 * 60) == nil)
    #expect(TimeOfDay(minutesSinceMidnight: 0) != nil)
    #expect(TimeOfDay(minutesSinceMidnight: 24 * 60 - 1) != nil)
    #expect(TimeOfDay(hour: 24, minute: 0) == nil)
    #expect(TimeOfDay(hour: 23, minute: 60) == nil)
    #expect(TimeOfDay(hour: -1, minute: 0) == nil)
}

/// **The conformance that was removed, pinned so its removal is falsifiable** (Copilot,
/// PR #46). A synthesized `init(from:)` assigns the stored property directly, so
/// `{"minutesSinceMidnight":1440}` decoded to an hour of 24 — a value the initializers
/// below refuse. Nothing serializes this type, so `Codable` cost the invariant and bought
/// nothing; without this test, re-adding it would contradict a comment and nothing else.
///
/// Through `Any`, so the compiler cannot decide the cast statically and warn about it.
@Test("TimeOfDay is not Codable, so no decoder can bypass its bounds")
func timeOfDayIsNotCodable() {
    let value: Any = TimeOfDay.eightAM

    #expect(!(value is any Decodable), "a synthesized init(from:) bypasses the bounds check")
    #expect(!(value is any Encodable))
}

@Test("a date's hour and minute become the setting, and its date is dropped")
func aDateBecomesATimeOfDay() throws {
    let calendar = try pacific()
    let afternoon = try instant("2026-10-06 14:45:30", in: calendar)

    let time = TimeOfDay(of: afternoon, calendar: calendar)

    #expect(time.hour == 14)
    #expect(time.minute == 45)
}

/// The probe this type's documentation records. `direction` defaults to `.forward`,
/// which reads as though this would answer *tomorrow's* 08:00 — it does not, and the
/// rule above it depends on which day is meant.
@Test("an occurrence is on the day it is asked about, even when already past")
func anOccurrenceStaysOnItsOwnDay() throws {
    let calendar = try pacific()
    let afternoon = try instant("2026-10-06 14:00:00", in: calendar)

    let morning = try #require(TimeOfDay.eightAM.instant(on: afternoon, calendar: calendar))

    #expect(morning == (try instant("2026-10-06 08:00:00", in: calendar)))
    #expect(morning < afternoon)
}

/// 02:30 does not exist on 2026-03-08 in this zone. Under the default
/// `matchingPolicy: .nextTime` the day still has an occurrence — 03:00 — so a skipped
/// hour costs thirty minutes rather than a whole day's refresh. `.strict` would answer
/// the *next day's* 02:30, which is why the default is load bearing.
@Test("a time inside a skipped hour moves forward, not to the next day")
func aSkippedHourMovesForward() throws {
    let calendar = try pacific()
    let springForward = try instant("2026-03-08 12:00:00", in: calendar)
    let halfPastTwo = try #require(TimeOfDay(hour: 2, minute: 30))

    let occurrence = try #require(halfPastTwo.instant(on: springForward, calendar: calendar))

    #expect(occurrence == (try instant("2026-03-08 03:00:00", in: calendar)))
}

@Test("a repeated hour answers its first instance")
func aRepeatedHourAnswersItsFirstInstance() throws {
    let calendar = try pacific()
    let fallBack = try instant("2026-11-01 12:00:00", in: calendar)
    let halfPastOne = try #require(TimeOfDay(hour: 1, minute: 30))

    let occurrence = try #require(halfPastOne.instant(on: fallBack, calendar: calendar))

    // The first 01:30 that day is still on daylight time, seven hours behind UTC.
    #expect(calendar.timeZone.secondsFromGMT(for: occurrence) == -7 * 60 * 60)
}
```

- [ ] **Step 2: Run them and confirm they fail**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -E "error:|Cannot find" /tmp/test.log | head -3
```

Expected: BUILD FAILED, `cannot find 'TimeOfDay' in scope`. A compile failure is the correct red here — the type does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Settings/TimeOfDay.swift`:

```swift
import Foundation

/// A wall-clock time with no date attached — FR-6's "refresh at 08:00", as a value.
///
/// **Not a `Date`, which is the whole reason this type exists.** SwiftUI's
/// `DatePicker(displayedComponents: .hourAndMinute)` binds a `Date`, so a setting
/// stored straight from the picker is an instant whose date component is noise every
/// reader has to know to ignore — and whose *meaning* moves with the time zone it
/// was written in, because 08:00 in Berlin and 08:00 in San Francisco are different
/// instants but the same setting. Minutes since midnight has no second meaning.
///
/// Stored as that one integer rather than as two, so `defaults read
/// com.lgabrielgr.steno` prints something legible and there is only one value to
/// validate on the way in.
/// **Deliberately not `Codable`** (Copilot, PR #46). A synthesized `init(from:)` assigns
/// the stored property directly, so it bypasses both validating initializers below:
/// `{"minutesSinceMidnight":1440}` decodes to an hour of 24, a value this type's own
/// initializer refuses. Nothing serializes a `TimeOfDay` — the setting is stored as an
/// `Int` in `UserDefaults`, and §10's export deliberately does not carry settings (D-024)
/// — so the conformance bought nothing and cost the invariant. If serialization is ever
/// needed, write `init(from:)` through `init?(minutesSinceMidnight:)` rather than letting
/// it be synthesized. `TimeOfDayTests` pins this, so re-adding it turns a test red rather
/// than only contradicting this comment.
public struct TimeOfDay: Sendable, Equatable {
    /// §5.5's default: "a user-set time (default 08:00)".
    ///
    /// **A static rather than `TimeOfDay(hour: 8, minute: 0)` at every call site.**
    /// The public initializers are failable — an out-of-range stored value must not
    /// be able to produce a `TimeOfDay` — and `force_unwrapping` is an enabled lint
    /// rule, so a literal default spelled at a call site would need an unwrap this
    /// repository does not allow. Built through the private unchecked initializer,
    /// whose argument is a literal the compiler can see.
    public static let eightAM = TimeOfDay(unchecked: 8 * 60)

    /// Minutes in a day, and the exclusive upper bound on `minutesSinceMidnight`.
    public static let minutesPerDay = 24 * 60

    /// The only stored property. `hour` and `minute` are views of it, so the two can
    /// never disagree.
    public let minutesSinceMidnight: Int

    public var hour: Int { minutesSinceMidnight / 60 }
    public var minute: Int { minutesSinceMidnight % 60 }

    /// `nil` for a time outside the day.
    ///
    /// **Failable rather than clamping**, because the caller is either a settings
    /// read — where the right answer to a nonsense stored value is "use the default",
    /// which only the caller knows — or a test. Clamping would turn `25:00` into
    /// 23:59 and refresh at a time the user never chose.
    public init?(minutesSinceMidnight minutes: Int) {
        guard (0..<Self.minutesPerDay).contains(minutes) else { return nil }
        self.minutesSinceMidnight = minutes
    }

    /// `nil` unless both components are in range.
    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.minutesSinceMidnight = hour * 60 + minute
    }

    /// The hour and minute `date` falls on, in `calendar`.
    ///
    /// Not failable: `Calendar.component(_:from:)` answers an hour in `0..<24` and a
    /// minute in `0..<60` for every date and every calendar, so there is no
    /// out-of-range case for a caller to handle. This is how the Settings picker's
    /// `Date` becomes a setting.
    public init(of date: Date, calendar: Calendar) {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        self.init(unchecked: hour * 60 + minute)
    }

    /// Trusted construction, for values the compiler or `Calendar` has already
    /// bounded. Private, so "trusted" cannot be claimed from another file.
    private init(unchecked minutes: Int) {
        self.minutesSinceMidnight = minutes
    }

    /// This time of day on `day`'s calendar date, or `nil` if the calendar cannot
    /// form one.
    ///
    /// **The one place `date(bySettingHour:minute:second:of:)` is called**, so its
    /// behaviour is documented once. Probed on 2026-10-06, `America/Los_Angeles`:
    ///
    /// - It does **not** search forward across days, despite `direction` defaulting
    ///   to `.forward`: 08:00 applied to a 14:00 date answers that same day's 08:00,
    ///   already in the past. The `startOfDay` anchor below is kept regardless, so
    ///   that which day is meant does not depend on reading that subtlety correctly.
    /// - On a spring-forward day, a time inside the skipped hour answers the next
    ///   valid instant that day — 02:30 becomes 03:00 — under the default
    ///   `matchingPolicy: .nextTime`. `.strict` instead answers *the next day's*
    ///   02:30, which would skip a day's refresh outright, so the default is load
    ///   bearing and not merely inherited.
    /// - On a fall-back day, a repeated time answers its first instance.
    ///
    /// The `nil` return is unreachable for a `TimeOfDay`, every value of which names
    /// an hour and minute `Calendar` can match. It is still propagated rather than
    /// forced, because the only honest alternative is a crash in a background timer.
    public func instant(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
    }
}
```

Two things in that file are load-bearing and were measured, not assumed (probe, `America/Los_Angeles`, 2026-10-06):

- `date(bySettingHour:minute:second:of:)` does **not** search forward across days, although `direction` defaults to `.forward`. 08:00 applied to a 14:00 date answers that day's 08:00, already past.
- A time inside a spring-forward skipped hour answers the next valid instant **that day** (02:30 → 03:00) under the default `matchingPolicy: .nextTime`. `.strict` answers *the next day's* 02:30 and would skip a day's refresh.

- [ ] **Step 4: Run them and confirm they pass**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # must print 0
```

- [ ] **Step 5: Mutate, to prove the tests can fail**

Apply each edit, run `make test`, confirm the named test goes red, then revert it.

| Edit | Must go red |
|---|---|
| `guard (0..<Self.minutesPerDay)` → `guard (0...Self.minutesPerDay)` | `a time outside the day is refused` |
| add `matchingPolicy: .strict` to the `date(bySettingHour:...)` call | `a time inside a skipped hour moves forward, not to the next day` |

```bash
git checkout -- StenoKit/Settings/TimeOfDay.swift   # after each mutation
```

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Settings/TimeOfDay.swift StenoTests/Settings/TimeOfDayTests.swift
git commit   # subject: "feat: TimeOfDay, so a schedule is not a Date"
```

The body says *why*: the picker binds a `Date`, the stored setting must not be one, and `instant(on:calendar:)` is the one place the calendar API is called so its measured behaviour is documented once.

---

## Task 2: The schedule's three settings keys

**Files:**
- Create: `StenoKit/Settings/AppSettings+ScheduledRefresh.swift` — this feature's keys and accessors, as an extension
- Modify: `StenoKit/Settings/AppSettings.swift` — add the keys to `allKeys` (the array at ~line 50); make `defaults` and `flag(_:)` internal rather than `private`, since `private` is file-scoped and the extension is the other half of the type
- Modify: `StenoTests/Settings/AppSettingsTests.swift` — append a `// MARK: - §5.5's scheduled refresh (M4-05)` section at the end
- Modify: `StenoTests/AI/AISecretsTests.swift:47` — `#expect(AppSettings.allKeys.count == 10)` becomes `14`

**Why an extension and not more of `AppSettings.swift`:** that file reaches SwiftLint's 400-line `file_length` limit once this feature's keys are in it, and `--strict` makes that a build failure. Splitting by subject is what `IntegrationsSettingsModel+Credential.swift` already does. Task 1's `TimeOfDay` and Task 7's `CredentialRejection` are both referenced from here, so write this file after Task 1 and extend it in Task 7.

**Interfaces:**
- Consumes: `TimeOfDay` and `TimeOfDay.eightAM` (Task 1).
- Produces, used by Tasks 4 and 5:
  - `AppSettings.scheduledRefreshEnabledKey / scheduledRefreshTimeKey / scheduledRefreshLastRunKey: String`
  - `var scheduledRefreshEnabled: Bool { get nonmutating set }`
  - `var scheduledRefreshTime: TimeOfDay { get nonmutating set }`
  - `var scheduledRefreshLastRun: Date? { get nonmutating set }`

- [ ] **Step 1: Write the failing tests**

Append to `StenoTests/Settings/AppSettingsTests.swift` (the file already has a private `scratch()` returning `(AppSettings, UserDefaults)` over a per-test suite — use it, do not write a second one):

```swift
// MARK: - §5.5's scheduled refresh (M4-05)

/// **Absence means enabled**, which `UserDefaults.bool(forKey:)` cannot say. §5.5
/// states the schedule as policy rather than as an option, and the inverse spelling
/// would make a fresh install's schedule inert in the one direction nobody notices: a
/// pass that never fires looks exactly like one with nothing to fetch.
@Test("a fresh install has the schedule on, at 08:00, never run")
@MainActor
func aFreshInstallIsScheduledAtEight() throws {
    let (settings, _) = try scratch()

    #expect(settings.scheduledRefreshEnabled)
    #expect(settings.scheduledRefreshTime == .eightAM)
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("the schedule's three settings round-trip")
@MainActor
func theScheduleRoundTrips() throws {
    let (settings, _) = try scratch()
    let dispatchedAt = Date(timeIntervalSince1970: 1_792_000_000)
    let quarterPastSix = try #require(TimeOfDay(hour: 6, minute: 15))

    settings.scheduledRefreshEnabled = false
    settings.scheduledRefreshTime = quarterPastSix
    settings.scheduledRefreshLastRun = dispatchedAt

    #expect(settings.scheduledRefreshEnabled == false)
    #expect(settings.scheduledRefreshTime == quarterPastSix)
    #expect(settings.scheduledRefreshLastRun == dispatchedAt)
}

/// Midnight is a legitimate setting, which is why the getter reads `object(forKey:)`
/// rather than `integer(forKey:)` — the latter answers `0` for an absent key, so
/// midnight and "unset" would be the same value and the 08:00 default would be
/// unreachable for anyone who ever chose 00:00.
@Test("midnight is a real setting, not an absent one")
@MainActor
func midnightIsARealSetting() throws {
    let (settings, _) = try scratch()
    let midnight = try #require(TimeOfDay(minutesSinceMidnight: 0))

    settings.scheduledRefreshTime = midnight

    #expect(settings.scheduledRefreshTime == midnight)
}

@Test("an out-of-range stored time reads as the default")
@MainActor
func anOutOfRangeTimeReadsAsTheDefault() throws {
    let (settings, defaults) = try scratch()

    // What a hand-written `defaults write` can produce. It must not trap, and it must
    // not schedule a refresh at a time the user never chose.
    defaults.set(99 * 60, forKey: AppSettings.scheduledRefreshTimeKey)

    #expect(settings.scheduledRefreshTime == .eightAM)
}

@Test("a stored time of the wrong type reads as the default")
@MainActor
func aWrongTypedTimeReadsAsTheDefault() throws {
    let (settings, defaults) = try scratch()

    defaults.set("eight o'clock", forKey: AppSettings.scheduledRefreshTimeKey)

    #expect(settings.scheduledRefreshTime == .eightAM)
}

@Test("clearing the last run removes it")
@MainActor
func clearingTheLastRunRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.scheduledRefreshLastRun = Date()

    settings.scheduledRefreshLastRun = nil

    #expect(settings.scheduledRefreshLastRun == nil)
    #expect(defaults.object(forKey: AppSettings.scheduledRefreshLastRunKey) == nil)
}

@Test("the unattended credential rejection round-trips")
@MainActor
func theRejectionRoundTrips() throws {
    let (settings, _) = try scratch()
    let rejection = CredentialRejection(
        displayName: "Jira", at: Date(timeIntervalSince1970: 1_792_000_000))

    settings.scheduledRefreshRejection = rejection

    #expect(settings.scheduledRefreshRejection == rejection)
}

@Test("an unreadable stored rejection reads as none")
@MainActor
func anUnreadableRejectionReadsAsNone() throws {
    let (settings, defaults) = try scratch()

    defaults.set("not json", forKey: AppSettings.scheduledRefreshRejectionKey)

    #expect(settings.scheduledRefreshRejection == nil)
}

@Test("clearing the rejection removes it")
@MainActor
func clearingTheRejectionRemovesIt() throws {
    let (settings, defaults) = try scratch()
    settings.scheduledRefreshRejection = CredentialRejection(displayName: "Jira", at: Date())

    settings.scheduledRefreshRejection = nil

    #expect(settings.scheduledRefreshRejection == nil)
    #expect(defaults.object(forKey: AppSettings.scheduledRefreshRejectionKey) == nil)
}
```

- [ ] **Step 2: Run them and confirm they fail**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -E "error:|Cannot find|has no member" /tmp/test.log | head -3
```

Expected: BUILD FAILED — `value of type 'AppSettings' has no member 'scheduledRefreshEnabled'`.

- [ ] **Step 3: Add the keys and their accessors**

In `AppSettings.allKeys`, after `integrationsDisabledKey,`:

```swift
        scheduledRefreshEnabledKey,
        scheduledRefreshTimeKey,
        scheduledRefreshLastRunKey,
```

Then create `StenoKit/Settings/AppSettings+ScheduledRefresh.swift`:

```swift
import Foundation

/// §5.5's scheduled refresh, as settings (M4-05).
///
/// **A second file rather than more of `AppSettings.swift`**, which reached SwiftLint's
/// 400-line `file_length` limit when D-227's rejection record was added. Split by subject,
/// the way `IntegrationsSettingsModel+Credential.swift` splits its own type: everything here
/// belongs to one feature, and the audit that reads `AppSettings.allKeys` is unaffected —
/// the keys below are declared in this extension and listed in that array, which the
/// compiler checks and `AISecretsTests` counts.
extension AppSettings {
    // MARK: - §5.5, the scheduled background refresh

    /// M4-05's three keys, namespaced for the reason auto-export's six are.
    ///
    /// `lastRun` is state rather than preference, and lives here anyway, beside
    /// `autoExportStatus` which is also state — this type's doc comment above is
    /// explicit that one place for every `UserDefaults` key is what makes §8's
    /// audit possible.
    public static let scheduledRefreshEnabledKey = "com.lgabrielgr.steno.scheduledRefresh.enabled"
    public static let scheduledRefreshTimeKey = "com.lgabrielgr.steno.scheduledRefresh.time"
    public static let scheduledRefreshLastRunKey = "com.lgabrielgr.steno.scheduledRefresh.lastRun"
    public static let scheduledRefreshRejectionKey =
        "com.lgabrielgr.steno.scheduledRefresh.rejection"

    /// Whether §5.5's scheduled pass runs at all.
    ///
    /// **Absent means `true`.** §5.5 states the schedule as policy rather than as an
    /// option, so a fresh install schedules; the toggle exists because unattended
    /// network activity deserves an off switch that is not "switch the integration
    /// off entirely", which would also stop the launch and Prepare passes. `flag(_:)`
    /// is what expresses that, for the reason it was written: `bool(forKey:)` answers
    /// `false` for a key never written, and a schedule that silently never fires looks
    /// exactly like one with nothing to fetch.
    public var scheduledRefreshEnabled: Bool {
        get { flag(Self.scheduledRefreshEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.scheduledRefreshEnabledKey) }
    }

    /// When the scheduled pass runs. 08:00 unless the user says otherwise (§5.5).
    ///
    /// Stored as minutes since midnight — see `TimeOfDay`, which exists so this is not
    /// a `Date` whose date component is noise and whose meaning moves with the time
    /// zone it was written in.
    ///
    /// **An unusable stored value reads as the default rather than trapping**, which
    /// is `hotkeyChord`'s posture and for its reason: a hand-written `defaults write`
    /// must not be able to break the app. `object(forKey:)` rather than
    /// `integer(forKey:)`, because the latter answers `0` for an absent key and `0` is
    /// a legitimate setting — midnight.
    public var scheduledRefreshTime: TimeOfDay {
        get {
            guard let stored = defaults.object(forKey: Self.scheduledRefreshTimeKey) as? Int,
                let time = TimeOfDay(minutesSinceMidnight: stored)
            else { return .eightAM }
            return time
        }
        nonmutating set {
            defaults.set(newValue.minutesSinceMidnight, forKey: Self.scheduledRefreshTimeKey)
        }
    }

    /// When a scheduled pass was last **dispatched** — not when one last succeeded
    /// (D-223).
    ///
    /// `nil` until the first one runs, which is what makes the first launch after
    /// install serve the day's occurrence if it is inside the grace window.
    public var scheduledRefreshLastRun: Date? {
        get { defaults.object(forKey: Self.scheduledRefreshLastRunKey) as? Date }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.scheduledRefreshLastRunKey)
                return
            }
            defaults.set(newValue, forKey: Self.scheduledRefreshLastRunKey)
        }
    }

    /// The credential an unattended pass last found broken (D-227), or `nil`.
    ///
    /// **This is the M4-05 requirement that `expiryWarning` cannot meet.** That warning is
    /// derived from the user-entered expiry date, so a revoked token — or one that expired
    /// with no date recorded — leaves the pane silent; the scheduled pass is the only thing
    /// that knows, and before this key it discarded what it knew (Copilot, PR #46).
    ///
    /// Stored as JSON, the shape `autoExportStatus` uses, and an unreadable value reads as
    /// `nil` rather than being overwritten — `hotkeyChord`'s posture.
    public var scheduledRefreshRejection: CredentialRejection? {
        get {
            guard let data = defaults.data(forKey: Self.scheduledRefreshRejectionKey),
                let decoded = try? JSONDecoder().decode(CredentialRejection.self, from: data)
            else { return nil }
            return decoded
        }
        nonmutating set {
            guard let newValue, let encoded = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.scheduledRefreshRejectionKey)
                return
            }
            defaults.set(encoded, forKey: Self.scheduledRefreshRejectionKey)
        }
    }
}
```

The fourth key and its accessor — `scheduledRefreshRejection` — belong to Task 7; everything else here is this task's.

Three readings in there are deliberate and each has a test:

- **Absence of the toggle means enabled.** §5.5 states the schedule as policy, not as an option, so a fresh install schedules. `flag(_:)` already exists for exactly this: `bool(forKey:)` answers `false` for a key never written, and a schedule that silently never fires looks exactly like one with nothing to fetch.
- **`object(forKey:) as? Int`, not `integer(forKey:)`.** The latter answers `0` for an absent key, and `0` is midnight — a legitimate setting. Written the obvious way, midnight and "unset" become the same value and the 08:00 default is unreachable for anyone who chose 00:00.
- **An unusable stored value reads as the default** rather than trapping, which is `hotkeyChord`'s posture: a hand-written `defaults write` must not be able to break the app.

- [ ] **Step 4: Update the §8 audit's count**

`StenoTests/AI/AISecretsTests.swift`: `#expect(AppSettings.allKeys.count == 10)` → `14` (three keys here, one more in Task 7).

That assertion is what stops the audit passing by matching nothing — a key added without being listed in `allKeys` turns the suite red rather than quietly shrinking the audit's coverage. Confirm the other assertion in that test still holds: none of the three new key names looks like a credential.

- [ ] **Step 5: Run them and confirm they pass**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # must print 0
```

- [ ] **Step 6: Mutate, to prove the tests can fail**

| Edit | Must go red |
|---|---|
| `get { flag(Self.scheduledRefreshEnabledKey) }` → `get { defaults.bool(forKey: Self.scheduledRefreshEnabledKey) }` | `a fresh install has the schedule on, at 08:00, never run` |
| the time getter's `object(forKey:) as? Int` → `integer(forKey:)` (with `case let` to keep it compiling) | `a fresh install has the schedule on, at 08:00, never run` — because midnight then reads as the stored value for an absent key |

- [ ] **Step 7: Commit**

```bash
git add StenoKit/Settings/AppSettings.swift StenoTests/Settings/AppSettingsTests.swift \
        StenoTests/AI/AISecretsTests.swift
git commit   # subject: "feat: the schedule's three settings keys"
```

---

## Task 3: The rule that decides when a pass is owed

**Files:**
- Create: `StenoKit/Integrations/ScheduledRefreshDue.swift`
- Test: `StenoTests/Integrations/ScheduledRefreshDueTests.swift`

**Interfaces:**
- Consumes: `TimeOfDay`, `TimeOfDay.eightAM`, `TimeOfDay.instant(on:calendar:)` (Task 1); `Log.sources` (existing, `StenoKit/Support/Logging.swift`).
- Produces, used by Task 4:
  - `ScheduledRefreshDue.grace: TimeInterval` (four hours)
  - `ScheduledRefreshDue.isDue(now: Date, at: TimeOfDay, lastRun: Date?, grace: TimeInterval = .grace, calendar: Calendar) -> Bool`
  - `ScheduledRefreshDue.mostRecentOccurrence(of: TimeOfDay, notAfter: Date, calendar: Calendar) -> Date?` (internal)

**The two decisions in this file:**

- **The most recent occurrence, not today's.** Today's is the obvious reading and is wrong at the edge a laptop hits most: with the time set to 23:00, a Mac asleep from 23:30 until 01:00 computes that day's 23:00, finds it in the future, and concludes nothing is owed — silently dropping the occurrence the grace window exists to catch.
- **Four hours, then the day is skipped.** The launch pass already refreshes anything older than thirty minutes and Prepare Stand-up refreshes the window unconditionally, so correctness never depends on this; a 19:00 catch-up optimizes a morning that has gone, and retrying one would be the thundering herd the task forbids.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Integrations/ScheduledRefreshDueTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

/// A fixed calendar. Every case below is a date arithmetic question, so inheriting the
/// machine's time zone would make the suite pass or fail by geography.
private func calendar(in zone: String = "America/Los_Angeles") throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
}

private func instant(_ text: String, in calendar: Calendar) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return try #require(formatter.date(from: text))
}

private func isDue(
    _ nowText: String, time: TimeOfDay = .eightAM, lastRun: String? = nil,
    zone: String = "America/Los_Angeles"
) throws -> Bool {
    let calendar = try calendar(in: zone)
    return ScheduledRefreshDue.isDue(
        now: try instant(nowText, in: calendar), at: time,
        lastRun: try lastRun.map { try instant($0, in: calendar) },
        calendar: calendar)
}

// MARK: - The window

@Test("nothing is due before the configured time")
func nothingIsDueBeforeTheTime() throws {
    #expect(try isDue("2026-10-06 07:59:59") == false)
}

/// The lower boundary, pinned: exactly at the configured time *is* due. Mutating the
/// comparison in `mostRecentOccurrence` from `<=` to `<` makes this red.
@Test("the configured minute itself is due")
func theConfiguredMinuteIsDue() throws {
    #expect(try isDue("2026-10-06 08:00:00"))
}

@Test("a pass is due inside the grace window")
func aPassIsDueInsideTheWindow() throws {
    #expect(try isDue("2026-10-06 11:59:59"))
}

/// The upper boundary, pinned in the other direction: exactly `grace` late is *not*
/// due. Mutating `<` to `<=` in `isDue` makes this red.
@Test("exactly four hours late is too late")
func exactlyFourHoursLateIsTooLate() throws {
    #expect(try isDue("2026-10-06 12:00:00") == false)
}

@Test("an afternoon launch does not refresh for a morning that has gone")
func anAfternoonLaunchSkipsTheDay() throws {
    #expect(try isDue("2026-10-06 16:30:00") == false)
}

// MARK: - The stamp

@Test("an occurrence already served is not served again")
func anOccurrenceIsServedOnce() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2026-10-06 08:02:00") == false)
}

@Test("yesterday's pass does not serve today's occurrence")
func yesterdaysPassDoesNotCount() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2026-10-05 08:02:00"))
}

/// A clock dragged backwards — a stored `Date` read after a time-zone change is the
/// usual cause — must not disable the schedule until real time catches up, which for a
/// mis-set year means never. `AutoExportDue` takes the same position.
@Test("a stamp in the future is treated as no stamp")
func aFutureStampIsIgnored() throws {
    #expect(try isDue("2026-10-06 09:00:00", lastRun: "2027-01-01 08:00:00"))
}

// MARK: - Midnight, and the walk-back

/// The edge a laptop hits most, and the reason the rule asks for the most recent
/// occurrence rather than today's: computing *this* day's 23:00 at 01:00 finds it in the
/// future and concludes nothing is owed, silently dropping the occurrence the grace
/// window exists to catch.
@Test("a late-evening schedule is still served after midnight")
func aLateEveningScheduleSurvivesMidnight() throws {
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))

    #expect(try isDue("2026-10-07 01:00:00", time: elevenAtNight))
}

@Test("a late-evening schedule expires after midnight like any other")
func aLateEveningScheduleStillExpires() throws {
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))

    #expect(try isDue("2026-10-07 03:30:00", time: elevenAtNight) == false)
}

/// **An app left running past midnight must not re-serve yesterday's occurrence.** The
/// walk-back makes the most recent occurrence yesterday's 08:00 at 00:30, and the stamp
/// from yesterday morning is what keeps it served — without that comparison a machine
/// left on overnight would fetch again every night at midnight.
@Test("a tick after midnight does not re-serve yesterday's morning")
func aTickAfterMidnightDoesNotRepeatYesterday() throws {
    #expect(try isDue("2026-10-07 00:30:00", lastRun: "2026-10-06 08:02:00") == false)
}

@Test("the walk-back finds the previous day's occurrence")
func theWalkBackFindsYesterday() throws {
    let pacific = try calendar()
    let elevenAtNight = try #require(TimeOfDay(hour: 23, minute: 0))
    let afterMidnight = try instant("2026-10-07 01:00:00", in: pacific)

    let occurrence = ScheduledRefreshDue.mostRecentOccurrence(
        of: elevenAtNight, notAfter: afterMidnight, calendar: pacific)

    #expect(occurrence == (try instant("2026-10-06 23:00:00", in: pacific)))
}

// MARK: - Daylight saving

/// 02:30 does not exist on 2026-03-08 in this zone; the occurrence lands at 03:00. The
/// day is not skipped, which is what `matchingPolicy: .nextTime` buys — `.strict` would
/// answer the next day's 02:30 and drop a day's refresh.
@Test("a schedule inside a skipped hour still runs that day")
func aSkippedHourStillRuns() throws {
    let halfPastTwo = try #require(TimeOfDay(hour: 2, minute: 30))

    #expect(try isDue("2026-03-08 03:05:00", time: halfPastTwo))
}

@Test("a repeated hour fires once, not twice")
func aRepeatedHourFiresOnce() throws {
    let pacific = try calendar()
    let halfPastOne = try #require(TimeOfDay(hour: 1, minute: 30))
    let firstInstance = try instant("2026-11-01 01:30:00", in: pacific)

    // 01:45 on the first pass through the hour: due, and nothing has run yet.
    #expect(
        ScheduledRefreshDue.isDue(
            now: firstInstance.addingTimeInterval(15 * 60), at: halfPastOne, lastRun: nil,
            calendar: pacific))

    // 01:45 again an hour later, on standard time. The stamp from the first instance
    // covers it: the day gets one pass, not two.
    #expect(
        ScheduledRefreshDue.isDue(
            now: firstInstance.addingTimeInterval(75 * 60), at: halfPastOne,
            lastRun: firstInstance, calendar: pacific) == false)
}

/// The same instant, two calendars. This is what the controller's per-tick
/// `calendar()` read buys: a user who flies from California to Berlin gets 08:00 in
/// Berlin on the next tick, with nothing re-armed and no relaunch.
@Test("the verdict follows the calendar it is given")
func theVerdictFollowsTheCalendar() throws {
    let pacific = try calendar()
    let moment = try instant("2026-10-06 08:00:00", in: pacific)
    let berlin = try calendar(in: "Europe/Berlin")

    #expect(
        ScheduledRefreshDue.isDue(
            now: moment, at: .eightAM, lastRun: nil, calendar: pacific))
    // 08:00 Pacific is 17:00 in Berlin — nine hours past the window.
    #expect(
        ScheduledRefreshDue.isDue(
            now: moment, at: .eightAM, lastRun: nil, calendar: berlin) == false)
}
```

Every case pins a fixed calendar. Inheriting the machine's time zone would make the suite pass or fail by geography, and two of the cases are about time zones.

- [ ] **Step 2: Run them and confirm they fail**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -E "error:|Cannot find" /tmp/test.log | head -3
```

Expected: BUILD FAILED, `cannot find 'ScheduledRefreshDue' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Integrations/ScheduledRefreshDue.swift`:

```swift
import Foundation

/// §5.5's "scheduled background refresh at a user-set time", as arithmetic.
///
/// **Pure, and holds no clock** — `RefreshPolicy`'s posture, for `RefreshPolicy`'s
/// reason: the rule that decides when the app reaches the network is the part worth
/// a test table rather than a wait. `ScheduledRefreshController` owns the timer and
/// has no decisions of its own.
///
/// **This is a latency optimization, not a data-integrity mechanism** (§5.5). The
/// launch pass refreshes anything older than 30 minutes and "Prepare Stand-up"
/// refreshes the report window unconditionally, so correctness never depends on this
/// rule firing. That is what licenses every answer below to be "no".
public enum ScheduledRefreshDue {
    /// How late a missed occurrence may still be served.
    ///
    /// Four hours: long enough that a Mac opened at 11:00 still gets its morning
    /// warmed, short enough that an evening launch does not spend requests on a
    /// morning that has gone. Past it the day is skipped rather than queued —
    /// M4-05's acceptance criteria ask for "a catch-up on next launch rather than a
    /// skipped day **or a thundering herd of requests**", and the window is how both
    /// halves of that sentence hold at once.
    public static let grace: TimeInterval = 4 * 60 * 60

    /// Whether a scheduled pass is owed right now.
    ///
    /// - Parameters:
    ///   - now: the caller's clock, injected so every case below is a test rather
    ///     than a wait.
    ///   - time: the user's configured time of day.
    ///   - lastRun: when a scheduled pass was last *dispatched* — not when one last
    ///     succeeded (D-223). A failed pass is a non-event under §5.5, and measuring
    ///     from success would retry every tick until the grace window closed.
    ///   - calendar: passed in rather than read here, and read fresh by the caller on
    ///     every tick, which is what makes a time-zone change take effect without
    ///     anything being re-armed.
    public static func isDue(
        now: Date,
        at time: TimeOfDay,
        lastRun: Date?,
        grace: TimeInterval = ScheduledRefreshDue.grace,
        calendar: Calendar
    ) -> Bool {
        guard let occurrence = mostRecentOccurrence(of: time, notAfter: now, calendar: calendar)
        else {
            // Unreachable for any `TimeOfDay` — see `TimeOfDay.instant(on:calendar:)`,
            // which documents the probe. Logged rather than ignored, because the only
            // way to arrive here is a `Calendar` behaving in a way this code does not
            // model, and silence would make that look like "nothing was due".
            Log.sources.error("scheduled refresh: no occurrence could be formed for the set time")
            return false
        }

        // **Strictly less than, so exactly `grace` late is not due.** Which side the
        // boundary falls on matters less than a test holding it still — the posture
        // `RefreshPolicy.due` already takes for its own boundary.
        guard now.timeIntervalSince(occurrence) < grace else { return false }

        guard let lastRun else { return true }

        // A stamp in the future is treated as no stamp at all. A clock dragged
        // backwards — usually a stored `Date` read after a time-zone change — would
        // otherwise suppress the schedule until real time caught up, which for a
        // mis-set year means never. `AutoExportDue` takes the same position.
        if lastRun > now { return true }

        // The occurrence has already been served. This is the line that makes a
        // repeated hour on a fall-back day fire once, and the line that makes a
        // five-minute tick inside one window dispatch one pass.
        return lastRun < occurrence
    }

    /// The latest instant matching `time` that is at or before `now`.
    ///
    /// **Not "today's occurrence", which is the obvious reading and is wrong at the
    /// edge a laptop hits most.** With the time set to 23:00, a Mac asleep from 23:30
    /// until 01:00 computes *that day's* 23:00, finds it in the future, and concludes
    /// nothing is owed — silently dropping the one occurrence the grace window exists
    /// to catch. Walking back a day costs one branch and removes the whole class.
    ///
    /// `internal` rather than private so the walk-back can be asserted directly; the
    /// public rule's tests would only see it through two other comparisons.
    static func mostRecentOccurrence(
        of time: TimeOfDay, notAfter now: Date, calendar: Calendar
    ) -> Date? {
        guard let today = time.instant(on: now, calendar: calendar) else { return nil }
        if today <= now { return today }
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
        return time.instant(on: dayBefore, calendar: calendar)
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # must print 0
```

- [ ] **Step 5: Mutate, to prove the tests can fail**

| Edit | Must go red |
|---|---|
| `now.timeIntervalSince(occurrence) < grace` → `<= grace` | `exactly four hours late is too late` |
| `if today <= now { return today }` → `if today < now { ... }` | `the configured minute itself is due` |
| `return lastRun < occurrence` → `return lastRun > occurrence` | `yesterday's pass does not serve today's occurrence` |
| delete the walk-back: `if today <= now { return today }` + the `dayBefore` lines → `return today` | `the walk-back finds the previous day's occurrence`, `a tick after midnight does not re-serve yesterday's morning`, `a late-evening schedule expires after midnight like any other`, `nothing is due before the configured time`, `a tick before the window neither dispatches nor stamps`, `the launch pass runs even when no occurrence is owed` |
| `if lastRun > now { return true }` → neutralize it with `&& false` | `a stamp in the future is treated as no stamp` |

A survivor means one of three things, and "the test is fine" is not among them: a mis-aimed mutation, a weak test, or a guard written at the wrong level.

**One row above is weaker than it looks, and the sweep is how that was found.** `a late-evening schedule is still served after midnight` does *not* go red when the walk-back is deleted: without it the occurrence is today's 23:00, still in the future, and `now - occurrence` is then negative — which is also less than the grace window, so the verdict stays `true` for the wrong reason. The walk-back is held by `the walk-back finds the previous day's occurrence`, which asserts the instant directly. Keep both: the behavioural one states the promise, the direct one is what can fail.

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/ScheduledRefreshDue.swift \
        StenoTests/Integrations/ScheduledRefreshDueTests.swift
git commit   # subject: "feat: the rule that decides when a scheduled pass is owed"
```

---

## Task 4: The tick, and the stamp written before the pass runs

**Files:**
- Create: `StenoKit/Integrations/ScheduledRefreshController.swift`
- Test: `StenoTests/Integrations/ScheduledRefreshControllerTests.swift`

**Interfaces:**
- Consumes: `AppSettings` and its three new accessors (Task 2); `ScheduledRefreshDue.isDue` (Task 3); `Log.sources`.
- Produces, used by Task 6:
  - `ScheduledRefreshController.tickInterval: TimeInterval` (five minutes)
  - `init(settings: AppSettings = AppSettings(), now: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { .current }, refresh: @escaping @MainActor () async -> Void)`
  - `func start(interval: TimeInterval = tickInterval)`, `func stop()`
  - internal: `@discardableResult func tick() -> Bool`, `@discardableResult func runLaunchPass() -> Bool`, `var armedTimer: Timer?`

**Read `AutoExportController` first** (`StenoKit/Portability/AutoExport/AutoExportController.swift`). This is deliberately the same shape: a timer, a `.common` run-loop mode, an idempotent `start()`, and every decision in a pure function elsewhere.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Integrations/ScheduledRefreshControllerTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

/// A box, because the refresh closure escapes and a captured `var` cannot be mutated
/// from one.
@MainActor
private final class PassCounter {
    var count = 0
}

/// Wait up to `limit` for `condition`, yielding between checks.
///
/// **A deadline, not a continuation the refresh closure resumes.** The continuation
/// version read better and was wrong in the way that matters: a mutation which stops the
/// pass being dispatched left it never resumed, so the suite *hung* instead of going red
/// — found by the mutation sweep, where one edit turned a fifteen-second run into a
/// fifteen-minute one. A test that hangs under mutation is worse than one that fails,
/// because the failure never arrives and nothing says why.
///
/// Returns `false` on timeout, so the caller's `#expect` is what records the issue. Two
/// seconds is generous for a `Task` already enqueued on this actor; the loop costs
/// nothing when the pass has already run.
@MainActor
private func waitFor(
    _ limit: Duration = .seconds(2), _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func scratchSettings() throws -> AppSettings {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    return AppSettings(defaults: defaults)
}

private func pacific() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    return calendar
}

private func instant(_ text: String, in calendar: Calendar) throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return try #require(formatter.date(from: text))
}

/// A controller whose clock stands still at `nowText` and whose pass does nothing.
///
/// The pass is a no-op because every test here asserts the *decision*, which
/// `tick()` and `runLaunchPass()` return synchronously. Observing the pass itself
/// through the closure would mean waiting on a `Task` that has not necessarily started
/// when they return — `aDispatchedPassReachesTheRefreshClosure` below is the one test
/// that waits for it, and it waits deterministically.
@MainActor
private func controller(
    settings: AppSettings, at nowText: String
) throws -> ScheduledRefreshController {
    let calendar = try pacific()
    let moment = try instant(nowText, in: calendar)
    return ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: { .idle })
}

@Test("a tick inside the window dispatches and stamps")
@MainActor
func aTickInsideTheWindowDispatches() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick())
    #expect(settings.scheduledRefreshLastRun != nil)
}

@Test("a tick before the window neither dispatches nor stamps")
@MainActor
func aTickBeforeTheWindowDoesNothing() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 07:30:00")

    #expect(subject.tick() == false)
    #expect(settings.scheduledRefreshLastRun == nil)
}

/// Five-minute ticks mean a four-hour window contains forty-eight of them. One
/// occurrence, one pass: the stamp written at dispatch is what makes the rest not-due,
/// which is also why the controller needs no in-flight flag.
@Test("two ticks inside one occurrence dispatch one pass")
@MainActor
func twoTicksDispatchOnePass() throws {
    let settings = try scratchSettings()
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick())
    #expect(subject.tick() == false)
}

/// The stamp is written at dispatch, not at success (D-223), so a pass that fails is
/// not retried every five minutes until noon. The failure is modelled the way §5.5
/// makes it available: the refresh closure returns having done nothing useful.
@Test("a failed pass is not retried inside the same occurrence")
@MainActor
func aFailedPassIsNotRetried() throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let attempts = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            attempts.count += 1
            return .idle
        })

    #expect(subject.tick())
    #expect(subject.tick() == false)
    #expect(subject.tick() == false)
    // The stamp survived the failure, which is the whole point: the next occurrence
    // still runs, this one does not run again.
    #expect(settings.scheduledRefreshLastRun == moment)
    #expect(attempts.count <= 1)
}

@Test("the toggle switches the schedule off entirely")
@MainActor
func theToggleSwitchesItOff() throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let subject = try controller(settings: settings, at: "2026-10-06 08:03:00")

    #expect(subject.tick() == false)
    // Nothing was claimed, so switching the schedule back on later still serves the
    // occurrence rather than finding it already stamped.
    #expect(settings.scheduledRefreshLastRun == nil)
}

/// §5.5's launch pass runs whether or not an occurrence is owed; the schedule decides
/// only whether this pass also serves one (D-224). Two passes at launch is the defect
/// this pins.
@Test("the launch pass runs even when no occurrence is owed")
@MainActor
func theLaunchPassAlwaysRuns() throws {
    let settings = try scratchSettings()
    let early = try controller(settings: settings, at: "2026-10-06 06:00:00")

    #expect(early.runLaunchPass() == false)
    #expect(settings.scheduledRefreshLastRun == nil)
}

@Test("a launch inside the window serves the occurrence as well")
@MainActor
func aLaunchInsideTheWindowServesIt() throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 09:30:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar }, refresh: { .idle })

    #expect(subject.runLaunchPass())
    #expect(settings.scheduledRefreshLastRun == moment)
    // And the tick that follows minutes later finds nothing owed.
    #expect(subject.tick() == false)
}

/// **Switching the schedule off must not switch off §5.5's launch pass**, which is a
/// fixed rule and not the setting the user was given. The toggle governs the unattended
/// pass at a time of day; a launch is the user opening the app.
@Test("the launch pass still runs with the schedule switched off")
@MainActor
func theLaunchPassIgnoresTheToggle() async throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)

    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            passes.count += 1
            return .idle
        })

    // No occurrence is claimed — the schedule is off — and the pass runs anyway.
    #expect(subject.runLaunchPass() == false)
    #expect(await waitFor { passes.count == 1 }, "the launch pass never reached the service")
    #expect(settings.scheduledRefreshLastRun == nil)
}

/// A scheduled `Timer` is retained by the run loop, so reassigning the property does
/// not stop the old one. Found by Copilot in PR #32 against `AutoExportController`; the
/// assertion here is that a second `start()` leaves exactly one armed timer, observed
/// through the controller's own handle.
@Test("start is idempotent and leaves one armed timer")
@MainActor
func startIsIdempotent() throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshEnabled = false
    let subject = try controller(settings: settings, at: "2026-10-06 06:00:00")

    subject.start(interval: 3600)
    let first = try #require(subject.armedTimer)
    subject.start(interval: 3600)
    let second = try #require(subject.armedTimer)

    #expect(first !== second)
    #expect(first.isValid == false, "the first timer must have been invalidated")
    #expect(second.isValid)

    subject.stop()
    #expect(subject.armedTimer == nil)
    #expect(second.isValid == false)
}

/// The test that waits for the pass itself rather than for the decision — the dispatch is
/// the one thing `tick()`'s return value does not prove, because a `Task` has not
/// necessarily started when the method that created it returns.
@Test("a dispatched pass reaches the refresh closure")
@MainActor
func aDispatchedPassReachesTheRefreshClosure() async throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            passes.count += 1
            return .idle
        })

    #expect(subject.tick())

    #expect(await waitFor { passes.count == 1 }, "the pass never reached the service")
}

// MARK: - D-227: what an unattended pass records about the credential

@Test("a refused credential is persisted by the pass that found it")
@MainActor
func aRefusedCredentialIsPersisted() async throws {
    let settings = try scratchSettings()
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            RefreshOutcome(
                attempted: 1,
                failures: [
                    RefreshOutcome.Failure(
                        connectorID: "jira", displayName: "Jira", error: .credentialExpired)
                ])
        })

    #expect(subject.tick())

    #expect(await waitFor { settings.scheduledRefreshRejection != nil })
    let rejection = try #require(settings.scheduledRefreshRejection)
    #expect(rejection.displayName == "Jira")
    #expect(rejection.discoveredAt == moment)
}

@Test("a later pass that reaches the source clears the record")
@MainActor
func aLaterPassClearsTheRecord() async throws {
    let settings = try scratchSettings()
    settings.scheduledRefreshRejection = CredentialRejection(displayName: "Jira", at: .distantPast)
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: { RefreshOutcome(attempted: 2, cached: 2) })

    #expect(subject.tick())

    #expect(await waitFor { settings.scheduledRefreshRejection == nil })
}

/// A pass with nothing due is the normal case, so clearing on one would erase the warning on
/// the next tick after recording it.
@Test("a pass that attempted nothing leaves the record standing")
@MainActor
func anEmptyPassLeavesTheRecord() async throws {
    let settings = try scratchSettings()
    let recorded = CredentialRejection(displayName: "Jira", at: .distantPast)
    settings.scheduledRefreshRejection = recorded
    let calendar = try pacific()
    let moment = try instant("2026-10-06 08:03:00", in: calendar)
    let passes = PassCounter()
    let subject = ScheduledRefreshController(
        settings: settings, now: { moment }, calendar: { calendar },
        refresh: {
            passes.count += 1
            return .idle
        })

    #expect(subject.tick())
    #expect(await waitFor { passes.count == 1 })

    #expect(settings.scheduledRefreshRejection == recorded)
}
```

Three things about the shape of these tests:

- **They assert the returned decision, not the pass.** A `Task` has not necessarily started when the method that created it returns, so counting passes immediately after `tick()` would be a test that passes for the wrong reason. Two tests do need the pass itself, and they wait with `waitFor`, a deadline-bounded poll.
- **`waitFor` exists because the obvious version hangs.** The first draft resumed a `CheckedContinuation` from inside the refresh closure, which reads better and fails catastrophically under exactly the mutations this task cares about: an edit that stops the pass being dispatched leaves the continuation never resumed, so the suite hangs rather than going red. The sweep found it — one mutation turned a fifteen-second run into a fifteen-minute one — and a test that hangs under mutation is worse than one that fails, because the failure never arrives and nothing says why. A timeout returns `false` and the caller's `#expect` records it.
- **`armedTimer` is observed directly** for idempotence, because an abandoned timer keeps working: behaviour cannot see the bug, which is exactly why it survived in `AutoExportController` until PR #32.
- **A `PassCounter` box**, because the refresh closure escapes and a captured `var` cannot be mutated from one.

- [ ] **Step 2: Run them and confirm they fail**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -E "error:|Cannot find" /tmp/test.log | head -3
```

Expected: BUILD FAILED, `cannot find 'ScheduledRefreshController' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Integrations/ScheduledRefreshController.swift`:

```swift
import Foundation

/// §5.5's third refresh trigger: a pass at the user's configured time (D-221).
///
/// **It exists for the one thing a pure function cannot hold** — a `Timer`.
/// `ScheduledRefreshDue` decides; this arms a tick and asks. That is
/// `AutoExportController`'s division of labour (D-121), and it is why this type has
/// almost no branches of its own.
///
/// **A polling tick, not a timer armed at the occurrence.** Arming for 08:00 fires on
/// the minute, and then every edge case becomes re-arming: the toggle changes, the
/// time changes, the machine sleeps, the time zone moves. A stale armed timer is
/// *silent*, which is the failure mode nobody notices — a refresh that never happens
/// looks exactly like a refresh with nothing to report. Polling has no state to go
/// stale: sleep, a closed app, a daylight-saving boundary and a clock dragged
/// backwards all reduce to "the next tick re-asks".
///
/// `NSBackgroundActivityScheduler` was the other candidate and cannot express this
/// setting: it schedules by interval, not by time of day, and its whole value is the
/// right to defer — including past the morning this exists to make fast.
@MainActor
public final class ScheduledRefreshController {
    /// Five minutes. The due check is a comparison against a stored date rather than
    /// a countdown, so the tick rate decides only how soon after the configured time
    /// the pass starts — and a pass that starts by 08:05 serves a stand-up nobody
    /// gives before 09:00.
    public static let tickInterval: TimeInterval = 5 * 60

    /// How long the system may coalesce a tick by. The tick costs two date
    /// comparisons when nothing is due, and letting the OS fold it into other work is
    /// how it stays that cheap — M4-05's fourth acceptance criterion is that this
    /// does not spin the machine.
    static let tickTolerance: TimeInterval = 60

    private let settings: AppSettings
    private let now: () -> Date
    private let calendar: () -> Calendar
    private let refresh: @MainActor () async -> RefreshOutcome
    private var timer: Timer?

    /// - Parameters:
    ///   - settings: the same instance the Settings pane writes, so the toggle and
    ///     the time take effect on the next tick with no relaunch.
    ///   - calendar: a closure, read per tick rather than stored, so a time-zone
    ///     change needs nothing re-armed — `SourceRegistry` reads enablement per
    ///     dispatch for the same reason (D-216).
    ///   - refresh: the pass to run. **A closure rather than a `SourceRefreshService`**
    ///     because the service needs a `ModelContext` only the composition root has,
    ///     and because a spy is what makes "dispatched once, not twice" assertable
    ///     without a container, a connector or a wait.
    ///
    ///     **It returns its `RefreshOutcome`, which the launch path used to discard**
    ///     (D-227). Nothing here acts on the counts; the one thing read is whether a
    ///     connector refused the credential, because an unattended pass is the only
    ///     thing that can discover a revoked token and the pane has no other way to
    ///     learn of it.
    public init(
        settings: AppSettings = AppSettings(),
        now: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .current },
        refresh: @escaping @MainActor () async -> RefreshOutcome
    ) {
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.refresh = refresh
    }

    /// Run the launch pass, then arm the tick.
    ///
    /// Separate from `init` so building the controller cannot reach the network —
    /// `StenoApp.init` builds it, and an initializer that opened a socket would put a
    /// fetch on the launch path before anything had decided one was wanted.
    public func start(interval: TimeInterval = ScheduledRefreshController.tickInterval) {
        // **Idempotent, because the timer half is not self-correcting.** Reassigning
        // `timer` does not stop the old one: a scheduled `Timer` is retained by the
        // run loop, so a second `start()` would leave two live tickers firing
        // forever. Found by Copilot in review of PR #32, against the controller this
        // one is modelled on.
        stop()

        runLaunchPass()

        let timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        timer.tolerance = Self.tickTolerance
        // `.common`, so the tick still fires while a menu is tracking or a window is
        // being resized — both put the run loop in a mode the default one does not
        // cover, and a schedule that pauses because a menu is open is one nobody can
        // reason about.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The armed tick, or `nil` when the controller is stopped.
    ///
    /// `internal` for one assertion: that a second `start()` invalidates the first
    /// timer rather than abandoning it to the run loop. A test cannot see that through
    /// behaviour — an abandoned timer keeps working, which is exactly why the bug
    /// survived in `AutoExportController` until PR #32 — so the handle itself is the
    /// only observable.
    var armedTimer: Timer? { timer }

    /// Disarm the tick. Nothing in the app calls this — `StenoApp` holds the
    /// controller for the life of the process — but a timer with no way to be
    /// invalidated is a leak waiting for the first test that builds two controllers.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// §5.5's launch behaviour and this task's, as **one pass** (D-224).
    ///
    /// The launch pass runs either way; the schedule decides only whether this pass
    /// also serves today's occurrence. Asking the rule *and* keeping a separate
    /// unconditional launch pass would dispatch twice, where the second finds nothing
    /// stale, fetches nothing, and leaves two triggers claiming the same moment in
    /// the log.
    /// - Returns: whether this pass also served a due occurrence.
    @discardableResult
    func runLaunchPass() -> Bool {
        let claimed = claimOccurrenceIfDue()
        if claimed {
            Log.sources.info("scheduled refresh: the launch pass serves the due occurrence")
        }
        dispatch()
        return claimed
    }

    /// One tick of the clock. Nothing happens unless an occurrence is owed.
    ///
    /// `internal` so tests drive it directly: a test that waited five minutes for a
    /// timer would not be run, and `start(interval:)` with a millisecond interval
    /// would assert that `Timer` works rather than that this rule does.
    ///
    /// **Returns the decision rather than only acting on it**, so a test can assert
    /// "this tick dispatched and the next did not" synchronously. Observing the same
    /// thing through the refresh closure would mean waiting on a `Task` that has not
    /// necessarily started when `tick()` returns — which is how an async test comes to
    /// pass for the wrong reason.
    @discardableResult
    func tick() -> Bool {
        guard claimOccurrenceIfDue() else { return false }
        Log.sources.info("scheduled refresh: the configured time has arrived; starting a pass")
        dispatch()
        return true
    }

    /// Whether an occurrence is owed — and, if it is, claim it by stamping.
    ///
    /// **The stamp is written here, before the pass runs, not after it succeeds**
    /// (D-223). This is the opposite of `AutoExportDue`, which measures from the last
    /// success so that a missing backup folder keeps re-announcing itself; a failed
    /// background refresh is not the user's problem — §5.5 makes it best-effort and
    /// the stand-up draft already labels stale data — so stamping on success would
    /// mean retrying every five minutes until the grace window closed, forty-eight
    /// passes at a source that is most likely down.
    ///
    /// One attempt per occurrence is also why there is no in-flight guard: the stamp
    /// makes the next tick not-due, so a second dispatch while the first is still
    /// fetching is unreachable rather than prevented. Do not add the flag back.
    private func claimOccurrenceIfDue() -> Bool {
        guard settings.scheduledRefreshEnabled else { return false }

        let moment = now()
        guard
            ScheduledRefreshDue.isDue(
                now: moment, at: settings.scheduledRefreshTime,
                lastRun: settings.scheduledRefreshLastRun, calendar: calendar())
        else { return false }

        settings.scheduledRefreshLastRun = moment
        return true
    }

    /// Fire and forget, silent, logs only — the launch pass's posture (D-176).
    ///
    /// This runs unattended, so it must never surface a modal, a permission prompt or
    /// an auth dialog. It cannot: `SourceRefreshService`'s refresh methods do not
    /// throw (D-167), and nothing on this path can present anything.
    ///
    /// **One thing is kept from the outcome rather than discarded** (D-227): whether a
    /// connector refused the credential. Everything else — the counts, the staleness, the
    /// expiry warnings — reaches the user at the next "Prepare Stand-up" through
    /// `SourceNotice` (D-193), which is the surface §5.2 chose for them.
    private func dispatch() {
        Task { @MainActor in
            let outcome = await refresh()
            record(outcome)
        }
    }

    /// Persist, or clear, what this pass learned about the credential (D-227).
    ///
    /// Three cases, and the third is the one that makes this correct:
    ///
    /// - A connector refused the credential → record it, with the time.
    /// - A pass that reached a source and was not refused → clear any recorded rejection.
    /// - **A pass that attempted nothing → leave the record alone.** Nothing due, nothing
    ///   configured, every integration switched off: none of those is evidence about the
    ///   token, and clearing on one would erase the warning on the very next tick, because
    ///   a pass with no refs due is the normal case.
    private func record(_ outcome: RefreshOutcome) {
        if let rejection = CredentialRejection.from(outcome, at: now()) {
            settings.scheduledRefreshRejection = rejection
            Log.sources.error(
                "unattended refresh: \(rejection.displayName, privacy: .public) refused the stored credential"
            )
        } else if CredentialRejection.isCleared(by: outcome) {
            settings.scheduledRefreshRejection = nil
        }
    }

    deinit {
        // `timer` is `@MainActor` state and `deinit` is not, so the invalidation
        // cannot happen here — the Swift 6 constraint `AutoExportController` records.
        // The timer's block captures `self` weakly, so an armed timer does not retain
        // this object; it ticks a `nil` and does nothing until `stop()`.
    }
}
```

- [ ] **Step 4: Run them and confirm they pass**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # must print 0
```

- [ ] **Step 5: Mutate, to prove the tests can fail**

| Edit | Must go red |
|---|---|
| delete `settings.scheduledRefreshLastRun = moment` (keep `_ = moment` so it compiles) | `two ticks inside one occurrence dispatch one pass`, `a failed pass is not retried inside the same occurrence`, `a launch inside the window serves the occurrence as well` |
| delete `guard settings.scheduledRefreshEnabled else { return false }` | `the toggle switches the schedule off entirely` |
| delete the `stop()` at the top of `start(interval:)` | `start is idempotent and leaves one armed timer` |
| `dispatch(); return claimed` → `if claimed { dispatch() }; return claimed` in `runLaunchPass()` | `the launch pass still runs with the schedule switched off` |

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Integrations/ScheduledRefreshController.swift \
        StenoTests/Integrations/ScheduledRefreshControllerTests.swift
git commit   # subject: "feat: the tick, and the stamp written before the pass runs"
```

---

## Task 5: The model the Settings pane binds to

**Files:**
- Create: `StenoKit/Features/Settings/ScheduledRefreshSettingsModel.swift`
- Test: `StenoTests/Settings/ScheduledRefreshSettingsModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings` accessors (Task 2), `TimeOfDay` (Task 1).
- Produces, used by Task 6:
  - `init(settings: AppSettings = AppSettings(), calendar: @escaping () -> Calendar = { .current })`
  - `var isEnabled: Bool`, `var time: TimeOfDay`, `var pickerDate: Date` — all settable, all written through

**Why its own type:** `IntegrationsSettingsModel` is about the Atlassian credential and the connectors over it, and is already 387 lines. A second subject would push that file past SwiftLint's `file_length` limit, which `--strict` reports as a failure — and splitting by subject is what lets this be tested without a Keychain double.

- [ ] **Step 1: Write the failing tests**

Create `StenoTests/Settings/ScheduledRefreshSettingsModelTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

@MainActor
private func scratch() throws -> (ScheduledRefreshSettingsModel, AppSettings) {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let model = ScheduledRefreshSettingsModel(settings: settings, calendar: { calendar })
    return (model, settings)
}

@Test("a fresh install is scheduled for 08:00")
@MainActor
func aFreshInstallIsScheduled() throws {
    let (model, _) = try scratch()

    #expect(model.isEnabled)
    #expect(model.time == .eightAM)
}

/// The mirror has to be written through, or the controller — which reads `AppSettings`
/// per tick — keeps the old schedule until the next launch.
@Test("switching the schedule off writes through to the settings")
@MainActor
func switchingOffWritesThrough() throws {
    let (model, settings) = try scratch()

    model.isEnabled = false

    #expect(settings.scheduledRefreshEnabled == false)
}

@Test("setting a time writes through to the settings")
@MainActor
func settingATimeWritesThrough() throws {
    let (model, settings) = try scratch()
    let halfPastSix = try #require(TimeOfDay(hour: 6, minute: 30))

    model.time = halfPastSix

    #expect(settings.scheduledRefreshTime == halfPastSix)
}

/// What the `DatePicker` binding does: the instant it hands back carries a date this
/// setting must not keep, because an instant drifts with the time zone it was set in
/// and a time of day does not.
@Test("the picker's date becomes an hour and a minute, and nothing else")
@MainActor
func thePickersDateBecomesATimeOfDay() throws {
    let (model, settings) = try scratch()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let components = DateComponents(
        calendar: calendar, year: 1999, month: 12, day: 31, hour: 7, minute: 15)
    let fromAnotherCentury = try #require(components.date)

    model.pickerDate = fromAnotherCentury

    #expect(settings.scheduledRefreshTime == (try #require(TimeOfDay(hour: 7, minute: 15))))
    // And reading it back shows the same clock time on today's date, not in 1999.
    #expect(calendar.component(.hour, from: model.pickerDate) == 7)
    #expect(calendar.component(.minute, from: model.pickerDate) == 15)
    #expect(calendar.component(.year, from: model.pickerDate) != 1999)
}

@Test("a stored schedule is read back at launch")
@MainActor
func aStoredScheduleIsReadBack() throws {
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    let settings = AppSettings(defaults: defaults)
    settings.scheduledRefreshEnabled = false
    settings.scheduledRefreshTime = try #require(TimeOfDay(hour: 21, minute: 45))

    let model = ScheduledRefreshSettingsModel(settings: settings)

    #expect(model.isEnabled == false)
    #expect(model.time.hour == 21)
    #expect(model.time.minute == 45)
}

/// D-227. Re-read rather than mirrored, because the controller writes it while the pane is
/// closed — a value captured at launch would still say "nothing" after an 08:00 pass was
/// refused.
@Test("the pane sees a rejection recorded after the model was built")
@MainActor
func theModelReloadsARejection() throws {
    let (model, settings) = try scratch()
    #expect(model.credentialRejection == nil)
    let rejection = CredentialRejection(
        displayName: "Jira", at: Date(timeIntervalSince1970: 1_792_000_000))

    settings.scheduledRefreshRejection = rejection
    model.reload()

    #expect(model.credentialRejection == rejection)
}

@Test("a cleared rejection disappears from the pane on the next appearance")
@MainActor
func aClearedRejectionDisappears() throws {
    let (model, settings) = try scratch()
    settings.scheduledRefreshRejection = CredentialRejection(displayName: "Jira", at: Date())
    model.reload()
    #expect(model.credentialRejection != nil)

    settings.scheduledRefreshRejection = nil
    model.reload()

    #expect(model.credentialRejection == nil)
}
```

- [ ] **Step 2: Run them and confirm they fail**

Expected: BUILD FAILED, `cannot find 'ScheduledRefreshSettingsModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Features/Settings/ScheduledRefreshSettingsModel.swift`:

```swift
import Foundation

/// What the Integrations pane's "Scheduled refresh" section binds to (FR-6, §5.5).
///
/// **Its own model rather than two more properties on `IntegrationsSettingsModel`.**
/// That type is about the Atlassian credential and the connectors over it, and it is
/// already 387 lines — adding a second subject would push the file past SwiftLint's
/// `file_length` limit, which `make lint --strict` reports as a failure. Splitting by
/// subject is also what makes this testable in four short tests instead of inside a
/// type that needs a Keychain double to build.
///
/// **Observable, mirroring `UserDefaults` rather than reading through to it.**
/// `@Observable` tracks stored properties; a computed property over `UserDefaults`
/// would change the setting and leave the control drawing its old value, because
/// nothing SwiftUI observes would have changed. The mirror is written through on every
/// set, so `ScheduledRefreshController` — which reads `AppSettings` per tick — sees the
/// change on the next tick with no relaunch and no notification between them.
///
/// Every rule lives here rather than in the pane: the unhosted test bundle cannot
/// reach the app target (D-010), so a rule only a view knows is a rule no test can
/// hold.
@Observable
@MainActor
public final class ScheduledRefreshSettingsModel {
    private let settings: AppSettings
    private let calendar: () -> Calendar

    /// §5.5's schedule, on or off.
    public var isEnabled: Bool {
        didSet { settings.scheduledRefreshEnabled = isEnabled }
    }

    /// The configured time of day.
    ///
    /// Written through on set, like `isEnabled`. The pane does not bind to this
    /// directly — `DatePicker` needs a `Date` — it binds to `pickerDate` below.
    public var time: TimeOfDay {
        didSet { settings.scheduledRefreshTime = time }
    }

    /// - Parameters:
    ///   - settings: injected so tests use a scratch suite rather than the developer's
    ///     own preferences (§9.4).
    ///   - calendar: injected for `pickerDate`'s conversion, so a test can pin a time
    ///     zone instead of inheriting the machine's.
    public init(
        settings: AppSettings = AppSettings(),
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.settings = settings
        self.calendar = calendar
        self.isEnabled = settings.scheduledRefreshEnabled
        self.time = settings.scheduledRefreshTime
    }

    /// What an unattended pass last learned about the credential (D-227), or `nil`.
    ///
    /// **Re-read rather than mirrored**, which is the opposite of `isEnabled` and `time`
    /// above, because this one is written by the controller rather than by this model: a
    /// mirror taken at launch would still say "nothing" after an 08:00 pass was refused.
    /// `reload()` is what the pane calls as it appears, which is the only moment the value
    /// has to be right — the pane cannot be open at the instant a background pass runs and
    /// then fail to redraw, because appearing is what triggers the read.
    public private(set) var credentialRejection: CredentialRejection?

    /// Re-read the rejection from the store. Called by the pane as it appears, beside the
    /// `forgetEntry()` the credential half already does there.
    public func reload() {
        credentialRejection = settings.scheduledRefreshRejection
    }

    /// `time` as the `Date` a `DatePicker(displayedComponents: .hourAndMinute)` binds.
    ///
    /// **The date component is deliberately today's and deliberately ignored.** The
    /// picker shows and edits hours and minutes only; the setter takes the hour and
    /// minute off whatever instant the picker produces and throws the rest away, which
    /// is what keeps the stored setting a time of day rather than an instant that
    /// drifts with the time zone it was set in.
    ///
    /// A `nil` from `instant(on:calendar:)` is unreachable — see
    /// `TimeOfDay.instant(on:calendar:)` — and falls back to the day's start, which
    /// shows 00:00 in the control rather than refusing to draw it.
    public var pickerDate: Date {
        get {
            let today = Date()
            return time.instant(on: today, calendar: calendar())
                ?? calendar().startOfDay(for: today)
        }
        set { time = TimeOfDay(of: newValue, calendar: calendar()) }
    }
}
```

**It mirrors `UserDefaults` rather than reading through to it.** `@Observable` tracks stored properties; a computed property over the store would change the setting and leave the control drawing its old value, because nothing SwiftUI observes would have changed. Every set writes through, so the controller — which reads `AppSettings` per tick — picks the change up on the next tick, with no notification between them and no relaunch.

- [ ] **Step 4: Run them and confirm they pass**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -c "recorded an issue" /tmp/test.log   # must print 0
```

- [ ] **Step 5: Mutate, to prove the tests can fail**

| Edit | Must go red |
|---|---|
| `didSet { settings.scheduledRefreshEnabled = isEnabled }` → `didSet {}` | `switching the schedule off writes through to the settings` |
| the `pickerDate` setter → keep the whole instant instead of its hour and minute | `the picker's date becomes an hour and a minute, and nothing else` |

- [ ] **Step 6: Commit**

```bash
git add StenoKit/Features/Settings/ScheduledRefreshSettingsModel.swift \
        StenoTests/Settings/ScheduledRefreshSettingsModelTests.swift
git commit   # subject: "feat: the model the Settings pane binds the schedule to"
```

---

## Task 6: The pane section, one pass at launch, and the decisions

**Files:**
- Create: `Steno/Features/Settings/ScheduledRefreshSection.swift`
- Modify: `Steno/Features/Settings/IntegrationsSettingsPane.swift` — a `scheduleModel` property on the view, and a `Section("Scheduled refresh")` immediately above `Section("Cached data")`
- Modify: `Steno/Features/Settings/SettingsView.swift` — a `scheduleModel` property, passed to `IntegrationsSettingsPane`
- Modify: `Steno/App/StenoApp.swift` — two stored properties, one assignment in `init`, `startLaunchRefresh` becomes `startScheduledRefresh`, and `SettingsView`'s new argument
- Modify: `docs/DECISIONS.md` — D-221…D-226
- Modify: `docs/tasks/README.md` — tick M4-05

**Interfaces:**
- Consumes: `ScheduledRefreshSettingsModel` (Task 5), `ScheduledRefreshController` (Task 4), and the existing `SourceRefreshService(context:registry:).refreshDue()`.
- Produces: nothing further — this is the last task.

**No test file.** The unhosted test bundle cannot reach the app target (D-010), which is why Tasks 1–5 hold every rule. This task is composition and copy, and its verification is reading plus the manual pass below.

- [ ] **Step 1: Write the section**

Create `Steno/Features/Settings/ScheduledRefreshSection.swift`:

```swift
import StenoKit
import SwiftUI

/// FR-6's control over §5.5's scheduled refresh: a switch and a time.
///
/// Its own file rather than another section inside `IntegrationsSettingsPane`, which
/// is at SwiftLint's `type_body_length` limit — the same reason
/// `IntegrationsPurgeSection` lives at the bottom of that file. It owns no rule;
/// everything it reads and writes is `ScheduledRefreshSettingsModel`, because the
/// unhosted test bundle cannot reach this target (D-010).
struct ScheduledRefreshSection: View {
    @Bindable var model: ScheduledRefreshSettingsModel

    var body: some View {
        // **A `Group`, so the whole section can carry one `.onAppear`.** The rows below are
        // separate `Form` children and a modifier cannot attach to the implicit tuple; a
        // `Group` is transparent in a `Form`, so each child is still its own row.
        Group {
            Toggle("Refresh in the background", isOn: $model.isEnabled)

            DatePicker(
                "At", selection: $model.pickerDate, displayedComponents: .hourAndMinute
            )
            .disabled(!model.isEnabled)
            // The visible label is one word, which tells a screen-reader user nothing
            // about what happens at that time. Nothing automated reaches VoiceOver, so
            // this line and the manual pass are the only things holding it.
            .accessibilityLabel("Scheduled refresh time")

            // D-227: the one thing an unattended pass can discover that no other surface can.
            // `expiryWarning` above is derived from the date the user typed, so a *revoked*
            // token shows nothing there — this is where the user finds out before a stand-up
            // depends on it. A timestamped fact, so it stays true after the token is replaced
            // and until a later pass clears it.
            if let rejection = model.credentialRejection {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A background refresh couldn't sign in to \(rejection.displayName).")
                        Text(
                            "Your token may have been revoked. Test the connection above, or paste a "
                                + "new one."
                        )
                        .foregroundStyle(.secondary)
                        Text(rejection.discoveredAt, format: .dateTime.weekday().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.slash")
                }
                .font(.callout)
            }

            // **Names the limitation rather than implying a guarantee.** The schedule
            // needs the app to be running, and a Mac asleep until the afternoon simply
            // refreshes on the next launch — "within a few hours" is
            // `ScheduledRefreshDue.grace`, so if that changes this sentence is part of the
            // change.
            Text(
                "Fetches ticket and page updates at this time, so your stand-up is ready "
                    + "without waiting. Skipped while your Mac is asleep; Steno catches up when "
                    + "it next wakes, within a few hours of the time you set."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        // D-227: a background pass refused at 08:00 is recorded while this window is closed,
        // so appearing is when the view has to go and look. Here rather than on the pane's
        // own `onAppear`, which is where it started: `IntegrationsSettingsPane` is at
        // SwiftLint's `file_length` limit, and the reload belongs with the view that reads
        // the value anyway.
        .onAppear { model.reload() }
    }
}
```

The sentence is the user-facing statement of the grace window, so if `ScheduledRefreshDue.grace` changes, that sentence is part of the change. It names the limitation — the app has to be running — rather than implying a guarantee the mechanism cannot make.

- [ ] **Step 2: Put it in the pane**

In `IntegrationsSettingsPane`, beside `@Bindable var model`:

```swift
    /// §5.5's schedule, as its own model — see `ScheduledRefreshSettingsModel` for why
    /// it is not two more properties on `model`.
    @Bindable var scheduleModel: ScheduledRefreshSettingsModel
```

and immediately above `Section("Cached data")`:

```swift
            // §5.5's scheduled pass. Here rather than in the Capture pane — FR-6
            // permits either — because what it governs is when integrations fetch,
            // not how capture behaves.
            Section("Scheduled refresh") {
                ScheduledRefreshSection(model: scheduleModel)
            }
```

Then thread it through `SettingsView`: a `let scheduleModel: ScheduledRefreshSettingsModel` property, and `IntegrationsSettingsPane(model: integrationsModel, scheduleModel: scheduleModel)` in `content(for:)`.

- [ ] **Step 3: Replace the launch pass with the controller**

In `StenoApp`, beside `autoExport`:

```swift
    /// §5.5's scheduled refresh (M4-05). Held for the whole process because it owns a
    /// timer, and a controller that went out of scope would take the schedule with it.
    ///
    /// `nil` when the store failed to open — there is nowhere to cache a fetch, so there
    /// is nothing to schedule. The pane's controls still work and still persist, which
    /// is §13's rule that degradation ships with the feature.
    private let scheduledRefresh: ScheduledRefreshController?

    /// FR-6's control over that schedule. Outside the `store` switch, like the
    /// Integrations model it sits beside.
    private let scheduleSettingsModel: ScheduledRefreshSettingsModel
```

In `init`, after `sourceRegistry = Self.makeSourceRegistry(settings: appSettings)`:

```swift
        scheduleSettingsModel = ScheduledRefreshSettingsModel(settings: appSettings)
```

Replace the `Self.startLaunchRefresh(...)` call with `scheduledRefresh = Self.startScheduledRefresh(container: container, registry: sourceRegistry, settings: appSettings)`, and add `scheduledRefresh = nil` to the `else` branch. Then replace `startLaunchRefresh` itself with:

```swift
    /// §5.5's launch pass and §5.5's scheduled pass, as one controller (M4-05).
    ///
    /// Both are fire-and-forget, silent, logs only (D-176) — they warm the cache so
    /// the morning view is instant, and a visible indicator would invite the user to
    /// wait for something designed not to be waited on.
    ///
    /// **One pass at launch, not two** (D-224). `start()` dispatches the launch pass
    /// unconditionally; the schedule decides only whether that pass also serves
    /// today's occurrence. The alternative — an unconditional launch pass plus a
    /// due-check pass — dispatches twice, where the second finds nothing stale and
    /// fetches nothing.
    ///
    /// **Here rather than in `MainWindowModel.init`** (D-179). The CLI bundle
    /// builds a store too, and `steno export` must not open network connections.
    /// `mainContext`, for the reason the seeding above uses it: the window's own
    /// model reads that context, so a pass writing into a sibling would depend on
    /// cross-context visibility.
    ///
    /// `static`, so `init` can call it before `self` exists — and its own function
    /// rather than nine lines inline, because `init` is at SwiftLint's
    /// `function_body_length` limit.
    private static func startScheduledRefresh(
        container: ModelContainer, registry: SourceRegistry, settings: AppSettings
    ) -> ScheduledRefreshController {
        let context = container.mainContext
        // The outcome is returned rather than discarded, so the controller can record a
        // credential a connector refused (D-227). Nothing else about it is read here.
        let controller = ScheduledRefreshController(settings: settings) {
            await SourceRefreshService(context: context, registry: registry).refreshDue()
        }
        controller.start()
        return controller
    }
```

**One pass at launch, not two** (D-224): the pass runs unconditionally and the schedule decides only whether it also serves today's occurrence. Asking the rule *and* keeping a separate unconditional pass would dispatch twice, where the second finds nothing stale, fetches nothing, and leaves two triggers claiming one moment in the log.

Finally, pass `scheduleModel: scheduleSettingsModel` to `SettingsView` in the `Settings` scene.

- [ ] **Step 4: Build, test, lint**

```bash
make build > /tmp/build.log 2>&1; echo "exit: $?"; grep -c "❌" /tmp/build.log
make test > /tmp/test.log 2>&1; echo "exit: $?"; grep -c "recorded an issue" /tmp/test.log
make lint > /tmp/lint.log 2>&1; echo "exit: $?"; tail -1 /tmp/lint.log
make format; git status --short   # a dirty tree after format is your change — commit it
```

`make build` renders errors as `❌`, not as `error:` — grepping for the latter reports a failing build as clean.

- [ ] **Step 5: Write the decisions**

Append to `docs/DECISIONS.md`, after confirming D-220 is still the maximum:

| | Decision |
|---|---|
| D-221 | A polling tick over a pure due rule, not a timer armed at the occurrence |
| D-222 | The most recent occurrence, a four-hour grace window, then the day is skipped |
| D-223 | `lastRun` is stamped at dispatch, not at success — one attempt per occurrence |
| D-224 | Launch runs exactly one pass; the schedule only decides whether it counts |
| D-225 | `TimeOfDay`, three settings keys, and a toggle whose absence means on |
| D-226 | The scheduled pass keeps the 30-minute staleness rule |

Each takes its argument from the spec, and each records what was rejected: an armed timer and `NSBackgroundActivityScheduler` (D-221), today's occurrence (D-222), stamping on success (D-223), two launch passes (D-224), a `Date`-valued setting (D-225), an unconditional sweep (D-226). Record the two deviations from the spec in D-225: the default time lives on `TimeOfDay.eightAM` rather than on `ScheduledRefreshDue`, because the failable initializers plus the `force_unwrapping` rule leave no other spelling; and the pane's model is a new `ScheduledRefreshSettingsModel` rather than an `IntegrationsSettingsModel+Schedule` extension, because an extension cannot add the stored properties `@Observable` needs.

- [ ] **Step 6: Tick the task index**

`docs/tasks/README.md`: M4-05's row from `[ ]` to `[x]`. Check M4-01…M4-04 are already ticked — a row that merged without being ticked is this PR's to fix (CLAUDE.md, "Working a task", step 4).

- [ ] **Step 7: The manual pass, which nothing automated can do**

An agent cannot click the pane or watch a timer fire. Record the result in the PR body.

1. `make run`, open Settings → Integrations. The section shows a switch and a time of 08:00.
2. Set the time to two minutes ahead, leave the app running, and watch:
   ```bash
   log show --last 10m --info --predicate 'subsystem == "com.lgabrielgr.steno" AND category == "sources"' | grep -i schedul
   ```
   Within five minutes: `scheduled refresh: the configured time has arrived; starting a pass`.
3. Quit and relaunch inside the window: the log says `the launch pass serves the due occurrence`, once, not on every relaunch.
4. Switch the toggle off, relaunch: no scheduled line, and the launch pass still runs.
5. VoiceOver (⌘F5) across the switch and the picker: the picker announces "Scheduled refresh time", not "At".

- [ ] **Step 8: Commit, push, open the PR**

```bash
git add Steno docs
git commit   # subject: "feat: the schedule in the Integrations pane, and one pass at launch"
git push -u origin feat/background-refresh
```

Read `.github/pull_request_template.md` before writing the body — `gh pr create` bypasses it silently. State the two spec deviations from Step 5, the manual results from Step 7, and the mutation results. **Do not merge.**

---

## Task 7: What review added — the credential an unattended pass was refused

**Added after the first review round.** Tasks 1–6 shipped, and Copilot found that the task file's
own requirement was unmet: "an expired Atlassian token discovered here should set the warning state
that M4-04 displays, not interrupt". The scheduled pass discarded its `RefreshOutcome`, and
`IntegrationsSettingsModel.expiryWarning` is derived from the *user-entered expiry date* — D-192
makes a blank date mean the warning cannot fire — so a **revoked** token left the pane silent while
the only component that knew threw the evidence away. Recorded as D-227.

**Files:**
- Create: `StenoKit/Integrations/CredentialRejection.swift` — the value and the two rules
- Create: `StenoTests/Integrations/CredentialRejectionTests.swift`
- Modify: `StenoKit/Settings/AppSettings+ScheduledRefresh.swift` — a fourth key, `scheduledRefreshRejection`
- Modify: `StenoKit/Integrations/ScheduledRefreshController.swift` — `refresh` returns `RefreshOutcome`; a `record(_:)` after each pass
- Modify: `StenoKit/Features/Settings/ScheduledRefreshSettingsModel.swift` — `credentialRejection` and `reload()`
- Modify: `Steno/Features/Settings/ScheduledRefreshSection.swift` — the warning row, and the `onAppear` that reloads it
- Modify: `Steno/App/StenoApp.swift` — the closure returns the outcome instead of discarding it
- Modify: `StenoTests/AI/AISecretsTests.swift` — `allKeys.count` 13 → 14

**Interfaces:**
- Consumes: `RefreshOutcome` and `RefreshOutcome.Failure` (M4-01), `SourceError` (M4-01).
- Produces: `CredentialRejection(displayName:at:)`, `.discoveredAt`, `.from(_:at:) -> CredentialRejection?`, `.isCleared(by:) -> Bool`; `AppSettings.scheduledRefreshRejection`; `ScheduledRefreshSettingsModel.credentialRejection` and `.reload()`.

- [ ] **Step 1: Write the failing tests for the rule**

Create `StenoTests/Integrations/CredentialRejectionTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

private let moment = Date(timeIntervalSince1970: 1_792_000_000)

private func failure(_ error: SourceError, connector: String = "jira") -> RefreshOutcome.Failure {
    RefreshOutcome.Failure(
        connectorID: connector, displayName: connector == "jira" ? "Jira" : "Confluence",
        error: error)
}

// MARK: - What counts as a rejection

@Test("an expired credential is recorded, naming the connector")
func anExpiredCredentialIsRecorded() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.credentialExpired)])

    let rejection = try #require(CredentialRejection.from(outcome, at: moment))

    #expect(rejection.displayName == "Jira")
    #expect(rejection.discoveredAt == moment)
}

@Test("a rejected credential is recorded")
func aRejectedCredentialIsRecorded() throws {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.invalidCredential)])

    #expect(try #require(CredentialRejection.from(outcome, at: moment)).displayName == "Jira")
}

/// **The list of errors that are *not* evidence about the token**, and the reason this is a
/// table rather than one case: a warning that fires on an unreachable network is one the
/// user learns to ignore, which is FR-5's reasoning applied to the credential.
@Test("a failure that says nothing about the token records nothing")
func anUnrelatedFailureRecordsNothing() {
    for error in [
        SourceError.network, .timedOut, .siteNotFound, .notConfigured, .notFound,
        .invalidResponse, .rateLimited(retryAfter: nil), .unavailable(status: 503),
    ] {
        let outcome = RefreshOutcome(attempted: 1, failures: [failure(error)])

        #expect(
            CredentialRejection.from(outcome, at: moment) == nil,
            "\(error) must not be read as a credential rejection")
    }
}

/// Both Atlassian connectors share one credential (§5.3), so a pass that fails both has
/// found one broken token. The first failure wins rather than two records being kept.
@Test("two connectors sharing one credential record one rejection")
func twoConnectorsRecordOneRejection() throws {
    let outcome = RefreshOutcome(
        attempted: 2,
        failures: [
            failure(.credentialExpired), failure(.invalidCredential, connector: "confluence"),
        ])

    #expect(try #require(CredentialRejection.from(outcome, at: moment)).displayName == "Jira")
}

// MARK: - What clears one

@Test("a pass that reached a source and was not refused clears the record")
func aSuccessfulPassClears() {
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(attempted: 3, cached: 3)))
}

/// **The case that makes this correct.** A pass with nothing due is the normal case — most
/// ticks attempt nothing — so clearing on one would erase the warning within five minutes of
/// recording it. D-163's rule in the form this needs: an empty failure list is not evidence
/// of success.
@Test("a pass that attempted nothing clears nothing")
func anEmptyPassClearsNothing() {
    #expect(CredentialRejection.isCleared(by: .idle) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(notConfigured: 2)) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(disabled: 2)) == false)
    #expect(CredentialRejection.isCleared(by: RefreshOutcome(readFailed: true)) == false)
}

@Test("a pass still being refused does not clear the record")
func aRefusedPassDoesNotClear() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.credentialExpired)])

    #expect(CredentialRejection.isCleared(by: outcome) == false)
}

/// A network failure neither records nor clears: the token is no more suspect than before,
/// and no less. Both halves asserted together, because the pair is the behaviour.
@Test("a network failure leaves an existing record exactly as it was")
func aNetworkFailureLeavesItAlone() {
    let outcome = RefreshOutcome(attempted: 1, failures: [failure(.network)])

    #expect(CredentialRejection.from(outcome, at: moment) == nil)
    #expect(CredentialRejection.isCleared(by: outcome) == false)
}
```

**`a network failure leaves an existing record exactly as it was` is the test that matters.** The
clearing rule was written twice before it was right, and that test is what failed the second
version — see the step after next.

- [ ] **Step 2: Run them and confirm they fail**

```bash
make test > /tmp/test.log 2>&1; echo "exit: $?"
grep -E "error:|Cannot find" /tmp/test.log | head -3
```

Expected: BUILD FAILED, `cannot find 'CredentialRejection' in scope`.

- [ ] **Step 3: Write the value and its two rules**

Create `StenoKit/Integrations/CredentialRejection.swift`:

```swift
import Foundation

/// A credential an **unattended** pass found broken, and when it found out (D-227).
///
/// **Why this exists at all.** M4-05's task file requires that "an expired Atlassian token
/// discovered here should set the warning state that M4-04 displays, not interrupt", and
/// before this type the scheduled pass discarded the only evidence it had.
/// `IntegrationsSettingsModel.expiryWarning` is derived from the *user-entered expiry
/// date* — by design, since D-192 made a blank date mean the warning cannot fire — so a
/// token that was **revoked**, or that expired with no date recorded, left the pane
/// showing nothing at all until the next "Prepare Stand-up". Raised by Copilot in review
/// of PR #46, against a claim in this task's own spec that said no plumbing was needed.
///
/// **A timestamped fact, not a current state.** "The background refresh at 08:03 could not
/// sign in" stays true however the credential is fixed afterwards, which is what keeps this
/// from needing to be invalidated from four places — the credential save, the connection
/// test, the toggle and a manual Prepare. A later pass that actually reaches the source
/// clears it, and until then the sentence it produces is still a fact.
///
/// `Codable` here is not the hole it was on `TimeOfDay`: this type has no invariant beyond
/// its fields, and it is genuinely serialized — it is stored as JSON in `UserDefaults`, the
/// shape `AutoExportStatus` already uses.
public struct CredentialRejection: Sendable, Equatable, Codable {
    /// The connector's `displayName`, so the sentence names what to fix. A connector
    /// constant, never response content — the property that keeps `SourceError`'s logging
    /// rule intact.
    public let displayName: String

    /// When the unattended pass was rejected, on the app's clock.
    public let discoveredAt: Date

    public init(displayName: String, at discoveredAt: Date) {
        self.displayName = displayName
        self.discoveredAt = discoveredAt
    }

    /// The rejection in `outcome`, if a connector refused this pass's credential.
    ///
    /// **Only `.credentialExpired` and `.invalidCredential`.** A network failure, a
    /// timeout, a mistyped site (`.siteNotFound`) and an unconfigured connector say nothing
    /// about whether the stored token is still good, and a warning that fires on an
    /// unreachable network is one the user learns to ignore — FR-5's reasoning, applied to
    /// the credential.
    ///
    /// The first such failure wins. Both Atlassian connectors share one credential (§5.3),
    /// so a pass that fails Jira and Confluence has found one broken token, not two.
    public static func from(_ outcome: RefreshOutcome, at moment: Date) -> CredentialRejection? {
        let rejected = outcome.failures.first { failure in
            failure.error == .credentialExpired || failure.error == .invalidCredential
        }
        guard let rejected else { return nil }
        return CredentialRejection(displayName: rejected.displayName, at: moment)
    }

    /// Whether `outcome` is evidence that a recorded rejection is over.
    ///
    /// **A fetch that succeeded, not merely a pass without a credential error.** `cached` is
    /// the count of refs whose `cachedSummary` and `lastFetchedAt` were written, so it is
    /// non-zero only if a connector actually authenticated and answered. Two weaker readings
    /// were tried and are both wrong:
    ///
    /// - `attempted > 0 && no credential failure` clears on a pass whose every ref failed
    ///   with `.network`. An unreachable source says nothing about whether the token is
    ///   valid, so that would erase a true warning the first time the user's wifi dropped.
    ///   Caught by `a network failure leaves an existing record exactly as it was`.
    /// - "no credential failure" alone clears on a pass that attempted nothing, which is the
    ///   *normal* case — most ticks have nothing due — so the warning would vanish within
    ///   five minutes of being recorded. D-163's rule: an empty failure list is not evidence
    ///   of success.
    ///
    /// A pass whose fetches succeeded but whose save was rolled back (D-172) leaves the
    /// record standing for one more pass. That is the safe direction: the warning is stale by
    /// a few hours rather than absent while a token is broken.
    public static func isCleared(by outcome: RefreshOutcome) -> Bool {
        outcome.cached > 0 && from(outcome, at: .distantPast) == nil
    }
}
```

**Three readings of "what clears a recorded rejection", two of them wrong:**

| Rule | Why it fails |
|---|---|
| no credential failure in the outcome | Clears on a pass that attempted nothing — the normal case, since most ticks have nothing due — so the warning vanishes within five minutes of being recorded |
| `attempted > 0` and no credential failure | Clears on a pass whose every ref failed with `.network`. An unreachable source says nothing about the token, so a dropped wifi connection erases a true warning |
| **`cached > 0` and no credential failure** | `cached` counts refs whose cache was written, so it is non-zero only if a connector authenticated and answered |

- [ ] **Step 4: Store it**

Add the fourth key to `AppSettings+ScheduledRefresh.swift` and to `allKeys`, then bump
`AISecretsTests`'s count to 14. Stored as JSON, like `autoExportStatus`; an unreadable value reads
as `nil` rather than being overwritten.

**`Codable` here is not the hole it was on `TimeOfDay`** (round 1's finding): this type has no
invariant beyond its fields, and it is genuinely serialized. Say so where it is declared, or the
next reader applies round 1's lesson to the wrong type.

- [ ] **Step 5: Record it from the pass**

`ScheduledRefreshController`'s `refresh` closure becomes `@MainActor () async -> RefreshOutcome`,
and `dispatch()` awaits it and calls `record(_:)`. Add the D-227 cases to
`ScheduledRefreshControllerTests` — the existing tests need `refresh: { .idle }` in place of
`refresh: {}`.

Then surface it: `credentialRejection` and `reload()` on the settings model, the warning row in
`ScheduledRefreshSection`, and `.onAppear { model.reload() }` on that section's `Group`.

**Re-read, not mirrored.** `isEnabled` and `time` are mirrors written by the pane; this one is
written by the controller while the window is closed, so a value captured at launch would still
say "nothing" after an 08:00 pass was refused.

**The `onAppear` lives on the section, not the pane.** `IntegrationsSettingsPane` is at 398 lines
of SwiftLint's 400, and the reload belongs with the view that reads the value. A `Group` wraps the
section's rows so a single modifier can attach to all of them; `Group` is transparent in a `Form`.

- [ ] **Step 6: Run everything**

```bash
make build > /tmp/build.log 2>&1; echo "exit: $?"; grep -c "❌" /tmp/build.log
make test  > /tmp/test.log  2>&1; echo "exit: $?"; grep -c "recorded an issue" /tmp/test.log
make lint  > /tmp/lint.log  2>&1; echo "exit: $?"; tail -1 /tmp/lint.log
```

- [ ] **Step 7: Mutate, to prove the tests can fail**

| Edit | Must go red |
|---|---|
| `outcome.cached > 0` → `outcome.attempted > 0` | `a network failure leaves an existing record exactly as it was` |
| drop the `.invalidCredential` arm | `a rejected credential is recorded` |
| add `\|\| failure.error == .network` to that arm | `a failure that says nothing about the token records nothing` |
| delete the `else if CredentialRejection.isCleared` branch | `a later pass that reaches the source clears the record` |
| `else if CredentialRejection.isCleared(by: outcome)` → `else if true` | `a pass that attempted nothing leaves the record standing` |
| `settings.scheduledRefreshRejection = rejection` → `_ = rejection` | `a refused credential is persisted by the pass that found it` |

- [ ] **Step 8: Commit**

```bash
git add StenoKit Steno StenoTests docs
git commit   # subject: "fix: record the credential a background pass was refused"
```

The body says what the spec got wrong, not just what the code now does: this task's own spec
claimed no plumbing was needed, and the claim did not survive contact with D-192.
