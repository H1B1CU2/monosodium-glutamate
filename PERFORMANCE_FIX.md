# MSG — Performance & Energy Fix Plan

**Status:** specification, not yet implemented
**Baseline:** working tree at `5b32ba9` + uncommitted changes (2026-07-28)
**Audience:** implementing agent. A reviewer will diff your work against this document.

---

## 0. Ground rules — read before touching anything

These are non-negotiable. Violating any of them fails review regardless of measured wins.

1. **Do not run `./build.sh`, do not launch the app, do not copy to `/Applications`.** The
   repo owner builds via Xcode. Type-check only (see §7.1).
2. **New `.swift` files must be added to `MSG.xcodeproj/project.pbxproj`** or the Xcode build
   breaks. Prefer *not* creating new files; every fix below fits in an existing one except
   where explicitly noted (F3 introduces one shared type — see its note).
3. **Never replace the main-thread `Timer` + `CACurrentMediaTime()` progress pattern with
   `CVDisplayLink` / `CADisplayLink` / `DisplayLink`.** This is documented in `CLAUDE.md` and
   has been tried and reverted twice. Any diff containing `DisplayLink` is rejected outright.
4. **Animation timers keep `tolerance = 0` and keep their current intervals.** The 60 Hz pill
   animation, the 60 Hz corner grow-in, the 30 Hz visualizer, and the 30 Hz hardware bar
   easing are the fluidity budget. Only *sampling/polling* timers get tolerance.
5. **The MC/fullscreen snapshot rule from `CLAUDE.md` still holds**: state that feeds
   animation diffs (`previousSpaces`, `previousActiveDisplayIndex`) is mutated only when
   `systemState.isStable`. Nothing here changes that; do not let a refactor weaken it.
6. **No behaviour changes the user can see.** Every fix below is invisible at the UI layer.
   If you find yourself changing a duration, an easing curve, a colour, or a layout constant,
   you have gone outside scope — stop and flag it.
7. **One commit per fix ID**, message prefixed with the ID (e.g. `F1: gate music polling on
   consumers`). This is how the reviewer bisects.

### Line-number anchors

Line numbers below are accurate as of the baseline commit but **will drift as you edit**.
The durable anchors are the *function names* and *quoted code*. Always locate by symbol,
never by line number alone.

---

## 1. Why this exists — measured baseline

MSG installs **nine unconditional repeating timers** at launch. None of them sets
`.tolerance`, so every one forces a precise kernel wakeup that cannot be coalesced with any
other timer on the system.

On an otherwise idle Mac, with **default settings** (`cornersEnabled=true`,
`cornerGrowEnabled=true`, `musicEnabled=true`, `hardwareStatsEnabled=false`,
`systemHUDEnabled=false`, `mediaKeyPriorityMusic=false`):

| Source | Symbol | Rate | Work per tick |
|---|---|---|---|
| Now Playing poll | `MusicMonitor.poll` | 1 Hz | **forks `/usr/bin/perl`**, dyld-links it + `libMSGMediaRemote.dylib` + MediaRemote.framework, one synchronous read, base64 artwork, exit |
| Space-slide detection | `AppDelegate.pollSlideState` | 30 Hz | `CGSGetActiveSpace` + `CGSManagedDisplayIsAnimating` per display + **full `CGWindowListCopyWindowInfo` dump** |
| MC/fullscreen detection | `SystemState.refreshState` | 8.3 Hz | **second full window-list dump** + `AXIsProcessTrusted` + `AXUIElementCreateApplication` + 2× `AXUIElementCopyAttributeValue` |
| Hardware sensors | `HardwareMonitor.poll` | 0.5 Hz | **~112 SMC IOKit round trips** + `IOAccelerator` registry walk + full `AppleSmartBattery` property copy + `CFPreferencesAppSynchronize` |
| Presented-framerate | `HardwareMonitor.pollFPS` | 1 Hz | one SkyLight call (cheap) |
| Wallpaper drift check | `WallpaperEngine.checkForExternalChange` | 1 Hz | `NSWorkspace.desktopImageURL` IPC per screen |
| Screen arrangement | `AppDelegate.arrangementPollSource` | 2 Hz | `NSScreen.screens` frame diff |
| Tray tap health | `TrayPanel.startHealthTimer` | 0.2 Hz | `CGEvent.tapIsEnabled` (trivial) |
| Visualizer (only while music plays) | `Indicator.startVisualizer` | 30 Hz | full `makeMusicFrame` re-render |

Per hour, before the user touches anything:

- **~3,600** process spawns
- **~138,000** full on-screen window-list dumps (108k from slide detection + 30k from MC detection)
- **~60,000** Accessibility IPC round trips into whatever app is frontmost — **for a value nobody reads**
- **~201,600** SMC transactions — **with hardware stats disabled by default, so zero consumers**

The fixes are grouped into three tiers. **Tier 1 is where essentially all the energy is and
none of it changes a pixel.** Implement tiers in order; do not start Tier 2 until Tier 1 is
complete and type-checks.

---

# TIER 1 — high impact, no visual change

---

## F1 — Stop spawning a `perl` process every second

**Files:** `MSG/MusicMonitor.swift`, `MSG/AppDelegate.swift`
**Symbols:** `MusicMonitor.start()`, `MusicMonitor.poll()`, `MusicMonitor.stop()`
**Anchors:** `MusicMonitor.swift:194-242`; `AppDelegate.swift:69-71`
**Impact:** largest single energy cost in the app.

### Problem

`MediaRemoteAdapter.query` (`MediaRemoteAdapter.swift:62`) launches a fresh
`/usr/bin/perl` process on **every** poll — by design, per the comment at the top of that
file (a long-lived stream went stale; the one-shot process cannot). That design decision is
correct and **must be preserved**. What is wrong is the *cadence* and the *lack of gating*:

- `poll()` never checks `settings.musicEnabled`. With the music indicator switched off, MSG
  still spawns 86,400 perl processes a day for data nothing displays.
- The interval is a flat 1 Hz whether or not anything is playing. When nothing is playing
  there is no title to keep fresh, no marquee to scroll, and no track boundary to catch.

### Consumers of `MusicMonitor` (verified — this is the full set)

| Consumer | Needs live data when |
|---|---|
| `Indicator.refresh()` (`Indicator.swift:493`) | `settings.musicEnabled` **and** `settings.musicDisplayMode != .off` |
| `MusicPopover.pollTick()` (`MusicPopover.swift:96`) | popover is on screen (its own 0.3 Hz timer already starts/stops with `show`/`close`) |
| `TrayState` observer (`TrayState.swift:96`) | tray panel is visible (⌘⇥ held) |
| `SystemHUDMonitor` media-key routing (`AppDelegate.swift:332-337`) | `settings.mediaKeyPriorityMusic` — routes through `shouldRouteMediaKeysToAppleMusic`, which reads `musicAppState`, **not** the Now Playing snapshot |

Note the last row: media-key routing depends on `refreshAppleMusicState()` (AppleScript to
Music.app), **not** on the perl helper. The two are independent and must be gated separately.

### Required change

