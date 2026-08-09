# How MSG Detects Things

MSG reports a lot of live system state — active Space, Mission Control, real
frame rate, temperatures, fan RPM, battery/charge-limit,
volume/brightness key presses — with **zero external dependencies** and, for
most of it, **no special permissions**. It does this by reading public IOKit /
CoreGraphics / CoreAudio interfaces plus a small set of private-but-stable
Apple symbols resolved at runtime with `dlsym`.

This document explains the signal behind each feature: *what* we detect, *how*
we detect it, and the *caveats* that made the naive approach fail. It's the map
you want before changing any of this code, because several of these signals are
undocumented and moved between macOS releases.

> Legend — **Permission:** what macOS must grant. **Stability:** how likely the
> signal is to survive an OS update.

---

## 1. Active Space & display layout

**What:** which desktop Space is current on each display, and how many Spaces
exist — per monitor, in physical arrangement order.

**How:** the private CoreGraphics *Spaces* API, resolved from the `SkyLight`/
`CoreGraphics` connection:
- `CGSMainConnectionID()` — our WindowServer connection.
- `CGSCopyManagedDisplaySpaces(cid)` — array of displays, each with its ordered
  Space list and the UUID of the current Space.
- `CGSGetActiveSpace(cid)` — the globally active Space id (cheap scalar; safe to
  poll every frame).

`SpaceWatcher.readSpaceInfo()` joins the CGS display list to `NSScreen` by UUID
so Spaces are ordered by physical X position, not enumeration order.

**Caveat:** during Mission Control and space transitions, CGS briefly reports
*transient* "current Space" values that don't match reality. `readSpaceInfo()`
therefore takes a `previous: SpaceInfo?` and, when it can't resolve a display's
current Space, falls back to the previous value **by UUID** instead of
defaulting to Space 1. Snapshot state that feeds animation diffs is only updated
when the system is stable (see `CLAUDE.md` → "The MC/Fullscreen Animation Bug").

**Permission:** none. **Stability:** medium — private symbols, stable for years.

---

## 2. Mission Control / App Exposé is on screen

**What:** whether Mission Control or App Exposé is currently open.

**How:** `CGWindowListCopyWindowInfo(.optionOnScreenOnly, …)`, then look for a
window **owned by the `WindowManager` process at a small positive layer**
(`kCGWindowLayer` in ~14–19). On the idle desktop, WindowManager only owns
wallpaper/backdrop/shield windows at hugely *negative* layers; when Mission
Control opens it adds overlays at positive layers:

| Window name          | Layer | Role                              |
|----------------------|-------|-----------------------------------|
| `Spaces Bar`         | 14    | top spaces strip                  |
| `Expose Overlay`     | 17    | window-thumbnail overlay          |
| `ExposeShieldWindow` | 19    | background shield                 |

See `MissionControlDetector.isActive()`.

**Caveat:** this replaced the old "count Dock-owned windows" heuristic, which is
**dead on macOS 26 (Tahoe)** — the Dock now keeps a persistent layer-20 window
on screen at all times, so its presence proves nothing. If Screen Recording
permission is granted the window *name* is readable and we require a known
overlay name (so Stage Manager's positive-layer windows can't false-positive);
without that permission the name is empty and a positive-layer WindowManager
window is, by itself, a strong enough signal to accept.

**Permission:** none required (name check is a bonus if Screen Recording is on).
**Stability:** low — layer numbers/names are OS-version specific; re-verify each
major release.

---

## 3. Space-switch slide is in progress

**What:** whether WindowServer is mid-slide switching desktops on a display —
detected ~500 ms *before* `activeSpaceDidChangeNotification`, which only fires at
landing. Used to start corner grow-in animations in time.

**How:** `CGSManagedDisplayIsAnimating(CGSMainConnectionID(), uuid)`.

**Caveat (measured):** only desktop↔desktop slides set this. Transitions to or
from a fullscreen-app Space (Space type 4) never do — for those, the only
early signal is the menu-bar window-pair count in `CGWindowListCopyWindowInfo`
(see `project_space_switch_grow` design note).

**Permission:** none. **Stability:** medium.

---

