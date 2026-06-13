# MSG (MonoSodiumGlutamate)

A highly optimized macOS menu bar utility that provides real-time desktop space indicators, rounds screen corners with customizable overlays, manages multi-display arrangement presets, and integrates an advanced now-playing music controller with gesture-based trackpad volume tracking.

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

## 🛠️ Technical Architecture & Inner Workings

MSG operates directly against lower-level macOS and CoreGraphics subsystem APIs with **zero external dependencies**:

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
5. On the first launch, grant **Accessibility** permissions (required for active space detection).

---

## ⌨️ Usage

* **Open Controls**: Left-click the space indicator pill in the macOS menu bar to open the popup settings UI.
* **Open Music HUD**: Slide or click on the music indicator inside the menu bar.
* **Quit Utility**: Press `Q` while the settings menu is open or use the Quit button.

---

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