Add a demand-counted gate to `MusicMonitor`.

```swift
// MusicMonitor.swift

/// Non-zero while some consumer needs fresh Now Playing data. The popover and the
/// tray hold a token while visible; the indicator holds one while the music display
/// is switched on. At zero the poller idles completely.
private var demandTokens = 0

func retainPolling() {
    demandTokens += 1
    if demandTokens == 1 { restartPollTimer() }
}

func releasePolling() {
    demandTokens = max(0, demandTokens - 1)
    if demandTokens == 0 { restartPollTimer() }
}

/// True when the indicator itself wants music on the status item.
private var indicatorWantsMusic: Bool {
    settings.musicEnabled && settings.musicDisplayMode != .off
}

private var wantsNowPlaying: Bool { indicatorWantsMusic || demandTokens > 0 }
```

Rewrite the timer plumbing so there is **exactly one** place that owns the interval. Today
the interval is reassigned in four places (`start()`, `pollAppleMusic()` twice, and
`updateInterval`-style logic inline) — collapse them:

```swift
/// Poll cadence. 1 s while something is playing (track changes, marquee, linger
/// need it); 5 s when idle — nothing on screen depends on sub-5s latency for the
/// transition from "nothing playing" to "playing", and the first poll that sees
/// playback immediately snaps the timer back to 1 s.
private func desiredPollInterval() -> TimeInterval {
    guard wantsNowPlaying else { return 0 }              // 0 == no timer at all
    if settings.musicSource == .appleMusic && !isAppleMusicRunning { return 3.0 }
    return isPlaying ? 1.0 : 5.0
}

private func restartPollTimer() {
    let wanted = desiredPollInterval()
    if wanted == 0 {
        pollTimer?.invalidate(); pollTimer = nil
        return
    }
    if let t = pollTimer, abs(t.timeInterval - wanted) < 0.01 { return }   // already correct
    pollTimer?.invalidate()
    let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in self?.poll() }
    t.tolerance = wanted * 0.2                                             // see F5
    RunLoop.main.add(t, forMode: .common)
    pollTimer = t
}
```

Then:

- `start()` calls `restartPollTimer()` and, if `wantsNowPlaying`, one immediate `poll()`.
- **Every place that currently sets `isPlaying`** must call `restartPollTimer()` afterward so
  the 5 s → 1 s snap-back happens on the first tick that sees playback. There are five such
  sites: `applyAdapterState` (both branches), `pollNowPlaying`'s success branch,
  `pollNowPlayingMR` (both branches), and `pollAppleMusic`'s handler. Missing one produces a
  5 s lag before the music indicator appears — that is the main regression risk of this fix.
- `poll()` gains an early `guard wantsNowPlaying` **after** the `mediaKeyPriorityMusic` block
  (that block must keep running independently — see F1b).
- Delete the two inline `pollTimer` reassignments inside `pollAppleMusic()`
  (`MusicMonitor.swift:399-413`); route them through `restartPollTimer()` and an
  `isAppleMusicRunning` cached flag instead.
- `AppSettings.onChange` must poke it: in `AppDelegate.settings.onChange`, the `.indicator`
  and `.structural` cases both call `musicMonitor.restartPollTimer()` (expose it as
  `func settingsChanged()`).

Wire the two token holders:

- `MusicPopover.show(relativeTo:)` → `monitor.retainPolling()`; `MusicPopover.close()` →
  `monitor.releasePolling()`. Guard against double-release if `close()` can be called twice
  (it can — `closeMonitor` and `buttonClicked` both call it): track a `didRetain` bool.
- `TrayPanel.show(goBack:)` / `TrayPanel.hide(activate:)` → same pair via
  `state.musicMonitor`.

### F1b — same file, do not skip

`refreshAppleMusicState()` (`MusicMonitor.swift:672`) compiles **and** executes a brand-new
`NSAppleScript` every second whenever `mediaKeyPriorityMusic` is on and Music.app is running.
Two cheap fixes, both required:

1. Hoist the script to a lazily-created stored property so it compiles once:
   ```swift
   private lazy var musicStateScript = NSAppleScript(source: """
   tell application "Music"
       ...unchanged...
   end tell
   """)
   ```
   `NSAppleScript` is not thread-safe; it is already confined to
   `MusicMonitor.scriptQueue`, so keep every use on that queue and do not read the property
   from main. Simplest safe form: make it a `static let` protected by the same serial queue,
   or build it once inside the first `scriptQueue.async` and cache it in a queue-local.
2. Drive it from a **separate 2 s timer** that only exists while
   `settings.mediaKeyPriorityMusic` is true, instead of piggybacking on `poll()`. The routing
   decision only matters at key-press time, and `handleRoutedMediaKey` (`:651`) already flips
   the cached state optimistically, so 2 s staleness is invisible.

### Acceptance criteria

- With `musicEnabled = false` and the popover/tray closed: **zero** perl spawns.
  Verify with `sudo fs_usage -w -f exec | grep perl` for 60 s, or
  `sudo execsnoop 2>/dev/null | grep perl` — expect no lines.
- With `musicEnabled = true` and nothing playing: one spawn per ~5 s.
- With music playing: one spawn per ~1 s (unchanged from today).
- Starting playback while idle-polling shows the music indicator within ≤ 5 s and the poll
  rate snaps to 1 Hz on that same tick.
- Opening the music popover with `musicEnabled = false` still shows live title/artist.
- Holding ⌘⇥ with `musicEnabled = false` still shows the tray's Now Playing card.

### Risk

**Medium.** The failure mode is a stale or missing music indicator, which is user-visible.
The `restartPollTimer()`-on-every-`isPlaying`-write rule is the whole ballgame — audit it.

---

## F2 — Delete the dead fullscreen Accessibility poll

**File:** `MSG/SystemState.swift`
**Symbols:** `SystemState.refreshState()`, `SystemState.detectFullscreen()`, `SystemState.isFullscreen`
**Anchors:** `SystemState.swift:17`, `:51`, `:75-78`, `:96-107`; `Indicator.swift:416`
**Impact:** removes ~60,000 Accessibility IPC round trips per hour.

### Problem

Every 120 ms, on a `.userInteractive` queue, `refreshState()` calls `detectFullscreen()`,
which does:

```swift
if !NSMenu.menuBarVisible() { return true }
guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return false }
let appRef = AXUIElementCreateApplication(app.processIdentifier)   // fresh element every call
AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute, &winRef)   // IPC into that app
AXUIElementCopyAttributeValue(win, "AXFullScreen", &fsRef)                  // IPC into that app
```

Two synchronous Accessibility round trips into whatever app is frontmost, 8.3 times a
second, forever. If the target app is busy, these block the detection queue.

**The result is never read.** `isFullscreen` is surfaced exactly once, at
`Indicator.swift:416` (`var isFullscreen: Bool { systemState.isFullscreen }`), and grep
across the whole target finds no consumer of `indicator.isFullscreen`. The only other hit is
a stale comment at `CornerWindow.swift:38`.

### Required change

