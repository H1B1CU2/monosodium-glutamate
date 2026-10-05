import CoreGraphics

enum TilingLayoutMode: String {
    case splitTree
    case masterStack
}

enum TilingWindowStatus: String {
    case split = "Split"
    case leftTabbed = "Left Column"
    case rightTabbed = "Right Column"
    case floating = "Floating"
    case paused = "Paused"
}

/// Keep each column's tabs together without disturbing the user's existing
/// order inside either group. Non-column windows stay after the two groups.
extension TilingWindowStatus {
    static func groupedForColumns<Item>(_ items: [Item], status: (Item) -> TilingWindowStatus) -> [Item] {
        items.filter { status($0) == .leftTabbed } +
            items.filter { status($0) == .rightTabbed } +
            items.filter { status($0) != .leftTabbed && status($0) != .rightTabbed }
    }
}

enum TilingSplitAxis: String {
    case columns
    case rows
}

/// Runtime tree for one native macOS Space. Window ids are intentionally not
/// persisted: WindowServer can reuse them after an app exits.
indirect enum TilingTree: Equatable {
    case leaf(CGWindowID)
    case split(axis: TilingSplitAxis, ratio: CGFloat, first: TilingTree, second: TilingTree)

    var windowIDs: [CGWindowID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.windowIDs + second.windowIDs
        }
    }

    func inserting(_ newID: CGWindowID, beside targetID: CGWindowID?, targetFrame: CGRect?) -> TilingTree {
        guard !windowIDs.contains(newID) else { return self }
        let target = targetID.flatMap { windowIDs.contains($0) ? $0 : nil } ?? windowIDs.last
        guard let target else { return .leaf(newID) }
        switch self {
        case .leaf(let id) where id == target:
            // Wide windows divide into rows like the reference layout; tall or
            // near-square windows divide into columns.
            let frame = targetFrame ?? .zero
            let axis: TilingSplitAxis = frame.width > frame.height * 1.35 ? .rows : .columns
            return .split(axis: axis, ratio: 0.5, first: .leaf(id), second: .leaf(newID))
        case .leaf:
            return self
        case .split(let axis, let ratio, let first, let second):
            if first.windowIDs.contains(target) {
                return .split(axis: axis, ratio: ratio,
                              first: first.inserting(newID, beside: target, targetFrame: targetFrame),
                              second: second)
            }
            return .split(axis: axis, ratio: ratio, first: first,
                          second: second.inserting(newID, beside: target, targetFrame: targetFrame))
        }
    }


    func swapping(_ a: CGWindowID, with b: CGWindowID) -> TilingTree {
        guard a != b, windowIDs.contains(a), windowIDs.contains(b) else { return self }
        return replacingForSwap(a, b)
    }

    private func replacingForSwap(_ a: CGWindowID, _ b: CGWindowID) -> TilingTree {
        switch self {
        case .leaf(let id): return .leaf(id == a ? b : (id == b ? a : id))
        case .split(let axis, let ratio, let first, let second):
            return .split(axis: axis, ratio: ratio,
                          first: first.replacingForSwap(a, b), second: second.replacingForSwap(a, b))
        }
    }

    /// Change only split boundaries touched by a user resize. Coordinates are
    /// AppKit (bottom-left); outside display edges never change a split weight.
    func resized(windowID: CGWindowID, from old: CGRect, to new: CGRect,
                 in rect: CGRect, gap: CGFloat) -> TilingTree {
        guard windowIDs.contains(windowID),
              case .split(let axis, let ratio, let first, let second) = self else { return self }
        let original = frames(in: rect, gap: gap)
        func union(_ tree: TilingTree) -> CGRect {
            tree.windowIDs.compactMap { original[$0] }.reduce(CGRect.null) { $0.union($1) }
        }
        let a = union(first)
        let b = union(second)
        let inFirst = first.windowIDs.contains(windowID)
        var updatedRatio = ratio
        switch axis {
        case .columns where abs(new.width - old.width) > 2:
            let edge = inFirst ? old.maxX : old.minX
            let boundary = inFirst ? a.maxX : b.minX
            if abs(edge - boundary) < 2 {
                let delta = inFirst ? new.maxX - old.maxX : new.minX - old.minX
                updatedRatio += delta / max(1, rect.width - gap)
            }
        case .rows where abs(new.height - old.height) > 2:
            let edge = inFirst ? old.minY : old.maxY
            let boundary = inFirst ? a.minY : b.maxY
            if abs(edge - boundary) < 2 {
                let delta = inFirst ? new.minY - old.minY : new.maxY - old.maxY
                updatedRatio -= delta / max(1, rect.height - gap)
            }
        default: break
        }
        return .split(axis: axis, ratio: min(0.8, max(0.2, updatedRatio)),
                      first: first.resized(windowID: windowID, from: old, to: new, in: a, gap: gap),
                      second: second.resized(windowID: windowID, from: old, to: new, in: b, gap: gap))
    }

    func removing(ids removed: Set<CGWindowID>) -> TilingTree? {
        switch self {
        case .leaf(let id):
            return removed.contains(id) ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let a = first.removing(ids: removed)
            let b = second.removing(ids: removed)
            switch (a, b) {
            case (nil, nil): return nil
            case (let survivor?, nil), (nil, let survivor?): return survivor
            case (let a?, let b?): return .split(axis: axis, ratio: ratio, first: a, second: b)
            }
        }
    }

    func frames(in rect: CGRect, gap: CGFloat) -> [CGWindowID: CGRect] {
        switch self {
        case .leaf(let id):
            return [id: rect.integral]
        case .split(let axis, let ratio, let first, let second):
            let r = min(0.8, max(0.2, ratio))
            let g = max(0, gap)
            let aRect: CGRect
            let bRect: CGRect
            switch axis {
            case .columns:
                let available = max(0, rect.width - g)
                let firstWidth = floor(available * r)
                aRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                bRect = CGRect(x: aRect.maxX + g, y: rect.minY,
                               width: available - firstWidth, height: rect.height)
            case .rows:
                let available = max(0, rect.height - g)
                let firstHeight = floor(available * r)
                aRect = CGRect(x: rect.minX, y: rect.maxY - firstHeight,
                               width: rect.width, height: firstHeight)
                bRect = CGRect(x: rect.minX, y: rect.minY,
                               width: rect.width, height: available - firstHeight)
            }
            return first.frames(in: aRect, gap: g).merging(second.frames(in: bRect, gap: g)) { _, rhs in rhs }
        }
    }

    func updatingRatio(at path: [Int], to newRatio: CGFloat) -> TilingTree {
        guard case .split(let axis, let ratio, let first, let second) = self else { return self }
        if path.isEmpty {
            return .split(axis: axis, ratio: min(0.8, max(0.2, newRatio)), first: first, second: second)
        }
        let index = path[0]
        let remaining = Array(path.dropFirst())
        if index == 0 {
            return .split(axis: axis, ratio: ratio, first: first.updatingRatio(at: remaining, to: newRatio), second: second)
        } else {
            return .split(axis: axis, ratio: ratio, first: first, second: second.updatingRatio(at: remaining, to: newRatio))
        }
    }

    func dividers(in rect: CGRect, gap: CGFloat, path: [Int] = []) -> [TilingDivider] {
        switch self {
        case .leaf:
            return []
        case .split(let axis, let ratio, let first, let second):
            let r = min(0.8, max(0.2, ratio))
            let g = max(0, gap)
            var result: [TilingDivider] = []
            let aRect: CGRect
            let bRect: CGRect
            switch axis {
            case .columns:
                let available = max(0, rect.width - g)
                let firstWidth = floor(available * r)
                aRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                bRect = CGRect(x: aRect.maxX + g, y: rect.minY, width: available - firstWidth, height: rect.height)
                let coord = aRect.maxX + (g > 0 ? g / 2.0 : 0)
                let minWidth = min(220.0, floor(available * 0.45))
                let minMargin = max(floor(available * 0.2), minWidth)
                let minCoord = rect.minX + minMargin + (g > 0 ? g / 2.0 : 0)
                let maxCoord = rect.maxX - minMargin - (g > 0 ? g / 2.0 : 0)
                result.append(TilingDivider(
                    id: "split-col-\(path.map(String.init).joined(separator: "-"))",
                    axis: .vertical,
                    coordinate: coord,
                    minCoordinate: minCoord,
                    maxCoordinate: maxCoord,
                    parentRect: rect,
                    span: rect.minY...rect.maxY,
                    treePath: path,
                    isMasterDivider: false,
                    firstWindowIDs: first.windowIDs,
                    secondWindowIDs: second.windowIDs,
                    gap: g
                ))
            case .rows:
                let available = max(0, rect.height - g)
                let firstHeight = floor(available * r)
                aRect = CGRect(x: rect.minX, y: rect.maxY - firstHeight, width: rect.width, height: firstHeight)
                bRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: available - firstHeight)
                let coord = bRect.maxY + (g > 0 ? g / 2.0 : 0)
                let minHeight = min(150.0, floor(available * 0.45))
                let minMargin = max(floor(available * 0.2), minHeight)
                let minCoord = rect.minY + minMargin + (g > 0 ? g / 2.0 : 0)
                let maxCoord = rect.maxY - minMargin - (g > 0 ? g / 2.0 : 0)
                result.append(TilingDivider(
                    id: "split-row-\(path.map(String.init).joined(separator: "-"))",
                    axis: .horizontal,
                    coordinate: coord,
                    minCoordinate: minCoord,
                    maxCoordinate: maxCoord,
                    parentRect: rect,
                    span: rect.minX...rect.maxX,
                    treePath: path,
                    isMasterDivider: false,
                    firstWindowIDs: first.windowIDs,
                    secondWindowIDs: second.windowIDs,
                    gap: g
                ))
            }
            result.append(contentsOf: first.dividers(in: aRect, gap: g, path: path + [0]))
            result.append(contentsOf: second.dividers(in: bRect, gap: g, path: path + [1]))
            return result
        }
    }
}

