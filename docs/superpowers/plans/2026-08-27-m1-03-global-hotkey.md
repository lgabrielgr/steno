# M1-03 Global Hotkey & Floating Capture Window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A system-wide `⌥Space` that opens a focused, non-activating capture panel above every application, writing through M1-02's existing capture path and returning the user to what they were doing.

**Architecture:** Carbon `RegisterEventHotKey` binds the chord — it is not TCC-gated, so this feature needs no Accessibility permission. The panel is an `NSPanel` with `.nonactivatingPanel`, so the user's own application never stops being frontmost and dismissal has nothing to restore. Everything except the panel and its controller lives in `StenoKit` and is covered by the headless bundle.

**Tech Stack:** Swift 6 language mode, macOS 14 target, SwiftUI + AppKit (`NSPanel`, `NSHostingView`), Carbon HIToolbox, SwiftData, Swift Testing (XCTest only for `measure`, per D-011).

**Spec:** [`docs/superpowers/specs/2026-08-27-m1-03-global-hotkey-design.md`](../specs/2026-08-27-m1-03-global-hotkey-design.md)

## Global Constraints

- **Never commit to `main`.** This work is one branch, `feat/global-hotkey-capture`, and one PR that you do not merge (§9.5).
- **`make build && make test && make lint` must all pass before the PR** (§9.5 step 4). Verify, don't assert.
- **The event log is append-only.** No code here writes to an existing `Event` (§3.3, §13).
- **Never break capture latency.** §1.1 gives the whole path a ~3 second budget; changes to it are measured, not assumed (CLAUDE.md non-negotiable #4).
- **Do not re-implement capture.** M1-02 owns the write. If this task grows a second way to create a task, it is wrong (D15).
- Swift version `6.0`, deployment target macOS `14.0`, bundle ID prefix `com.lgabrielgr`.
- SwiftLint runs `--strict`, so warnings fail. Enabled opt-in rules: `empty_count`, `explicit_init`, `first_where`, `force_unwrapping`. `identifier_name` rejects identifiers under 3 characters — never name anything `id`, `to`, `m`.
- swift-format owns layout, SwiftLint owns semantics (D-013). Run `make format` before `make lint`.
- Every commit message carries a Conventional Commits type prefix and ends with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Test files import `Testing` and use `@testable import StenoKit`. Types under test that a `@Test` function takes as a parameter must make the test function `private` too.
- `make test` regenerates `Steno.xcodeproj` every run, by design.

**Every code block below type-checks** under `xcrun swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos14.0`, EXIT=0, and the §3 decoder additionally ran against the real `com.apple.symbolichotkeys` domain. Do not "fix" these snippets on the assumption that they are sketches.

---

## File Structure

| File | Responsibility |
|---|---|
| `StenoKit/Capture/HotkeyChord.swift` | **Create.** Chord value type, Cocoa↔Carbon conversion, display string |
| `StenoKit/Capture/SystemHotkeys.swift` | **Create.** `ReservedHotkey`, the default-chord table, plist resolution |
| `StenoKit/Capture/HotkeyConflictChecker.swift` | **Create.** Chord vs reserved |
| `StenoKit/Capture/GlobalHotkeyMonitor.swift` | **Create.** Protocol, error type, `CarbonHotkeyMonitor` |
| `StenoKit/Capture/CaptureNotifications.swift` | **Create.** `Notification.Name.stenoDidCapture`, `CaptureObservation` |
| `StenoKit/Capture/CaptureService.swift` | **Modify.** Post on successful save |
| `StenoKit/Features/MainWindow/MainWindowModel.swift` | **Modify.** Observe and reload |
| `StenoKit/Features/Capture/QuickCaptureModel.swift` | **Create.** The panel's model: field, projects, registration state |
| `Steno/Features/Capture/CaptureFieldView.swift` | **Modify.** Gains `CaptureFieldStyle` |
| `Steno/Features/Capture/CapturePanel.swift` | **Create.** The non-activating panel |
| `Steno/Features/Capture/QuickCaptureController.swift` | **Create.** Monitor → panel → model wiring |
| `Steno/App/StenoApp.swift` | **Modify.** Build the controller at launch |

Tests mirror these under `StenoTests/Capture/` and `StenoTests/Features/Capture/`.

---

### Task 1: `HotkeyChord`

**Files:**
- Create: `StenoKit/Capture/HotkeyChord.swift`
- Test: `StenoTests/Capture/HotkeyChordTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public struct HotkeyChord: Equatable, Hashable, Codable, Sendable` with `public let keyCode: UInt16`, `public let modifiers: UInt` (Cocoa `NSEvent.ModifierFlags` raw value), `public init(keyCode:modifiers:)`, `public static let default: HotkeyChord`, `public var carbonModifiers: UInt32`, `public var displayString: String`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/HotkeyChordTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import StenoKit

@Test("the default chord is ⌥Space")
func defaultChordIsOptionSpace() {
    #expect(HotkeyChord.default.keyCode == 49)
    #expect(HotkeyChord.default.modifiers == NSEvent.ModifierFlags.option.rawValue)
    #expect(HotkeyChord.default.displayString == "⌥Space")
}

/// The two encodings are unrelated bit layouts, and confusing them binds the
/// user to a chord other than the one they chose. See design §3.2.
@Test(
    "Cocoa modifier flags convert to their Carbon equivalents",
    arguments: [
        (NSEvent.ModifierFlags.shift, UInt32(512)),
        (NSEvent.ModifierFlags.control, UInt32(4096)),
        (NSEvent.ModifierFlags.option, UInt32(2048)),
        (NSEvent.ModifierFlags.command, UInt32(256)),
    ])
func cocoaModifiersConvertToCarbon(flags: NSEvent.ModifierFlags, carbon: UInt32) {
    let chord = HotkeyChord(keyCode: 49, modifiers: flags.rawValue)
    #expect(chord.carbonModifiers == carbon)
}

@Test("combined modifiers convert as a union")
func combinedModifiersConvert() {
    let chord = HotkeyChord(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue)

    #expect(chord.carbonModifiers == UInt32(4096 | 2048))
    #expect(chord.displayString == "⌃⌥Space")
}

@Test("a chord round-trips through Codable")
func chordRoundTripsThroughCodable() throws {
    let encoded = try JSONEncoder().encode(HotkeyChord.default)
    let decoded = try JSONDecoder().decode(HotkeyChord.self, from: encoded)

    #expect(decoded == HotkeyChord.default)
}

@Test("an unmapped key code degrades to a readable label rather than empty text")
func unmappedKeyCodeDegrades() {
    let chord = HotkeyChord(keyCode: 200, modifiers: NSEvent.ModifierFlags.command.rawValue)

    #expect(chord.displayString == "⌘Key 200")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — compilation error, `cannot find 'HotkeyChord' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/HotkeyChord.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import Foundation

/// One global keyboard chord: a virtual key code plus its modifiers.
///
/// **Modifiers are stored in the Cocoa encoding** — `NSEvent.ModifierFlags`
/// raw values — and converted to Carbon only at the registration call. Two
/// reasons. It is what `com.apple.symbolichotkeys` speaks, so
/// `HotkeyConflictChecker` compares like with like; and it is what a key
/// recorder control in M1-08 will hand over. The two layouts are unrelated
/// (design §3.2), so a single canonical form with one conversion point is the
/// difference between a chord that binds correctly and one that binds to
/// something else.
public struct HotkeyChord: Equatable, Hashable, Codable, Sendable {
    /// A virtual key code — `kVK_Space` and friends, layout-independent.
    public let keyCode: UInt16

    /// `NSEvent.ModifierFlags.rawValue`, not a Carbon mask.
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// FR-1.1's default. Verified free of system shortcuts on the development
    /// machine — the only Space chords macOS claims there are `⌃Space` and
    /// `⌃⌥Space`, both input-source switching — so a fresh install does not
    /// open on a conflict warning.
    public static let `default` = HotkeyChord(
        keyCode: UInt16(kVK_Space),
        modifiers: NSEvent.ModifierFlags.option.rawValue
    )

    /// The Carbon mask `RegisterEventHotKey` expects.
    public var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// For M1-08's rebinding pane and for conflict messages.
    ///
    /// Modifier order is macOS's own — `⌃⌥⇧⌘` — so a chord reads the way the
    /// same chord reads in a system menu.
    public var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// Covers the keys the default chord and the conflict table actually use.
    ///
    /// A table rather than a `switch`: twelve cases put the function over
    /// SwiftLint's `cyclomatic_complexity` threshold of 10, which `--strict`
    /// makes a build failure. It is also the better shape — this is data.
    private static let keyNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_DownArrow: "↓",
        kVK_UpArrow: "↑",
        kVK_ANSI_3: "3",
        kVK_ANSI_4: "4",
        kVK_ANSI_5: "5",
        kVK_ANSI_D: "D",
        kVK_ANSI_Slash: "/",
    ]

    /// An unmapped code degrades to a readable label rather than to empty
    /// text: a rebinding pane showing a bare `⌘` is worse than one showing
    /// `⌘Key 200`.
    static func keyName(for keyCode: UInt16) -> String {
        keyNames[Int(keyCode)] ?? "Key \(keyCode)"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/HotkeyChord.swift StenoTests/Capture/HotkeyChordTests.swift
git commit -m "$(cat <<'EOF'
feat: HotkeyChord, with one canonical modifier encoding

Cocoa and Carbon encode modifiers in unrelated bit layouts, and a chord that
mixes them binds the user to something other than what they chose. The chord
stores the Cocoa form — what com.apple.symbolichotkeys speaks, so conflict
checking compares like with like — and converts at the single point that
needs Carbon.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `SystemHotkeys` — reserved-chord resolution

**Files:**
- Create: `StenoKit/Capture/SystemHotkeys.swift`
- Test: `StenoTests/Capture/SystemHotkeysTests.swift`

**Interfaces:**
- Consumes: `HotkeyChord` from Task 1.
- Produces: `public struct ReservedHotkey: Equatable, Sendable` with `public let identifier: Int`, `public let name: String`, `public let chord: HotkeyChord`; and `public enum SystemHotkeys` with `public static func reserved(in domain: [String: Any]) -> [ReservedHotkey]` and `public static func systemDomain() -> [String: Any]`.

**This task is where the design's central finding lives.** `com.apple.symbolichotkeys` records *deviations*, not state: Spotlight (64), Finder search (65), Mission Control (32) and App windows (33) are absent from the domain entirely on a stock machine while being live at their defaults, and ids 79/81 appear as bare `{enabled: true}` with no `value`. A resolver that trusts the plist alone reports `⌘Space` as free.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/SystemHotkeysTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import StenoKit

private let commandSpace = HotkeyChord(
    keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
private let controlSpace = HotkeyChord(
    keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)

/// Shaped exactly like the real domain: an id with a recorded `value`, an id
/// enabled with no `value` at all, a disabled id, and — critically — no entry
/// for Spotlight.
///
/// A function, not a `let`. A file-scope `let` of type `[String: Any]` is a
/// **compile error** in Swift 6 — the type is not `Sendable`, so it cannot be
/// a global. Verified, not guessed.
private func realisticDomain() -> [String: Any] {
    [
        "60": ["enabled": true,
               "value": ["parameters": [32, 49, 262_144], "type": "standard"]],
        "79": ["enabled": true],
        "65": ["enabled": false],
    ]
}

@Test("a recorded value is used as the reserved chord")
func recordedValueIsUsed() throws {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let entry = try #require(reserved.first { $0.identifier == 60 })

    #expect(entry.chord == controlSpace)
}

@Test("an id enabled with no recorded value falls back to the default table")
func enabledWithoutValueUsesDefaultTable() throws {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let entry = try #require(reserved.first { $0.identifier == 79 })

    // ⌃← — the domain says only that it is on, never what it is bound to.
    #expect(entry.chord.keyCode == 123)
    #expect(entry.chord.modifiers == NSEvent.ModifierFlags.control.rawValue)
}

/// The regression test for design §3.1. Spotlight is absent from the fixture,
/// exactly as it is absent from a stock machine's real domain — and is
/// nonetheless live at ⌘Space. A resolver that reads only the plist reports
/// the likeliest conflict a user can hit as free.
@Test("an id absent from the domain is still reserved at its default chord")
func absentIDIsStillReserved() throws {
    #expect(realisticDomain()["64"] == nil)

    let reserved = SystemHotkeys.reserved(in: realisticDomain())
    let spotlight = try #require(reserved.first { $0.identifier == 64 })

    #expect(spotlight.chord == commandSpace)
    #expect(spotlight.name == "Spotlight search")
}

@Test("an explicitly disabled id is not reserved")
func disabledIDIsNotReserved() {
    let reserved = SystemHotkeys.reserved(in: realisticDomain())

    #expect(!reserved.contains { $0.identifier == 65 })
}

@Test("malformed entries are skipped rather than crashing")
func malformedEntriesAreSkipped() {
    let domain: [String: Any] = [
        "not-a-number": ["enabled": true],
        "60": "not-a-dictionary",
        "61": ["enabled": true, "value": ["parameters": [32]]],
    ]

    let reserved = SystemHotkeys.reserved(in: domain)

    // 61 is enabled but its parameters are too short, so it resolves from the
    // default table; the other two contribute nothing.
    #expect(reserved.contains { $0.identifier == 61 })
    #expect(!reserved.contains { $0.identifier == 60 && $0.chord.keyCode == 0 })
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'SystemHotkeys' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/SystemHotkeys.swift`:

```swift
import AppKit
import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut macOS has already claimed.
public struct ReservedHotkey: Equatable, Sendable {
    /// The `AppleSymbolicHotKeys` id, kept so a conflict message can name the
    /// shortcut and a future setting could point the user at the right pane.
    public let identifier: Int
    public let name: String
    public let chord: HotkeyChord

    public init(identifier: Int, name: String, chord: HotkeyChord) {
        self.identifier = identifier
        self.name = name
        self.chord = chord
    }
}

/// macOS's own shortcuts, resolved from the `com.apple.symbolichotkeys`
/// defaults domain.
///
/// **The domain records deviations, not state.** This is the whole reason this
/// type is more than a plist read. On a stock machine Spotlight (64), Finder
/// search (65), Mission Control (32) and application windows (33) are absent
/// from the domain *entirely* and are live at their defaults; other ids appear
/// as a bare `{"enabled": true}` with no `value` key, meaning "on, at a chord
/// this file does not record". A resolver that trusts the plist alone reports
/// `⌘Space` as free — which is the single likeliest conflict any user of
/// FR-1.1 will ever attempt. Design §3.1.
public enum SystemHotkeys {
    public static let domainName = "com.apple.symbolichotkeys"
    public static let defaultsKey = "AppleSymbolicHotKeys"

    /// The chords macOS ships enabled, for the ids a capture hotkey could
    /// plausibly collide with.
    ///
    /// This is **data, not logic** — extend it if a gap turns up rather than
    /// adding special cases to `reserved(in:)`.
    static let systemDefaults: [Int: ReservedHotkey] = {
        func entry(_ identifier: Int, _ name: String, _ code: Int,
                   _ flags: NSEvent.ModifierFlags) -> (Int, ReservedHotkey)
        {
            (
                identifier,
                ReservedHotkey(
                    identifier: identifier, name: name,
                    chord: HotkeyChord(keyCode: UInt16(code), modifiers: flags.rawValue))
            )
        }
        return Dictionary(
            uniqueKeysWithValues: [
                entry(32, "Mission Control", kVK_UpArrow, [.control]),
                entry(33, "Application windows", kVK_DownArrow, [.control]),
                entry(52, "Turn Dock hiding on/off", kVK_ANSI_D, [.option, .command]),
                entry(60, "Select previous input source", kVK_Space, [.control]),
                entry(61, "Select next input source", kVK_Space, [.control, .option]),
                entry(64, "Spotlight search", kVK_Space, [.command]),
                entry(65, "Finder search window", kVK_Space, [.option, .command]),
                entry(79, "Move left a space", kVK_LeftArrow, [.control]),
                entry(81, "Move right a space", kVK_RightArrow, [.control]),
                entry(98, "Show Help menu", kVK_ANSI_Slash, [.shift, .command]),
                entry(28, "Screenshot to file", kVK_ANSI_3, [.shift, .command]),
                entry(30, "Screenshot region to file", kVK_ANSI_4, [.shift, .command]),
                entry(184, "Screenshot and recording options", kVK_ANSI_5, [.shift, .command]),
            ])
    }()

    /// Every chord macOS currently claims.
    ///
    /// The domain is a parameter rather than read internally so the whole
    /// resolution is testable against fixtures with no dependency on the
    /// machine running the suite (§9.4).
    public static func reserved(in domain: [String: Any]) -> [ReservedHotkey] {
        var found: [ReservedHotkey] = []
        var seen: Set<Int> = []

        for (rawIdentifier, rawEntry) in domain {
            guard let identifier = Int(rawIdentifier),
                let entry = rawEntry as? [String: Any]
            else { continue }
            seen.insert(identifier)

            // Absent `enabled` means off: macOS writes the key when it writes
            // the entry, so an entry without one is not a live shortcut.
            guard (entry["enabled"] as? Bool) ?? false else { continue }

            if let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Int],
                parameters.count >= 3
            {
                // parameters = (ascii, keyCode, cocoaModifierMask).
                found.append(
                    ReservedHotkey(
                        identifier: identifier,
                        name: systemDefaults[identifier]?.name ?? "System shortcut \(identifier)",
                        chord: HotkeyChord(
                            keyCode: UInt16(truncatingIfNeeded: parameters[1]),
                            modifiers: UInt(bitPattern: parameters[2]))))
            } else if let fallback = systemDefaults[identifier] {
                // Enabled, but the chord is not recorded here.
                found.append(fallback)
            }
        }

        // The ids the domain never mentions, which are live at their defaults.
        for (identifier, fallback) in systemDefaults where !seen.contains(identifier) {
            found.append(fallback)
        }
        return found
    }

    /// The running machine's domain. Unsandboxed (see `Steno.entitlements`),
    /// so this reads the user's real preferences.
    public static func systemDomain() -> [String: Any] {
        UserDefaults(suiteName: domainName)?.dictionary(forKey: defaultsKey) ?? [:]
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/SystemHotkeys.swift StenoTests/Capture/SystemHotkeysTests.swift
git commit -m "$(cat <<'EOF'
feat: resolve macOS reserved hotkeys, defaults included

com.apple.symbolichotkeys records deviations, not state. On a stock machine
Spotlight, Finder search and Mission Control are absent from the domain
entirely while live at their defaults, and other ids appear enabled with no
recorded chord. Reading the plist alone therefore reports ⌘Space as free —
the likeliest conflict a user of FR-1.1 can hit.

Resolution is three-way: a recorded value wins, an enabled id without one
falls back to a static default table, and an id the domain never mentions is
reserved at its default. The domain is injected so the whole thing is testable
against fixtures rather than against the machine running the suite.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `HotkeyConflictChecker`

**Files:**
- Create: `StenoKit/Capture/HotkeyConflictChecker.swift`
- Test: `StenoTests/Capture/HotkeyConflictCheckerTests.swift`

**Interfaces:**
- Consumes: `HotkeyChord` (Task 1), `ReservedHotkey` and `SystemHotkeys` (Task 2).
- Produces: `public enum HotkeyConflictChecker` with `public static func conflict(for chord: HotkeyChord, against reserved: [ReservedHotkey]) -> ReservedHotkey?`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/HotkeyConflictCheckerTests.swift`:

```swift
import AppKit
import Foundation
import Testing

@testable import StenoKit

/// A stock machine's domain: Spotlight is not in it.
///
/// A function rather than a `let` — a file-scope `[String: Any]` is not
/// `Sendable` and will not compile in Swift 6.
private func stockDomain() -> [String: Any] {
    ["60": ["enabled": true,
            "value": ["parameters": [32, 49, 262_144], "type": "standard"]]]
}

@Test("the default chord is free on a stock machine")
func defaultChordIsFree() {
    let reserved = SystemHotkeys.reserved(in: stockDomain())

    #expect(HotkeyConflictChecker.conflict(for: .default, against: reserved) == nil)
}

/// End-to-end for design §3.1: the fixture omits Spotlight, and ⌘Space must
/// still be reported as taken.
@Test("⌘Space conflicts with Spotlight even though the domain omits it")
func commandSpaceConflictsWithSpotlight() throws {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)

    let conflict = try #require(
        HotkeyConflictChecker.conflict(for: chord, against: reserved))

    #expect(conflict.name == "Spotlight search")
}

@Test("a chord recorded in the domain conflicts")
func recordedChordConflicts() throws {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)

    let conflict = try #require(
        HotkeyConflictChecker.conflict(for: chord, against: reserved))

    #expect(conflict.identifier == 60)
}

@Test("modifiers must match exactly, not merely overlap")
func modifiersMustMatchExactly() {
    let reserved = SystemHotkeys.reserved(in: stockDomain())
    let chord = HotkeyChord(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue)

    // ⌃⇧Space is not ⌃Space.
    #expect(HotkeyConflictChecker.conflict(for: chord, against: reserved) == nil)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'HotkeyConflictChecker' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/HotkeyConflictChecker.swift`:

```swift
import Foundation

/// FR-1.1's "detect and warn on conflicts".
///
/// **One class of conflict is detectable through public API, and this type
/// covers exactly that one.** System-reserved chords come from
/// `SystemHotkeys`; our own failed registration is reported by
/// `GlobalHotkeyMonitor`. A chord claimed by *another third-party
/// application* is not detectable at all — `RegisterEventHotKey` typically
/// returns `noErr` and the other application simply wins — and no amount of
/// work here changes that. Design §3 states the limit rather than implying
/// coverage this cannot provide.
public enum HotkeyConflictChecker {
    /// The reserved shortcut this chord collides with, if any.
    ///
    /// Equality is exact on key code *and* modifiers: `⌃⇧Space` is a different
    /// chord from `⌃Space`, and treating an overlap as a conflict would refuse
    /// perfectly good bindings.
    public static func conflict(for chord: HotkeyChord, against reserved: [ReservedHotkey])
        -> ReservedHotkey?
    {
        reserved.first { $0.chord == chord }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/HotkeyConflictChecker.swift \
        StenoTests/Capture/HotkeyConflictCheckerTests.swift
git commit -m "$(cat <<'EOF'
feat: detect chords macOS has already claimed

Exact match on key code and modifiers, so an overlap is not mistaken for a
collision. The end-to-end case is the one that matters: a fixture omitting
Spotlight, as a stock machine's domain does, must still report ⌘Space taken.

Third-party collisions remain undetectable by any public API. That is
documented in the type rather than simulated.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `GlobalHotkeyMonitor` and the Carbon implementation

**Files:**
- Create: `StenoKit/Capture/GlobalHotkeyMonitor.swift`
- Test: `StenoTests/Capture/HotkeyRegistrationErrorTests.swift`

**Interfaces:**
- Consumes: `HotkeyChord` (Task 1).
- Produces: `public enum HotkeyRegistrationError: Error, Equatable` with cases `alreadyRegistered` and `systemRefused(OSStatus)` and a `public var message: String`; `@MainActor public protocol GlobalHotkeyMonitor: AnyObject` with `func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws` and `func unregister()`; `@MainActor public final class CarbonHotkeyMonitor: GlobalHotkeyMonitor` with `public init()`.

**Why this lives in `StenoKit` and not `Steno`:** D-010's test is *"if it cannot be tested without a window server, it does not belong in `Steno/`."* Carbon hotkey registration has no window-server dependency; an `NSPanel` does. So the monitor stays where the headless bundle can reach the protocol, the error mapping, and every consumer.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/HotkeyRegistrationErrorTests.swift`:

```swift
import Foundation
import Testing

@testable import StenoKit

@Test("each failure explains itself in words a settings pane can show")
func failuresCarryReadableMessages() {
    #expect(
        HotkeyRegistrationError.alreadyRegistered.message
            == "That shortcut is already registered.")
    #expect(
        HotkeyRegistrationError.systemRefused(-9868).message
            == "macOS refused the shortcut (error -9868).")
}

@Test("registration errors compare by case and status")
func registrationErrorsCompare() {
    #expect(HotkeyRegistrationError.systemRefused(-1) != .systemRefused(-2))
    #expect(HotkeyRegistrationError.alreadyRegistered == .alreadyRegistered)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'HotkeyRegistrationError' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/GlobalHotkeyMonitor.swift`:

```swift
import Carbon.HIToolbox
import Foundation

/// Why a chord could not be bound.
public enum HotkeyRegistrationError: Error, Equatable {
    /// `eventHotKeyExistsErr` — this process already holds the chord.
    case alreadyRegistered
    /// Any other non-`noErr` status from `RegisterEventHotKey`.
    case systemRefused(OSStatus)

    /// Written for a person, not a log: M1-08's rebinding pane shows this
    /// string verbatim.
    public var message: String {
        switch self {
        case .alreadyRegistered:
            return "That shortcut is already registered."
        case .systemRefused(let status):
            return "macOS refused the shortcut (error \(status))."
        }
    }
}

/// Binds a system-wide chord.
///
/// A protocol so `QuickCaptureModel` is testable without registering anything
/// real — ARCHITECTURE §2 rule 4, applied to a system service rather than a
/// network one.
@MainActor
public protocol GlobalHotkeyMonitor: AnyObject {
    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws
    func unregister()
}

/// The real one, over Carbon's hot key API.
///
/// **`RegisterEventHotKey`, deliberately, and not an `NSEvent` global monitor
/// or a `CGEventTap`.** Those two are gated by Accessibility (TCC) and fail
/// silently until the user grants it; this one is dispatched by the
/// WindowServer to the registering process and needs no permission at all.
/// That is why M1-03 ships no permissions UI, and why REQUIREMENTS.md §9.3
/// was amended — see design §1. If a permission dialog ever appears for this
/// feature, that reasoning is wrong and should be revisited rather than
/// worked around.
@MainActor
public final class CarbonHotkeyMonitor: GlobalHotkeyMonitor {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    /// 'STNO' — identifies our hot key in the event, so the handler ignores
    /// anything else the dispatcher routes through it.
    private static let signature = OSType(0x5354_4E4F)

    public init() {}

    public func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        // Idempotent: rebinding from M1-08 is register-over-register, and a
        // stale handler would deliver the old chord as well as the new one.
        unregister()
        self.onPress = onPress

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // `passUnretained`: the handler is torn down in `unregister`, which
        // runs before deinit can complete, so retaining self here would be a
        // cycle for no added safety.
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let monitor = Unmanaged<CarbonHotkeyMonitor>.fromOpaque(userData)
                    .takeUnretainedValue()
                // Carbon dispatches hot keys on the main thread; this asserts
                // that rather than hopping, because a hop would put the panel
                // one runloop turn further from the keypress (§1.1).
                MainActor.assumeIsolated { monitor.onPress?() }
                return noErr
            }, 1, &spec, context, &handlerRef)

        let status = RegisterEventHotKey(
            UInt32(chord.keyCode), chord.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &hotKeyRef)

        guard status == noErr else {
            unregister()
            throw status == OSStatus(eventHotKeyExistsErr)
                ? HotkeyRegistrationError.alreadyRegistered
                : HotkeyRegistrationError.systemRefused(status)
        }
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onPress = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/GlobalHotkeyMonitor.swift \
        StenoTests/Capture/HotkeyRegistrationErrorTests.swift
git commit -m "$(cat <<'EOF'
feat: bind the global chord via Carbon, behind a protocol

RegisterEventHotKey is not TCC-gated — NSEvent global monitors and CGEventTap
are — so this feature needs no Accessibility permission and ships no
permissions UI. The reasoning is recorded on the type, because an agent who
assumes otherwise will build a subsystem for a state that cannot occur.

Registration is idempotent so M1-08's rebinding is register-over-register
without leaving a stale handler delivering the old chord.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `.stenoDidCapture` — closing D-019's staleness hole

**Files:**
- Create: `StenoKit/Capture/CaptureNotifications.swift`
- Modify: `StenoKit/Capture/CaptureService.swift` (in `capture`, after the `do/catch` around `save`)
- Modify: `StenoKit/Features/MainWindow/MainWindowModel.swift` (stored properties and end of `init`)
- Test: `StenoTests/Capture/CaptureNotificationTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `public extension Notification.Name { static let stenoDidCapture: Notification.Name }`, and `CaptureObservation` (internal). `CaptureService.capture` gains a post; `MainWindowModel` gains `private var captureObservation: CaptureObservation?`.

D-019 names this task: *"M1-03's floating window and M1-04's popover must add a refresh or the main window will silently miss tasks captured elsewhere."*

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Capture/CaptureNotificationTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private func makeService() throws -> (CaptureService, ModelContext) {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()
    return (CaptureService(context: context, now: { epoch }), context)
}

/// Counts posts synchronously. The post is made on the main actor with no
/// delivery queue, so by the time `capture` returns the count is final —
/// which is what makes these assertions deterministic rather than timed.
@MainActor
private final class PostCounter {
    /// Named `posts`, not `count`: SwiftLint's `empty_count` rejects
    /// `something.count == 0`, and `--strict` makes that a build failure.
    private(set) var posts = 0
    private var observation: CaptureObservation?

    init() {
        observation = CaptureObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidCapture, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.posts += 1 }
            })
    }
}