1. Delete the `let fs = Self.detectFullscreen()` call from `refreshState()` and the
   `if fs != isFullscreen { ... }` block from `applyDetectedState`. Change
   `applyDetectedState(mc:fs:)` to `applyDetectedState(mc:)`.
2. **Keep** `static func detectFullscreen()` — it is a correct, useful helper and cheap when
   not called in a loop. Add a doc comment noting it is now on-demand only.
3. Keep the `isFullscreen` stored property, but drive it from notifications rather than
   polling, so the API stays available without the cost:
   ```swift
   // In start(), alongside the poll timer:
   fsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
       forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
   ) { [weak self] _ in self?.refreshFullscreen() })
   fsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
       forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
   ) { [weak self] _ in self?.refreshFullscreen() })
   ```
   where `refreshFullscreen()` hops to `detectionQueue`, calls `detectFullscreen()`, and
   applies the result on main. Remove the observers in `stop()`.
4. Update the stale comment at `CornerWindow.swift:38` — it claims AppDelegate drives corner
   state from "reliable `isMissionControl` / `isFullscreen` state", but
   `applyCornerWindowTopState()` (`AppDelegate.swift:590`) only reads `isMissionControl`.

### Acceptance criteria

- No `AXUIElementCopyAttributeValue` call remains on any repeating-timer path. Verify:
  `grep -n "AXUIElementCopyAttributeValue" MSG/SystemState.swift` shows hits only inside
  `detectFullscreen`, and `grep -n "detectFullscreen" MSG/` shows no call from
  `refreshState`.
- Mission Control detection is unaffected (F2 must not touch `MissionControlDetector`).
- Entering a fullscreen app then activating another app updates `isFullscreen` within one
  notification hop.

### Risk

**Low.** The removed value has no consumer. Keep the notification path so nothing regresses
if a consumer is added later.

---

## F3 — One window-list scan instead of two, gated on user input

**Files:** `MSG/AppDelegate.swift`, `MSG/MissionControlDetector.swift`, `MSG/SystemState.swift`
**Symbols:** `AppDelegate.menuBarWindowCount()`, `AppDelegate.pollSlideState()`,
`MissionControlDetector.isActive()`, `SystemState.refreshState()`
**Anchors:** `AppDelegate.swift:463-470`, `:505-584`; `MissionControlDetector.swift:27-48`;
`SystemState.swift:48-56`
**Impact:** removes ~138,000 full window-list dumps per hour → near zero when the user is away.

### Problem

`CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` is an IPC to WindowServer
that materialises a `CFArray` of `CFDictionary` — one dictionary, fully populated, for *every
on-screen window on the system*. On a busy desktop that is 100–200 dictionaries.

MSG does this **twice, independently**:

- `AppDelegate.menuBarWindowCount()` at 30 Hz (counts `Window Server` windows at layer 24)
- `MissionControlDetector.isActive()` at 8.3 Hz (looks for `WindowManager` windows at small
  positive layers)

Both filter the same array for different predicates. Neither needs anything the other
doesn't already have.

### Required change — part A: merge the scanners

Introduce a single shared scanner. **This is the one place a new file is acceptable** — put
it in `MSG/WindowListScanner.swift` and **add it to `MSG.xcodeproj/project.pbxproj`**
(alongside the existing `MissionControlDetector.swift` entry in both `PBXBuildFile` and
`PBXSourcesBuildPhase`). Alternatively append it to `MissionControlDetector.swift` to avoid
the pbxproj edit entirely — **prefer this** unless the file becomes unwieldy.

```swift
/// One on-screen window-list pass, yielding every signal MSG derives from it.
/// Both consumers (Mission Control detection and menu-bar-pair slide detection)
/// used to run their own full `CGWindowListCopyWindowInfo` dump; this collapses
/// them into a single WindowServer round trip.
struct WindowListSignals {
    /// Mission Control / App Exposé is on screen.
    let missionControlActive: Bool
    /// Onscreen Window Server menu bar windows (layer 24). ≥2 means a space
    /// slide is in flight — see the doc on `menuBarWindowCount` for why.
    let menuBarWindowCount: Int
}

enum WindowListScanner {
    static func scan() -> WindowListSignals {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return WindowListSignals(missionControlActive: false, menuBarWindowCount: 1)
        }
        var mc = false
        var menuBars = 0
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if owner == "Window Server", layer == 24 { menuBars += 1; continue }
            guard !mc, owner == "WindowManager", layer > 0, layer < 1000 else { continue }
            // Name check preserved verbatim from MissionControlDetector — see the
            // rationale comment there about Screen Recording permission and Stage Manager.
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                if MissionControlDetector.overlayNames.contains(name) { mc = true }
            } else {
                mc = true
            }
        }
        return WindowListSignals(missionControlActive: mc,
                                 menuBarWindowCount: max(1, menuBars))
    }
}
```

**Preserve `MissionControlDetector.isActive()` as a public entry point** — `WallpaperEngine`
calls it directly at `WallpaperEngine.swift:423` on the space-change path and must keep
working. Reimplement it as `WindowListScanner.scan().missionControlActive`, and promote
`overlayNames` from `private` to `internal`.

Rewire the two pollers. **Read this whole subsection before writing code — the naive wiring
breaks Mission Control detection in two separate ways.**

#### The two traps

**Trap 1 — the slide timer does not always exist.** `applySlideDetection()`
(`AppDelegate.swift:491-503`) only installs `slidePollTimer` when
`settings.cornersEnabled && settings.cornerGrowEnabled`. If the user turns off either one,
that timer is invalidated. So you **cannot** hang MC detection off `pollSlideState` — with
corners disabled, MC detection would die completely, and MC detection is load-bearing for
things unrelated to corners:

| Consumer of MC state | Why it matters |
|---|---|
| `SystemState.isStable` → `Indicator.refresh()` (`Indicator.swift:581`, `:628-631`) | **The entire reason `SystemState` exists.** Gates snapshot mutation so MC exit from a fullscreen app doesn't fire a false pill animation (`CLAUDE.md`, "The MC/Fullscreen Animation Bug") |
| `SpaceWatcher.isInMissionControl` (`SpaceWatcher.swift:82,86,90`) | Suppresses CGS chase-reads that would contend with WindowServer mid-animation |
| `WallpaperEngine.isMissionControlActive` (`WallpaperEngine.swift:86`, `:118`) | Suppresses `setDesktopImageURL` during the MC animation |
| `AppDelegate.applyCornerWindowTopState()` (`:590`) | Corner top-hiding |

Only the last one is corner-related. Killing MC detection when corners are off would
reintroduce the exact animation bug this codebase was rewritten to prevent.

**Trap 2 — `pollSlideState` early-returns during MC.** At `AppDelegate.swift:528`, when
`indicator.isMissionControl` is true, the function returns *before* reaching the scan
dispatch at `:573`. If MC state came from that same scan, the first tick that detects MC
would stop scanning, and MC exit would never be observed — MSG would believe Mission Control
is open forever.

#### Required wiring

Give the scanner its **own timer, owned by `SystemState`**, independent of the corner
settings. `SystemState` keeps its timer but stops doing its own `CGWindowListCopyWindowInfo`
— it now runs the shared scan and publishes both signals:

```swift
// SystemState.swift — replaces the current refreshState()

/// Published on every scan so the slide detector can consume the menu-bar-pair
/// count without paying for a second window-list dump.
var onMenuBarWindowCount: ((Int) -> Void)?

private func refreshState() {
    guard !scanInFlight else { return }          // one at a time, like the old slide scan
    scanInFlight = true
    detectionQueue.async { [weak self] in
        let signals = WindowListScanner.scan()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanInFlight = false
            self.applyDetectedState(mc: signals.missionControlActive)   // FIRST
            self.onMenuBarWindowCount?(signals.menuBarWindowCount)      // THEN
        }
    }
}
```

The MC-before-pair ordering is required: `applyMenuBarPair` reads `indicator.isMissionControl`
at `AppDelegate.swift:478` to suppress the pair path during MC. Publishing the pair first
evaluates it against the previous tick's MC state.

**Scan rate.** `SystemState` currently polls at 0.12 s (8.3 Hz); slide detection needs 30 Hz.
Make the rate demand-driven:

```swift
/// 30 Hz while the slide detector is listening (the menu-bar-pair signal is the
/// only slide-start tell for fullscreen-space switches and needs to be caught
/// within a frame or two); 0.12 s otherwise, which is all Mission Control
/// detection has ever needed.
private var scanInterval: TimeInterval { onMenuBarWindowCount == nil ? 0.12 : 1.0 / 30.0 }
```

`AppDelegate.applySlideDetection()` sets or clears `indicator.systemState.onMenuBarWindowCount`
instead of creating/destroying `slidePollTimer`, and calls a `SystemState.rescheduleScan()`.
Keep `slidePollTimer` **only** for the cheap CGS scalar work (`activeSpaceID`,
`isDisplayAnimating`) if you want it at 30 Hz — or fold that into the same callback and delete
the timer entirely. Folding it in is cleaner; either is acceptable.

**`pollSlideState` loses its scan block.** Delete `AppDelegate.swift:573-583` (the
`slideScanInFlight` / `slideScanQueue` / `menuBarWindowCount` dispatch) along with
`slideScanInFlight`, `slideScanStartedAt`, `menuBarWindowCount()`, and the 2 s watchdog at
`:519-522` — the in-flight guard now lives in `SystemState`. What remains of
`pollSlideState` (the MC early-return, the active-flip detection, the per-display
`isDisplayAnimating` loop) is driven from the scan callback instead, and the MC early-return
is now harmless because it no longer gates the scan.

**Rate note:** MC detection moves from 8.3 Hz to 30 Hz whenever slide detection is on, which
makes it *more* responsive, not less. When slide detection is off it stays at 8.3 Hz exactly
as today.

### Required change — part B: gate on user input

A space slide is always user-initiated (⌃→, trackpad swipe, clicking in Mission Control,
clicking a Dock icon for an app on another space, ⌘⇥). So when the user has not generated an
input event recently, no slide can begin and the scan is pure waste.

In `SystemState.refreshState()`, before dispatching the scan:

```swift
/// `kCGAnyInputEventType`. Not exposed as a Swift constant; 0xFFFFFFFF is the
/// documented value and has been stable since 10.4.
private static let anyInputEvent = CGEventType(rawValue: UInt32.max)!

// A space slide is always user-initiated (⌃→, swipe, a Mission Control click, a
// Dock click for an app on another space, ⌘⇥). With no input for a few seconds
// no slide can start, so skip the WindowServer round trip entirely — this is what
// takes an unattended-but-awake Mac to zero window-list dumps. The cheap CGS
// scalar reads still run, and activeSpaceDidChangeNotification still lands the
// corners, so the worst case for a missed slide is a lost grow-in animation, not
// a stuck state.
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                   eventType: Self.anyInputEvent)
let userActive = idle < 3.0
```

Then:

- `guard userActive || isMissionControl || slideInProgress else { return }` before the scan
  dispatch, where `slideInProgress` is fed from `AppDelegate.menuBarPairActive`. The extra
  disjuncts guarantee that a slide or an MC session already in flight is always followed to
  completion even if the user stops moving — **without them, entering Mission Control and
  then sitting still for 3 s would strand `isMissionControl` at `true` forever.** This is
  the same class of bug as Trap 2 above; do not omit them.
- **Do not** gate the CGS scalar reads (`activeSpaceID`, `isDisplayAnimating`) — they are
  cheap, and they are the fallback path that still lands the corners if a scan is skipped.

### Acceptance criteria

- Exactly one call site remains: `grep -rn "CGWindowListCopyWindowInfo" MSG/*.swift` returns
  a single hit, inside `WindowListScanner.scan()`.
- `MissionControlDetector.isActive()` still exists and still works — `WallpaperEngine.swift:423`
  calls it on the space-change path.
- **Enter Mission Control, sit completely still for 10 s, then exit** → corners grow in and MC
  state returns to false. This is the regression test for both Trap 2 and the idle-gate
  disjuncts. If MSG gets stuck thinking MC is open, you missed one of them.
- **Turn off `cornersEnabled`, then enter and exit Mission Control** → no false pill
  animation on the indicator. This is the regression test for Trap 1: it proves MC detection
  survives the slide detector being switched off.
- Leave the Mac untouched for 30 s with the screen on → the scan stops. Prove it with a
  temporary `NSLog` in `WindowListScanner.scan()`, then **remove the NSLog before committing**.
- Switch spaces with ⌃→ immediately after 30 s of no input → corners still hide and grow in.
  (The keypress resets the idle timer before the next 33 ms tick.)
- Switch spaces via a trackpad swipe after idle → same.
- Switch to and from a **fullscreen app's** space → corners hide and grow. This is the path
  that depends on the menu-bar-pair signal specifically; `CGSManagedDisplayIsAnimating` never
  fires for it (`SpaceWatcher.swift:136-137`).

### Risk

**High — the highest in this document.** This touches the space-slide grow-in, which
`CLAUDE.md` and the memory notes flag as hard-won. Two specific traps: (a) the early-return
ordering, (b) forgetting that `pollSlideState` is also what keeps MC detection alive. Test
both paths by hand before declaring done.

---

## F4 — Stop polling hardware nobody is watching, and stop retrying dead SMC keys

**Files:** `MSG/AppDelegate.swift`, `MSG/HardwareMonitor.swift`
**Symbols:** `HardwareMonitor.start()/stop()/poll()`, `readTemps()`, `averageTemp()`,
`SMCController.read()`, `readChargeLimitPercent()`
**Anchors:** `AppDelegate.swift:73-74`, `:249-301`; `HardwareMonitor.swift:186-282`,
`:448-476`, `:504-512`, `:1514-1539`
**Impact:** removes ~201,600 SMC transactions per hour at default settings.

### Problem 1 — it runs with zero consumers

`hardwareStatsEnabled` defaults to **`false`** (`Settings.swift:370`), but
`AppDelegate.applicationDidFinishLaunching` calls `hardwareMonitor.start()` unconditionally
(`AppDelegate.swift:74`). The only consumers are `HardwareStatusItem`, `BatteryStatusItem`,
and the settings pane's stats card (`SettingsPanes.swift:869`). So out of the box, every 2 s,
MSG reads every sensor on the machine and hands the result to nobody.

