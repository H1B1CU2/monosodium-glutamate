# Tiling improvements — 12 September 2026

MSG continues to manage native macOS Spaces using its existing split tree and master/stack layouts. AeroSpace was read as an architectural reference; its source was not copied into MSG and its virtual workspace model was not adopted.

## Source reviewed

AeroSpace commit `39e519044725694635712c739df9ca40ae78c5d1`:

- [Mouse resize handling](https://github.com/nikitabobko/AeroSpace/blob/39e519044725694635712c739df9ca40ae78c5d1/Sources/AppBundle/mouse/resizeWithMouse.swift): compares user geometry with the previous layout and adjusts the surrounding container weights. MSG adjusts the touched ancestor split ratios during mouse dragging, with 20–80% bounds. Master mode adjusts the master/stack divider.
- [Container normalization](https://github.com/nikitabobko/AeroSpace/blob/39e519044725694635712c739df9ca40ae78c5d1/Sources/AppBundle/tree/normalizeContainers.swift): removes empty/redundant containers. MSG retains its existing branch-collapse behavior and now rejects duplicate insertion.
- [Refresh scheduling](https://github.com/nikitabobko/AeroSpace/blob/39e519044725694635712c739df9ca40ae78c5d1/Sources/AppBundle/layout/refresh.swift): cancels superseded refresh tasks and checks whether the manager is enabled. MSG retains its coalesced refresh, cancels pending work when suspended/stopped, and avoids layout writes during mouse gestures.

## Resulting behavior

- Master stack follows the split tree's stable window order, not changing window z-order when the user clicks.
- Newly discovered windows use the last focused existing tile when the new window already owns focus.
- Mouse gestures record the initial window/Space/work-area state. Resizing updates neighbors while the pointer owns the dragged window, with all ratio calculations based on the initial layout to avoid accumulated drift. Dragging into another tile swaps window identities without changing slot geometry. Release uses the pointer position at mouse-up. Changing Space, display geometry, or tile membership during a gesture discards that resize.
- Fullscreen Spaces do not reconcile or erase their stored tiling state.
- Floating choices survive hiding/minimizing while the window remains registered.
- AX dialogs and nonstandard utility windows are excluded.
- Geometry changes trigger refresh. If an app rejects an unchanged target rectangle and remains at the same actual rectangle, MSG avoids repeatedly sending the rejected request. Retile explicitly retries.

## Menu bar ownership

The menu bar behavior is MSG-specific, not an AeroSpace implementation. `_HIHideMenuBar` is written through CFPreferences, followed by `AppleInterfaceMenuBarHidingChangedNotification`. See the independently published [HazeOver example](https://gist.github.com/pointum/f740e74e7d04a91eb0a5be3601295c92) for this preference/notification pair.

Enabling Tiling saves the original global auto-hide preference, including an absent key, before enabling auto-hide. Disabling Tiling or quitting restores it. An already-enabled preference is untouched. A later manual override is respected. The restore journal survives an unclean exit and is recovered on the next MSG launch; a failed restoration keeps the journal for another attempt. Force-killing MSG cannot run immediate cleanup. Native fullscreen menu bar preferences are not changed.

## Control bar regression

Actions previously fired on mouse-down while the tiling engine refused writes with a held mouse button. Buttons now accept first click and activate on release inside the original hit area. Explicit forced refreshes survive a held button until the next poll. Commands resolve a target on the clicked display, and the floating toggle reads Float/Tile to expose its state.

## Validation and boundaries

- `check_tiling_buttons.py`: executes production event methods without opening an app window; release activation, first click, drag-out cancellation and stale release.
- `TilingLayoutTests.swift`: insertion and collapse, master placement, resizing either side of a divider, row/column directions, movement vs resize, outer-edge behavior, nested resize with positive/negative deltas and ratio clamps.
- `TilingMenuBarTests.swift`: isolated injected preference backend; restoration, absent keys, preexisting auto-hide, user overrides, crash recovery, restore failure/retry. Tests do not change the system menu bar setting.
- Build verification is separate from live interaction verification. No MSG launch, UI manipulation, or global preference change is performed by these tests.

Layouts remain session-local. This change does not add AeroSpace-style virtual workspaces or shortcuts. App-imposed minimum sizes can still prevent a requested layout from fitting. Native mouse event timing and live menu bar notification behavior require manual verification on the installed build.