struct TilingDivider: Equatable {
    enum Axis: Equatable {
        case vertical   // columns
        case horizontal // rows
    }

    let id: String
    let axis: Axis
    let coordinate: CGFloat
    let minCoordinate: CGFloat
    let maxCoordinate: CGFloat
    let parentRect: CGRect
    let span: ClosedRange<CGFloat>
    let treePath: [Int]?
    let isMasterDivider: Bool
    let firstWindowIDs: [CGWindowID]
    let secondWindowIDs: [CGWindowID]
    var gap: CGFloat = 4.0
}

struct TilingFrameVelocity: Equatable {
    var minX: CGFloat
    var maxX: CGFloat
    var minY: CGFloat
    var maxY: CGFloat

    static let zero = TilingFrameVelocity(minX: 0, maxX: 0, minY: 0, maxY: 0)
}

struct TilingFrameSpringSample {
    let frame: CGRect
    let velocity: TilingFrameVelocity
}

struct TilingColumnAssignment: Equatable {
    var leftIDs: Set<CGWindowID>
    var leftActiveID: CGWindowID?
    var rightActiveID: CGWindowID?
}

enum TilingColumnDropKind: Equatable {
    case tab
    case swap
    /// Every window shares one column: the dragged one takes the left or
    /// right half on its own, and the rest become the other column.
    case split(left: Bool)
}