@Test("a successful capture posts exactly once")
@MainActor
func successfulCapturePostsOnce() throws {
    let (service, _) = try makeService()
    let counter = PostCounter()

    try service.capture(text: "PAY-421 fix the retry handler", preferred: nil)

    #expect(counter.posts == 1)
}

@Test("text that is empty after trimming posts nothing")
@MainActor
func emptyCaptureDoesNotPost() throws {
    let (service, _) = try makeService()
    let counter = PostCounter()

    try service.capture(text: "   \n ", preferred: nil)

    #expect(counter.posts == 0)
}

@Test("a failed save posts nothing")
@MainActor
func failedSaveDoesNotPost() throws {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: [],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    struct SaveFailure: Error {}
    let service = CaptureService(
        context: context, now: { epoch }, save: { _ in throw SaveFailure() })
    let counter = PostCounter()

    #expect(throws: SaveFailure.self) {
        try service.capture(text: "something", preferred: nil)
    }
    #expect(counter.posts == 0)
}

@Test("the main window reloads when another surface captures")
@MainActor
func mainWindowReloadsOnCapture() throws {
    let container = try StenoStore.inMemory()
    let context = ModelContext(container)
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: [],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    let model = MainWindowModel(context: context, now: { epoch })
    #expect(model.groups.allSatisfy { $0.tasks.isEmpty })

    // A different surface, over the same store, exactly as the panel will be.
    try CaptureService(context: context, now: { epoch })
        .capture(text: "captured from elsewhere", preferred: nil)

    #expect(model.groups.contains { group in
        group.tasks.contains { $0.title == "captured from elsewhere" }
    })
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'CaptureObservation' in scope` and `type 'Notification.Name' has no member 'stenoDidCapture'`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Capture/CaptureNotifications.swift`:

```swift
import Foundation

extension Notification.Name {
    /// Posted by `CaptureService` after a capture is on disk.
    ///
    /// **Posted at the write, not by each surface.** D-019 recorded that view
    /// models fetch manually and do not refresh, and named this task: the
    /// floating panel and M1-04's popover would otherwise insert tasks an open
    /// main window never notices. One post site covers all three of D15's
    /// surfaces and M1-05's and M1-06's future writes.
    ///
    /// The alternative D-019 itself suggested — reloading on
    /// `NSApplication.didBecomeActiveNotification` — is less code and leaves
    /// two holes: a main window visible on a second display and never
    /// re-activated stays stale, and the popover will not activate the
    /// application either.
    public static let stenoDidCapture = Notification.Name("com.lgabrielgr.steno.didCapture")
}

/// Holds a `NotificationCenter` token and removes it when its owner is
/// deallocated.
///
/// **Why this is a separate object rather than a stored token plus a
/// `deinit`.** In Swift 6 the `deinit` of a `@MainActor` class is nonisolated
/// and may not reference isolated stored properties, so the obvious
/// `deinit { NotificationCenter.default.removeObserver(token) }` inside
/// `MainWindowModel` does not compile. Holding the token in a non-isolated
/// object means ARC releases it along with the model and *this* `deinit`,
/// which touches nothing isolated, does the removal.
final class CaptureObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
```

