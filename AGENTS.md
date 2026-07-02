# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Build & Run

```bash
./build.sh          # Compile to ./build/MSG.app
open build/MSG.app  # Launch

# Or compile individual files for quick checks:
cd MSG && swiftc *.swift -o /tmp/msg_test -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos12.0 -framework AppKit -O
```

## Architecture

9 source files, each ~100-400 lines:

| File | Responsibility |
|------|---------------|
| `main.swift` | Entry point, creates NSApp + AppDelegate |
| `AppDelegate.swift` | Lifecycle wiring (~160 lines). Screen changes, focus detection, corner window management. |
| `Settings.swift` | Centralized persistent config via UserDefaults. `onChange` emits `.corners`/`.indicator`/`.structural` categories. |
| `SystemState.swift` | MC/fullscreen tracking. Exposes `isStable`, `isFullscreen`, `isMissionControl`. Fires `didStabilize` after MC exit + quiesce window. |
| `SpaceWatcher.swift` | CGS private API bindings (`CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace`). Returns `SpaceInfo` struct. Falls back to previous values when CGS data is incomplete. |
| `Indicator.swift` | Menu bar status item owner. Runs the render loop, coordinates 5 animation slots. **Snapshot state (previousSpaces, previousActiveDisplayIndex) is only mutated when `systemState.isStable` is true.** On `didStabilize`, snapshot is atomically resynced without triggering animation. |
| `IndicatorRenderer.swift` | Pure drawing functions. `makePillFrame()` (pill/dots with grid support), `makeNumbersAttributedString()` (numbers/boldNumber). Easing functions in the `Easing` enum. |
| `CornerWindow.swift` | Transparent overlay windows that paint black corner masks. One per managed screen. |
| `SettingsMenu.swift` | NSMenu-delegate-backed settings UI. No Laboratory section. |

## Key Design Rules

### The MC/Fullscreen Animation Bug

The bug this rewrite prevents: when Mission Control exits from a fullscreen app, CGS briefly reports transient "current space" values that differ from reality. If these are baked into snapshot state (`previousSpaces`, `previousActiveDisplayIndex`), the next stable read triggers a false animation.

**Rule:** State that feeds animation diffs must only be updated when `systemState.isStable && !systemState.isFullscreen`. On `didStabilize`, atomically resync snapshot to current without triggering animations.

### SpaceWatcher Previous-Value Fallback

`SpaceWatcher.readSpaceInfo()` accepts an optional `previous: SpaceInfo?` parameter. When CGS can't resolve "Current Space" for a display, it falls back to the previous value (by UUID) instead of defaulting to 1.
