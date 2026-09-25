import AppKit

/// Manages interactive floating resize handle panels for tiled window dividers.
/// Uses compact, individual pill-sized panels only where dividers exist,
/// ensuring zero full-screen overlays so app clicks and scrolling are never blocked.
final class TilingResizeOverlayController {
    var onResizeStart: ((TilingDivider) -> Void)?
    var onResizeDrag: ((TilingDivider, CGFloat) -> Void)?
    var onResizeEnd: (() -> Void)?

    private var panels: [String: TilingHandlePanel] = [:]
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
        dropPreviewPanel?.orderOut(nil)
        dropPreviewPanel = nil
        resizePreviewPanels.values.forEach { $0.orderOut(nil) }
        resizePreviewPanels = [:]
        panels = [:]
        activeDividers = []
    }

    func update(dividers: [String: [TilingDivider]], tiledWindowIDs: Set<CGWindowID> = []) {
        guard !isDragging else { return }
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
