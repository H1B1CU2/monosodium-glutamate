#!/usr/bin/env python3
"""Regression tests for stable control-bar ordering and native Space switching."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
controller = (root / "MSG/TilingController.swift").read_text()
bar = (root / "MSG/TilingControlBar.swift").read_text()
space_jump = (root / "MSG/SpaceJump.c").read_text()
build_script = (root / "build.sh").read_text()

# 1. Order Cache Stability Guards
assert "private var orderedWindowIDsBySpace: [String: [CGWindowID]] = [:]" in controller
assert "private func stableOrderedWindows(" in controller
assert "cachedOrder.removeAll { !currentIDs.contains($0) }" in controller
assert "orderedWindows.map(\\.windowID)" in controller
assert "allBarWindowCache[bw.windowID] = CachedAllBarWindow(" in controller
assert "registeredIDs.contains(windowID), runningPIDs.contains(cachedValue.window.pid)" in controller
assert "mappedSpace ?? cachedValue.window.spaceNumber" in controller

# 2. Space Indicator Click-to-Switch Guards
assert "private func switchToSpace(displayUUID: String, spaceNumber: Int)" in controller
assert "private func representativeWindow(displayUUID: String," in controller
assert "if let targetWindow = representativeWindow(" in controller
assert "activateWindow(windowID: targetWindow.windowID," in controller
assert "windows.first(where: \\.isShownInLayout)" in controller
assert "private func postNativeSpaceJump(direction: Int, steps: Int) -> Bool" in controller
assert "MSGPostSpaceJump(Int32(direction), Int32(steps))" in controller
direct_shortcut = "postConfiguredDirectSpaceShortcut(spaceNumber: spaceNumber)"
instant_fallback = "let postedDirectly = postNativeSpaceJump(direction: direction, steps: steps)"
window_fallback = "if let targetWindow = representativeWindow("
assert direct_shortcut in controller
assert controller.index(direct_shortcut, controller.index("private func switchToSpace")) < controller.index(
    window_fallback, controller.index("private func switchToSpace")
)
assert controller.index(direct_shortcut, controller.index("private func switchToSpace")) < controller.index(
    instant_fallback, controller.index("private func switchToSpace")
)
assert "CGEventSource(stateID: .hidSystemState)" in controller
assert "kRawIOHIDPayloadField = 4205" in space_jump
assert "CGEventCreateFromData" in space_jump
assert "postModernPhase(kPhaseBegan" in space_jump
assert "postModernPhase(kPhaseChanged" in space_jump
assert "postModernPhase(kPhaseEnded" in space_jump
assert "CGPreflightPostEventAccess()" in space_jump
assert '"$BUILD_DIR/SpaceJump.o"' in build_script
assert "waitForDirectSpaceLanding(displayUUID:" in controller
assert "attempt >= 12" in controller
assert "performNativeSpaceSwitchFallback" in controller
assert "performNativeSpaceSwitchStep" in controller
assert "let hotkeyID = 117 + spaceNumber" in controller
assert "CGSManagedDisplaySetCurrentSpace" not in controller
assert "controlBar.onSwitchSpace = { [weak self] displayUUID, spaceNum in" in controller
assert "var onSwitchSpace: ((String, Int) -> Void)?" in bar
assert "var onSwitchSpace: ((Int) -> Void)?" in bar
assert "view.onSwitchSpace = { [weak self] spaceNumber in" in bar
assert "prepareForClickedSpaceChange(spaceNumber)" in bar
assert "onSwitchSpace?(spaceNumber)" in bar
assert "activateDisplayedWindow" not in bar
assert "let clickedSpaceTarget = pendingClickedSpaceNumber" in bar
assert "private var clickedSpaceTransitionGeneration = 0" in bar
assert "scheduleClickedSpaceUnlock(spaceNumber: clickedSpaceTarget)" in bar
assert "self.clickedSpaceTransitionGeneration == generation" in bar
assert "suppressClickedSpaceAnimationUntil" not in bar
assert "setSpaceIndicatorImmediately(clickedSpaceTarget)" in bar
assert "animatedPillIndex = CGFloat(spaceNumber)" in bar

# 3. Visual Transition & Settling Guards
assert "private var programmaticTargetSpaceByDisplay: [String: Int] = [:]" in controller
assert "private var nativeSpaceSwitchGeneration = 0" in controller
assert "programmaticTargetSpaceByDisplay[displayUUID.lowercased()] = spaceNumber" in controller
assert "programmaticTargetSpaceByDisplay.removeAll()" in controller

# 4. Preserve tile identity through transient window enumeration gaps
assert "shouldRemoveWindowFromSpace(" in controller
assert "guard !memberships.isEmpty else { return false }" in controller
assert "state.mainTabIDs.contains(state.masterID!)" in controller

# 5. Critical visual preservations
assert "let spaceChanged = isAllSpaces" in bar
assert "if spaceChanged {" in bar
assert "columnChanged" not in bar
assert "columnGap" not in bar
assert "if groupEnd - groupStart >= 2 {" in bar
assert "hasOtherColumn" not in bar
assert "TilingWindowStatus.groupedForColumns(orderedWindows)" in controller
assert "NSBezierPath(roundedRect: groupRect" in bar
assert "drawShownPill(for item:" in bar
assert "startShownPillAnimation(from:" in bar
assert "shownPillTravelStarts" in bar
assert "self.scheduleRefresh(after: 0.35)" in controller

# 6. Each display owns only its own app icons
assert "let resolvedDisplayUUID = screen(containing: frame)?.uuid ?? cachedOwner" in controller
assert "resolvedDisplayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame" in controller
assert "cached.displayUUID.caseInsensitiveCompare(displayUUID) == .orderedSame" in controller

print("PASS: stable order, native Space switching, and tile identity retention verified")