## 4. Which display has focus

**What:** the display the user is "on", so its Spaces highlight and others dim.

**How:** two selectable strategies —
- **Click detection** — a global mouse-down monitor maps the click location to
  the containing `NSScreen`.
- **Pointer position** — the screen containing `NSEvent.mouseLocation`.

**Permission:** none (global monitors need no Accessibility for mouse location).
**Stability:** high — public AppKit.

---

## 5. Real presented frame rate (FPS)

**What:** frames the WindowServer *actually presented* per second — real
rendering throughput, not the panel's fixed refresh Hz.

**How:** the SkyLight frame counter, resolved via `dlsym`:
- `SLSMainConnectionID()`
- `SLSGetPerformanceTotalUpdateCount(cid, &count, &timestamp)` — cumulative
  presented-frame count plus a monotonic timestamp (the same data Quartz Debug's
  frame meter shows). FPS = Δcount / Δtimestamp between polls.

This is why the FPS module reads, e.g., 0 on a still screen and jumps to the
panel rate only when something animates — unlike `CGDisplayModeGetRefreshRate`,
which would always report a flat 60/120.

**Permission:** none. **Stability:** medium — private symbol, long-lived.

---

## 6. CPU / GPU / memory load

**What:** system-wide CPU %, GPU %, and memory pressure/usage.

**How:**
- **CPU** — `host_statistics64(… HOST_CPU_LOAD_INFO …)`, differencing
  user/system/idle/nice tick counters between polls.
- **Memory** — `host_statistics64(… HOST_VM_INFO64 …)` for pressure and used/total.
- **GPU** — the `IOAccelerator` service's `PerformanceStatistics` dictionary,
  reading the `"Device Utilization %"` field.

**Permission:** none. **Stability:** high (host stats) / medium (IOAccelerator keys).

---

## 7. Temperatures & fans (SMC)

**What:** CPU/GPU die temperatures and per-fan RPM (current/min/max).

**How:** the Apple System Management Controller via `IOServiceMatching("AppleSMC")`
and `IOConnectCallStructMethod`. Keys are 4-char codes (`smcFourCC`):
- **Temps** — a probe list of die sensors: Intel-style `TC0D/TC0E/TC0P/TCAD…`
  and Apple-silicon cluster sensors `Tp01/Tp05/Tp09…`; the first plausible read
  (0 < °C < sane-max) wins.
- **Fans** — `F<n>Ac` (actual RPM), `F<n>Mn`/`F<n>Mx` (min/max) per fan index.

**Reads** work unprivileged. **Writes** (fan control) do not — see §11 in the
README's helper section: a root socket helper performs the SMC writes.

**Permission:** none for reads. **Stability:** medium — key sets vary by model.

---

## 8. Power draw & battery

**What:** live system power (W), charge %, charging/plugged state, adapter watts.

**How:** the `AppleSmartBattery` IORegistry entry (the same source coconutBattery
reads):
- Power = `|Amperage| × Voltage` (signed live current/voltage sensors; positive
  amperage = charging).
- `CurrentCapacity` = charge %, `IsCharging`, `AdapterDetails.Watts` = adapter rating.

On battery-less Macs (desktops) there is no `AppleSmartBattery`, so power falls
back to SMC power keys (`PSTR`, `PPBR`, …).

**Held at limit / full on AC:** amperage is ~0 (no current in/out of the
battery), so `|Amperage| × Voltage` would read 0 W even though the Mac is running
off the adapter. In that state we substitute the live system input power from
`AppleSmartBattery.PowerTelemetryData.SystemPowerIn` (milliwatts → W) so the card
shows real draw. Active charging/discharging still uses the battery-current
figure.

**Permission:** none. **Stability:** high.

---

## 9. The user's charge limit

**What:** the **Charge Limit** percentage the user set in *System Settings ▸
Battery* (e.g. 80%, 90%). Used to draw the limit tick (ขีด) on the battery bar so
it's clear where charging stops.

**How:** it's stored as a plain per-user preference — no SMC, no root, no helper:

```
domain: com.apple.batteryui.charging.mac
key:    com.apple.batteryui.charging.mac.prior.limit   →  Int (e.g. 90)
```