Modify `StenoKit/Capture/CaptureService.swift` — in `capture(text:preferred:defaultProjectID:ignoringTicketKey:)`, immediately after the `do/catch` block that calls `save` and before `return task`:

```swift
        // After the save, never before: an observer that reloads must not be
        // able to read a context whose write has not landed. `queue: nil` on
        // the observing side keeps delivery synchronous on this actor, which
        // is what lets the tests assert a count rather than wait for one.
        NotificationCenter.default.post(name: .stenoDidCapture, object: nil)
        return task
```

Modify `StenoKit/Features/MainWindow/MainWindowModel.swift` — add a stored property alongside `private let save`:

```swift
    /// Kept alive so the observation lives exactly as long as this model. See
    /// `CaptureObservation` for why the token is not a plain stored property.
    private var captureObservation: CaptureObservation?
```

and replace the trailing `reload()` in `init` with:

```swift
        reload()

        // Registered last, deliberately: `self` may only be captured once
        // every stored property has a value. This is what closes the gap the
        // type's own "Known limit" comment describes — a capture from the
        // floating panel or the menu bar popover now reaches this model.
        captureObservation = CaptureObservation(
            NotificationCenter.default.addObserver(
                forName: .stenoDidCapture, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
```

Also update that type's doc comment: replace the "**Known limit.**" paragraph with:

```swift
/// **Cross-surface writes.** A manual fetch does not refresh when another
/// surface writes, so this model observes `.stenoDidCapture` and reloads.
/// M1-03's floating panel and M1-04's popover therefore reach it without
/// either one knowing this type exists.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations. The pre-existing `MainWindowModel` and `CaptureService` suites must still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Capture/CaptureNotifications.swift StenoKit/Capture/CaptureService.swift \
        StenoKit/Features/MainWindow/MainWindowModel.swift \
        StenoTests/Capture/CaptureNotificationTests.swift
git commit -m "$(cat <<'EOF'
feat: tell open surfaces when any surface captures

D-019 named this task: view models fetch manually and do not refresh, so the
floating panel would insert tasks an open main window never notices — which
reads as data loss even though nothing is lost. CaptureService posts once,
after the save, and MainWindowModel reloads.

Posted at the write rather than per surface, so M1-04's popover and M1-05's
and M1-06's writes are covered without further work. The token lives in a
separate object because a @MainActor class's deinit is nonisolated in Swift 6
and cannot reference isolated stored properties.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `QuickCaptureModel`

**Files:**
- Create: `StenoKit/Features/Capture/QuickCaptureModel.swift`
- Test: `StenoTests/Features/Capture/QuickCaptureModelTests.swift`

**Interfaces:**
- Consumes: `HotkeyChord`, `SystemHotkeys`, `ReservedHotkey`, `HotkeyConflictChecker`, `GlobalHotkeyMonitor`, `HotkeyRegistrationError` (Tasks 1–4); `CaptureService` and `CaptureFieldModel` (M1-02).
- Produces: `@Observable @MainActor public final class QuickCaptureModel` with `public let field: CaptureFieldModel`, `public private(set) var registrationProblem: String?`, `public private(set) var chord: HotkeyChord`, `public init(context:monitor:reserved:defaults:onCaptured:)`, `public func start(onPress:)`, `public func prepareForShow()`, `public func rebind(to:onPress:)`.

- [ ] **Step 1: Write the failing test**

Create `StenoTests/Features/Capture/QuickCaptureModelTests.swift`:

```swift
import AppKit
import Foundation
import SwiftData
import Testing

@testable import StenoKit

private let epoch = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private final class FakeHotkeyMonitor: GlobalHotkeyMonitor {
    var registered: HotkeyChord?
    var unregisterCount = 0
    var failure: (any Error)?

    func register(_ chord: HotkeyChord, onPress: @escaping () -> Void) throws {
        if let failure { throw failure }
        registered = chord
    }

    func unregister() {
        unregisterCount += 1
        registered = nil
    }
}

/// The helper's three values as a named struct rather than a tuple.
/// SwiftLint's `large_tuple` rejects a bare 3-tuple — the same reason
/// `CaptureFieldModelTests` declares a `Fixture`.
private struct Fixture {
    let model: QuickCaptureModel
    let context: ModelContext
    let monitor: FakeHotkeyMonitor
}

