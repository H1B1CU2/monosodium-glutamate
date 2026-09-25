#!/usr/bin/env python3
"""Source guards for the automatic two-column tiling workflow."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
controller = (root / "MSG/TilingController.swift").read_text()
layout = (root / "MSG/TilingLayout.swift").read_text()
settings = (root / "MSG/Settings.swift").read_text()
pane = (root / "MSG/TilingPane.swift").read_text()
bar = (root / "MSG/TilingControlBar.swift").read_text()

assert "var mode: TilingLayoutMode = .masterStack" in controller
assert "var masterRatio: CGFloat = 0.50" in controller
assert "state.mode = .masterStack" in controller
assert "settings.tilingMasterRatio(for: key.displayUUID)" in controller
assert controller.count("settings.setTilingMasterRatio(") >= 2
assert "!$0.automaticallyFloating" in controller
assert "TilingLayout.shouldAutomaticallyFloat(" in controller
assert "shouldAutomaticallyFloat(" in layout
assert 'static let tilingMasterRatios' in settings
assert 'UserDefaults.standard.set(stored, forKey: Key.tilingMasterRatios)' in settings
assert 'static let tilingPillScope' in settings
assert 'static let tilingOneAppPerDeskspace' in settings
assert 'static let tilingAutoDeleteEmptySpaces' in settings
assert 'Key.tilingOneAppPerDeskspace:  true' in settings
assert 'Key.tilingAutoDeleteEmptySpaces: false' in settings
assert 'TilingPillScope.currentSpace.rawValue' in settings
assert 'Picker("Shown-window pill"' in pane
assert 'case currentSpace = "Current Deskspace"' in controller
assert 'case allSpaces = "All Deskspaces"' in controller
assert 'shownWindowIDsBySpace' in controller
assert 'orderedWindowIDsBySpace' in controller
assert 'stableOrderedWindows' in controller
assert 'mappedSpace ?? cachedValue.window.spaceNumber' in controller
assert 'self.scheduleRefresh(after: 0.35)' in controller
assert 'cachedShownWindowIDs(' in controller
assert 'withShownInLayout(targetShown.contains' in controller
assert 'without waiting for the slower layout reconciliation pass' in controller
assert 'shouldRemoveWindowFromSpace(' in controller
assert 'guard !memberships.isEmpty else { return false }' in controller
assert 'state.mainTabIDs.contains(state.masterID!)' in controller
assert 'Button("Move Focused Window to Left Column")' in pane
assert '"Remove empty Deskspaces"' in pane
assert '"One app per Deskspace"' in pane
assert 'isOn: $vm.tilingOneAppPerDeskspace' in pane
assert 'isOn: $vm.tilingAutoDeleteEmptySpaces' in pane
assert 'scanForEmptySpacesIfNeeded()' in controller
assert 'emptyDuration: now - emptySince' in controller
assert 'spaceID != currentID, userSpaceCount > 1' in controller
assert '"AXRemoveDesktop" as CFString' in controller
assert '"/System/Applications/Mission Control.app"' in controller
assert 'orderedVisibleIDs' in controller
assert 'masterID: activeMasterID' in controller
assert 'Make Focused Window Tabbed' not in pane
assert 'Make Focused Window Master / Use Split' not in pane
assert '"Move to Left Column"' in bar
assert '"Move to Right Column"' in bar
assert 'var mainTabIDs: Set<CGWindowID> = []' in controller
assert 'var stackID: CGWindowID?' in controller
assert 'mainTabIDs: state.mainTabIDs' in controller
assert 'TilingLayout.movingTab(' in controller
assert 'TilingLayout.columnDropPlacement(' in controller
assert 'if self.commitColumnDropFromGesture()' in controller
assert 'dragStart: dragStartPoint' in controller
assert 'TilingLayout.swappingTabs(' in controller
assert 'width: edgeWidth' in layout
assert 'width: targetFrame.width - edgeWidth' in layout
assert '"Floating (Automatic)"' in bar
assert "window.isShownInLayout" in bar
assert "if groupEnd - groupStart >= 2 {" in bar
assert "hasOtherColumn" not in bar
assert "if spaceChanged {" in bar
assert "columnChanged" not in bar
assert "columnGap" not in bar
assert "TilingWindowStatus.groupedForColumns(orderedWindows)" in controller
assert "case .leftTabbed: return 0" in bar
assert "case .rightTabbed: return 1" in bar
assert "NSBezierPath(roundedRect: groupRect" in bar
assert "drawShownPill(for item:" in bar
assert "startShownPillAnimation(from:" in bar
assert "startShownPillTravel(from:" in bar
assert "shownPillTravelStarts" in bar
assert "!oldShown.isEmpty && !newShown.isEmpty" in bar
assert "4 * sin(travel * .pi)" in bar
assert "let positionChanged = abs(rect.midX - item.rect.midX) > 0.75" in bar
assert "let movementStretch = motionStart == nil ? 0" in bar
assert "requestClickedPillPop(windowID: item.window.windowID)" in bar
assert "startClickedPillPop(windowID:" in bar
assert "let clickedPopArrived" in bar
assert "settleShownPills(newShown)" in bar
assert "let stretch = max(movementStretch, clickStretch)" in bar
assert "outgoing = originalCandidates.first" in bar
assert "both pills visibly split and travel" in bar
assert "TilingDisplayClock.interval(for: window?.screen)" in bar
assert "0.32 * progress * alpha" in bar
assert "FLIP-style repositioning" in bar
assert "oldRect.minX + (targetRect.minX - oldRect.minX) * progress" in bar
assert "animatedRect.minX - targetRect.minX" in bar
assert "let spaceChanged = isAllSpaces" in bar
assert "onAssignTabbed" not in controller + bar
assert "onUseSplit" not in controller + bar

print("PASS: automatic two-column layout, per-display ratio memory and Finder floating guards")
