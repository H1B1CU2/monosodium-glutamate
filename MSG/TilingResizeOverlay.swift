import AppKit

/// One visible tab stack in a reserved, screen-edge rail.
struct TilingColumnPill {
    let id: String
    let railFrame: CGRect
    let tabCount: Int
    let tabIDs: [CGWindowID]
    let selectedIndex: Int
    let edgeAttached: Bool
    let isLeft: Bool
}

/// Shared clock for the real window slide and its adjacent tab marker.
enum TilingTabSwitchTiming {
    /// The side pill's move: as long as the window's slide, so they land together.
    static let transitionDuration: CFTimeInterval = 0.32
    static let windowSlideDuration: CFTimeInterval = 0.32
    /// Once the real window is up beneath, the slide dissolves into it.
    static let windowSettleFadeDuration: CFTimeInterval = 0.12
}

/// Manages interactive floating resize handle panels for tiled window dividers.
/// Uses compact, individual pill-sized panels only where dividers exist,
/// ensuring zero full-screen overlays so app clicks and scrolling are never blocked.
final class TilingResizeOverlayController {
    var onResizeStart: ((TilingDivider) -> Void)?
    var onResizeDrag: ((TilingDivider, CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    private var panels: [String: TilingHandlePanel] = [:]
    private var columnPills: [String: TilingColumnPillPanel] = [:]
    private var dropPreviewPanel: TilingDropPreviewPanel?
    private var resizePreviewPanels: [CGWindowID: TilingDropPreviewPanel] = [:]
    private var activeDividers: [TilingDivider] = []
    /// The windows the dividers sit between — what has to be under the pointer
    /// for a handle to belong there.
    private var tiledWindowIDs: Set<CGWindowID> = []
    private var isDragging = false
    private var lastCheckTime: TimeInterval = 0

    func start() {
        // Ready to display handles when dividers are provided
    }

    func stop() {
        isDragging = false
        panels.values.forEach { $0.orderOut(nil) }
        columnPills.values.forEach { $0.closePill() }
        columnPills = [:]
        dropPreviewPanel?.orderOut(nil)
        dropPreviewPanel = nil
        resizePreviewPanels.values.forEach { $0.orderOut(nil) }
        resizePreviewPanels = [:]
        panels = [:]
        activeDividers = []
    }

    func update(dividers: [String: [TilingDivider]], tiledWindowIDs: Set<CGWindowID> = [],
                columnTabs: [TilingColumnPill] = []) {
        guard !isDragging else { return }
        let activePills = Set(columnTabs.map(\.id))
        for (id, panel) in columnPills where !activePills.contains(id) {
            panel.hidePill()
            columnPills.removeValue(forKey: id)
        }
        for pill in columnTabs where pill.tabCount > 1 {
            let panel = columnPills[pill.id] ?? TilingColumnPillPanel()
            columnPills[pill.id] = panel
            panel.show(pill)
        }
        let allDividers = dividers.values.flatMap { $0 }
        activeDividers = allDividers
        self.tiledWindowIDs = tiledWindowIDs

        // Remove panels for dividers that no longer exist
        let currentIDs = Set(allDividers.map(\.id))
        for (id, panel) in panels where !currentIDs.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        // Check if cursor is already near a divider
        handleMouseMove(at: NSEvent.mouseLocation, force: true)
    }

    /// Begin the rail motion on the same frame as the swipe's window transition,
    /// instead of waiting for Accessibility and the next tiling refresh.
    func selectColumnTab(_ windowID: CGWindowID, displayUUID: String) {
        for (id, panel) in columnPills where id.hasPrefix("\(displayUUID)-") {
            panel.select(windowID)
        }
    }

    func handleMouseMove(at screenPoint: CGPoint, force: Bool = false) {
        guard !isDragging else { return }

        // Throttle proximity checks to ~60Hz to keep CPU at near zero
        let now = CACurrentMediaTime()
        if !force && (now - lastCheckTime < DisplayRate.interval) { return }
        lastCheckTime = now

        guard !activeDividers.isEmpty else {
            hideAllPanels()
            return
        }

        // Find if mouse is near any divider (within 18pt of the line, and within the span)
        var hoveredDivider: TilingDivider?
        for divider in activeDividers {
            let dist: CGFloat
            let inSpan: Bool
            switch divider.axis {
            case .vertical:
                dist = abs(screenPoint.x - divider.coordinate)
                inSpan = screenPoint.y >= (divider.span.lowerBound - 10) && screenPoint.y <= (divider.span.upperBound + 10)
            case .horizontal:
                dist = abs(screenPoint.y - divider.coordinate)
                inSpan = screenPoint.x >= (divider.span.lowerBound - 10) && screenPoint.x <= (divider.span.upperBound + 10)
            }
            if inSpan && dist <= 18.0 {
                hoveredDivider = divider
                break
            }
        }

        if let divider = hoveredDivider, pointerIsOverLayout(screenPoint) {
            showHandle(for: divider)
        } else {
            hideAllPanels()
        }
    }

    /// A handle belongs to the two tiles it parts. A floating window, a panel
    /// or a menu lying over the divider owns that point instead, so the handle
    /// stays hidden rather than drawing on top of it. The gap between tiles
    /// shows the desktop and still counts as the layout.
    private func pointerIsOverLayout(_ screenPoint: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        let myPID = ProcessInfo.processInfo.processIdentifier
        // CGWindowList bounds are top-left origin; the pointer is bottom-left.
        let point = CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != myPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.contains(point) else { continue }
            return tiledWindowIDs.contains(id)
        }
        return true
    }

    func notifyDragEnded() {
        isDragging = false
        showDropPreview(frame: nil)
        hideResizePreviews()
        for panel in panels.values {
            panel.finishDrag()
        }
        handleMouseMove(at: NSEvent.mouseLocation, force: true)
    }

    /// Shows the exact tile that will receive a moved window on mouse-up.
    /// The panel is only the size of the target tile and ignores all input.
    func showDropPreview(frame: CGRect?, kind: TilingDropPreviewKind = .move) {
        guard let frame, frame.width > 1, frame.height > 1 else {
            dropPreviewPanel?.hideAnimated()
            return
        }
        let panel: TilingDropPreviewPanel
        if let existing = dropPreviewPanel {
            panel = existing
        } else {
            panel = TilingDropPreviewPanel()
            dropPreviewPanel = panel
        }
        panel.previewKind = kind
        panel.show(frame: frame)
    }

    /// Lightweight geometry feedback used while Accessibility-backed windows
    /// remain stationary. This avoids repeatedly issuing separate position and
    /// size writes, which WindowServer can visibly present as a shaking edge.
    func showResizePreviews(frames: [CGWindowID: CGRect]) {
        let activeIDs = Set(frames.keys)
        let staleIDs = resizePreviewPanels.keys.filter { !activeIDs.contains($0) }
        for id in staleIDs {
            resizePreviewPanels.removeValue(forKey: id)?.hideAnimated()
        }
        for (id, frame) in frames where frame.width > 1 && frame.height > 1 {
            let panel = resizePreviewPanels[id] ?? TilingDropPreviewPanel()
            resizePreviewPanels[id] = panel
            panel.show(frame: frame)
        }
    }

    func hideResizePreviews() {
        resizePreviewPanels.values.forEach { $0.hideAnimated() }
        resizePreviewPanels = [:]
    }

    private func showHandle(for divider: TilingDivider) {
        let panel: TilingHandlePanel
        if let existing = panels[divider.id] {
            panel = existing
        } else {
            panel = TilingHandlePanel(divider: divider)
            panel.onResizeStart = { [weak self] d in
                self?.isDragging = true
                self?.onResizeStart?(d)
            }
            panel.onResizeDrag = { [weak self] d, coord in
                self?.onResizeDrag?(d, coord)
            }
            panel.onResizeEnd = { [weak self] in
                self?.isDragging = false
                self?.onResizeEnd?()
            }
            panels[divider.id] = panel
        }

        panel.updatePosition(for: divider)
        panel.showAnimated()

        // Hide any other panels
        for (id, p) in panels where id != divider.id {
            p.hideAnimated()
        }
    }

    private func hideAllPanels() {
        guard !isDragging else { return }
        for panel in panels.values {
            panel.hideAnimated()
        }
    }

    func updateHandlePosition(dividerID: String, coordinate: CGFloat) {
        panels[dividerID]?.clampHandlePosition(to: coordinate)
    }
}

/// Mouse-transparent, sized to the exact space reserved beside the window.
private final class TilingColumnPillPanel: NSPanel {
    private let pillView = TilingColumnPillView(frame: .zero)
    private var transitionGeneration = 0
    private var tabIDs: [CGWindowID] = []

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = pillView
    }

