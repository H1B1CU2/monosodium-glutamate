#!/usr/bin/env python3
"""Source-level regression checks for preview-card drops without moving a real window."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
capture = (root / "MSG/WindowPreviewCapture.swift").read_text()
drag = (root / "MSG/WindowPreviewDragController.swift").read_text()
project = (root / "MSG.xcodeproj/project.pbxproj").read_text()
build = (root / "build.sh").read_text()
controller = (root / "MSG/TilingController.swift").read_text()
bar = (root / "MSG/TilingControlBar.swift").read_text()

drop = drag[drag.index("    func performDeskspaceDrop("):drag.index("// MARK: - CardInteractionCatcher")]
move_call = "await WindowPreviewCapture.moveWindow(window.id, toManagedSpace: targetSpaceID)"
raise_call = "await WindowPreviewCapture.raiseWindow("
animation_call = "await animateWindow(axWin, from: animationStart, to: finalPos)"

assert '@_silgen_name("SLSMoveWindowsToManagedSpace")' in capture
assert "static func currentManagedSpaceID(for screen: NSScreen)" in capture
assert 'NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")' in capture
assert 'NSSelectorFromString("initWithWindows:spaceID:")' in capture
assert 'NSSelectorFromString("performWithWMBridgeDelegate")' in capture
assert "submitBridgedSpaceMove(windowID: windowID, spaceID: spaceID)" in capture
assert "SLSMoveWindowsToManagedSpace(connection, windows, spaceID)" in capture
assert move_call in drop and raise_call in drop and drop.index(move_call) < drop.index(raise_call), \
    "Space reassignment must be verified before activation"
assert animation_call in drop and drop.index(raise_call) < drop.index(animation_call), \
    "the visible concrete window must animate only after Space reassignment and activation"
assert "let isCrossSpaceDrop = !WindowPreviewCapture.window(window.id, isOnManagedSpace: targetSpaceID)" in drop
landing_call = "await animateCrossSpaceLanding(image: window.image, from: landingStart,"
assert landing_call in drop and drop.index(landing_call) < drop.index(move_call), \
    "cross-Space card animation must finish before WindowServer moves the real window"
assert "panel.setFrame(targetFrame, display: true)" in drag
assert "if !isCrossSpaceDrop" in drop and "fadeGhostOut(duration: 0.16, generation: generation, settle: true)" in drop
assert "accessibilityDisplayShouldReduceMotion" in drag
assert "let duration: CFTimeInterval = 0.28" in drag and "let eased = Easing.outQuart(raw)" in drag
assert "let windowRect = convert(bounds, to: nil)" in drag
assert "window?.convertToScreen(windowRect)" in drag
assert "convertToScreen(bounds)" not in drag
assert "/tmp/msg_catcher_debug.log" not in drag
assert "WindowPreviewDragController.swift" in build
assert sum("WindowPreviewDragController.swift" in line for line in project.splitlines()) == 4, \
    "drag controller must have build-file, file-reference, group and Sources entries"
assert "newSpaceDisplayUUID: displayUUID" in drop, \
    "a newly created Desktop must remain marked through the provider callback"
assert "if target.newSpaceDisplayUUID != nil, spacePreviewStorage != nil" in bar, \
    "only a newly created Desktop should rebuild the strip before destination tiling"
assert "layoutSpaceAfterDrop(Int(spaceID))" in controller
assert "for window in tiled { appliedFrames.removeValue(forKey: window.id) }" in controller
assert "reloadSpacePreviewAfterPendingFrameWrites()" in controller
assert "if framePipeline.isActive || !frameAnimations.isEmpty" in controller
pipeline = (root / "MSG/TilingFramePipeline.swift").read_text()
assert "let retryDelays: [TimeInterval] = [0.02, 0.04, 0.08, 0.12]" in pipeline

print("PASS: drag uses card-local screen geometry and verified Space reassignment before activation")
