# MSG (MonoSodiumGlutamate)

A macOS menu bar utility that shows desktop space indicators and customizes screen corner radius.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-macOS%2011.5+-lightgrey.svg)
![Swift](https://img.shields.io/badge/Swift-5.0+-orange.svg)

## Features

### Space Indicator

A configurable indicator in the menu bar that shows which macOS desktop space is active.

- **Indicator Styles** — Pill (segmented bar), Numbers (`1/3`), Bold Number, Dots (minimalist circles)
- **Multi-Display Support** — Space info for all connected displays with per-display labels
- **Stack Modes** — Inline (side-by-side), Stack (vertical), Dynamic (auto-detects arrangement)
- **Dynamic Grid** — When using Dynamic + Physical Detection + 3+ displays, mirrors actual monitor layout: side-by-side displays render inline, above/below displays get their own rows
- **Display Order** — Physical Display Detection (orders by real arrangement) or Prioritize Main Display (built-in always first)
- **Focus Detection** — Highlights active display via click detection or dynamic mouse polling
- **Animation Styles** — None, Solid, Liquid (ease-out), or Jelly (spring) transitions
- **Opacity & Brightness** — Adjustable via sliders

### Cornermization

Rounds the corners of your displays with black overlay masks.

- **Per-Display Radius** — Separate corner radius for built-in and external monitors
- **Precision Controls** — 1–30px slider with haptic feedback
- **Independent Toggles** — Top and bottom corners separately
- **Position Modes** — Screen edge or below menu bar
- **Mirroring** — External settings can mirror built-in display

### Laboratory (Work In Progress)

- **Black Menu Bar** — Persistent black overlay for the menu bar area
- **Smart Visibility** — Hide in Mission Control or show only during fullscreen

## Installation

1. Clone the repository
2. Open `MSG.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Grant **Accessibility** permissions when prompted

## Usage

Click the space indicator in the menu bar to open settings. Press `Q` to quit.

## Technical Notes

- AppKit + CoreGraphics + private CGS APIs for space detection
- Zero external dependencies
- macOS 11.5+
- Runs as menu bar agent (`LSUIElement` — no dock icon)

## License

MIT