`HardwareMonitor.readChargeLimitPercent()` reads it with
`CFPreferencesCopyAppValue`, calling `CFPreferencesAppSynchronize` first so a
change made in System Settings while MSG runs is picked up live. The value is
validated to 1…100 before use.

**Why this and not SMC:** the SMC keys (`CHWA`/`CHTE`/`BCLM`) are the *mechanism*
that enforces the cap — they're model-dependent and tell you the enforced
hardware value, not necessarily the number the user picked. This pref *is* the
slider value, and reading it needs no privileges. It was cross-checked against
hardware: when the pref reads 90, `pmset -g batt` reports "90%; not charging" and
`AppleSmartBattery.NotChargingReason` shows the limit-hold bit — i.e. the pref
reflects the *active* limit.

**Caveat:** the key is named `.prior.limit`. We couldn't verify what it holds
after the limit is turned fully *off* (turning it off would disrupt a real
machine), so a stale value could linger. The battery tick is therefore gated on
being plugged in **and** limit < 100; if staleness ever bites, the fallback is to
cross-check `AppleSmartBattery.NotChargingReason` before showing the tick.

**Permission:** none (MSG is unsandboxed, so it can read another app's domain).
**Stability:** low — undocumented internal key; guard on `nil`.

---

## 10. Energy mode (Automatic / Low / High Power)

**What:** the current energy mode, and the ability to change it.

**How (read):** parse `pmset -g custom` — the `powermode` line per power source
(`0` = automatic, `1` = low, `2` = high). No privileges to read.
**How (write):** `pmset -a powermode N` requires root, so it goes through the
same socket helper used for fan writes.

**Permission:** none to read; root (via helper) to change. **Stability:** high.

---

## 11. Volume / brightness key presses

**What:** the hardware volume-up/down/mute and brightness-up/down keys, so MSG
can replace the native OSD with its own indicator bar.

**How:** a session-level `CGEventTap` (`.cgSessionEventTap`, head-insert) on
`NX_SYSDEFINED` (event type 14) events. For each event we decode the NX aux key
code from `NSEvent.data1` (soundUp=0, soundDown=1, brightnessUp=2,
brightnessDown=3, mute=7). For the keys MSG owns we **consume** the event
(return `nil`) so macOS never asks OSDUIHelper to draw its popup, then apply the
change ourselves — **CoreAudio** (`AudioObjectGet/SetPropertyData`,
`VirtualMainVolume`) for audio, **DisplayServices**
(`DisplayServicesGet/SetBrightness`) for the built-in panel — read the value
back, and fire `onChange`. Shift+Option = fine (quarter-step) adjustment. Every
other media key (play/pause, next/prev, keyboard backlight) is passed through
untouched.

**Caveat:** the tap runs on the main run loop, so its C callback is on the main
thread and uses `MainActor.assumeIsolated`. If the tap is disabled by timeout it
re-enables itself.

**Permission:** **Accessibility** (required to create the event tap).
**Stability:** medium — NX subtypes/keycodes are long-lived IOKit constants.

---

## 12. Output-device icon (speaker / headphones / AirPods / AirPods Pro)

**What:** which icon the volume HUD shows for the current default output device.

**How:** two layers —
- **Name/UID/transport heuristic** — match `kAudioObjectPropertyName` / device UID /
  model UID substrings (`"airpods pro"`, `"buds"`, `"beats"`, …), falling back to
  `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBluetooth` →
  generic headphones.
- **BLE model detection (preferred, when available)** — `AirPodsBLEDetector` runs a
  `CBCentralManager` scan for Apple's unencrypted "Proximity Pairing" broadcast
  (manufacturer ID `0x004C`, message type `0x07`) and reads its 2-byte device-model
  field (bytes 5–6 of the manufacturer payload, big-endian) against a table of known
  IDs (AirPods 1st–4th gen, AirPods Pro 1st/2nd gen incl. USB-C, AirPods Max). This
  identifies the real hardware regardless of the Bluetooth device's user-editable
  name — the name heuristic alone breaks the moment a device is renamed.

**Caveat:** BLE advertisements use a rotating private MAC unrelated to the
Classic-Bluetooth audio MAC, so there's no direct way to prove a given broadcast
belongs to *your* connected device. MSG takes the strongest, freshest (< 8 s)
match, and won't replace it with a weaker reading for a *different* model within
a 4 s window (avoids flapping between two nearby Apple headsets). Device-model
IDs are reverse-engineered and undocumented by Apple — cross-checked against the
LibrePods and furiousMAC/hexway projects plus live scans on real hardware, but
newer/uncataloged devices (e.g. AirPods Pro 3 at the time of writing) fall back
to the name heuristic.

**Permission:** **Bluetooth** (prompted on first use). Falls back to the name
heuristic if denied. **Stability:** low — undocumented protocol; the model table
needs updates as Apple ships new hardware.

---

## 13. Now Playing (media metadata)

**What:** current track/artist/artwork/playback state across Apple Music,
Spotify, browsers, etc.

**How:** `MediaRemote.framework`, which since **macOS 15.4** requires the private
entitlement `com.apple.mediaremote.fetch-now-playing-info` — self-signing it gets
the binary AMFI-killed. MSG sidesteps this by loading a helper dylib
(`libMSGMediaRemote.dylib`) inside an **Apple-signed** `/usr/bin/perl` process
(via `DynaLoader`), which streams Now Playing updates back as JSON lines over
stdout. See the README's "macOS 15.4+ Now Playing Bypass".

**Artwork:** macOS 26+ stops embedding artwork bytes in the now-playing snapshot
(and every *async* MediaRemote call — `MRNowPlayingRequest` instance requests,
`MRMediaRemoteGetNowPlayingInfo` — silently never completes in the helper, so
artwork cannot be requested explicitly). The snapshot's
`kMRMediaRemoteNowPlayingInfoArtworkIdentifier` is often a direct CDN URL
(mzstatic for Music); the helper emits it as `artURL` and MSG downloads the
image itself. AppleScript artwork remains the fallback for sources without a
URL, though Music returns no artwork via AppleScript for streaming tracks.

**Permission:** none (the perl host carries the platform entitlement).
**Stability:** low — depends on MediaRemote internals and the entitlement regime.

---

## 14. Music player state (Apple Music / Spotify)

**What:** precise transport state and volume for the scriptable players.

**How:** `NSAppleScript`, but funneled through a single dedicated serial dispatch
queue (`com.h1d3s1gn.MSG.applescript`) to avoid NSAppleScript thread contention
that otherwise hangs across sleep/wake and burns CPU.

**Permission:** **Automation** (per-app AppleEvents consent) on first use.
**Stability:** high.

---

## Quick reference

| Signal | Primary API | Permission |
|---|---|---|
| Active Space / layout | `CGSCopyManagedDisplaySpaces`, `CGSGetActiveSpace` | none |
| Mission Control open | `CGWindowListCopyWindowInfo` + WindowManager layer | none |
| Space-slide in progress | `CGSManagedDisplayIsAnimating` | none |
| Focused display | `NSEvent.mouseLocation` / click monitor | none |
| Real FPS | `SLSGetPerformanceTotalUpdateCount` | none |
| CPU / memory | `host_statistics64` | none |
| GPU load | `IOAccelerator` `PerformanceStatistics` | none |
| Temps / fan RPM | `AppleSMC` (`IOConnectCallStructMethod`) | none (reads) |
| Power / battery | `AppleSmartBattery` IORegistry | none |
| Charge limit | `com.apple.batteryui.charging.mac` pref | none |
| Energy mode | `pmset -g custom` | none (read) |
| Volume/brightness keys | `CGEventTap` on `NX_SYSDEFINED` | Accessibility |
| Output-device icon | `CBCentralManager` + Apple Proximity Pairing broadcast | Bluetooth |
| Now Playing | `MediaRemote` via perl-hosted dylib | none |
| Music transport | `NSAppleScript` | Automation |

*Private/undocumented symbols are resolved at runtime with `dlsym` and every read
is defensive (nil/`0`/out-of-range → treated as unavailable), so a symbol that
disappears in a future macOS degrades the affected feature rather than crashing
the app.*