@MainActor
private func makeModel(
    monitor: FakeHotkeyMonitor = FakeHotkeyMonitor(),
    reserved: [ReservedHotkey] = [],
    stored: HotkeyChord? = nil
) throws -> Fixture {
    let context = ModelContext(try StenoStore.inMemory())
    context.insert(
        Project(
            name: "Payments", colorHex: "#3B82F6", jiraProjectKeys: ["PAY"],
            sortOrder: 0, modifiedAt: epoch))
    try context.save()

    // `try #require`, never `!` — `force_unwrapping` is an enabled opt-in rule
    // and `--strict` promotes it to a build failure.
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    if let stored {
        defaults.set(try JSONEncoder().encode(stored), forKey: QuickCaptureModel.chordKey)
    }

    let model = QuickCaptureModel(
        context: context, monitor: monitor, reserved: { reserved }, defaults: defaults,
        now: { epoch })
    return Fixture(model: model, context: context, monitor: monitor)
}

@Test("with no stored chord the model binds ⌥Space")
@MainActor
func bindsTheDefaultChord() throws {
    let fixture = try makeModel()
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start { }

    #expect(model.chord == .default)
    #expect(monitor.registered == .default)
    #expect(model.registrationProblem == nil)
}

@Test("a stored chord is used in place of the default")
@MainActor
func storedChordIsUsed() throws {
    let stored = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.control.rawValue)
    let fixture = try makeModel(stored: stored)
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start { }

    #expect(model.chord == stored)
    #expect(monitor.registered == stored)
}

@Test("an undecodable stored chord falls back to the default without erasing it")
@MainActor
func undecodableStoredChordFallsBack() throws {
    let context = ModelContext(try StenoStore.inMemory())
    let defaults = try #require(UserDefaults(suiteName: "steno.tests.\(UUID().uuidString)"))
    defaults.set(Data([0x01, 0x02]), forKey: QuickCaptureModel.chordKey)

    let model = QuickCaptureModel(
        context: context, monitor: FakeHotkeyMonitor(), reserved: { [] }, defaults: defaults,
        now: { epoch })
    model.start { }

    #expect(model.chord == .default)
    // M1-08's pane will want to show what the bad value was.
    #expect(defaults.data(forKey: QuickCaptureModel.chordKey) == Data([0x01, 0x02]))
}

@Test("a reserved chord warns and is registered anyway")
@MainActor
func reservedChordWarnsAndStillBinds() throws {
    let spotlight = ReservedHotkey(
        identifier: 64, name: "Spotlight search",
        chord: .default)
    let fixture = try makeModel(reserved: [spotlight])
    let (model, monitor) = (fixture.model, fixture.monitor)

    model.start { }

    let problem = try #require(model.registrationProblem)
    #expect(problem.contains("Spotlight search"))
    // Refusing to bind guarantees a dead hotkey; binding leaves a chord that
    // may still work, plus an explanation if it does not. Design §3.4.
    #expect(monitor.registered == .default)
}

@Test("a failed registration is reported in the monitor's own words")
@MainActor
func failedRegistrationIsReported() throws {
    let monitor = FakeHotkeyMonitor()
    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let model = try makeModel(monitor: monitor).model

    model.start { }

    #expect(model.registrationProblem == "That shortcut is already registered.")
}

@Test("rebinding replaces the chord and clears a stale problem")
@MainActor
func rebindingReplacesTheChord() throws {
    let monitor = FakeHotkeyMonitor()
    monitor.failure = HotkeyRegistrationError.alreadyRegistered
    let model = try makeModel(monitor: monitor).model
    model.start { }
    #expect(model.registrationProblem != nil)

    monitor.failure = nil
    let replacement = HotkeyChord(keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue)
    model.rebind(to: replacement) { }

    #expect(model.chord == replacement)
    #expect(model.registrationProblem == nil)
    #expect(monitor.registered == replacement)
}

@Test("preparing to show refetches projects so a new one routes immediately")
@MainActor
func prepareForShowRefetchesProjects() throws {
    let fixture = try makeModel()
    let (model, context) = (fixture.model, fixture.context)
    model.prepareForShow()

    context.insert(
        Project(
            name: "Hiring", colorHex: "#F59E0B", jiraProjectKeys: ["HIR"],
            sortOrder: 1, modifiedAt: epoch))
    try context.save()
    model.prepareForShow()

    model.field.text = "HIR-9 schedule the loop"

    let chip = try #require(model.field.chip)
    #expect(chip.projectName == "Hiring")
}

/// Design §8.1: blur and the hotkey toggle hide the panel without discarding
/// the draft, so showing must not clear it. Only `Return` and `Esc` clear.
@Test("preparing to show preserves an in-progress draft")
@MainActor
func prepareForShowPreservesTheDraft() throws {
    let model = try makeModel().model
    model.field.text = "half a thought"

    model.prepareForShow()

    #expect(model.field.text == "half a thought")
}

