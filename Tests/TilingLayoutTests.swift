import CoreGraphics
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TilingLayoutTests {
    static func main() {
        expect(TilingLayout.keepsPendingTabSelection(target: 2, previousFocus: 1,
                                                     observedFocus: 1, age: 0.2),
               "an outgoing focus snapshot must not undo an explicit tab switch")
        expect(!TilingLayout.keepsPendingTabSelection(target: 2, previousFocus: 1,
                                                      observedFocus: 2, age: 0.2),
               "the pending selection settles when the new tab gains focus")
        expect(!TilingLayout.keepsPendingTabSelection(target: 2, previousFocus: 1,
                                                      observedFocus: 3, age: 0.2),
               "a different user focus must supersede the pending selection")
        expect(!TilingLayout.keepsPendingTabSelection(target: 2, previousFocus: 1,
                                                      observedFocus: 1, age: 1.5),
               "a failed activation must not pin the selected tab forever")
        let bounds = CGRect(x: 4, y: 4, width: 992, height: 792)
        let leftTabs = TilingLayout.columnPillSides(windowIDs: [1, 2, 3],
                                                    mainTabIDs: [1, 2], masterID: 1, enabled: true)
        expect(leftTabs.left && !leftTabs.right,
               "a left tab stack must reserve only the left screen-edge rail")
        let rightTabs = TilingLayout.columnPillSides(windowIDs: [1, 2, 3],
                                                     mainTabIDs: [1], masterID: 1, enabled: true)
        expect(!rightTabs.left && rightTabs.right,
               "a right tab stack must reserve only the right screen-edge rail")
        let bothTabs = TilingLayout.columnPillSides(windowIDs: [1, 2, 3, 4],
                                                    mainTabIDs: [1, 2], masterID: 1, enabled: true)
        let edgeAtZero = TilingLayout.columnPillGeometry(in: bounds, gap: 0,
                                                          left: bothTabs.left, right: bothTabs.right,
                                                          edgeAttached: true)
        let insetAtZero = TilingLayout.columnPillGeometry(in: bounds, gap: 0,
                                                           left: bothTabs.left, right: bothTabs.right,
                                                           edgeAttached: false)
        expect(edgeAtZero.leftRail?.width == 9 && insetAtZero.leftRail?.width == 11,
               "rail width must adapt to the pill alignment instead of staying fixed")
        expect(edgeAtZero.work.height == bounds.height && insetAtZero.work.height == bounds.height,
               "side rails must not consume vertical window space")
        let edgeGlyphInner = edgeAtZero.leftRail!.minX + TilingLayout.columnPillEdgeOffset + TilingLayout.columnPillThickness
        let insetGlyphInner = insetAtZero.leftRail!.midX + TilingLayout.columnPillThickness / 2
        expect(edgeAtZero.work.minX - edgeGlyphInner == 4.5 &&
               insetAtZero.work.minX - insetGlyphInner == 4,
               "both modes should place the window about four points from the painted pill")
        let disabledTabs = TilingLayout.columnPillSides(windowIDs: [1, 2, 3, 4],
                                                        mainTabIDs: [1, 2], masterID: 1, enabled: false)
        expect(!disabledTabs.left && !disabledTabs.right,
               "turning column pills off must return both side rails to windows")
        let edgeRails = TilingLayout.columnPillGeometry(in: bounds, gap: 4,
                                                         left: true, right: true,
                                                         edgeAttached: true)
        let insetRails = TilingLayout.columnPillGeometry(in: bounds, gap: 4,
                                                          left: true, right: true,
                                                          edgeAttached: false)
        expect(edgeRails.leftRail?.minX == bounds.minX &&
               edgeRails.rightRail?.maxX == bounds.maxX,
               "Screen Edge mode must attach both rails to the usable display edges")
        expect(insetRails.leftRail?.minX == bounds.minX + 4 &&
               insetRails.rightRail?.maxX == bounds.maxX - 4,
               "Inset mode must preserve the original outer tiling gap")
        expect(edgeRails.work.minX < insetRails.work.minX &&
               edgeRails.work.minX >= edgeRails.leftRail!.maxX &&
               edgeRails.work.maxX <= edgeRails.rightRail!.minX,
               "either mode must reserve rail space without covering a window")
        let largeGap = TilingLayout.columnPillGeometry(in: bounds, gap: 18,
                                                        left: true, right: false,
                                                        edgeAttached: true)
        expect(largeGap.work.minX == bounds.minX + 18,
               "a larger user-configured outer padding remains a minimum")
        expect(TilingLayout.orderedColumnTabs([1, 2, 3], barOrder: [3, 1, 2]) == [3, 1, 2],
               "pill tab order must match the swipe switcher's bar order")
        expect(TilingLayout.verticalPillIndex(tabIndex: 0, count: 3) == 3 &&
               TilingLayout.verticalPillIndex(tabIndex: 1, count: 3) == 2,
               "advancing a tab must move the pill upward with the window transition")
        expect(TilingLayout.containsIncludingEdges(CGPoint(x: bounds.midX, y: bounds.maxY), in: bounds),
               "a pointer stopped exactly at the screen top edge must remain inside the reveal zone")
        expect(!TilingLayout.containsIncludingEdges(CGPoint(x: bounds.midX, y: bounds.maxY + 0.01), in: bounds),
               "a point beyond the screen edge must remain outside the reveal zone")
        let dockAnchoredStart = CGRect(x: 900, y: 0, width: 549, height: 949)
        let dockAnchoredTarget = CGRect(x: 760, y: 0, width: 689, height: 949)
        let dockMidFrame = TilingLayout.interpolatedAlignedFrame(from: dockAnchoredStart,
                                                                 to: dockAnchoredTarget,
                                                                 progress: 0.5)
        expect(dockMidFrame.maxX == 1449,
               "frame animation must keep the Dock-adjacent edge pixel-stable")
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let fullWork = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let rightDock = CGRect(x: 1450, y: 120, width: 62, height: 740)
        let reserved = TilingLayout.excludingFixedDock(fullWork, screen: screen,
                                                        dock: rightDock, orientation: "right")
        expect(reserved.maxX == rightDock.minX,
               "fixed right Dock must constrain tiles even if visibleFrame does not")
        let axDock = CGRect(x: 1445, y: 124, width: 57, height: 701)
        expect(TilingLayout.excludingFixedDock(fullWork, screen: screen,
                                                dock: axDock, orientation: "right").maxX == 1445,
               "the Dock Accessibility frame must reserve its actual inset")
        let hiddenAXDock = CGRect(x: 1512, y: 124, width: 57, height: 701)
        expect(TilingLayout.excludingFixedDock(fullWork, screen: screen,
                                                dock: hiddenAXDock, orientation: "right") == fullWork,
               "a Dock AX frame fully outside the display must not reserve space")
        let alreadyVisible = CGRect(x: 0, y: 0, width: 1444, height: 949)
        expect(TilingLayout.excludingFixedDock(alreadyVisible, screen: screen,
                                                dock: rightDock, orientation: "right") == alreadyVisible,
               "Dock reservation must not double-inset an accurate visibleFrame")
        expect(TilingLayout.excludingFixedDock(fullWork, screen: screen,
                                                dock: nil, orientation: "right") == fullWork,
               "an auto-hidden or absent Dock must not reserve space")
        let leftDock = CGRect(x: 0, y: 120, width: 60, height: 740)
        expect(TilingLayout.excludingFixedDock(fullWork, screen: screen,
                                                dock: leftDock, orientation: "left").minX == 60,
               "fixed left Dock must constrain tiles")
        let bottomDock = CGRect(x: 200, y: 0, width: 1000, height: 70)
        expect(TilingLayout.excludingFixedDock(screen, screen: screen,
                                                dock: bottomDock, orientation: "bottom").minY == 70,
               "fixed bottom Dock must constrain tiles")
        let springStart = CGRect(x: 100, y: 50, width: 500, height: 700)
        let springTarget = CGRect(x: 20, y: 50, width: 580, height: 700)
        let springAtZero = TilingLayout.springFrame(from: springStart, to: springTarget, elapsed: 0)
        expect(springAtZero.frame == springStart,
               "spring must begin at the current presented frame")
        let springMid = TilingLayout.springFrame(from: springStart, to: springTarget, elapsed: 0.10)
        expect(springMid.frame.minX < springStart.minX && springMid.frame.minX > springTarget.minX,
               "spring must move toward the target without jumping past it")
        expect(springMid.frame.maxX == springStart.maxX,
               "spring resize must keep an unchanged outer edge anchored")
        let springEnd = TilingLayout.springFrame(from: springStart, to: springTarget, elapsed: 0.32)
        expect(abs(springEnd.frame.minX - springTarget.minX) <= 1,
               "spring must visually settle before its final commit")
        let redirectedTarget = CGRect(x: 180, y: 50, width: 420, height: 700)
        let redirected = TilingLayout.springFrame(from: springMid.frame, to: redirectedTarget,
                                                   initialVelocity: springMid.velocity, elapsed: 0.04)
        expect(redirected.frame.minX >= springMid.frame.minX && redirected.frame.minX <= redirectedTarget.minX,
               "a reversed retarget must remain bounded between its current frame and new target")
        let tree = TilingTree.leaf(1)
            .inserting(2, beside: 1, targetFrame: CGRect(x: 0, y: 0, width: 1200, height: 600))
        let two = tree.frames(in: bounds, gap: 4)
        expect(two.count == 2, "split tree should place two windows")
        expect(abs((two[1]?.minY ?? 0) - (two[2]?.maxY ?? 0) - 4) < 0.01,
               "wide-window split should keep a four point row gap")

        let pruned = tree.removing(ids: [2])
        expect(pruned == .leaf(1), "removing one branch should collapse its parent")

        let master = TilingLayout.masterStackFrames(windowIDs: [1, 2, 3], masterID: 2,
                                                     in: bounds, gap: 4)
        expect(master.count == 3, "master stack should place every window")
        expect(master[2]?.width == master[1]?.width, "the initial two-column layout should be balanced")
        expect(master[1] == master[3],
               "tabbed windows should share the same frame")
        let dualTabs = TilingLayout.masterStackFrames(windowIDs: [1, 2, 3, 4], masterID: 2,
                                                       mainTabIDs: [1, 2], in: bounds, gap: 4)
        expect(dualTabs[1] == dualTabs[2], "main tabs should share the left frame")
        expect(dualTabs[3] == dualTabs[4], "stack tabs should share the right frame")
        expect(dualTabs[1]!.maxX < dualTabs[3]!.minX,
               "the two independent tab groups must remain in separate columns")
        expect(TilingLayout.windowStatus(mode: .masterStack, paused: false, focusedID: 2,
                                         masterID: 2, floatingIDs: []) == .leftTabbed,
               "focused left-column tab should report Left Column")
        expect(TilingLayout.windowStatus(mode: .masterStack, paused: false, focusedID: 3,
                                         masterID: 2, floatingIDs: []) == .rightTabbed,
               "focused right-column tab should report Right Column")
        expect(TilingLayout.windowStatus(mode: .masterStack, paused: false, focusedID: 1,
                                         masterID: 2, mainTabIDs: [1, 2], floatingIDs: []) == .leftTabbed,
               "an inactive left-group window should report Left Column")
        expect(TilingLayout.windowStatus(mode: .masterStack, paused: false, focusedID: 3,
                                         masterID: 2, floatingIDs: [3]) == .floating,
               "floating status should take priority over the layout role")
        expect(TilingLayout.windowStatus(mode: .masterStack, paused: true, focusedID: 2,
                                         masterID: 2, floatingIDs: []) == .paused,
               "paused status should take priority")
        let movedLeftTab = TilingLayout.movingTab(
            2, onto: 3, orderedIDs: [1, 2, 3], leftIDs: [1, 2],
            leftActiveID: 2, rightActiveID: 3)
        expect(movedLeftTab.leftIDs == [1] && movedLeftTab.leftActiveID == 1 &&
               movedLeftTab.rightActiveID == 2,
               "moving a left tab right must leave the other left tab in place")
        let movedFinalLeftTab = TilingLayout.movingTab(
            1, onto: 2, orderedIDs: [1, 2, 3], leftIDs: [1],
            leftActiveID: 1, rightActiveID: 2)
        expect(movedFinalLeftTab.leftIDs.isEmpty && movedFinalLeftTab.leftActiveID == nil &&
               movedFinalLeftTab.rightActiveID == 1,
               "tabbing the final left window right must collapse to one right-side stack")
        let movedRightTab = TilingLayout.movingTab(
            3, onto: 1, orderedIDs: [1, 2, 3], leftIDs: [1],
            leftActiveID: 1, rightActiveID: 3)
        expect(movedRightTab.leftIDs == [1, 3] && movedRightTab.leftActiveID == 3 &&
               movedRightTab.rightActiveID == 2,
               "moving a right tab left must activate it and keep the remaining right tab")
        let swappedTabs = TilingLayout.swappingTabs(3, with: 1, leftIDs: [1, 2])
        expect(swappedTabs?.leftIDs == [2, 3] && swappedTabs?.leftActiveID == 3 &&
               swappedTabs?.rightActiveID == 1,
               "the outer edge must swap only the dragged and target windows")
        expect(TilingLayout.swappingTabs(2, with: 1, leftIDs: [1, 2]) == nil,
               "tabs already in one column cannot perform a cross-column swap")
        expect(TilingLayout.masterIDForTabbedAssignment(windowIDs: [1, 2, 3], currentMasterID: 1, assignedID: 3) == 1,
               "assigning an existing stack window should preserve the current master")
        expect(TilingLayout.masterIDForTabbedAssignment(windowIDs: [1, 2, 3], currentMasterID: 1, assignedID: 1) == 2,
               "assigning the master to stack should promote the first remaining window")
        expect(TilingLayout.masterIDForTabbedAssignment(windowIDs: [1], currentMasterID: 1, assignedID: 1) == nil,
               "a single window cannot be assigned to a stack")
        expect(TilingLayout.masterIDForTabbedAssignment(windowIDs: [1, 2], currentMasterID: nil, assignedID: 2) == 1,
               "assigning from split mode should choose another window as master")
        expect(TilingLayout.visibleMasterID(windowIDs: [1, 2, 3], masterID: 1,
                                            visibleIDs: [2, 3]) == 2,
               "a missing master should temporarily promote the first visible window")
        expect(TilingLayout.visibleMasterID(windowIDs: [1, 2, 3], masterID: 1,
                                            visibleIDs: [1, 3]) == 1,
               "a visible persisted master must keep the left column")
        expect(TilingLayout.shouldAutoRemoveSpace(isUserSpace: true, isCurrent: false,
                                                   userSpaceCount: 4, hasApplicationWindows: false,
                                                   emptyDuration: 5.0),
               "the last-position empty desktop may be removed after five seconds")
        expect(!TilingLayout.shouldAutoRemoveSpace(isUserSpace: true, isCurrent: false,
                                                    userSpaceCount: 1, hasApplicationWindows: false,
                                                    emptyDuration: 30),
               "macOS must retain one desktop per display")
        expect(!TilingLayout.shouldAutoRemoveSpace(isUserSpace: true, isCurrent: true,
                                                    userSpaceCount: 4, hasApplicationWindows: false,
                                                    emptyDuration: 30),
               "the active desktop must never be removed")
        expect(!TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.finder", identifier: nil,
            subrole: "AXStandardWindow", document: "file:///Users/test"),
            "a Finder folder window should join the two-column layout")
        expect(TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.finder", identifier: nil,
            subrole: "AXStandardWindow", document: nil),
            "a Finder Get Info window without a document URL must float")
        expect(TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.finder", identifier: nil,
            subrole: "AXDialog", document: nil),
            "a Finder dialog must float")
        expect(!TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.TextEdit", identifier: nil,
            subrole: "AXStandardWindow", document: nil),
            "non-Finder windows must not be classified by Finder rules")
        // An Open dialog is a standard, resizable window by every other signal.
        expect(TilingLayout.shouldAutomaticallyFloat(
            bundleID: "company.thebrowser.dia", identifier: "open-panel",
            subrole: "AXStandardWindow", document: nil),
            "an app's own Open dialog must float")
        expect(TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.TextEdit", identifier: "save-panel",
            subrole: "AXStandardWindow", document: nil),
            "an app's own Save dialog must float")
        expect(TilingLayout.shouldAutomaticallyFloat(
            bundleID: "com.apple.appkit.xpc.openAndSavePanelService", identifier: nil,
            subrole: "AXStandardWindow", document: nil),
            "a sandboxed app's file dialog, which lives in the panel service, must float")
        expect(!TilingLayout.shouldAutomaticallyFloat(
            bundleID: "company.thebrowser.dia", identifier: "bigBrowserWindow_AB9AD08D",
            subrole: "AXStandardWindow", document: nil),
            "an ordinary window with an identifier must still tile")

        // A window that refuses to shrink must widen its own tile rather than
        // lie over its neighbour.
        let overflowFrames = TilingLayout.masterStackFrames(
            windowIDs: [1, 2], masterID: 1,
            in: CGRect(x: 5, y: 38, width: 1502, height: 939), gap: 5,
            masterRatio: 0.2, minWidths: [1: 500])
        expect(overflowFrames[1]!.width >= 500, "a tile must not be narrower than what its window can shrink to")
        expect(overflowFrames[1]!.maxX <= overflowFrames[2]!.minX,
               "the master tile must stop before the stack tile begins")
        expect(TilingLayout.masterWidth(available: 1000, masterRatio: 0.5) == 500,
               "a ratio with no minimums is unchanged")
        expect(TilingLayout.masterWidth(available: 1000, masterRatio: 0.2, masterMinWidth: 500) == 500,
               "the master's own minimum raises a too-small ratio")
        expect(TilingLayout.masterWidth(available: 1000, masterRatio: 0.8, stackMinWidth: 400) == 600,
               "the stack's minimum caps a too-large ratio")
        expect(TilingLayout.masterWidth(available: 600, masterRatio: 0.5,
                                        masterMinWidth: 500, stackMinWidth: 500) == 300,
               "minimums that cannot both fit leave the ratio alone")
        let divs = TilingLayout.dividers(mode: .masterStack, tree: .split(axis: .columns, ratio: 0.5,
                                                                          first: .leaf(1), second: .leaf(2)),
                                         masterID: 1, masterRatio: 0.2,
                                         in: CGRect(x: 5, y: 38, width: 1502, height: 939), gap: 5,
                                         minWidths: [1: 500])
        expect(divs.first!.coordinate >= 505, "the handle sits on the edge the windows actually have")
        expect(divs.first!.minCoordinate >= 505, "dragging must not re-open the overlap")

        expect(tree.inserting(1, beside: 2, targetFrame: bounds) == tree, "duplicate discovery must not add a second leaf")
        let columns = TilingTree.split(axis: .columns, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        let original = columns.frames(in: bounds, gap: 4)
        let left = original[1]!
        let right = original[2]!
        let widerLeft = CGRect(x: left.minX, y: left.minY, width: left.width + 80, height: left.height)
        let resized = columns.resized(windowID: 1, from: left, to: widerLeft, in: bounds, gap: 4)
        let resizedFrames = resized.frames(in: bounds, gap: 4)
        expect(abs(resizedFrames[1]!.width - widerLeft.width) <= 1, "right-edge drag should grow the left tile")
        expect(abs(resizedFrames[2]!.minX - resizedFrames[1]!.maxX - 4) < 0.01, "resize must preserve the gap")
        let smallerRight = CGRect(x: right.minX + 80, y: right.minY, width: right.width - 80, height: right.height)
        expect(columns.resized(windowID: 2, from: right, to: smallerRight, in: bounds, gap: 4) == resized,
               "dragging either side of a shared boundary should have the same result")
        expect(columns.resized(windowID: 1, from: left, to: left.offsetBy(dx: 100, dy: 80), in: bounds, gap: 4) == columns,
               "moving a window must not change its split proportions")
        let outerResize = CGRect(x: left.minX - 50, y: left.minY, width: left.width + 50, height: left.height)
        expect(columns.resized(windowID: 1, from: left, to: outerResize, in: bounds, gap: 4) == columns,
               "dragging an outer edge must not move an inner boundary")
        let top = two[1]!
        let tallerTop = CGRect(x: top.minX, y: top.minY - 60, width: top.width, height: top.height + 60)
        let rowsResized = tree.resized(windowID: 1, from: top, to: tallerTop, in: bounds, gap: 4).frames(in: bounds, gap: 4)
        expect(abs(rowsResized[1]!.height - tallerTop.height) <= 1, "bottom-edge drag must grow the top row")
        let nested = TilingTree.split(axis: .columns, ratio: 0.5,
            first: .split(axis: .rows, ratio: 0.5, first: .leaf(1), second: .leaf(3)), second: .leaf(2))
        let nestedOriginal = nested.frames(in: bounds, gap: 4)[1]!
        for delta in stride(from: -1200, through: 1200, by: 20) {
            let proposed = CGRect(x: nestedOriginal.minX, y: nestedOriginal.minY - CGFloat(delta),
                                  width: max(1, nestedOriginal.width + CGFloat(delta)),
                                  height: max(1, nestedOriginal.height + CGFloat(delta)))
            let result = nested.resized(windowID: 1, from: nestedOriginal, to: proposed, in: bounds, gap: 4)
            let frames = result.frames(in: bounds, gap: 4)
            expect(Set(frames.keys) == [1, 2, 3], "nested resize must preserve window identity")
            for frame in frames.values {
                expect(frame.width > 0 && frame.height > 0 && bounds.contains(frame), "clamped resize must remain within the display")
            }
            expect(!frames[1]!.intersects(frames[2]!) && !frames[1]!.intersects(frames[3]!) && !frames[2]!.intersects(frames[3]!),
                   "nested resize must not overlap siblings")
        }
        let beforeSwap = nested.frames(in: bounds, gap: 4)
        let swapped = nested.swapping(1, with: 2)
        let afterSwap = swapped.frames(in: bounds, gap: 4)
        expect(afterSwap[1] == beforeSwap[2], "swap must exchange slot 1 and 2")
        expect(afterSwap[2] == beforeSwap[1], "swap must exchange slot 2 and 1")
        expect(afterSwap[3] == beforeSwap[3], "swap must preserve slot 3")
        expect(swapped.swapping(1, with: 2) == nested, "swapping twice must restore the exact layout")
        expect(nested.swapping(1, with: 999) == nested, "a stale drag target must not replace a window")
        let startFrame = beforeSwap[1]!
        let movedFrame = startFrame.offsetBy(dx: 150, dy: -30)
        let drop = CGPoint(x: beforeSwap[2]!.midX, y: beforeSwap[2]!.midY)
        expect(TilingLayout.dropTarget(movingID: 1, from: startFrame, to: movedFrame, pointer: drop, slots: beforeSwap) == 2,
               "dragging into another tile must select that tile")
        expect(TilingLayout.dropTarget(movingID: 1, from: startFrame, to: startFrame, pointer: drop, slots: beforeSwap) == nil,
               "clicks must not swap windows")
        expect(TilingLayout.dropTarget(movingID: 1, from: startFrame, to: movedFrame.insetBy(dx: -20, dy: 0), pointer: drop, slots: beforeSwap) == nil,
               "resize must not become a swap")
        expect(TilingLayout.dropTarget(movingID: 1, from: startFrame, to: movedFrame, pointer: CGPoint(x: -100, y: -100), slots: beforeSwap) == nil,
               "dropping outside tiles must not reorder them")
        expect(TilingLayout.dropTarget(movingID: 1, from: startFrame, to: movedFrame, pointer: CGPoint(x: startFrame.midX, y: startFrame.midY), slots: beforeSwap) == nil,
               "dropping on the original slot must not swap")
        let leftColumn = CGRect(x: 0, y: 0, width: 400, height: 700)
        let groupedColumns = TilingWindowStatus.groupedForColumns(
            [(1, TilingWindowStatus.rightTabbed), (2, .leftTabbed),
             (3, .rightTabbed), (4, .leftTabbed), (5, .floating)]) { $0.1 }.map(\.0)
        expect(groupedColumns == [2, 4, 1, 3, 5],
               "all left and right tabs must remain contiguous in their original per-column order")
        let rightColumn = CGRect(x: 404, y: 0, width: 400, height: 700)
        let columnSlots: [CGWindowID: CGRect] = [1: leftColumn, 2: rightColumn]
        let rightToLeftMove = rightColumn.offsetBy(dx: -120, dy: 0)
        let leftSwap = TilingLayout.columnDropPlacement(
            movingID: 2, from: rightColumn, to: rightToLeftMove,
            pointer: CGPoint(x: 50, y: 350), slots: columnSlots,
            leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(leftSwap?.kind == .swap && leftSwap?.previewFrame == leftColumn,
               "the outer-left half of a left target must swap, previewing the whole column")
        let leftTab = TilingLayout.columnDropPlacement(
            movingID: 2, from: rightColumn, to: rightToLeftMove,
            pointer: CGPoint(x: 250, y: 350), slots: columnSlots,
            leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(leftTab?.kind == .tab && leftTab?.previewFrame == leftColumn.union(rightColumn),
               "the inner half of a left target must tab into the left stack")
        let unchangedAfterDrop = TilingLayout.columnDropPlacement(
            movingID: 2, from: rightColumn, to: rightColumn,
            pointer: CGPoint(x: 250, y: 350), dragStart: CGPoint(x: 600, y: 350),
            slots: columnSlots, leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(unchangedAfterDrop?.kind == .tab,
               "a window snapping back before the drop scan must still tab from its pointer gesture")
        let resizedDuringDrag = TilingLayout.columnDropPlacement(
            movingID: 2, from: rightColumn, to: rightColumn.insetBy(dx: 4, dy: 0),
            pointer: CGPoint(x: 250, y: 350), dragStart: CGPoint(x: 600, y: 350),
            slots: columnSlots, leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(resizedDuringDrag?.kind == .tab,
               "a harmless size change during title-bar dragging must not cancel a tab drop")
        let noDrag = TilingLayout.columnDropPlacement(
            movingID: 2, from: rightColumn, to: rightColumn,
            pointer: CGPoint(x: 250, y: 350), dragStart: CGPoint(x: 249, y: 350),
            slots: columnSlots, leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(noDrag == nil, "a click without a drag must not move a tab")
        let fullColumn = CGRect(x: 0, y: 0, width: 800, height: 700)
        let oneColumn: [CGWindowID: CGRect] = [1: fullColumn, 2: fullColumn]
        let splitRight = TilingLayout.columnDropPlacement(
            movingID: 2, from: fullColumn, to: fullColumn.offsetBy(dx: 120, dy: 0),
            pointer: CGPoint(x: 600, y: 350), slots: oneColumn,
            leftIDs: [1, 2], leftActiveID: 2, rightActiveID: nil)
        expect(splitRight?.kind == .split(left: false) &&
               splitRight?.previewFrame == CGRect(x: 400, y: 0, width: 400, height: 700),
               "dragging within a single column must split it, previewing the half it lands in")
        let splitLeft = TilingLayout.columnDropPlacement(
            movingID: 2, from: fullColumn, to: fullColumn.offsetBy(dx: -120, dy: 0),
            pointer: CGPoint(x: 100, y: 350), slots: oneColumn,
            leftIDs: [1, 2], leftActiveID: 2, rightActiveID: nil)
        expect(splitLeft?.kind == .split(left: true), "the left half of a single column must split left")
        let splitColumns = TilingLayout.splittingColumn(2, toLeft: false, orderedIDs: [1, 2],
                                                        leftActiveID: 2, rightActiveID: nil)
        expect(splitColumns == TilingColumnAssignment(leftIDs: [1], leftActiveID: 1, rightActiveID: 2),
               "a right split must leave the other windows as the left column")
        let tabKeepsColumn = TilingLayout.columnDropPlacement(
            movingID: 3, from: rightColumn, to: rightColumn.offsetBy(dx: -120, dy: 0),
            pointer: CGPoint(x: 250, y: 350), slots: [1: leftColumn, 2: rightColumn, 3: rightColumn],
            leftIDs: [1], leftActiveID: 1, rightActiveID: 3)
        expect(tabKeepsColumn?.previewFrame == leftColumn,
               "a tab that leaves windows behind in its column must preview only the target column")
        let ownColumn = TilingLayout.columnDropPlacement(
            movingID: 3, from: rightColumn, to: rightColumn.offsetBy(dx: 0, dy: 60),
            pointer: CGPoint(x: 600, y: 350), slots: [1: leftColumn, 2: rightColumn, 3: rightColumn],
            leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(ownColumn == nil, "a drag over a tab of its own column must do nothing while two columns exist")
        let leftToRightMove = leftColumn.offsetBy(dx: 120, dy: 0)
        let rightSwap = TilingLayout.columnDropPlacement(
            movingID: 1, from: leftColumn, to: leftToRightMove,
            pointer: CGPoint(x: 780, y: 350), slots: columnSlots,
            leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(rightSwap?.kind == .swap && rightSwap?.previewFrame == rightColumn,
               "the outer-right half of a right target must be its only swap zone")
        let rightTab = TilingLayout.columnDropPlacement(
            movingID: 1, from: leftColumn, to: leftToRightMove,
            pointer: CGPoint(x: 500, y: 350), slots: columnSlots,
            leftIDs: [1], leftActiveID: 1, rightActiveID: 2)
        expect(rightTab?.kind == .tab && rightTab?.previewFrame == leftColumn.union(rightColumn),
               "the inner half of a right target must tab into the right stack")
        let resizedAgain = nested.resized(windowID: 1, from: startFrame, to: startFrame, in: bounds, gap: 4)
        expect(resizedAgain == nested, "returning a live resize to its starting frame must restore its ratios")

        // Divider tests
        let nestedDividers = TilingLayout.dividers(mode: .splitTree, tree: nested, masterID: nil, masterRatio: 0.6, in: bounds, gap: 4)
        expect(nestedDividers.count == 2, "nested tree with 3 windows must produce exactly 2 dividers")
        let colDivider = nestedDividers.first { $0.axis == .vertical }!
        expect(colDivider.span == (bounds.minY...bounds.maxY), "column divider must span the entire work height")
        expect(colDivider.firstWindowIDs == [1, 3] && colDivider.secondWindowIDs == [2], "first and second window IDs must match sides")
        let rowDivider = nestedDividers.first { $0.axis == .horizontal }!
        expect(rowDivider.firstWindowIDs == [1] && rowDivider.secondWindowIDs == [3], "row divider window IDs must match top/bottom")

        // Test updatingRatio directly on tree
        let updatedTree = nested.updatingRatio(at: colDivider.treePath!, to: 0.7)
        let updatedFrames = updatedTree.frames(in: bounds, gap: 4)
        expect(updatedFrames[2]!.width < beforeSwap[2]!.width, "growing left column must shrink right window")

        // Test ratio computation from coordinate
        let midCoord = (colDivider.minCoordinate + colDivider.maxCoordinate) / 2
        let calculatedRatio = TilingLayout.ratio(for: colDivider, at: midCoord, gap: 4)
        expect(abs(calculatedRatio - 0.5) < 0.05, "midpoint coordinate must map to ~0.5 ratio")

        // Master-stack dividers
        let masterDividers = TilingLayout.dividers(mode: .masterStack, tree: nested, masterID: 1, masterRatio: 0.6, in: bounds, gap: 4)
        expect(masterDividers.count == 1, "master stack must produce a vertical divider between master and stack")
        expect(masterDividers[0].firstWindowIDs == [1], "master side must contain master window")
        let dualTabDividers = TilingLayout.dividers(mode: .masterStack, tree: nested, masterID: 1,
                                                     mainTabIDs: [1, 3], masterRatio: 0.6,
                                                     in: bounds, gap: 4)
        expect(dualTabDividers[0].firstWindowIDs == [1, 3],
               "the divider must resize every tab in the main group")
        expect(dualTabDividers[0].secondWindowIDs == [2],
               "the divider must keep stack-group membership separate")

        print("TilingLayoutTests passed: insertion, pruning, master stack, both resize axes, nested boundaries and clamps, dividers and ratio math")
    }
}