    func show(_ pill: TilingColumnPill) {
        transitionGeneration &+= 1
        tabIDs = pill.tabIDs
        let height = TilingColumnPillView.height(for: pill.tabCount)
        let frame = CGRect(x: pill.railFrame.minX,
                           y: pill.railFrame.midY - height / 2,
                           width: pill.railFrame.width, height: height)
        pillView.frame = CGRect(origin: .zero, size: frame.size)
        pillView.update(count: pill.tabCount, selected: pill.selectedIndex,
                        edgeAttached: pill.edgeAttached, isLeft: pill.isLeft)
        if !isVisible {
            setFrame(frame, display: true)
            alphaValue = 0
            orderFrontRegardless()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { alphaValue = 1 }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    animator().alphaValue = 1
                }
            }
        } else if abs(self.frame.minX - frame.minX) > 1 ||
                    abs(self.frame.minY - frame.minY) > 1 ||
                    abs(self.frame.height - frame.height) > 1 {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { setFrame(frame, display: true) }
            else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().setFrame(frame, display: true)
                }
            }
        }
    }

    func select(_ windowID: CGWindowID) {
        guard let index = tabIDs.firstIndex(of: windowID) else { return }
        pillView.update(count: tabIDs.count, selected: index,
                        edgeAttached: pillView.edgeAttached, isLeft: pillView.isLeft)
    }

    func hidePill() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        pillView.stopAnimation()
        guard isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transitionGeneration == generation else { return }
                self.orderOut(nil)
            }
        }
    }

    func closePill() {
        transitionGeneration &+= 1
        pillView.stopAnimation()
        orderOut(nil)
    }
}