@Test("a capture through the panel routes on a ticket key with no surface context")
@MainActor
func panelCaptureRoutesOnTicketKey() throws {
    let fixture = try makeModel()
    let (model, context) = (fixture.model, fixture.context)
    model.prepareForShow()

    model.field.text = "PAY-421 fix the retry handler"
    model.field.commit()

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    #expect(tasks.count == 1)
    #expect(model.field.text.isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'QuickCaptureModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `StenoKit/Features/Capture/QuickCaptureModel.swift`:

```swift
import Foundation
import SwiftData

/// The floating panel's model: its capture field, its project list, and the
/// state of its hotkey registration.
///
/// **It does not reach for `MainWindowModel`.** The panel must open, route and
/// write correctly when no main window exists at all — that is most of the
/// point of a global hotkey. It shares the *code path* with the main window,
/// per D15, not the main window's state. The other direction is handled for
/// it: `CaptureService` posts `.stenoDidCapture`, and any open main window
/// reloads itself.
@Observable
@MainActor
public final class QuickCaptureModel {
    /// The shared capture field — the same type the main window's sheet uses,
    /// so the FR-1.4 chip cannot drift between surfaces.
    public let field: CaptureFieldModel

    /// The chord currently bound.
    public private(set) var chord: HotkeyChord

    /// A conflict or a registration failure, in words. M1-08's rebinding pane
    /// renders this; M1-03 has no settings UI to put it in, so the property
    /// *is* the attachment point (design §3.4).
    public private(set) var registrationProblem: String?

    /// Where the user's chord is stored. `UserDefaults`, not SwiftData: it is
    /// configuration, not domain data, and §10's export carries the domain.
    public static let chordKey = "com.lgabrielgr.steno.hotkeyChord"

    private let context: ModelContext
    private let monitor: any GlobalHotkeyMonitor
    private let reserved: () -> [ReservedHotkey]
    private let defaults: UserDefaults
    private let projectBox: ProjectBox

    /// Holds the project list the field reads through.
    ///
    /// A separate object because `CaptureFieldModel` takes its projects as a
    /// closure, and that closure has to be built during `init` — before `self`
    /// can be captured. A box constructed as a local first, then stored,
    /// sidesteps that without an implicitly unwrapped property.
    @MainActor
    final class ProjectBox {
        var projects: [Project] = []
    }

    public init(
        context: ModelContext,
        monitor: any GlobalHotkeyMonitor,
        reserved: @escaping () -> [ReservedHotkey] = {
            SystemHotkeys.reserved(in: SystemHotkeys.systemDomain())
        },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        onCaptured: @escaping () -> Void = {}
    ) {
        let box = ProjectBox()
        self.projectBox = box
        self.context = context
        self.monitor = monitor
        self.reserved = reserved
        self.defaults = defaults
        self.chord = .default
        self.field = CaptureFieldModel(
            service: CaptureService(context: context, now: now),
            projects: { box.projects },
            // The panel has no surface context to prefer — routing falls to
            // the ticket key, then last-used. `CaptureService`'s own
            // documentation specifies `nil` for exactly this surface.
            preferred: { nil },
            onCaptured: { _ in onCaptured() }
        )
    }

    /// Read the stored chord, check it, and bind it.
    public func start(onPress: @escaping () -> Void) {
        chord = storedChord()
        bind(onPress: onPress)
    }

    /// M1-08's entry point. Deliberately present from day one so that task
    /// adds a pane rather than redesigning this type.
    public func rebind(to replacement: HotkeyChord, onPress: @escaping () -> Void) {
        chord = replacement
        if let encoded = try? JSONEncoder().encode(replacement) {
            defaults.set(encoded, forKey: Self.chordKey)
        }
        bind(onPress: onPress)
    }

    /// Called on every open.
    ///
    /// Refetches live projects so a project created since the last capture
    /// routes immediately. **It does not clear the draft** — clearing is a
    /// dismissal responsibility (design §8.1): `Return` and `Esc` clear, while
    /// losing key focus and the hotkey toggle deliberately do not, so a
    /// half-typed thought survives a fumbled chord.
    public func prepareForShow() {
        projectBox.projects = liveProjects()
    }

    private func bind(onPress: @escaping () -> Void) {
        registrationProblem = nil

        // Warn, then register anyway. Refusing to bind guarantees a dead
        // hotkey; binding a claimed chord leaves the user with one that may
        // still work plus an explanation if it does not. The failure FR-1.1
        // exists to prevent is silence, not registration.
        if let conflict = HotkeyConflictChecker.conflict(for: chord, against: reserved()) {
            registrationProblem =
                "\(chord.displayString) is already used by \(conflict.name). "
                + "Steno's shortcut may not work until you change one of them."
            Log.app.fault(
                "hotkey \(self.chord.displayString, privacy: .public) conflicts with "
                    + "\(conflict.name, privacy: .public)")
        }

        do {
            try monitor.register(chord, onPress: onPress)
        } catch let error as HotkeyRegistrationError {
            registrationProblem = error.message
            Log.app.fault("hotkey registration failed: \(error.message, privacy: .public)")
        } catch {
            registrationProblem = "The shortcut could not be registered."
            Log.app.fault(
                "hotkey registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A bad stored value falls back without being overwritten — M1-08's pane
    /// will want to show the user what is actually in there.
    private func storedChord() -> HotkeyChord {
        guard let data = defaults.data(forKey: Self.chordKey),
            let decoded = try? JSONDecoder().decode(HotkeyChord.self, from: data)
        else { return .default }
        return decoded
    }

    private func liveProjects() -> [Project] {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            // An empty list means the chip does not appear; capture itself
            // still routes, because `CaptureService` fetches its own projects.
            Log.app.error(
                "could not load projects for quick capture: "
                    + "\(String(describing: error), privacy: .public)")
            return []
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations.

If `init` trips SwiftLint's `function_parameter_count` (threshold 5, promoted to a failure by `--strict`), note that `reserved`, `defaults`, `now` and `onCaptured` all already carry defaults, and D-028 records that `ignores_default_parameters` defaults to true — so it should not fire. If it does, add a default to `monitor` last, never an inline `swiftlint:disable` (D-023).

- [ ] **Step 5: Commit**

```bash
git add StenoKit/Features/Capture/QuickCaptureModel.swift \
        StenoTests/Features/Capture/QuickCaptureModelTests.swift
git commit -m "$(cat <<'EOF'
feat: the floating panel's model, testable without a panel

Owns the shared CaptureFieldModel, its own project list, and the hotkey
registration state. It deliberately does not reach for MainWindowModel: the
panel must open and route when no main window exists, which is most of the
point of a global hotkey.

A conflicting chord warns and binds anyway — refusing guarantees a dead
hotkey, while binding leaves one that may still work plus an explanation.
rebind(to:) exists now so M1-08 attaches a pane rather than redesigning this.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `CaptureFieldView` gains a bar style

**Files:**
- Modify: `Steno/Features/Capture/CaptureFieldView.swift`
- Modify: `Steno/Features/MainWindow/MainWindowView.swift:48` (the `NewTaskSheet` call site needs no change; `NewTaskSheet` itself passes the style)

**Interfaces:**
- Consumes: `CaptureFieldModel` (M1-02).
- Produces: `enum CaptureFieldStyle { case sheet, bar }`; `CaptureFieldView.init(field:style:onDismiss:)`.

Not unit-testable (D-010) — the gate is that the build, the whole existing suite, and lint stay green.

- [ ] **Step 1: Add the style enum and thread it through**

In `Steno/Features/Capture/CaptureFieldView.swift`, above `struct CaptureFieldView`:

```swift
/// How a capture field is being presented.
///
/// One view with two styles rather than two views, because M1-04's acceptance
/// criterion is "the auto-routing chip behaving identically to the main
/// window" — and the cheapest way to guarantee that is for there to be only
/// one chip. The chip, the error row, the `isBlank` rule and the guarded
/// `onSubmit` are shared literally; only chrome differs.
enum CaptureFieldStyle {
    /// The main window's modal sheet: fixed width, padding, Cancel and Add.
    case sheet
    /// M1-03's floating panel: no button row, panel chrome.
    ///
    /// The buttons are dropped deliberately. Cancel and Add duplicate `Esc`
    /// and `Return` on a surface whose stated requirement (FR-1.1) is that it
    /// works with no mouse at all.
    case bar
}
```

Add the stored property to `CaptureFieldView`, immediately after `let onDismiss: () -> Void`:

```swift
    var style: CaptureFieldStyle = .sheet
```

Wrap the button row so it only renders for `.sheet` — replace the existing `HStack { Spacer(); Button("Cancel"...); Button("Add"...) }` block with:

```swift
            if style == .sheet {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel, action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                    Button("Add", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isBlank)
                }
            } else {
                // The panel has no buttons, so `Esc` needs a declaration of its
                // own — in the sheet it came free with the Cancel button's
                // `.cancelAction` shortcut.
                Button("", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
```

Replace the two trailing modifiers `.padding(20)` and `.frame(width: 420)` with:

```swift
        .padding(style == .sheet ? 20 : 14)
        .frame(width: style == .sheet ? 420 : 560)
```

- [ ] **Step 2: Keep the existing call site explicit**

In the same file, in `NewTaskSheet.body`, pass the style rather than relying on the default:

```swift
    var body: some View {
        CaptureFieldView(field: field, onDismiss: { model.activeSheet = nil }, style: .sheet)
    }
```

- [ ] **Step 3: Verify nothing regressed**

Run: `make format && make build && make test && make lint`
Expected: PASS. The full pre-existing suite must be unchanged and green — this step must not alter behaviour for the sheet.

- [ ] **Step 4: Commit**

```bash
git add Steno/Features/Capture/CaptureFieldView.swift
git commit -m "$(cat <<'EOF'
feat: one capture field, two presentations

M1-04's acceptance criterion is that its chip behaves identically to the main
window's, and the cheapest way to guarantee that is for there to be only one
chip. The bar style drops the Cancel/Add row — they duplicate Esc and Return
on a surface whose requirement is that it works with no mouse — and declares
Esc explicitly, since it came free with the Cancel button before.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: The panel, the controller, and launch wiring

**Files:**
- Create: `Steno/Features/Capture/CapturePanel.swift`
- Create: `Steno/Features/Capture/QuickCaptureController.swift`
- Modify: `Steno/App/StenoApp.swift`

**Interfaces:**
- Consumes: `QuickCaptureModel`, `CarbonHotkeyMonitor` (Tasks 4, 6); `CaptureFieldView`, `CaptureFieldStyle` (Task 7).
- Produces: `@MainActor final class QuickCaptureController` with `init(container: ModelContainer)` and `func start()`.

Not unit-testable (D-010). The gate is `make build` plus Task 9's manual checks.

- [ ] **Step 1: Write the panel**

Create `Steno/Features/Capture/CapturePanel.swift`:

```swift
import AppKit
import SwiftUI

/// The floating capture window.
///
/// **`.nonactivatingPanel`, and shown without `NSApp.activate`.** This is the
/// whole of the design's focus story. The panel becomes key and receives
/// typing, while at the `NSWorkspace` level the user's own application never
/// stops being frontmost — so dismissing has nothing to restore and there is
/// no restore step to get wrong. The task file makes returning focus part of
/// the 3-second budget rather than polish (§1.1); this meets it by never
/// taking focus away.
///
/// The rejected alternative was to activate and then restore
/// `NSWorkspace.shared.frontmostApplication`: the menu bar swaps, the Dock
/// icon marks active, and the restore is an asynchronous cross-process call
/// that can lose a race. Do not "simplify" toward it.
///
/// `.canJoinAllSpaces` with `.fullScreenAuxiliary` is what puts the panel over
/// another application's full-screen space.
final class CapturePanel: NSPanel {
    /// Required: a panel that cannot become key cannot receive typing, and a
    /// capture field that needs a click has already failed FR-1.1.
    override var canBecomeKey: Bool { true }

    /// Never main — being main is what would make Steno the active
    /// application and take the user out of their own.
    override var canBecomeMain: Bool { false }

    init(root: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        // The panel must survive the app not being active — it is shown while
        // another application is frontmost, which is the normal case.
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: root)
    }

    /// Slightly above centre, where a Spotlight-style panel is expected and
    /// where it does not cover what the user is looking at.
    func positionForCapture() {
        guard let screen = NSScreen.main else { return center() }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY + visible.height * 0.15
            ))
    }
}
```

- [ ] **Step 2: Write the controller**

Create `Steno/Features/Capture/QuickCaptureController.swift`:

```swift
import AppKit
import StenoKit
import SwiftData
import SwiftUI

/// Owns the hotkey, the panel, and the model behind it.
///
/// **Built once, at launch, and kept resident** (design §4.2). Building lazily
/// would put `NSPanel` creation, `NSHostingView` instantiation and a SwiftData
/// fetch inside the *first* press of every launch — the press §1.1 most cares
/// about, and the hardest one to measure. One panel resident for the process
/// lifetime is not a cost worth that.
@MainActor
final class QuickCaptureController {
    private let model: QuickCaptureModel
    private let panel: CapturePanel
    private var isShowing = false