struct TilingColumnDropPlacement: Equatable {
    let targetID: CGWindowID
    let kind: TilingColumnDropKind
    let previewFrame: CGRect
}

struct TilingColumnRailGeometry: Equatable {
    let work: CGRect
    let leftRail: CGRect?
    let rightRail: CGRect?
}

enum TilingLayout {
    /// A focus snapshot can still name the outgoing tab while an explicit
    /// selection is in flight. Only a genuinely new focus or timeout may
    /// supersede that selection.
    static func keepsPendingTabSelection(target: CGWindowID, previousFocus: CGWindowID?,
                                          observedFocus: CGWindowID?, age: CFTimeInterval) -> Bool {
        guard age < 1.5, observedFocus != target else { return false }
        return observedFocus == nil || observedFocus == previousFocus
    }
    static let columnPillThickness: CGFloat = 3
    static let columnPillEdgeOffset: CGFloat = 1.5
    static let columnPillWindowGap: CGFloat = 4

    static func columnPillRailWidth(edgeAttached: Bool) -> CGFloat {
        if edgeAttached {
            return ceil(columnPillEdgeOffset + columnPillThickness + columnPillWindowGap)
        }
        return 2 * (columnPillWindowGap + columnPillThickness / 2)
    }

    static func columnPillSides(windowIDs: [CGWindowID], mainTabIDs: Set<CGWindowID>,
                                masterID: CGWindowID?, enabled: Bool) -> (left: Bool, right: Bool) {
        guard enabled else { return (false, false) }
        let leftCount = windowIDs.filter { mainTabIDs.contains($0) || $0 == masterID }.count
        return (leftCount > 1, windowIDs.count - leftCount > 1)
    }

    /// Match the tab switcher's bar order, retaining any tree member omitted
    /// from a transient bar snapshot so the rail never loses a dot mid-swipe.
    static func orderedColumnTabs(_ ids: [CGWindowID], barOrder: [CGWindowID]) -> [CGWindowID] {
        let members = Set(ids)
        let ordered = barOrder.filter { members.contains($0) }
        let seen = Set(ordered)
        return ordered + ids.filter { !seen.contains($0) }
    }