### Problem 2 — ~112 SMC round trips per poll, most of them guaranteed misses

`readTemps()` calls `averageTemp` over `cpuSensorKeys` (26 keys) and `gpuSensorKeys`
(30 keys). Each `SMCController.read` is **two** `IOConnectCallStructMethod` syscalls
(`HardwareMonitor.swift:1519-1531`): one `cmdReadKeyInfo`, one `cmdReadBytes`.
26 + 30 = 56 keys × 2 = **112 kernel round trips per poll**.

The key lists are a deliberate union across M1/M2/M3/M4/Intel, so on any *given* Mac the
large majority are absent — and an absent key still costs a full `cmdReadKeyInfo` round trip
before it can fail. The code already discovers exactly which keys are live, for a one-time
`NSLog` at `HardwareMonitor.swift:451-461`, and then throws that knowledge away.

### Problem 3 — a forced preferences disk read every poll

`readPower()` (`:515`) calls `readChargeLimitPercent()` (`:504`) on every poll, which calls
`CFPreferencesAppSynchronize` — a forced re-read from disk through `cfprefsd`. The value it
fetches is a slider in System Settings that changes maybe twice a year.

### Problem 4 — all of it on the main thread

`start()` adds the timer to `RunLoop.current` (main) at `:201`. `poll()` therefore performs
112 SMC syscalls, an `IOAccelerator` registry walk, a full `AppleSmartBattery` property
dictionary copy, and a cfprefsd round trip **on the main thread**, which is the same thread
running the 60 Hz pill animation.

### Required change

**4a — gate on demand.** Move `hardwareMonitor.start()` out of
`applicationDidFinishLaunching` and into `applyHardwareStats()` (`AppDelegate.swift:249`):

```swift
private func applyHardwareStats() {
    let s = settings
    if s.hardwareStatsEnabled {
        hardwareMonitor.start()          // idempotent — start() already guards
        ...existing body...
    } else {
        hardwareMonitor.stop()
        ...existing teardown...
    }
}
```

`start()` must become idempotent (`guard timer == nil else { return }`) since
`applyHardwareStats()` is called on every `.structural` settings change.

The settings pane also reads stats (`SettingsPanes.swift:869-872` polls
`HardwareMonitor.shared.stats` on a 2 s timer). Give `HardwareMonitor` the same
`retainPolling()` / `releasePolling()` token pair as F1, and have that pane's
`.onAppear` / `.onDisappear` hold a token. Do **not** let the pane leave the monitor running
after it closes.

**4b — cache the live sensor key set.** Replace the discovery logic:

```swift
/// Sensor keys that returned a plausible reading on the first probe. The key
/// lists are a union across M1/M2/M3/M4/Intel, so on any given Mac most are
/// absent — and an absent key still costs a full `cmdReadKeyInfo` round trip
/// before it can fail. Probe once, then only read what exists.
private var liveCPUSensorKeys: [UInt32]?
private var liveGPUSensorKeys: [UInt32]?

private func readTemps() {
    if liveCPUSensorKeys == nil {
        liveCPUSensorKeys = Self.cpuSensorKeys.filter { k in
            if let v = SMCController.read(k), v > 0, v < 130 { return true }
            return false
        }
        liveGPUSensorKeys = Self.gpuSensorKeys.filter { k in
            if let v = SMCController.read(k), v > 0, v < 130 { return true }
            return false
        }
        logDiscoveredSensors()          // folds in the existing one-time NSLog
    }
    stats.cpuTemp = averageTemp(liveCPUSensorKeys ?? [])
    stats.gpuTemp = averageTemp(liveGPUSensorKeys ?? [])
}
```

Keep the existing `NSLog("[HW] Valid temp sensors: ...")` output — it is useful — but fold it
into `logDiscoveredSensors()` so the probe happens once instead of the current
probe-plus-separate-log-pass.

Do **not** cache negatively forever without an escape hatch: if both live lists come back
empty, re-probe at most once every 60 s (a sensor can appear after a sleep/wake cycle on some
machines). Track `lastSensorProbeAt`.

**4c — cache `SMCController` key metadata.** In `SMCController`, memoise the
`cmdReadKeyInfo` result per key:

```swift
private static var keyInfoCache: [UInt32: (type: UInt32, size: UInt32)] = [:]
```

`read(_:)` consults the cache and skips call #1 on a hit. Key metadata (data type + size) is
immutable for the life of the connection. **Invalidate the cache in `close()`.** This halves
whatever survives 4b.

Note `SMCController` is accessed from `HardwareMonitor`'s timer and from the fan-control
paths. If any of those run off-main, guard the cache with a lock or confine it — check
`fanQuitCleanup` / `applySelectedFanPresetFromUser` before assuming single-threaded access.

**4d — throttle the charge-limit read.** In `readPower()`:

```swift
// The charge limit is a System Settings slider. CFPreferencesAppSynchronize
// forces a disk re-read through cfprefsd; doing that every poll is absurd for
// a value that changes twice a year.
if now - lastChargeLimitReadAt > 30 {
    lastChargeLimitReadAt = now
    cachedChargeLimit = Self.readChargeLimitPercent()
}
stats.chargeLimitPercent = cachedChargeLimit
```

**4e — move sampling off the main thread.** Change `poll()` to sample on a utility queue and
publish on main:

```swift
private let sampleQueue = DispatchQueue(label: "msg.hw.sample", qos: .utility)

private func poll() {
    sampleQueue.async { [weak self] in
        guard let self else { return }
        let sampled = self.sampleAll()          // pure reads, no `stats` mutation
        DispatchQueue.main.async {
            self.stats = sampled
            self.applyFanCurve()
            self.updateBatteryPollingState()
            self.notify()
        }
    }
}
```

`sampleAll()` returns a fresh `HardwareStats` rather than mutating `self.stats` field by
field, so `stats` is only ever written on main and observers never see a torn value.
`applyFanCurve()` and `updateBatteryPollingState()` stay on main — they touch timers and the
fan helper.

**Keep this change last** within F4, and verify the fan-control paths (which do blocking
`Thread.sleep` at `HardwareMonitor.swift:974` and `:1318`) are not newly re-entered from two
threads. If that audit looks risky, ship 4a–4d and leave 4e as a separate follow-up commit
rather than rushing it.

### Acceptance criteria

- With `hardwareStatsEnabled = false`: no SMC traffic. Verify by adding a temporary counter
  in `SMCController.read` logged every 10 s; expect zero. Remove before committing.
- With `hardwareStatsEnabled = true`: the menu-bar stats read the same values as before
  (compare CPU / GPU / temp / fan / power against the pre-change build side by side).
- Temperature values are unchanged after the key-set cache lands — this is the correctness
  test that matters most for 4b.
- Opening then closing the hardware settings pane leaves the monitor stopped when
  `hardwareStatsEnabled = false`.
- The 0.35 s bar easing in `HardwareStatusItem` still runs at 30 Hz and looks identical.