    init(container: ModelContainer) {
        // `container.mainContext`, matching what `MainWindowView` reads, so a
        // capture from the panel and the window's own fetches agree without
        // relying on cross-context visibility.
        let model = QuickCaptureModel(
            context: container.mainContext,
            monitor: CarbonHotkeyMonitor()
        )
        self.model = model

        // Built here so the field and its chip are live before the first
        // press, not constructed during it.
        panel = CapturePanel(
            root: CaptureFieldView(
                field: model.field,
                onDismiss: { [weak model] in
                    // Esc: an explicit discard, so the draft goes too.
                    model?.field.reset()
                    NotificationCenter.default.post(name: .capturePanelShouldHide, object: nil)
                },
                style: .bar
            )
        )
        panel.delegate = PanelDelegate.shared
    }

    func start() {
        model.start { [weak self] in self?.toggle() }

        // Both dismissals that are *not* Esc route through here.
        NotificationCenter.default.addObserver(
            forName: .capturePanelShouldHide, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// Pressing the chord while the panel is open dismisses it — the platform
    /// idiom, and FR-1.1 does not specify otherwise. The draft survives,
    /// because a fumbled chord is not a decision to discard (design §8.1).
    private func toggle() {
        // Not a ternary: SwiftLint's `void_function_in_ternary` rejects
        // `isShowing ? hide() : show()` and `--strict` fails the build on it.
        if isShowing {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        // §1.1 makes this path P0 and §13 requires it measured. Read with:
        //   /usr/bin/log show --last 5m --signpost --predicate \
        //     'subsystem == "com.lgabrielgr.steno" AND category == "capture"'
        let interval = Log.captureSignposter.beginInterval("hotkeyShow")
        defer { Log.captureSignposter.endInterval("hotkeyShow", interval) }

        model.prepareForShow()
        panel.positionForCapture()
        // No `NSApp.activate`. See `CapturePanel`.
        panel.makeKeyAndOrderFront(nil)
        isShowing = true
    }

    private func hide() {
        panel.orderOut(nil)
        isShowing = false
    }
}

extension Notification.Name {
    /// Raised by the panel's content and by its delegate; the controller owns
    /// the actual `orderOut` so there is one place that knows the panel is up.
    static let capturePanelShouldHide = Notification.Name(
        "com.lgabrielgr.steno.capturePanelShouldHide")
}

/// Hides the panel when it stops being key.
///
/// **Hides without resetting** (design §8.1). The user clicked away
/// mid-thought; the next press restores their draft. The alternative —
/// Spotlight's discard-on-blur — throws away typed capture text, which
/// `CaptureFieldView`'s own comment calls the single worst thing a capture
/// tool can do. `Esc` remains the way to actually discard.
private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()

    func windowDidResignKey(_ notification: Notification) {
        NotificationCenter.default.post(name: .capturePanelShouldHide, object: nil)
    }
}
```

- [ ] **Step 3: Wire it into launch**

In `Steno/App/StenoApp.swift`, add a stored property beside `storePath`:

```swift
    /// FR-1.1's surface. Held here so it lives for the whole process — a
    /// controller that goes out of scope takes the hotkey with it.
    private let quickCapture: QuickCaptureController?
```

At the end of `init`, after the seeding block, replace the closing of the `if case .success` block with:

```swift
        // Only on a working store: with no container there is nowhere to
        // capture to, and a hotkey opening a panel over a failure scene would
        // be worse than no hotkey (D-018).
        if case .success(let container) = store {
            let controller = QuickCaptureController(container: container)
            controller.start()
            quickCapture = controller
        } else {
            quickCapture = nil
        }
```

Note the seeding block already opens `if case .success(let container) = store`; keep the two blocks separate rather than merging them, so a seeding failure cannot prevent the hotkey from binding.

- [ ] **Step 4: Verify the build**

Run: `make format && make build && make test && make lint`
Expected: PASS, 0 lint violations, existing suite unchanged.

- [ ] **Step 5: Run it and confirm the hotkey binds**

Run: `make run`, then in a second terminal:

```bash
/usr/bin/log show --last 2m --predicate 'subsystem == "com.lgabrielgr.steno"' --info
```

Expected: `Steno launched` and `store opened at …`, and **no** `hotkey registration failed` fault. Press `⌥Space` from another application; the panel must appear. If a fault is present, read its message before changing anything.

- [ ] **Step 6: Commit**

```bash
git add Steno/Features/Capture/CapturePanel.swift \
        Steno/Features/Capture/QuickCaptureController.swift Steno/App/StenoApp.swift
git commit -m "$(cat <<'EOF'
feat: floating capture panel on a global hotkey

A non-activating NSPanel takes key without activating the app, so the user's
own application never stops being frontmost and dismissal has nothing to
restore — focus return is structural rather than a step that can race.

Built once at launch: constructing the panel, its hosting view and the project
fetch lazily would put all three inside the first press of every launch, which
is the press §1.1 most cares about and the hardest to measure. The show path
carries a hotkeyShow signpost so the claim is readable rather than asserted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Amend the documents this work contradicts

**Files:**
- Modify: `docs/REQUIREMENTS.md` (§9.3, status line, changelog)
- Modify: `docs/ARCHITECTURE.md` (§5 prose and file tree)
- Modify: `docs/DECISIONS.md` (four new entries)
- Modify: `docs/tasks/M1-03-global-hotkey.md` (acceptance criterion 5, signing note)
- Modify: `docs/tasks/README.md` (M1-03 row)

CLAUDE.md: *"A PR that quietly contradicts REQUIREMENTS.md is worse than one that pauses to ask."* This task is what stops that happening.

- [ ] **Step 1: Correct REQUIREMENTS.md §9.3**

Replace the paragraph beginning "FR-1's global hotkey requires macOS Accessibility permission" with:

```markdown
FR-1's global hotkey is bound with Carbon's `RegisterEventHotKey`, which is **not** gated by
Accessibility (TCC) — the WindowServer dispatches the chord to the registering process directly.
Steno therefore never prompts for Accessibility, and a permission dialog appearing for the
hotkey is a bug rather than expected behaviour. (`NSEvent.addGlobalMonitorForEvents` and
`CGEventTap` *are* TCC-gated; do not switch to either without reopening this section.)

A stable identity still matters. Ad-hoc signing produces a new identity on every build, so macOS
treats each rebuild as a different application — which breaks any TCC grant the app does come to
need (Screen Recording, Automation, and Full Disk Access are all candidates as M4 and M5 land),
resets per-app state keyed to the signature, and makes local debugging inconsistent.
```

- [ ] **Step 2: Bump the version and add a changelog line**

Change the status line to `**Status:** Draft v1.12` and the date to `2026-08-27`. Add as the first changelog bullet:

```markdown
- *v1.12* — Corrected §9.3. It claimed FR-1's global hotkey requires Accessibility permission, granted by TCC against the code signature. It does not: `RegisterEventHotKey` is not TCC-gated, unlike the `NSEvent` global monitor and `CGEventTap` alternatives. The stable-signing conclusion is unchanged and its reasoning is now correct. Left uncorrected, M1-03 would have shipped a permissions subsystem for a state that cannot occur, plus a banner on the launch path of a feature whose whole argument is that it interrupts nothing. Found while implementing M1-03.
```

- [ ] **Step 3: Widen ARCHITECTURE §5**

Change `Steno/            application — SwiftUI views and @main, nothing else` to:

```
Steno/            application — views, windows, and @main, nothing else
```

and extend the tree's `Features/` line for `Steno/` to mention Capture's panel. Add under `StenoKit/`:

```
  Capture/        ref extraction (M1-01); routing, capture service (M1-02);
                  hotkey chord, conflict detection, Carbon monitor (M1-03)
```

Immediately below the tree, add:

```markdown
The rule that decides membership is D-010's, not the summary line above: **if it cannot be
tested without a window server, it does not belong in `Steno/`.** M1-03 is the case that makes
the distinction visible — Carbon hotkey registration has no window-server dependency and lives
in `StenoKit`, while the `NSPanel` it feeds cannot and does not.
```

Also update the §3 invariant table row for cross-surface refresh by adding a new row:

```markdown
| Surfaces see each other's writes | Every successful capture posts `.stenoDidCapture` | `CaptureService` posts, `MainWindowModel` observes (M1-03) | D-019 |
```

- [ ] **Step 4: Add the DECISIONS.md entries**

Append four entries, numbered from the current highest (D-028), each following the existing format — a bold date/task/status line, **Why**, **Alternatives**, and where relevant **The cost, and who pays it**:

- **D-029 — The global hotkey needs no Accessibility permission.** Carbon vs the two TCC-gated alternatives; the acceptance criterion dropped rather than implemented; §9.3 amended; the runtime evidence is manual check 6, and the entry must say so rather than claim it as verified in the test suite.
- **D-030 — The capture panel is non-activating.** Focus return is structural; records the two rejected alternatives (activate-and-restore, activation-policy toggling) and, explicitly, that the SwiftUI `@FocusState`-in-a-non-activating-panel question was settled by manual check, naming the result.
- **D-031 — `.stenoDidCapture` is posted at the write, not per surface.** Closes D-019's named gap; why not `didBecomeActive`; the synchronous main-actor post is what makes the tests deterministic; the observation token lives in a separate object because a `@MainActor` class's `deinit` is nonisolated in Swift 6.
- **D-032 — Reserved-hotkey detection carries a static default table.** `com.apple.symbolichotkeys` records deviations, not state; the concrete evidence (Spotlight, Finder search, Mission Control absent from a real domain; 79/81 enabled with no value); a plist-only checker reports `⌘Space` free; third-party conflicts are undetectable and are documented rather than simulated.

Also add a row to the "Open — decided by the task that owns them" table:

```markdown
| O-9 | Whether the hotkey chord in `UserDefaults` is carried by §10's export | `M2.5-01` |
```

- [ ] **Step 5: Correct the task file**

In `docs/tasks/M1-03-global-hotkey.md`, replace the fifth acceptance criterion with:

```markdown
- [ ] No Accessibility (TCC) permission is ever requested, and Steno does not appear in System
      Settings → Privacy & Security → Accessibility. `RegisterEventHotKey` is not TCC-gated; a
      permission prompt here means the mechanism was changed (D-029, REQUIREMENTS.md §9.3 v1.12).
```

And in "Notes for the spec/plan phase", replace the first bullet's reasoning while keeping its advice:

```markdown
- **Signing stability still matters, but not for the reason this file originally gave.** §9.3
  claimed the hotkey needs Accessibility permission granted by TCC against the code signature.
  It does not (D-029). Keep M0-01's stable Personal Team identity anyway: ad-hoc signing makes
  every rebuild a new app to macOS, which resets any per-signature state the app does acquire.
```

- [ ] **Step 6: Update the task index**

In `docs/tasks/README.md`, append ` — PR #N` to the M1-03 row once the PR number is known. Re-read the whole index for rows that merged without being ticked (CLAUDE.md working-a-task step 4) and tick any found in this PR.

- [ ] **Step 7: Verify**

Run: `make build && make test && make lint`
Expected: PASS. Then re-read the diff of `docs/REQUIREMENTS.md` and confirm the version, date and changelog line agree with each other.

- [ ] **Step 8: Commit**

```bash
git add docs/
git commit -m "$(cat <<'EOF'
docs: correct §9.3's Accessibility claim and record M1-03's decisions

REQUIREMENTS.md §9.3 stated that FR-1's global hotkey requires Accessibility
permission granted by TCC against the code signature. RegisterEventHotKey is
not TCC-gated, so the premise is wrong; the stable-signing conclusion it
supports is right and is kept with corrected reasoning. Bumped to v1.12.

ARCHITECTURE §5's "views and @main, nothing else" is widened to admit windows,
and the D-010 rule that actually decides membership is stated below the tree —
M1-03 is the case that makes the distinction visible.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Verify and open the PR

- [ ] **Step 1: Full verification**

Run: `make build && make test && make lint`
Expected: all three green. Record the test count.

Read the performance numbers, which `make test` hides:

```bash
sandbox-exec -f Scripts/test-sandbox.sb xcodebuild -project Steno.xcodeproj \
  -scheme Steno -derivedDataPath .build -configuration Debug \
  -destination 'platform=macOS' -only-testing:StenoTests/CapturePerformanceTests \
  test-without-building 2>&1 | grep measured
```

Expected: no regression against M1-02's recorded numbers. This task did not touch the write path, so an unchanged result is the expected evidence — if it moved, find out why before opening the PR.

- [ ] **Step 2: Hand the manual checks to the user**

The eight checks in design §7 cannot be run by an agent — TCC blocks screen capture and Screen Recording is denied. Present them as a list and **wait**. Do not claim the acceptance criteria are met before the user reports back, and lead with check 1: if `@FocusState` does not take the caret inside a non-activating panel, that is a design-level result (D-030's fallback), not a bug to patch around.

- [ ] **Step 3: Open the PR**

```bash
git push -u origin feat/global-hotkey-capture
gh pr create --title "M1-03: global hotkey and floating capture window (FR-1.1)" --body "$(cat <<'EOF'
Implements FR-1.1. `⌥Space` opens a non-activating floating panel above every
application, writing through M1-02's capture path.

## What was done
- Carbon `RegisterEventHotKey` behind a `GlobalHotkeyMonitor` protocol.
- Reserved-chord detection over `com.apple.symbolichotkeys`, with a static
  default table (see below).
- A `.nonactivatingPanel` `NSPanel`, built once at launch and signposted.
- `CaptureFieldView` gains a `.bar` style; the chip and commit logic stay shared.
- `.stenoDidCapture`, closing the staleness gap D-019 named for this task.

## Spec deviations, declared
1. **The Accessibility acceptance criterion is dropped, and §9.3 is corrected.**
   `RegisterEventHotKey` is not TCC-gated, unlike the `NSEvent` monitor and
   `CGEventTap` alternatives, so the criterion had no code behind it.
   REQUIREMENTS.md is bumped to v1.12 with a changelog line. See D-029.
2. **ARCHITECTURE §5 is widened** to admit windows alongside views, and the
   D-010 rule that actually decides target membership is stated. See §2.1 of
   the design.
3. **`com.apple.symbolichotkeys` records deviations, not state.** Spotlight,
   Finder search and Mission Control are absent from a real domain while live
   at their defaults, so a plist-only checker reports ⌘Space free. The checker
   carries a default table. See D-032.
4. **Third-party hotkey conflicts are undetectable** by any public API, and are
   documented rather than simulated. FR-1.1's "detect and warn" is met for
   system-reserved chords and for our own failed registration.

## Deliberately out
The rebinding UI (M1-08 — `rebind(to:)` and `registrationProblem` are the
attachment points), the menu bar item (M1-04), and launch at login (M1-08).
No activation-policy changes, so M1-04 inherits an unmade decision.

## Verification
`make build`, `make test`, `make lint` all green. `CapturePerformanceTests`
re-run unchanged — this PR does not touch the write path.

Manual checks from design §7, run by the reviewer: [fill in results, especially
check 1 — @FocusState inside a non-activating panel — and check 6, no
Accessibility prompt].

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Stop**

Do not merge. The user reviews and merges (§9.5, CLAUDE.md non-negotiable #1).

---

## Self-Review

**Spec coverage.** §1 → Tasks 4, 9. §2 units table → Tasks 1–8. §2.1 → Task 9 step 3. §3 → Tasks 2, 3. §3.1 → Task 2. §3.2 → Task 1. §3.3 → Task 1. §3.4 → Task 6. §4 → Task 8. §4.1 → Task 10 step 2. §4.2 → Task 8. §5 → Tasks 6, 8. §5.1 → Task 5. §5.2 → Task 6. §6 → Tasks 1–6, 10. §7 → Task 10 step 2. §8 table, all six rows → Tasks 6 (registration failure, reserved chord, undecodable chord), 8 (store failure, toggle), 7 (capture failure, unchanged from M1-02). §8.1 → Tasks 6, 8. §9 → Task 7. §10 → Task 9 (O-9). §11 → Task 9.

**Types and names, checked across tasks.** `HotkeyChord.modifiers: UInt`, `keyCode: UInt16`, `carbonModifiers: UInt32` used consistently in Tasks 1–4, 6. `ReservedHotkey.name`/`.identifier`/`.chord` consistent in Tasks 2, 3, 6. `SystemHotkeys.reserved(in:)` and `.systemDomain()` consistent in Tasks 2, 3, 6. `GlobalHotkeyMonitor.register(_:onPress:)` matches the fake in Task 6 and the caller in Task 8. `QuickCaptureModel.chordKey` used by both the tests and the implementation in Task 6. `CaptureObservation` used in Task 5's test and implementation and named in Task 9's D-031. `CaptureFieldStyle` produced in Task 7 and consumed in Task 8. `Log.captureSignposter` and `Log.app` are pre-existing.

**Verification actually run on this plan, not claimed.** Every complete-file
Swift block was extracted and checked: the five self-contained `StenoKit`
units (`HotkeyChord`, `SystemHotkeys`, `HotkeyConflictChecker`,
`GlobalHotkeyMonitor`, `CaptureNotifications`) type-check together under
`-swift-version 6 -target arm64-apple-macos14.0`, EXIT=0; the panel, the
controller and the observer/box shapes were probed separately; and all 14
complete-file blocks pass `swiftlint --strict` against this repo's
`.swiftlint.yml`, 0 violations. The `SystemHotkeys` decoder was additionally
*run* against the real `com.apple.symbolichotkeys` domain, where it reports
`⌘Space` as taken by Spotlight from a domain that does not contain Spotlight —
which is the behaviour Task 2 exists to produce.

Five defects were found that way and fixed in this plan rather than left for
the implementer to hit. They are listed because each is a trap worth knowing:
a file-scope `private let ... : [String: Any]` is a **compile error** in Swift
6 (not `Sendable`); `deinit` on a `@MainActor` class is nonisolated and cannot
touch isolated stored properties; `force_unwrapping` is enabled, so a test
needs `try #require(UserDefaults(suiteName:))` rather than `!`; `empty_count`
rejects any `x.count == 0`, which renamed the test counter's property; and a
twelve-case `switch` exceeds `cyclomatic_complexity`, which turned
`keyName(for:)` into a table.

**Known soft spots, called out rather than hidden.** Task 8's `PanelDelegate`/notification hop between the panel's dismiss closure and the controller is the one piece of structure the design did not specify; if it reads as over-built during implementation, collapsing it into a closure the controller passes in is a fine simplification. And Task 7's hidden zero-size Esc button is a SwiftUI idiom, not a verified one — if `Esc` does not dismiss the panel in manual check 3, that button is the first place to look.
