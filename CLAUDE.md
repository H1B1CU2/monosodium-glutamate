# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
./build.sh          # Compile to ./build/MSG.app
open build/MSG.app  # Launch

# Or compile individual files for quick checks:
cd MSG && swiftc *.swift -o /tmp/msg_test -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos12.0 -framework AppKit -O
```

## Architecture

35 source files, ~23k lines. The build list lives in `build.sh` — a new file
must be added there by hand or it silently won't compile in.

### Core

| File | Responsibility |
|------|---------------|
| `main.swift` | Entry point, creates NSApp + AppDelegate |
| `AppDelegate.swift` | Lifecycle wiring. Screen changes, focus detection, corner window management. |
| `Settings.swift` | Centralized persistent config via UserDefaults. `onChange` emits `.corners`/`.indicator`/`.structural` categories. |
| `Shared.swift` | Cross-cutting helpers: `DisplayID`/`NSScreen.uuid`, and `PresentationState` (see Power Gating below). |
| `SystemState.swift` | MC/fullscreen tracking. Exposes `isStable`, `isFullscreen`, `isMissionControl`. Fires `didStabilize` after MC exit + quiesce window. Scans off-main, idle-gated — the pattern other pollers should copy. |
| `SpaceWatcher.swift` | CGS private API bindings (`CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`). Returns `SpaceInfo` struct. Falls back to previous values when CGS data is incomplete. |
| `MissionControlDetector.swift` | `WindowListScanner` — window-list signals used by `SystemState`. |

### Menu bar indicator

| File | Responsibility |
|------|---------------|
| `Indicator.swift` | Menu bar status item owner. Runs the render loop, coordinates 5 animation slots. **Snapshot state (previousSpaces, previousActiveDisplayIndex) is only mutated when `systemState.isStable` is true.** On `didStabilize`, snapshot is atomically resynced without triggering animation. |
| `IndicatorRenderer.swift` | Pure drawing functions. `makePillFrame()` (pill/dots with grid support), `makeNumbersAttributedString()` (numbers/boldNumber). Easing functions in the `Easing` enum. |
| `CornerWindow.swift` | Transparent overlay windows that paint black corner masks. One per managed screen. |
| `SystemHUDMonitor.swift`, `SystemHUDStatusItem.swift` | Volume/brightness HUD capture and its status item. |
| `InputSourceMonitor.swift` | Keyboard input source changes. |

### Hardware stats

| File | Responsibility |
|------|---------------|
| `HardwareMonitor.swift` | Sampling engine + `SMCController`. Temps/fans sweep on `sensorQueue`, everything else on main. Fan curve + presets, `FanControlHelper` launch. |
| `HardwareStatusItem.swift` | The bar/dot/circular/value menu bar renderer and its popover. |

### Music

| File | Responsibility |
|------|---------------|
| `MusicMonitor.swift`, `MediaRemoteAdapter.swift` | Now-playing state via MediaRemote (private framework + Apple-signed perl bridge). |
| `MusicPopover.swift` | Now-playing popover. |
| `AudioSpectrumTap.swift` | Process-tap spectrum for the visualizer bars. |

### Displays

| File | Responsibility |
|------|---------------|
| `Displaplacer.swift` | Private CGS display arrangement API. |
| `DisplayInput.swift` | DDC/CI input switching via private IOAVService. |
| `WallpaperEngine.swift` | Wallpaper compositing for the corner masks. |

### Dock / switcher / tray

| File | Responsibility |
|------|---------------|
| `DockPreview.swift`, `AppSwitcherPreview.swift`, `WindowPreviewCapture.swift` | Window thumbnails via AX + SkyLight. |
| `TrayState.swift`, `TrayPanel.swift`, `TrayHUDView.swift` | The tray panel. |

### Settings UI

| File | Responsibility |
|------|---------------|
| `SettingsWindow.swift` | Window controller. Retains the window across close (`isReleasedWhenClosed = false`) — see Power Gating. |
| `SettingsPanes.swift`, `SettingsPreviews.swift`, `DockPane.swift`, `TrayPane.swift` | SwiftUI panes and their live previews. |
| `SettingsMenu.swift` | NSMenu-delegate-backed status item menu. |

## Key Design Rules

### The MC/Fullscreen Animation Bug

The bug this rewrite prevents: when Mission Control exits from a fullscreen app, CGS briefly reports transient "current space" values that differ from reality. If these are baked into snapshot state (`previousSpaces`, `previousActiveDisplayIndex`), the next stable read triggers a false animation.

**Rule:** State that feeds animation diffs must only be updated when `systemState.isStable && !systemState.isFullscreen`. On `didStabilize`, atomically resync snapshot to current without triggering animations.

### SpaceWatcher Previous-Value Fallback

`SpaceWatcher.readSpaceInfo()` accepts an optional `previous: SpaceInfo?` parameter. When CGS can't resolve "Current Space" for a display, it falls back to the previous value (by UUID) instead of defaulting to 1.

### Power Gating

This app is mostly repeating timers, and none of them are free. Anything that
repeats must answer two questions.

**Can it be seen?** Check `PresentationState.shared.canPresent` (Shared.swift)
before starting a repeating timer, and register an observer to stop/restart on
transitions. It is false while the screen is locked, the displays are asleep, or
the login session is inactive. `HardwareMonitor.wantsPolling` and
`Indicator.startVisualizer()` are the reference cases.

One exception is deliberate: `wantsPolling` ignores the gate whenever a fan
preset is driving the fans. A preset puts them in SMC *manual* mode, which
survives display sleep — stop polling and `applyFanCurve()` stops with it,
leaving the fans pinned at their last RPM while the machine keeps working with
the display off. Anything else that acts on the world, rather than just drawing,
needs the same carve-out.

**Does it idle?** `TimelineView(.animation)` never does — it redraws every
display frame for as long as the view exists, whether or not anything moved.
Settings previews must use `PreviewTimeline` (SettingsPreviews.swift) instead,
which runs at `previewAnimationFPS` and parks entirely via
`PreviewAnimationGate`. This matters because the settings window is *retained
after close* (`isReleasedWhenClosed = false`, and the yellow button only calls
`orderOut`), so its NSHostingView and every preview inside it outlive the
window being on screen. Left ungated, that alone cost 22-36% CPU with nothing
visible.

### SMC Access

`SMCController` shares one `io_connect_t` across the whole app. Sensor sweeps
run on `HardwareMonitor.sensorQueue` while fan control still writes from main,
so every call funnels through `callSMC` under `connLock`. Each key read is two
`IOConnectCallStructMethod` round trips into the kernel — never add SMC reads
to a main-thread path.

## Testing

There are no tests. Verification is `./build.sh` plus running the app. When
changing sampling or animation behaviour, `sample <pid>` on the running process
is the fastest way to see what the main thread is actually doing.