private final class TilingColumnPillView: NSView {
    private static let dot = TilingLayout.columnPillThickness
    private static let selectedLength: CGFloat = 14
    private static let spacing: CGFloat = 5
    private static let padding: CGFloat = 5
    private static let dimColor = NSColor.white.withAlphaComponent(0.42).cgColor
    private static let brightColor = NSColor.white.withAlphaComponent(0.96).cgColor

    private var count = 0
    /// Visual index (1 = top) of the tab the pill marks.
    private var selected = 0
    /// Dim dots, one per tab, and the one bright pill that travels between them.
    private var dots: [CAShapeLayer] = []
    private let highlight = CAShapeLayer()
    private(set) var edgeAttached = false
    private(set) var isLeft = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        highlight.fillColor = Self.brightColor
        layer?.addSublayer(highlight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderFinalState()
    }

    static func height(for count: Int) -> CGFloat {
        selectedLength + CGFloat(max(0, count - 1)) * (dot + spacing) + padding * 2
    }

    func update(count: Int, selected: Int, edgeAttached: Bool, isLeft: Bool) {
        if self.edgeAttached != edgeAttached || self.isLeft != isLeft {
            self.edgeAttached = edgeAttached
            self.isLeft = isLeft
            renderFinalState()
        }
        guard count > 1 else { stopAnimation(); return }
        // The window transition moves UP when a swipe advances to the next
        // tab. Reverse the visual index so the pill travels UP with it.
        let next = TilingLayout.verticalPillIndex(tabIndex: selected, count: count)
        if count != self.count {
            stopAnimation()
            self.count = count
            self.selected = next
            rebuildDots()
            renderFinalState()
            return
        }
        guard next != self.selected else { return }
        let from = self.selected
        self.selected = next
        stopAnimation()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            renderFinalState()
            return
        }
        animate(from: from, to: next)
    }

    /// The bright pill travels with the window it marks: its leading end
    /// sets off at once, the trailing end follows a beat later, so it
    /// stretches toward the new tab and gathers there — one pill in motion,
    /// never two half-lit ones. Same length and curve as the window slide.
    private func animate(from: Int, to: Int) {
        let duration = TilingTabSwitchTiming.transitionDuration
        let steps = 36
        var dotPaths = Array(repeating: [CGPath](), count: count)
        var dotAlphas = Array(repeating: [NSNumber](), count: count)
        var pillPaths: [CGPath] = []
        for step in 0...steps {
            let frame = renderedFrame(from: from, to: to, t: CGFloat(step) / CGFloat(steps))
            pillPaths.append(frame.pill)
            for index in 0..<count {
                dotPaths[index].append(frame.dots[index].path)
                dotAlphas[index].append(NSNumber(value: Float(frame.dots[index].alpha)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func keyframes(_ keyPath: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            return animation
        }
        highlight.path = pillPaths.last
        highlight.add(keyframes("path", pillPaths), forKey: "tabPath")
        for index in 0..<count {
            let dot = dots[index]
            dot.path = dotPaths[index].last
            dot.opacity = dotAlphas[index].last?.floatValue ?? 1
            dot.add(keyframes("path", dotPaths[index]), forKey: "tabPath")
            dot.add(keyframes("opacity", dotAlphas[index]), forKey: "tabAlpha")
        }
        CATransaction.commit()
    }

    func stopAnimation() {
        highlight.removeAnimation(forKey: "tabPath")
        for dot in dots {
            dot.removeAnimation(forKey: "tabPath")
            dot.removeAnimation(forKey: "tabAlpha")
        }
    }

    private func rebuildDots() {
        dots.forEach { $0.removeFromSuperlayer() }
        dots = (0..<count).map { _ in
            let dot = CAShapeLayer()
            dot.frame = bounds
            dot.fillColor = Self.dimColor
            layer?.insertSublayer(dot, below: highlight)
            return dot
        }
    }

    private func renderFinalState() {
        guard dots.count == count, count > 1 else { return }
        let frame = renderedFrame(from: selected, to: selected, t: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        highlight.path = frame.pill
        for (dot, item) in zip(dots, frame.dots) {
            dot.frame = bounds
            dot.path = item.path
            dot.opacity = Float(item.alpha)
        }
        CATransaction.commit()
    }

    /// Top to bottom, each tab's slot with `selected` (visual, 1-based) long.
    private func slots(selected: Int) -> [CGRect] {
        var y = bounds.maxY - Self.padding
        var rects: [CGRect] = []
        for index in 1...count {
            let length = index == selected ? Self.selectedLength : Self.dot
            y -= length
            rects.append(CGRect(x: railX, y: y, width: Self.dot, height: length))
            y -= Self.spacing
        }
        return rects
    }

    private var railX: CGFloat {
        edgeAttached
            ? (isLeft ? TilingLayout.columnPillEdgeOffset : bounds.maxX - Self.dot - TilingLayout.columnPillEdgeOffset)
            : bounds.midX - Self.dot / 2
    }

    private func renderedFrame(from: Int, to: Int, t: CGFloat) -> (pill: CGPath, dots: [(path: CGPath, alpha: CGFloat)]) {
        let before = slots(selected: from), after = slots(selected: to)
        func clamp(_ v: CGFloat) -> CGFloat { max(0, min(1, v)) }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
        func easeOut(_ p: CGFloat) -> CGFloat { 1 - pow(1 - p, 3) }
        func easeInOut(_ p: CGFloat) -> CGFloat { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
        // Leading end quick, trailing end a beat behind.
        let lead = easeOut(clamp(t / 0.7))
        let trail = easeInOut(clamp((t - 0.14) / 0.86))
        func rect(_ a: CGRect, _ b: CGRect, _ p: CGFloat) -> CGRect {
            CGRect(x: a.minX, y: lerp(a.minY, b.minY, p), width: a.width, height: lerp(a.height, b.height, p))
        }
        func path(_ r: CGRect) -> CGPath {
            let radius = min(r.width, r.height) / 2
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }

        let start = before[from - 1], end = after[to - 1]
        let pill: CGRect
        if from == to {
            pill = end
        } else {
            // Going down the rail (y shrinking): the bottom end leads.
            let down = to > from
            let leadEdge = down ? lerp(start.minY, end.minY, lead) : lerp(start.maxY, end.maxY, lead)
            let trailEdge = down ? lerp(start.maxY, end.maxY, trail) : lerp(start.minY, end.minY, trail)
            pill = CGRect(x: start.minX, y: min(leadEdge, trailEdge), width: start.width,
                          height: max(Self.dot, abs(leadEdge - trailEdge)))
        }

        var dots: [(CGPath, CGFloat)] = []
        for index in 1...count {
            let a = before[index - 1], b = after[index - 1]
            if index == to {
                // Under the arriving pill: gone as the pill gets there.
                let dotAtEnd = CGRect(x: b.minX, y: b.midY - Self.dot / 2, width: Self.dot, height: Self.dot)
                dots.append((path(rect(a, dotAtEnd, trail)), from == to ? 0 : 1 - lead))
            } else if index == from {
                // Left behind: shows once the trailing end has let go.
                dots.append((path(b), trail))
            } else {
                // The rest shift over as the long slot moves.
                dots.append((path(rect(a, b, trail)), 1))
            }
        }
        return (path(pill), dots)
    }
}

/// What a drop will do, shown as a badge in the preview.
enum TilingDropPreviewKind: Equatable {
    case move, swap, tab
    case split(left: Bool)
}

/// Input-transparent border showing where a moved tiled window will land.
final class TilingDropPreviewPanel: NSPanel {
    private var transitionGeneration = 0

    var previewKind: TilingDropPreviewKind = .move {
        didSet {
            guard previewKind != oldValue, let view = contentView as? TilingDropPreviewView else { return }
            view.kind = previewKind
        }
    }

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        alphaValue = 0
        contentView = TilingDropPreviewView(frame: .zero)
    }

    func show(frame: CGRect) {
        transitionGeneration &+= 1
        let wasVisible = isVisible && alphaValue > 0.05
        if wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
                animator().alphaValue = 1
            }
        } else {
            setFrame(frame, display: true)
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func hideAnimated() {
        guard isVisible else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            self.orderOut(nil)
            self.previewKind = .move
        })
    }
}

final class TilingDropPreviewView: NSView {
    override var isOpaque: Bool { false }

    private static let badgeSide: CGFloat = 64
    private let badge = NSView()
    private let icon = NSImageView()

    var kind: TilingDropPreviewKind = .move {
        didSet {
            guard kind != oldValue else { return }
            updateBadge(from: oldValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        badge.layer?.cornerRadius = 16
        badge.layer?.cornerCurve = .continuous
        badge.isHidden = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        badge.addSubview(icon)
        addSubview(badge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let side = Self.badgeSide
        badge.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        icon.frame = badge.bounds.insetBy(dx: 14, dy: 14)
        // Scale about the badge's center, not its corner.
        if let layer = badge.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        }
        badge.alphaValue = bounds.width > side + 22 && bounds.height > side + 22 ? 1 : 0
    }

    private static func symbol(for kind: TilingDropPreviewKind) -> String? {
        switch kind {
        case .move: return nil
        case .swap: return "arrow.left.arrow.right"
        case .tab: return "rectangle.stack"
        case .split(let left): return left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled"
        }
    }

    /// Morphs the icon between kinds, and pops the badge in when it first appears.
    private func updateBadge(from old: TilingDropPreviewKind) {
        guard let name = Self.symbol(for: kind),
              let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            badge.isHidden = true
            return
        }
        let appearing = badge.isHidden || Self.symbol(for: old) == nil
        badge.isHidden = false
        if #available(macOS 14.0, *), !appearing {
            icon.setSymbolImage(image, contentTransition: .replace.downUp)
            icon.addSymbolEffect(.bounce.up, options: .nonRepeating)
        } else {
            icon.image = image
        }
        guard let layer = badge.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = appearing ? 0.4 : 0.82
        pop.toValue = 1
        pop.damping = 12
        pop.stiffness = 260
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "pop")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 3, dy: 3)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}

/// A compact, borderless, non-activating floating panel sized exactly to the pill handle.
final class TilingHandlePanel: NSPanel {
    var onResizeStart: ((TilingDivider) -> Void)?
    var onResizeDrag: ((TilingDivider, CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    private var divider: TilingDivider
    private let handleView: TilingHandleView

    init(divider: TilingDivider) {
        self.divider = divider
        let size = Self.panelSize(for: divider.axis)
        let contentRect = CGRect(origin: .zero, size: size)
        self.handleView = TilingHandleView(frame: contentRect, axis: divider.axis)

        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        alphaValue = 0.0

        contentView = handleView

        handleView.onResizeStart = { [weak self] in
            guard let self else { return }
            self.onResizeStart?(self.divider)
        }
        handleView.onResizeDrag = { [weak self] coord in
            guard let self else { return }
            self.onResizeDrag?(self.divider, coord)
        }
        handleView.onResizeEnd = { [weak self] in
            self?.onResizeEnd?()
        }
    }

    static func panelSize(for axis: TilingDivider.Axis) -> CGSize {
        switch axis {
        case .vertical:
            return CGSize(width: 22, height: 56)
        case .horizontal:
            return CGSize(width: 56, height: 22)
        }
    }

    func updatePosition(for divider: TilingDivider) {
        self.divider = divider
        handleView.updateDivider(divider)

        let size = Self.panelSize(for: divider.axis)
        let origin: CGPoint
        switch divider.axis {
        case .vertical:
            let midY = (divider.span.lowerBound + divider.span.upperBound) / 2.0
            origin = CGPoint(x: round(divider.coordinate - size.width / 2.0),
                             y: round(midY - size.height / 2.0))
        case .horizontal:
            let midX = (divider.span.lowerBound + divider.span.upperBound) / 2.0
            origin = CGPoint(x: round(midX - size.width / 2.0),
                             y: round(divider.coordinate - size.height / 2.0))
        }
        setFrameOrigin(origin)
    }

    func showAnimated() {
        if !isVisible || alphaValue < 0.05 {
            orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1.0
        }
    }

    func hideAnimated() {
        guard isVisible, alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            if self?.alphaValue ?? 0 < 0.05 {
                self?.orderOut(nil)
            }
        })
    }

    func finishDrag() {
        handleView.finishDrag()
    }

    func clampHandlePosition(to coordinate: CGFloat) {
        var origin = frame.origin
        switch divider.axis {
        case .vertical:
            origin.x = round(coordinate - frame.width / 2.0)
        case .horizontal:
            origin.y = round(coordinate - frame.height / 2.0)
        }
        setFrameOrigin(origin)
    }
}

/// Custom view rendering the pill handle and handling cursor & dragging.
final class TilingHandleView: NSView {
    var onResizeStart: (() -> Void)?
    var onResizeDrag: ((CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    private let axis: TilingDivider.Axis
    private var divider: TilingDivider?
    private var isDragging = false
    private var dragStartPointer: CGPoint = .zero
    private var dragStartCoord: CGFloat = 0

    init(frame: CGRect, axis: TilingDivider.Axis) {
        self.axis = axis
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateDivider(_ divider: TilingDivider) {
        self.divider = divider
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func finishDrag() {
        isDragging = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor = axis == .vertical ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // Forward scroll wheel events to next responder so scrolling is never consumed
        nextResponder?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let divider else { return }
        isDragging = true
        dragStartPointer = NSEvent.mouseLocation
        dragStartCoord = divider.coordinate

        switch axis {
        case .vertical: NSCursor.resizeLeftRight.push()
        case .horizontal: NSCursor.resizeUpDown.push()
        }

        onResizeStart?()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let divider, let window else { return }
        let currentMouse = NSEvent.mouseLocation
        let delta: CGFloat
        switch axis {
        case .vertical: delta = currentMouse.x - dragStartPointer.x
        case .horizontal: delta = currentMouse.y - dragStartPointer.y
        }

        let raw = dragStartCoord + delta
        let clamped = min(divider.maxCoordinate, max(divider.minCoordinate, raw))

        // Live-update panel position under cursor
        var frame = window.frame
        switch axis {
        case .vertical:
            frame.origin.x = round(clamped - frame.width / 2.0)
        case .horizontal:
            frame.origin.y = round(clamped - frame.height / 2.0)
        }
        window.setFrameOrigin(frame.origin)

        onResizeDrag?(clamped)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        NSCursor.pop()
        isDragging = false
        needsDisplay = true
        onResizeEnd?()
    }

    /// Computes the dragger thickness based on the space (padding/gap) available,
    /// ensuring ample breathing room on both sides of the dragger handle.
    private func draggerThickness(for space: CGFloat) -> CGFloat {
        let base: CGFloat
        if space <= 0 {
            base = 1.0
        } else if space <= 2 {
            base = 0.8
        } else if space <= 3 {
            base = 1.0
        } else if space <= 4 {
            // For padding 4, give 1.35pt breathing room on each side (2.7pt physical)
            base = 1.3
        } else if space <= 5 {
            base = 1.6
        } else if space <= 6 {
            base = 2.0
        } else {
            base = min(3.0, space - 3.0)
        }

        if isDragging {
            // Very subtle expansion while keeping plenty of breathing room
            return space > 2 ? base + 0.2 : base
        }
        return base
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()

        // Pill shape centered in view bounds, dynamically sized to gap space
        let space = divider?.gap ?? AppSettings.shared.tilingPadding
        let pillLength: CGFloat = 44.0
        let pillThickness: CGFloat = draggerThickness(for: space)
        let pillRect: CGRect

        switch axis {
        case .vertical:
            let x = (bounds.width - pillThickness) / 2.0
            let y = (bounds.height - pillLength) / 2.0
            pillRect = CGRect(x: x, y: y, width: pillThickness, height: pillLength)
        case .horizontal:
            let x = (bounds.width - pillLength) / 2.0
            let y = (bounds.height - pillThickness) / 2.0
            pillRect = CGRect(x: x, y: y, width: pillLength, height: pillThickness)
        }

        let radius = min(pillRect.width, pillRect.height) / 2.0
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

        // Soft, tight ambient shadow that stays inside the gap and doesn't spill onto windows
        context.setShadow(offset: .zero, blur: 0.8, color: NSColor.black.withAlphaComponent(0.18).cgColor)

        // Pill fill - thinner and less opaque
        let bodyColor = isDragging ? NSColor(white: 1.0, alpha: 0.85) : NSColor(white: 1.0, alpha: 0.65)
        bodyColor.setFill()
        pillPath.fill()

        // Pill border - subtle
        let borderColor = isDragging
            ? NSColor.controlAccentColor.withAlphaComponent(0.60)
            : NSColor.black.withAlphaComponent(0.15)
        borderColor.setStroke()
        pillPath.lineWidth = 0.4
        pillPath.stroke()

        context.restoreGState()
    }
}