    static func verticalPillIndex(tabIndex: Int, count: Int) -> Int {
        max(1, min(count, count - tabIndex))
    }

    /// Reserve only the width between the painted pill and its neighbour,
    /// rather than a fixed-size rail that leaves an unexplained empty strip.
    /// The user's outer gap remains a minimum when it is larger.
    static func columnPillGeometry(in baseWork: CGRect, gap: CGFloat,
                                   left: Bool, right: Bool,
                                   edgeAttached: Bool) -> TilingColumnRailGeometry {
        let inset = baseWork.insetBy(dx: gap, dy: gap)
        let railW = columnPillRailWidth(edgeAttached: edgeAttached)
        let leftX = edgeAttached ? baseWork.minX : inset.minX
        let rightX = edgeAttached ? baseWork.maxX - railW : inset.maxX - railW
        let minX = left ? max(inset.minX, leftX + railW) : inset.minX
        let maxX = right ? min(inset.maxX, rightX) : inset.maxX
        let work = CGRect(x: minX, y: inset.minY,
                          width: max(0, maxX - minX), height: inset.height)
        return TilingColumnRailGeometry(
            work: work,
            leftRail: left ? CGRect(x: leftX, y: work.minY, width: railW, height: work.height) : nil,
            rightRail: right ? CGRect(x: rightX, y: work.minY, width: railW, height: work.height) : nil)
    }

    /// `NSScreen.visibleFrame` can temporarily include a fixed Dock after its
    /// auto-hide setting changes. Reserve the Dock window's actual edge too.
    static func excludingFixedDock(_ work: CGRect, screen: CGRect, dock: CGRect?,
                                   orientation: String) -> CGRect {
        guard let dock, !dock.isNull, !dock.isEmpty,
              dock.intersects(screen) else { return work }
        let edgeTolerance: CGFloat = 16
        var result = work
        switch orientation {
        case "left" where dock.minX <= screen.minX + edgeTolerance && dock.midX < screen.midX:
            let minX = max(work.minX, dock.maxX)
            result.origin.x = minX
            result.size.width = max(0, work.maxX - minX)
        case "right" where dock.maxX >= screen.maxX - edgeTolerance && dock.midX > screen.midX:
            result.size.width = max(0, min(work.maxX, dock.minX) - work.minX)
        case "bottom" where dock.minY <= screen.minY + edgeTolerance && dock.midY < screen.midY:
            let minY = max(work.minY, dock.maxY)
            result.origin.y = minY
            result.size.height = max(0, work.maxY - minY)
        default:
            break
        }
        return result
    }

    /// A critically damped frame spring. Each edge moves independently so a
    /// resize keeps anchored edges steady, and velocity can carry through when
    /// a running re-tile is redirected to a new layout.
    static func springFrame(from start: CGRect, to target: CGRect,
                            initialVelocity: TilingFrameVelocity = .zero,
                            elapsed: Double,
                            response: CGFloat = 22) -> TilingFrameSpringSample {
        let t = CGFloat(max(0, elapsed))
        let omega = max(1, response)

        func component(_ start: CGFloat, _ target: CGFloat,
                       _ proposedVelocity: CGFloat) -> (value: CGFloat, velocity: CGFloat) {
            let delta = start - target
            guard abs(delta) >= 0.001 else { return (target, 0) }

            // Preserve velocity only when it is already heading at the new
            // target. The cap is the fastest monotonic critical response, so a
            // retarget never throws an edge past its destination.
            let towardTarget = delta * proposedVelocity < 0
            let maximumVelocity = omega * abs(delta)
            let velocity0 = towardTarget
                ? min(maximumVelocity, abs(proposedVelocity)) * (proposedVelocity < 0 ? -1 : 1)
                : 0
            let coefficient = velocity0 + omega * delta
            let decay = exp(-omega * t)
            let rawValue = target + (delta + coefficient * t) * decay
            let value = min(max(start, target), max(min(start, target), rawValue))
            let velocity = (velocity0 - omega * coefficient * t) * decay
            return (value, velocity)
        }

        let left = component(start.minX, target.minX, initialVelocity.minX)
        let right = component(start.maxX, target.maxX, initialVelocity.maxX)
        let bottom = component(start.minY, target.minY, initialVelocity.minY)
        let top = component(start.maxY, target.maxY, initialVelocity.maxY)
        let minX = left.value.rounded()
        let maxX = right.value.rounded()
        let minY = bottom.value.rounded()
        let maxY = top.value.rounded()
        return TilingFrameSpringSample(
            frame: CGRect(x: minX, y: minY,
                          width: max(1, maxX - minX), height: max(1, maxY - minY)),
            velocity: TilingFrameVelocity(minX: left.velocity, maxX: right.velocity,
                                          minY: bottom.velocity, maxY: top.velocity)
        )
    }

