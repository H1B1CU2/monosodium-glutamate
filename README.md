# MSG (MonoSodiumGlutamate)

A highly optimized macOS menu bar utility that provides real-time desktop space indicators, rounds screen corners with customizable overlays, manages multi-display arrangement presets, monitors live hardware (CPU/GPU/RAM, temperatures, fans, power, battery), replaces the native volume/brightness OSD, and integrates an advanced now-playing music controller with gesture-based trackpad volume tracking.

> **How does it read all this system state?** See **[DETECTION.md](DETECTION.md)** for the signal behind every feature — the exact APIs, why the naive approach failed, and the OS-version caveats.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2013.0+-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.0+-orange.svg)

---

## 🚀 Key Features

### 1. Space Indicator (Menu Bar)
Provides a visual indicator in the macOS menu bar showing active and total desktop space layouts across multiple displays.
* **Aesthetics & Styles** — Pill (segmented bar), Numbers (`1/3`), Bold Number, and Dots (minimalist circles).
* **Multi-Display Arrangements** — Support for all connected screens with optional per-display custom naming/labels.
* **Stack Modes** — Inline (side-by-side), Stack (vertical), or Dynamic (auto-detects absolute display arrangement).
* **Dynamic Grid Layout** — Detects physical monitor alignments and wraps space pills. If displays are stacked vertically, the grid places them vertically; if horizontal, they flow side-by-side.
* **Focus Detection** — Highlights the active screen's spaces and dims inactive displays. Focus is detected either via mouse clicks (`Click Detection`) or live mouse coordinates (`Pointer Position Detection`).
* **Animations** — Transitions can be configured to use `Liquid` (smooth slide) or `Solid` (instant) styles.

---

### 2. Cornermization (Screen Rounded Corners)
Bakes black overlay masks onto the corners of your screen to round hard edges, mimicking the industrial design of modern MacBook panels.
* **Per-Display Settings** — Configure individual rounding radius (1px to 30px) for your laptop display and external monitors independently.
* **Precision HUD Slider** — Adjust settings live with active haptic ticks for precise adjustment.
* **Positional Masking** — Round only the top corners, only the bottom corners, or all four.
* **MenuBar Alignment** — Set top corner masking either at the absolute screen edge or below the macOS menu bar.
* **Display Mirroring** — Instantly mirror main display corner styles to all external displays.

---

### 3. Displaplacer (Display Arrangement Presets & Soft-Eject)
Control display geometry and software connection state natively without physical unplugging.
* **Soft-Eject Monitors** — Toggle external displays off completely. The screen goes dark and macOS behaves as if the cable was unplugged (all windows migrate smoothly to remaining monitors). Reconnect with a simple toggle.
* **Layout Presets** — Save the exact origin alignment (X, Y) of all connected displays and restore them instantly with one click.
* **Session Persistence** — Remembers soft-disconnected display IDs and restores their connected/disconnected states across app restarts and system reboots.

---

### 4. Now Playing HUD & Gesture Controller
A gesture-driven media popover that attaches below your space indicator in the menu bar.
* **Universal Media Monitoring** — Tracks currently playing track, artist, album art, and playback status for Apple Music, Spotify, browsers, and other media processes.
* **Trackpad Gestures** — Control playback intuitively from a dedicated visual touchpad:
  * **Tap**: Toggle Play/Pause.
  * **Vertical Scroll/Swipe**: Smooth volume adjustment with haptic feedback ticks.
  * **Horizontal Scroll/Swipe**: Jump to the next track (swipe left) or previous track (swipe right) with visual icon overlays.
* **Active HUD Animations** — Live sliding popovers, text fade transitions, and dynamic visual indicators.
* **Apple Silicon & macOS 15.4+ Entitlement Bypass** — Bypasses restricted Apple Now Playing entitlements seamlessly via dynamic library injection.

---

