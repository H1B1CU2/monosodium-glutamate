# Tiling resize delivery

`TilingFramePipeline.swift` is a local Swift implementation of a latest-target
mailbox with per-application serial delivery. It is informed by Glide's actor
architecture, not a copied replacement window manager.

Reference inspected: https://github.com/glide-wm/glide/blob/6efd5f1d436d65e7e9b120dd4a2185c3b3aff858/src/actor/app.rs

## Invariants

- Both native neighbour resizing and divider resizing submit through this writer.
- Each app has its own queue; a blocked app does not block the main thread or a
  different app's setters. Pending requests collapse to the newest per window.
- A size/position pair finishes before another pair for the same app begins.
- Enhanced UI is suppressed once per active delivery session, restored after
  closing/settling, and restored on cancellation before the next session starts.
- Live pairs contain no geometry reads, WindowServer diagnostics or preference
  toggles. Final readback/retries run only while closing.
- Reconciliation waits for closing delivery. Observed intermediate sizes never
  become learned minimum constraints. Native dragged windows remain user-owned.
- Cancellation removes pending work. An already executing AX pair cannot be
  recalled; subsequent work for that PID remains serialized behind it.
- Stop waits up to one second for cancellation cleanup; forced process death
  cannot guarantee restoration.

## Verification boundary

Post-layout animation uses one AppKit display link per animated screen on macOS
14+, removed when motion ends. The requested ceiling is the display maximum,
capped at 120 Hz, 60 Hz in Low Power Mode or serious thermal state, and 30 Hz in
critical thermal state. This is a requested cadence, not guaranteed AX presentation
throughput. macOS 13 uses an active-animation-only timer fallback.

The writer reads an initial baseline once per window/session and skips unchanged
attributes thereafter. It probes writable AXFrame once, falling back to separate
size/position setters if unavailable or rejected. Attribute acceptance does not
prove compositor atomicity. Closing verification bypasses the unchanged cache.

`TilingFramePipelineTests.swift` exercises real queues with a deliberately stalled
writer: coalescing, multiple windows, final-target settle, cancellation ordering,
and independent app progress. `check_tiling_animation.py` checks controller wiring.

Neither test proves visual atomicity: AX still exposes separate setters. Use
`ObserveResize.swift` plus visual observation to test native-edge and divider
dragging with the real apps, including Dock shown/hidden and rapid reversals.
Do not interpret Space transitions (translation of whole windows) as resize jitter.
