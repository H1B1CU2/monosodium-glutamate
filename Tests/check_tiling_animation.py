#!/usr/bin/env python3
"""Source regression checks for post-gesture tiling frame animation."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "MSG/TilingController.swift").read_text()
overlay = (root / "MSG/TilingResizeOverlay.swift").read_text()
pipeline = (root / "MSG/TilingFramePipeline.swift").read_text()

apply_layout = source[source.index("    private func applyLayout("):source.index("    private func workArea(")]
animation = source[source.index("    private func animateFrame("):source.index("    private func approximatelyEqual(")]
live_resize = source[source.index("    private func updateLiveNativeResize("):source.index("    private func updateMouseResize(")]
overlay_resize = source[source.index("    private func handleOverlayResizeDrag("):source.index("    private func handleOverlayResizeEnd(")]

assert "animateFrame(from: window.frame, to: target" in apply_layout
assert "frameSpringDuration: TimeInterval = 0.32" in source
assert "frameSpringResponse: CGFloat = 22" in source
assert "TilingDisplayClock(screen: screen)" in animation
assert "TilingLayout.springFrame(" in animation
assert "initialVelocity: animation.initialVelocity" in animation
assert "let inherited = previous.map" in animation
assert "accessibilityDisplayShouldReduceMotion" in animation
assert "if settings.tilingStablePreviewResize" in live_resize
assert "resizeOverlay.showResizePreviews(frames: previewFrames)" in live_resize
assert "enqueueFrame(target, id: neighbor.id, element: neighbor.element)" in live_resize
assert "if settings.tilingStablePreviewResize" in overlay_resize
assert "resizeOverlay.showResizePreviews(frames:" in overlay_resize
assert "enqueueFrame(target, id: id, element: element)" in overlay_resize
# Delayed AX readback is not evidence of a minimum size. Constraints must
# come from declared attributes, never from a frame observed during dragging.
assert "minSizes[id] =" not in overlay_resize
assert "actual.size" not in overlay_resize
assert "minSizes: cached.compactMapValues { declaredMinimumSize(of: $0) }" in source
assert '["AXMinSize", "AXMinimumSize"]' in source
assert "animateFrame(" not in live_resize and "animateFrame(" not in overlay_resize
assert source.count("cancelFrameAnimations()") >= 4
assert "TilingLayout.dropTarget(" in live_resize
assert "resizeOverlay.showDropPreview(frame: targetID.flatMap { slots[$0] })" in live_resize
assert "final class TilingDropPreviewPanel: NSPanel" in overlay
assert "ignoresMouseEvents = true" in overlay
assert "NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()" in overlay
assert "showDropPreview(frame: nil)" in overlay[overlay.index("func notifyDragEnded()"):]
assert "private func scheduleOverlayResize(" in source
assert "pendingOverlayResize = (divider, coordinate)" in source
assert "TilingDisplayClock.interval(for:" in source
assert '"AXEnhancedUserInterface" as CFString, kCFBooleanFalse' in pipeline
assert '"AXEnhancedUserInterface" as CFString, kCFBooleanTrue' in pipeline
writer = pipeline[pipeline.index("        func write(_ request:"):pipeline.index("        func settle(_ request:")]
pair = writer[writer.index("let sizeResult"):]
assert "CopyAttribute" not in pair and "readFrame" not in pair
assert "TilingFrameWritePlan" in writer
assert "AXEnhancedUserInterface" not in writer
assert "if framePipeline.isActive" in source
assert "framePipeline.shutdown()" in source
assert "AXUIElementSetAttributeValue" not in animation
assert "AXUIElementSetAttributeValue" not in live_resize + overlay_resize
assert "requiresCoupledWrites" not in animation
assert "func showResizePreviews(frames:" in overlay

print("PASS: source guards for live/preview resize and stale-readback constraint regression (not visual verification)")