### Risk

**Medium.** 4a and 4d are trivial. 4b risks losing a sensor that only becomes readable later
(mitigated by the 60 s re-probe). 4c risks a stale metadata entry across an SMC reconnect
(mitigated by invalidating in `close()`). 4e is the one that can bite — treat it as optional.

---

## F5 — Give every sampling timer a tolerance

**Files:** all files listed below
**Impact:** lets the kernel coalesce wakeups; zero UX cost.

### Problem

`grep -rn "\.tolerance" MSG/*.swift` returns **nothing**. Every repeating `Timer` in the app
has the default tolerance of 0, which tells the kernel "wake me at exactly this instant, do
not batch me with anything else". For a 60 Hz animation that is correct. For a 5-second
health check it is wasteful — it denies macOS the timer coalescing that exists specifically
to let idle laptops stay in low-power states.

### Required change

Set `tolerance` on **sampling** timers only:

| Symbol | Anchor | Interval | Set tolerance to |
|---|---|---|---|
| `HardwareMonitor.timer` | `HardwareMonitor.swift:198`, `:235` | 2–10 s | `interval * 0.15` |
| `HardwareMonitor.fpsTimer` | `:202` | 1 s | `0.15` |
| `HardwareMonitor.batteryTimer` | `:265` | 1 s | `0.15` |
| `MusicMonitor.pollTimer` | `MusicMonitor.swift:195` (F1's `restartPollTimer`) | 1–5 s | `interval * 0.2` |
| `WallpaperEngine.pollTimer` | `WallpaperEngine.swift:448` | 1 s → 5 s (see F7) | `interval * 0.2` |
| `AppDelegate.arrangementPollSource` | `AppDelegate.swift:637-638` | 0.5 s | `DispatchSource`: add `leeway: .milliseconds(100)` to `schedule(...)` |
| `TrayPanel.healthTimer` | `TrayPanel.swift:118` | 5 s | `1.0` |
| `SettingsPanes` stats timer | `SettingsPanes.swift:870` | 2 s | `0.3` |
| `MusicPopover.pollTimer` | `MusicPopover.swift:77` | 0.3 s | `0.05` |

**Do NOT set tolerance on** (these must stay at 0):

- `Indicator.runProgressTimer` and everything built on it (`Indicator.swift:699-715`)
- `Indicator.startPillAnimation`'s 60 Hz timer (`:767`)
- `Indicator.visualizerTimer` (`:239`) — 30 Hz, drives the marquee
- `Indicator.startReverseMorph` (`:306`)
- `CornerWindow.startGrowIn` (`CornerWindow.swift:93`)
- `HardwareStatusItem` bar easing and window-height animations (`:203`, `:1541`, `:1738`, `:2408`)
- `SystemHUDStatusItem` fill timer (`SystemHUDStatusItem.swift:69`)
- `TrayHUDView` timer (`TrayHUDView.swift:410`)
- `AppDelegate.slidePollTimer` (`:494`) — 30 Hz slide detection is latency-critical
- Any one-shot `repeats: false` timer

Add a short comment at each site you touch so the next reader knows tolerance was a
deliberate choice, e.g. `t.tolerance = wanted * 0.2   // sampling, not animation — let the kernel coalesce`.

### Acceptance criteria

- `grep -rn "\.tolerance" MSG/*.swift` lists exactly the sampling timers above and no others.
- No animation timer gained a tolerance. Reviewer will check this list line by line.

### Risk

**Very low.**

---

# TIER 2 — moderate wins

---

## F6 — Remove the temporary debug logging from the shipping path

**File:** `MSG/AppDelegate.swift`
**Symbol:** `AppDelegate.slideLog(_:)`
**Anchor:** `AppDelegate.swift:440-456`, plus 9 call sites

### Problem

The function is labelled *"Temporary diagnostics for the 'stops working after a while'
report"*. It does, on the **main thread**, per call: a `FileManager.attributesOfItem` stat,
then open / seek-to-end / write / close on `/tmp/msg_slide_debug.log`. It fires on every
slide begin, end, skip, and suppression, plus a 30 s heartbeat that runs forever, and it
maintains a rotating 512 KB file on disk.

### Required change

Gate it behind a compile-time or defaults flag rather than deleting it outright — the
diagnostics were added for a real bug and may be wanted again:

```swift
/// Slide-path diagnostics. Off unless `defaults write <bundleid> MSGSlideDebug -bool YES`.
/// Kept (rather than deleted) because this instrumentation is what diagnosed the
/// "stops working after a while" report; it just must not run for normal users.
private static let slideDebugEnabled =
    UserDefaults.standard.bool(forKey: "MSGSlideDebug")

private func slideLog(_ s: @autoclosure () -> String) {
    guard Self.slideDebugEnabled else { return }
    ...existing body, using s()...
}
```

The `@autoclosure` matters: several call sites build interpolated strings with
`\(indicator.isMissionControl)` etc., and those interpolations should not run when logging is
off. Update all call sites to compile against the autoclosure form (most will need no textual
change).

Also delete the now-pointless `slideTicks`/`slideHeartbeatAt` bookkeeping at
`AppDelegate.swift:510-515` if it is only used by the heartbeat log — or keep it inside the
same guard.

### Acceptance criteria

- Fresh launch with no defaults key set: `/tmp/msg_slide_debug.log` is never created.
- `defaults write <bundleid> MSGSlideDebug -bool YES` then relaunch: logging works as before.

### Risk

**Low.**

---

## F7 — Slow and gate the wallpaper drift poll

**File:** `MSG/WallpaperEngine.swift`
**Symbols:** `beginPolling()`, `checkForExternalChange()`
**Anchor:** `WallpaperEngine.swift:447-481`

### Problem

`start()` is called unconditionally from `AppDelegate.swift:83` and installs a 1 Hz timer.
Each tick calls `Self.wallpaperURL(for:)` (`:551`) per screen — an
`NSWorkspace.desktopImageURL` IPC each — purely to notice that the user changed their
wallpaper in System Settings. A wallpaper change is not a sub-second event.

### Required change

1. Raise the interval to **5 s** and add `tolerance = 1.0` (per F5).
2. Early-out when there is nothing to protect:
   ```swift
   private func checkForExternalChange() {
       guard !isMissionControlActive else { return }
       // Nothing baked on any display → no baseline to defend, nothing to detect.
       guard !screens.isEmpty else { return }
       ...existing body...
   }
   ```
3. Add an immediate check on `NSWorkspace.activeSpaceDidChangeNotification` (the observer
   already exists at `:110`) so the latency the slower timer costs is recovered where it
   actually matters.

Do **not** change `sync()`, `bake()`, `reapplyToAllSpaces()`, or the `restore()` path — those
are correctness-critical and out of scope.

### Acceptance criteria

- Changing the wallpaper in System Settings while MSG runs is still detected and adopted
  (within ~5 s, or immediately on the next space change).
- The Cornermizer pane's external-change confirmation card still appears.

### Risk

**Low.**

---

## F8 — Stop repainting a full-screen surface at 60 fps to draw four corner wedges

**File:** `MSG/CornerWindow.swift`
**Symbols:** `CornerWindow.startGrowIn()`, `CornerView.draw(_:)`
**Anchor:** `CornerWindow.swift:90-103`, `:139-182`

### Problem

`CornerWindow` is a borderless window covering the entire screen frame. `CornerView` fills
that whole bounds, but `draw(_:)` only ever paints four wedges of radius `r` (typically
10–30 pt) at the corners.

`startGrowIn()` calls `self.view.display()` every frame for 0.25 s at 60 Hz. `display()`
invalidates and redraws the **entire** view, so WindowServer recomposites a full-screen
surface — on a 3456×2234 Retina display that is a ~30 MB backing store — 15 times, to change
about 4,000 pixels. This fires on every space switch and every Mission Control exit, i.e.
dozens of times an hour during normal use, and it is exactly the moment when the pill
animation is also running.

`spaceSlideBegan()` (`:70`) and `redraw()` (`:52`) have the same problem.

### Required change

Restructure `CornerView` into a container with **four small corner subviews**, each sized
`(maxRadius + 1) × (maxRadius + 1)` and positioned at its corner. Each subview draws only its
own wedge. Then `display()` touches four tiny surfaces instead of one enormous one.

Constraints you must preserve exactly:

- **The hidden→shown transition detection** at `:162-170` currently lives inside `draw()` and
  relies on `draw` being called. It sets `topGrowProgress = 0` and fires `onTopGrowInNeeded`
  exactly once per transition via `wasTopShown`. Move this to the container so it still fires
  **once**, not four times — a per-subview copy would arm the grow-in four times per
  transition.
- **The `underBar` top-Y offset** (`:153`): `topY = screen.frame.maxY - screen.visibleFrame.maxY`
  when the top corners sit under the menu bar. The two top subviews must be positioned with
  this offset applied, and it must be recomputed in `updateFrame()`.
- **`skipTop`** (`:154`) combines `skipTopCorners` with `!NSMenu.menuBarVisible()`. The menu-bar
  visibility half is evaluated at draw time and must stay that way — it is re-evaluated on
  space/fullscreen transitions via `redrawCornerWindows()`.
- Per-screen settings lookups (`extCornerRadius(for:)` etc.) resolve identically.
- The window keeps `ignoresMouseEvents`, its level, and its `collectionBehavior` unchanged.

If a faithful restructure looks like it will take more than a contained change, **do 8a only
and stop**:

**8a (minimum viable, do this first):** in `startGrowIn`, replace `self.view.display()` with
targeted invalidation of just the corner regions, and set `view.wantsLayer = true` plus
`layerContentsRedrawPolicy = .onSetNeedsDisplay` so AppKit is not re-rasterising the full
surface every frame. Note that AppKit coalesces multiple dirty rects into their **union**
before calling `draw(_:)` — and the union of four corners is the whole screen — so this alone
does not fix it. That is precisely why the subview split is the real answer; 8a is a partial
mitigation, not a substitute.

### Acceptance criteria

- Corner grow-in on Mission Control exit looks identical (same 0.25 s, same `outQuart` ramp).
- Corner grow-in on space switch (both desktop↔desktop and to/from fullscreen spaces) looks
  identical.
- `cornerGrowEnabled = false` still snaps corners straight to full size with no animation.
- Corners under the menu bar sit at the same Y as before on both built-in and external
  displays.
- Toggling `topCornersUnderMenuBar` repositions correctly.
- Multi-display: each screen's corners use that screen's own radius settings.

### Risk

**Medium-high.** This is the most invasive change in the document and it touches a feature
with a documented history of subtle breakage (see the `project_corner_grow_animation` and
`project_space_switch_grow` notes). **Ship it as its own commit, last.** If anything looks
off, revert F8 alone rather than unwinding the tier.

---

# TIER 3 — render micro-optimisations

These do not change a single rendered pixel. They reduce the cost of producing the same
pixels. Verify by diffing screenshots if in doubt.

---

## F9 — Stop running 120 CoreText layouts per second while music plays

**File:** `MSG/IndicatorRenderer.swift`
**Symbols:** `makeMusicFrame(...)`, `musicAttributedString(...)`, `musicMarqueeActive(...)`
**Anchor:** `IndicatorRenderer.swift:513-529`, `:531-614`

### Problem

`Indicator.startVisualizer` runs at 30 Hz and calls `refresh()` → `makeMusicFrame` on every
tick while music plays. Inside one call, `attr.size()` is invoked **four times**:

- `:546` — `let fullTextW = attr.size().width`
- `:577` — `let textY = (imgH - attr.size().height) / 2`
- `:578` — `attr.draw(in: NSRect(..., height: attr.size().height))`
- `:582` — the marquee's second copy, again

`NSAttributedString.size()` runs a full CoreText typesetting pass. That is **120 layout
passes per second**. On top of that, `musicAttributedString` allocates two `NSFont`s, three
`NSAttributedString`s and one `NSMutableAttributedString` per frame.

During steady playback none of the inputs change — only `marqueeOffset` and `barHeights` do.

### Required change

**9a — hoist the repeated `size()` calls.** Compute once before the draw closure:

```swift
let textSize = attr.size()
let fullTextW = textSize.width
let textH = textSize.height
```

and capture `textH` in the closure. This alone takes 4 layouts/frame → 1.

**9b — cache the attributed string.** Key it on everything that affects it:

```swift
/// `makeMusicFrame` runs at 30 Hz while music plays, and building the line plus
/// measuring it is a full CoreText pass each time. Only the marquee offset and the
/// bar heights change between frames during steady playback, so cache the line and
/// its measured size and rebuild only when the text or its colours actually change.
private struct MusicTextKey: Equatable {
    let title: String?
    let artist: String?
    let titleAlpha: CGFloat
    let fade: CGFloat
    let appearanceIsDark: Bool
}
private var musicTextKey: MusicTextKey?
private var musicTextAttr: NSAttributedString?
private var musicTextSize: NSSize = .zero
```

Quantise `titleAlpha` and `fade` to ~1/255 before keying, otherwise the pause-morph will miss
the cache on every frame *and* pay an equality check — which is fine (the morph is 0.267 s)
but pointless churn. Cache misses must produce byte-identical output to today.

`musicMarqueeActive(...)` (`:526`) builds and measures a *throwaway* string with
`.labelColor` just to compare widths. Route it through the same cache, or at minimum note
that its colours differ from the render path so it needs its own entry.

### Acceptance criteria

- Marquee scroll speed, direction, and wrap gap are unchanged.
- The pause morph (bars → ⏸) and its text dip-out/dip-in at `Indicator.swift:287-297` look
  identical.
- Track change cross-fade unchanged.
- A title long enough to marquee still marquees; one just short of the 200 pt threshold still
  does not.

### Risk

**Low**, provided the cache key is complete. The trap is forgetting `appearanceIsDark` and
shipping a stale-coloured string after a light/dark switch.

---

## F10 — Cache the menu-bar colours

**File:** `MSG/IndicatorRenderer.swift`
**Symbols:** `menuBarTextColor`, `menuBarDimColor`
**Anchor:** `IndicatorRenderer.swift:763-779`

### Problem

Both are computed properties. Each runs
`button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])`,
which allocates that candidate array on every access. `menuBarDimColor` calls
`menuBarTextColor` internally, so a single `makeMusicFrame` triggers three appearance lookups
(`:534`, `:535`, plus the nested one), and `makePalette()` (`:46`) adds another per pill frame
— at 60 Hz during a pill animation.

### Required change

Cache both, keyed on the resolved appearance name, and invalidate on appearance change. There
is already an appearance observer at `AppDelegate.swift:60-66`; either extend it to poke the
renderer, or have `IndicatorRenderer` observe
`NSApplication.didChangeScreenParametersNotification` plus its own KVO on
`button.effectiveAppearance`.

Simplest correct form: keep a `cachedAppearanceName: NSAppearance.Name?` alongside the two
colours; on each access compare the current `bestMatch` result — no, that defeats the point.
Instead resolve lazily and invalidate explicitly:

```swift
private var cachedTextColor: NSColor?
private var cachedDimColor: NSColor?

/// Called from the app's effectiveAppearance observer.
func appearanceChanged() {
    cachedTextColor = nil
    cachedDimColor = nil
}
```

Hoist the `[.darkAqua, .aqua, .vibrantDark, .vibrantLight]` array to a `static let` regardless
of whether you cache the colours.

### Acceptance criteria

- Switching macOS between light and dark updates the pill and music colours immediately.
- Moving the status item between a light and a dark wallpaper region (vibrancy) still
  resolves correctly — **test this specifically**, since `effectiveAppearance` on a status
  item button tracks menu-bar vibrancy, not just the system theme. If it does not hold,
  fall back to F10's static-array hoist only and drop the colour cache.

### Risk

**Low-medium.** The vibrancy case is the one that can regress. If in doubt, ship the array
hoist and skip the cache — the array allocation is most of the cost anyway.

---

# 6. Explicitly out of scope — do not touch

Changing any of these fails review:

- The main-thread `Timer` + `CACurrentMediaTime()` animation pattern (`CLAUDE.md`).
- Animation durations, easing curves, intervals, or the pre-rasterised pill frame cache
  (`Indicator.swift:754-765`) — the pre-rasterisation is already the right call.
- `SystemHUDMonitor`'s `CGEventTap` (`SystemHUDMonitor.swift:82-110`) — correctly
  event-driven, and the tap must keep serving both the HUD and media-key routing.
- `InputSourceMonitor` — already `DistributedNotificationCenter`-driven.
- `AudioSpectrumTap` — already `acquire()`/`release()` refcounted.
- `TrayState` — already `NSWorkspace` notification-driven.
- `DockHoverController` — already throttled to 40 Hz with a near-Dock guard
  (`DockPreview.swift:95-103`).
- `MusicPopover`'s 0.3 s timer — already starts on `show` and stops on `close`.
- The `MediaRemoteAdapter` one-shot-process architecture itself (see F1).
- `WallpaperEngine.restore()` / `sync()` / `bake()` — correctness-critical.
- The fan-control helper protocol and its SMC ownership reconciliation.
- `MSG.entitlements`, code signing, `Info.plist`.

---

# 7. Verification protocol

## 7.1 Type-check without building

Do **not** run `./build.sh`. Type-check the whole target:

```bash
cd /Users/h1d3s1gn/Documents/Xcode/MSG/MSG
swiftc -typecheck *.swift \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework CoreAudio -framework Carbon \
  -import-objc-header /dev/null 2>&1 | head -50
```

If the Objective-C bridging for `MediaRemoteHelper.m` blocks this, type-check the individual
files you changed instead, and say so in your report rather than silently skipping.

Every fix must type-check before you move to the next.

## 7.2 Per-fix functional checks

Each fix has its own **Acceptance criteria** section. Work through them literally; do not
substitute "it compiles" for "it behaves".

## 7.3 Overall smoke test (owner runs this, but list what you expect)

1. Switch spaces with ⌃← / ⌃→ on the built-in display → pill animates, corners hide and grow.
2. Switch to and from a fullscreen app's space → same.
3. Enter and exit Mission Control → no false pill animation, corners grow in on exit.
4. Play music → indicator swaps in, visualizer bars move, long titles marquee.
5. Pause → bars morph to ⏸, text dips and returns, linger expires.
6. Enable hardware stats → bars appear and ease; values match Activity Monitor.
7. Hold ⌘⇥ → tray appears with a correct Now Playing card.
8. Hover a Dock tile → window preview appears.
9. Change the wallpaper in System Settings → MSG adopts it.
10. Quit from the menu → app stays quit (does not relaunch).

## 7.4 Reporting back

For each fix ID report: **done / partial / skipped**, the commit sha, which acceptance
criteria you actually exercised versus which you only reasoned about, and anything you found
that contradicts this document. Do not claim a criterion passed if you could not run it —
say so plainly. If a fix turned out to be wrong or unnecessary, say that too; this plan was
written from a static read and may be wrong somewhere.

---

# 8. Implementation checklist

Work top to bottom. Each line is one commit.

```
TIER 1
[ ] F1   Gate + back off Now Playing polling            MusicMonitor, AppDelegate, MusicPopover, TrayPanel
[ ] F1b  Compile the Music-state script once; own timer MusicMonitor
[ ] F2   Delete the dead fullscreen AX poll             SystemState, Indicator, CornerWindow (comment)
[ ] F3   Merge window-list scanners + input gate        AppDelegate, MissionControlDetector, SystemState   (HIGH RISK — read "The two traps" first)
[ ] F4a  Gate HardwareMonitor on demand                 AppDelegate, HardwareMonitor, SettingsPanes
[ ] F4b  Cache the live SMC sensor key set              HardwareMonitor
[ ] F4c  Cache SMC key metadata                         HardwareMonitor (SMCController)
[ ] F4d  Throttle the charge-limit preference read      HardwareMonitor
[ ] F4e  Move hardware sampling off the main thread     HardwareMonitor   (OPTIONAL — skip if the fan audit looks risky)
[ ] F5   Tolerance on sampling timers only              9 files, see table

TIER 2
[ ] F6   Gate slide diagnostics behind a defaults key   AppDelegate
[ ] F7   Slow + gate the wallpaper drift poll           WallpaperEngine
[ ] F8   Corner subviews instead of full-screen redraw  CornerWindow      (HIGHEST RISK — do last, own commit)

TIER 3
[ ] F9   Hoist + cache the music text layout            IndicatorRenderer
[ ] F10  Cache menu-bar colours                         IndicatorRenderer, AppDelegate
```

**Expected result at default settings:** process spawns per hour 3,600 → ~0; window-list
dumps 138,000 → near zero while unattended; Accessibility round trips 60,000 → 0; SMC
transactions 201,600 → 0. With every feature switched on, each of those drops by roughly an
order of magnitude rather than to zero.

**Nothing above changes what the user sees.** If your diff changes a duration, an easing
curve, a colour, or a layout constant, you have gone out of scope.