### 5. System Monitor (Menu Bar)
Live hardware stats in the menu bar, with a detail popover of cards.
* **Metrics** — CPU %, GPU %, memory pressure/usage, CPU/GPU die temperatures, fan RPM, system power draw, and **real presented frame rate** (actual rendering throughput, not the panel's fixed Hz).
* **Render Styles** — Each module can draw as a vertical bar, horizontal bar, dot, circular gauge, bare number, or (for battery) a native-style glyph.
* **Fan Control** — Auto or a performance preset with a custom curve. Reads are unprivileged; the privileged SMC writes go through a root helper that idle-exits and reconciles manual mode across relaunches.

---

### 6. Battery & Energy
A battery card that goes beyond a percentage.
* **Live Detail** — Charge %, charging/plugged state, adapter wattage, and system power draw in one card.
* **Charge-Limit Marker** — When you're on power and macOS has a charge limit set, a tick on the level bar shows exactly where charging stops — read straight from your *System Settings ▸ Battery* limit.
* **Energy Mode** — Switch Automatic / Low Power / High Power inline (backed by `pmset powermode`).
* **Significant-Energy Apps** — An approximated "apps using significant energy" list (per-app CPU + GPU, billed to the responsible app), smoothed with hysteresis so it stays stable instead of flickering.

---

### 7. Volume & Brightness HUD
Replaces the native macOS OSD with an indicator that morphs into a level bar.
* **Key Interception** — A session event tap captures the hardware volume/brightness keys, suppresses the system popup, and applies the change itself (CoreAudio for audio, DisplayServices for the built-in panel).
* **Fine Adjustment** — Hold Shift+Option for quarter-step control, with the classic volume "tick" feedback.
* **Pass-Through** — Every other media key (play/pause, next/prev, keyboard backlight) is left untouched.
* **Device-Aware Icon** — The volume icon reflects your real output device (speaker, headphones, AirPods, AirPods Pro) by decoding Apple's BLE "Proximity Pairing" broadcast for the actual hardware model, so it stays correct even if you've renamed the device in Bluetooth settings — unlike name-based matching alone.

---

## 🛠️ Technical Architecture & Inner Workings

MSG operates directly against lower-level macOS and CoreGraphics subsystem APIs with **zero external dependencies**. The highlights below are a taste — **[DETECTION.md](DETECTION.md)** documents every detection path, its exact API, and its caveats.

### macOS 15.4+ Now Playing Bypass
Starting with macOS 15.4, accessing global media state requires the private entitlement `com.apple.mediaremote.fetch-now-playing-info`, which triggers AMFI to terminate self-signed binaries. 
To bypass this limitation, MSG:
1. Compiles a native helper library, `libMSGMediaRemote.dylib` (from `MediaRemoteHelper.m`), which dynamically interfaces with `MediaRemote.framework`.
2. Spawns an Apple-signed platform process—specifically `/usr/bin/perl`—using `DynaLoader` to load the dylib at runtime.
3. The helper streams updates via standard stdout in JSON lines, allowing MSG to read Now Playing data securely without code signing violations.

### Soft-Ejection via Private CoreGraphics APIs
Uses the unexported symbol `CGSConfigureDisplayEnabled` from `CoreGraphics.framework` inside a configuration transaction (`CGBeginDisplayConfiguration`/`CGCompleteDisplayConfiguration`) to enable or disable active display controllers.

### Thread-Safe AppleScript Execution
To query music state from Apple Music and Spotify, MSG schedules AppleScript commands via a single, dedicated serial dispatch queue (`com.h1d3s1gn.MSG.applescript`). This resolves thread contention within NSAppleScript, preventing hangs during system sleep/wake and removing high-CPU energy overhead.

### Mission Control Detection (macOS 26)
The old "count Dock windows" trick is dead on Tahoe — the Dock keeps a persistent window on screen. MSG instead scans `CGWindowListCopyWindowInfo` for a `WindowManager`-owned window at a small **positive** layer (`Spaces Bar`, `Expose Overlay`, `ExposeShieldWindow`), which only exists while Mission Control/Exposé is open. No Screen Recording permission required.

### Real Frame Rate via SkyLight
The FPS module reads the WindowServer's cumulative presented-frame counter (`SLSGetPerformanceTotalUpdateCount`) and diffs it between polls — the same data Quartz Debug's frame meter shows — so it reports *actual* rendering throughput instead of the panel's fixed refresh Hz.

### Charge-Limit Read (no privileges)
The battery card's charge-limit marker reads the user's *System Settings ▸ Battery* limit from a plain preference (`com.apple.batteryui.charging.mac`) via `CFPreferencesCopyAppValue` — no SMC poke, no root helper — and re-syncs each read so slider changes are picked up live.

---

## 📦 Building & Installation

To compile and pack the app manually:

1. Clone the repository:
   ```bash
   git clone https://github.com/H1B1CU2/monosodium-glutamate.git
   cd monosodium-glutamate
   ```

2. Run the build script to compile Swift files and build the helper dylib:
   ```bash
   ./build.sh
   ```

3. The compiled app bundle will be placed at:
   ```text
   build/MSG.app
   ```

4. Drag `MSG.app` into your `/Applications` directory.
5. On first launch, grant **Accessibility** (required for the volume/brightness key HUD). Space, Mission Control, and hardware detection work without any permission; scriptable-player control (Apple Music/Spotify) prompts for **Automation** on first use. See [DETECTION.md](DETECTION.md) for the per-feature permission table.

---

## ⌨️ Usage

* **Open Controls**: Left-click the space indicator pill in the macOS menu bar to open the popup settings UI.
* **Open Music HUD**: Slide or click on the music indicator inside the menu bar.
* **Quit Utility**: Press `Q` while the settings menu is open or use the Quit button.

---

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