    static func interpolatedAlignedFrame(from start: CGRect, to target: CGRect,
                                         progress: CGFloat) -> CGRect {
        let p = min(1, max(0, progress))
        func edge(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            (a + (b - a) * p).rounded()
        }
        let minX = edge(start.minX, target.minX)
        let maxX = edge(start.maxX, target.maxX)
        let minY = edge(start.minY, target.minY)
        let maxY = edge(start.maxY, target.maxY)
        return CGRect(x: minX, y: minY,
                      width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    static func containsIncludingEdges(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX &&
            point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Tabs a moving window into the target's column. Either column may become
    /// empty; the remaining stack then expands to the full work area.
    static func movingTab(_ movingID: CGWindowID, onto targetID: CGWindowID,
                          orderedIDs: [CGWindowID], leftIDs: Set<CGWindowID>,
                          leftActiveID: CGWindowID?, rightActiveID: CGWindowID?)
        -> TilingColumnAssignment {
        var result = TilingColumnAssignment(leftIDs: leftIDs,
                                            leftActiveID: leftActiveID,
                                            rightActiveID: rightActiveID)
        let targetWasLeft = result.leftIDs.contains(targetID)
        if targetWasLeft {
            result.leftIDs.insert(movingID)
            result.leftActiveID = movingID
            if result.rightActiveID == movingID {
                result.rightActiveID = orderedIDs.first { !result.leftIDs.contains($0) }
            }
        } else {
            result.leftIDs.remove(movingID)
            if result.leftActiveID == movingID {
                result.leftActiveID = orderedIDs.first { result.leftIDs.contains($0) }
            }
            result.rightActiveID = movingID
        }
        return result
    }

    /// Splits a single column: the moving window alone on one side, every
    /// other window tabbed together on the other.
    static func splittingColumn(_ movingID: CGWindowID, toLeft: Bool,
                                orderedIDs: [CGWindowID],
                                leftActiveID: CGWindowID?, rightActiveID: CGWindowID?)
        -> TilingColumnAssignment? {
        let others = orderedIDs.filter { $0 != movingID }
        guard !others.isEmpty else { return nil }
        let othersActive = [leftActiveID, rightActiveID].compactMap { $0 }
            .first { others.contains($0) } ?? others.first
        return toLeft
            ? TilingColumnAssignment(leftIDs: [movingID], leftActiveID: movingID, rightActiveID: othersActive)
            : TilingColumnAssignment(leftIDs: Set(others), leftActiveID: othersActive, rightActiveID: movingID)
    }

    /// The outer half swaps just the dragged and target windows. Other tabs
    /// keep their column memberships and order.
    static func swappingTabs(_ movingID: CGWindowID, with targetID: CGWindowID,
                             leftIDs: Set<CGWindowID>) -> TilingColumnAssignment? {
        let movingWasLeft = leftIDs.contains(movingID)
        let targetWasLeft = leftIDs.contains(targetID)
        guard movingWasLeft != targetWasLeft else { return nil }
        var nextLeft = leftIDs
        if movingWasLeft {
            nextLeft.remove(movingID)
            nextLeft.insert(targetID)
            return TilingColumnAssignment(leftIDs: nextLeft,
                                          leftActiveID: targetID,
                                          rightActiveID: movingID)
        }
        nextLeft.remove(targetID)
        nextLeft.insert(movingID)
        return TilingColumnAssignment(leftIDs: nextLeft,
                                      leftActiveID: movingID,
                                      rightActiveID: targetID)
    }

    /// Left targets expose a swap zone on their outer-left half; right
    /// targets expose it on their outer-right half. The inner half
    /// tabs the moving window into the target's column.
    static func columnDropPlacement(movingID: CGWindowID, from old: CGRect, to new: CGRect,
                                    pointer: CGPoint, dragStart: CGPoint? = nil,
                                    slots: [CGWindowID: CGRect],
                                    leftIDs: Set<CGWindowID>,
                                    leftActiveID: CGWindowID?, rightActiveID: CGWindowID?,
                                    splitRatio: CGFloat = 0.5)
        -> TilingColumnDropPlacement? {
        let movedPointer = dragStart.map { hypot(pointer.x - $0.x, pointer.y - $0.y) > 8 } ?? false
        let movedWindow = abs(new.width - old.width) <= 2 && abs(new.height - old.height) <= 2 &&
            (abs(new.minX - old.minX) > 8 || abs(new.minY - old.minY) > 8)
        guard movedPointer || movedWindow else { return nil }
        let preferred = [leftActiveID, rightActiveID].compactMap { $0 }
        let fallback = slots.keys.sorted().filter { !preferred.contains($0) }
        guard let targetID = (preferred + fallback).first(where: {
            $0 != movingID && slots[$0]?.contains(pointer) == true
        }), let targetFrame = slots[targetID] else { return nil }

        let movingIsLeft = leftIDs.contains(movingID)
        if leftIDs.contains(targetID) == movingIsLeft {
            // Over a tab of its own column. With a second column on screen
            // that is a no-op; with only one column it splits the screen.
            let hasOtherColumn = slots.keys.contains { leftIDs.contains($0) != movingIsLeft }
            guard !hasOtherColumn else { return nil }
            let toLeft = pointer.x < targetFrame.midX
            // The split lays out at the master ratio; preview the same share.
            let leftWidth = floor(targetFrame.width * min(0.8, max(0.2, splitRatio)))
            let preview = toLeft
                ? CGRect(x: targetFrame.minX, y: targetFrame.minY, width: leftWidth, height: targetFrame.height)
                : CGRect(x: targetFrame.minX + leftWidth, y: targetFrame.minY,
                         width: targetFrame.width - leftWidth, height: targetFrame.height)
            return TilingColumnDropPlacement(targetID: targetID, kind: .split(left: toLeft),
                                             previewFrame: preview.integral)
        }

        let targetIsLeft = leftIDs.contains(targetID)
        let edgeWidth = floor(targetFrame.width * 0.5)
        let isSwap = targetIsLeft
            ? pointer.x <= targetFrame.minX + edgeWidth
            : pointer.x >= targetFrame.maxX - edgeWidth
        // Preview the frame the dragged window will actually have: the target's
        // column — or, when a tab leaves the dragged window's column empty, the
        // whole work area the surviving column expands to. The kind is a badge.
        var preview = targetFrame
        let leavesColumnEmpty = !isSwap && !slots.keys.contains {
            $0 != movingID && leftIDs.contains($0) == movingIsLeft
        }
        if leavesColumnEmpty {
            preview = slots.values.reduce(targetFrame) { $0.union($1) }
        }
        return TilingColumnDropPlacement(targetID: targetID,
                                         kind: isSwap ? .swap : .tab,
                                         previewFrame: preview.integral)
    }

    static func windowStatus(mode: TilingLayoutMode, paused: Bool,
                             focusedID: CGWindowID?, masterID: CGWindowID?,
                             mainTabIDs: Set<CGWindowID> = [],
                             floatingIDs: Set<CGWindowID>) -> TilingWindowStatus {
        if paused { return .paused }
        guard let focusedID else { return mode == .masterStack ? .leftTabbed : .split }
        if floatingIDs.contains(focusedID) { return .floating }
        if mode == .masterStack {
            return focusedID == masterID || mainTabIDs.contains(focusedID)
                ? .leftTabbed : .rightTabbed
        }
        return .split
    }

    /// Returns the master that keeps `assignedID` on the stack. Preserve the
    /// current master when possible; assigning the master itself promotes the
    /// first remaining tiled window.
    static func masterIDForTabbedAssignment(windowIDs: [CGWindowID],
                                            currentMasterID: CGWindowID?,
                                            assignedID: CGWindowID) -> CGWindowID? {
        guard windowIDs.contains(assignedID), windowIDs.count >= 2 else { return nil }
        if let currentMasterID,
           currentMasterID != assignedID,
           windowIDs.contains(currentMasterID) {
            return currentMasterID
        }
        return windowIDs.first { $0 != assignedID }
    }

    /// Keeps the persisted master when it is visible. If it is hidden or has
    /// disappeared, the first visible window becomes the temporary master so
    /// the left column is never left empty.
    static func visibleMasterID(windowIDs: [CGWindowID], masterID: CGWindowID?,
                                visibleIDs: Set<CGWindowID>) -> CGWindowID? {
        if let masterID, visibleIDs.contains(masterID) { return masterID }
        return windowIDs.first { visibleIDs.contains($0) }
    }

    static func shouldAutoRemoveSpace(isUserSpace: Bool, isCurrent: Bool,
                                      userSpaceCount: Int, hasApplicationWindows: Bool,
                                      emptyDuration: Double) -> Bool {
        isUserSpace && !isCurrent && userSpaceCount > 1 &&
            !hasApplicationWindows && emptyDuration >= 5.0
    }

    /// A launch gets a new Deskspace only when its first usable window appeared
    /// on a normal Deskspace that already belongs to another app. An empty
    /// current Deskspace is intentionally reused, and later manual moves are
    /// never evaluated by this launch-only policy.
    static func shouldCreateDeskspaceForNewApp(hasUsableWindow: Bool,
                                               currentSpaceIsFullscreen: Bool,
                                               hasOtherApplication: Bool) -> Bool {
        hasUsableWindow && !currentSpaceIsFullscreen && hasOtherApplication
    }

    /// Finder folder windows expose a document URL. Finder's utility windows
    /// (Get Info, progress and confirmation surfaces) do not, so they should
    /// never enter the two-column layout.
    /// AppKit's identifiers for the Open and Save dialogs. An app that isn't
    /// sandboxed puts that dialog up in its own process, where every other AX
    /// signal — standard window, resizable, movable — is that of a document
    /// window; the identifier is what tells the two apart.
    private static let filePanelIdentifiers: Set<String> = ["open-panel", "save-panel"]

    /// A sandboxed app's Open/Save dialog is a window of this system service.
    private static let filePanelServiceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"

    /// Windows tiling leaves where the app put them: file dialogs, and Finder's
    /// Get Info and copy sheets, which are panels wearing a standard window's
    /// clothes and read as one tile taken over by a dialog when tiled.
    static func shouldAutomaticallyFloat(bundleID: String,
                                         identifier: String?,
                                         subrole: String?,
                                         document: String?) -> Bool {
        if bundleID == filePanelServiceBundleID { return true }
        if let identifier, filePanelIdentifiers.contains(identifier) { return true }
        guard bundleID == "com.apple.finder" else { return false }
        guard subrole == "AXStandardWindow" else { return true }
        return document?.isEmpty != false
    }

    static func dropTarget(movingID: CGWindowID, from old: CGRect, to new: CGRect,
                           pointer: CGPoint, slots: [CGWindowID: CGRect]) -> CGWindowID? {
        // A click or resize is never a reorder. Use the pointer at mouse-up,
        // not the moved window center (large windows overlap several tiles).
        guard abs(new.width - old.width) <= 2, abs(new.height - old.height) <= 2,
              abs(new.minX - old.minX) > 8 || abs(new.minY - old.minY) > 8 else { return nil }
        return slots.keys.sorted().first { $0 != movingID && slots[$0]!.contains(pointer) }
    }

    /// The master column's width for a ratio, never narrower than what either
    /// side can actually shrink to. An app that refuses to go below, say, 500pt
    /// keeps that width whatever frame it is sent, so a tile narrower than that
    /// does not shrink the window — it just leaves it lying over its neighbour.
    /// Widening the tile instead is the only way the two stay side by side.
    static func masterWidth(available: CGFloat, masterRatio: CGFloat,
                            masterMinWidth: CGFloat = 0, stackMinWidth: CGFloat = 0) -> CGFloat {
        let width = floor(available * min(0.8, max(0.2, masterRatio)))
        let lowest = max(0, masterMinWidth)
        let highest = available - max(0, stackMinWidth)
        // Both minimums together can exceed the screen; then nothing fits and
        // the ratio stands, rather than one side being crushed to nothing.
        guard lowest <= highest else { return width }
        return min(highest, max(lowest, width))
    }

    static func masterStackFrames(windowIDs: [CGWindowID], masterID: CGWindowID?,
                                  mainTabIDs: Set<CGWindowID> = [],
                                  in rect: CGRect, gap: CGFloat,
                                  masterRatio: CGFloat = 0.50,
                                  minWidths: [CGWindowID: CGFloat] = [:]) -> [CGWindowID: CGRect] {
        guard !windowIDs.isEmpty else { return [:] }
        var main = windowIDs.filter { mainTabIDs.contains($0) }
        if let master = masterID, windowIDs.contains(master), !main.contains(master) {
            main.insert(master, at: 0)
        }
        let mainSet = Set(main)
        let stack = windowIDs.filter { !mainSet.contains($0) }
        if main.isEmpty {
            return Dictionary(uniqueKeysWithValues: stack.map { ($0, rect.integral) })
        }
        guard !stack.isEmpty else {
            return Dictionary(uniqueKeysWithValues: main.map { ($0, rect.integral) })
        }

        let g = max(0, gap)
        let available = max(0, rect.width - g)
        let masterWidth = masterWidth(available: available, masterRatio: masterRatio,
                                      masterMinWidth: main.compactMap { minWidths[$0] }.max() ?? 0,
                                      stackMinWidth: stack.compactMap { minWidths[$0] }.max() ?? 0)
        let mainFrame = CGRect(x: rect.minX, y: rect.minY,
                               width: masterWidth, height: rect.height).integral
        var result = Dictionary(uniqueKeysWithValues: main.map { ($0, mainFrame) })
        let stackRect = CGRect(x: rect.minX + masterWidth + g, y: rect.minY,
                               width: available - masterWidth, height: rect.height)
        let sharedFrame = stackRect.integral
        for id in stack { result[id] = sharedFrame }
        return result
    }

    static func dividers(mode: TilingLayoutMode, tree: TilingTree?, masterID: CGWindowID?,
                         mainTabIDs: Set<CGWindowID> = [],
                         masterRatio: CGFloat, in rect: CGRect, gap: CGFloat,
                         minWidths: [CGWindowID: CGFloat] = [:]) -> [TilingDivider] {
        guard let tree else { return [] }
        switch mode {
        case .splitTree:
            return tree.dividers(in: rect, gap: gap)
        case .masterStack:
            let windowIDs = tree.windowIDs
            guard windowIDs.count >= 2 else { return [] }
            let g = max(0, gap)
            let available = max(0, rect.width - g)
            var mainIDs = windowIDs.filter { mainTabIDs.contains($0) }
            if let master = masterID, windowIDs.contains(master), !mainIDs.contains(master) {
                mainIDs.insert(master, at: 0)
            }
            let mainSet = Set(mainIDs)
            let stackIDs = windowIDs.filter { !mainSet.contains($0) }
            guard !mainIDs.isEmpty, !stackIDs.isEmpty else { return [] }
            // The handle sits on the edge the windows actually have.
            let masterMin = mainIDs.compactMap { minWidths[$0] }.max() ?? 0
            let stackMin = stackIDs.compactMap { minWidths[$0] }.max() ?? 0
            let masterWidth = masterWidth(available: available, masterRatio: masterRatio,
                                          masterMinWidth: masterMin, stackMinWidth: stackMin)
            let coord = rect.minX + masterWidth + (g > 0 ? g / 2.0 : 0)
            let minWidth = min(220.0, floor(available * 0.45))
            let minMargin = max(floor(available * 0.2), minWidth)
            // Dragging past a window's own minimum only re-opens the overlap.
            let minCoord = rect.minX + max(minMargin, masterMin) + (g > 0 ? g / 2.0 : 0)
            let maxCoord = rect.maxX - max(minMargin, stackMin) - (g > 0 ? g / 2.0 : 0)
            return [
                TilingDivider(
                    id: "master-divider",
                    axis: .vertical,
                    coordinate: coord,
                    minCoordinate: minCoord,
                    maxCoordinate: maxCoord,
                    parentRect: rect,
                    span: rect.minY...rect.maxY,
                    treePath: nil,
                    isMasterDivider: true,
                    firstWindowIDs: mainIDs,
                    secondWindowIDs: stackIDs,
                    gap: g
                )
            ]
        }
    }

    static func ratio(for divider: TilingDivider, at coordinate: CGFloat, gap: CGFloat) -> CGFloat {
        let g = max(0, gap)
        let parent = divider.parentRect
        switch divider.axis {
        case .vertical:
            let available = max(1, parent.width - g)
            let minR = max(0.15, (divider.minCoordinate - parent.minX - (g > 0 ? g / 2.0 : 0)) / available)
            let maxR = min(0.85, (divider.maxCoordinate - parent.minX - (g > 0 ? g / 2.0 : 0)) / available)
            let raw = (coordinate - parent.minX - (g > 0 ? g / 2.0 : 0)) / available
            return min(maxR, max(minR, raw))
        case .horizontal:
            let available = max(1, parent.height - g)
            let minR = max(0.15, 1.0 - (divider.maxCoordinate - parent.minY - (g > 0 ? g / 2.0 : 0)) / available)
            let maxR = min(0.85, 1.0 - (divider.minCoordinate - parent.minY - (g > 0 ? g / 2.0 : 0)) / available)
            let raw = 1.0 - (coordinate - parent.minY - (g > 0 ? g / 2.0 : 0)) / available
            return min(maxR, max(minR, raw))
        }
    }
}
