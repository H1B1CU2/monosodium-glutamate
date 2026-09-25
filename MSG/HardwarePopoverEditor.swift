import AppKit
import SwiftUI

/// Settings embeds the production popover. An editing surface handles drag
/// gestures without activating fan presets, energy controls, or Settings.
@available(macOS 14.0, *)
struct HardwarePopoverEditor: NSViewRepresentable {
    let stats: HardwareStats
    let layout: HardwareCardLayout
    let hiddenCards: Set<String>
    let onMove: (HardwareCardLayout) -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> HardwarePopoverEditorView {
        HardwarePopoverEditorView()
    }
    func updateNSView(_ view: HardwarePopoverEditorView, context: Context) {
        view.onMove = onMove
        view.onHeightChange = onHeightChange
        view.update(stats: stats, arrangement: layout, hidden: hiddenCards,
                    samples: HardwareMonitor.shared.powerHistory)
    }
}

private extension NSPasteboard.PasteboardType {
    static let hardwareCard = NSPasteboard.PasteboardType("H1D3S1GN.MSG.hardware-card")
}

final class HardwarePopoverEditorView: NSView, NSDraggingSource {
    // Leave controls styled exactly as in the popover. hitTest routes every
    // preview click here, so none of the controls can change hardware settings.
    let content = HardwarePopoverContentView(isInteractive: true, arrowHeight: 8, blendingMode: .withinWindow)
    var onMove: ((HardwareCardLayout) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    private var arrangement = HardwareCardLayout(columns: [], order: [], batterySpan: "full", batterySide: "left")
    private var modes = HardwareMonitor.EnergyModes()
    private var latest: (HardwareStats, HardwareCardLayout, Set<String>, [Double])?
    private var dragID: String?
    private var downPoint: NSPoint?
    private var isDragging = false
    private var frozenFrames: [String: NSRect] = [:]
    private let dropOverlay = HardwareDropIndicatorView()
    private var indicator: NSRect? { didSet { dropOverlay.indicator = indicator } }
    private var destination: (String, HardwareCardLayout.Edge)?
    private var measuredHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(content)
        addSubview(dropOverlay)
        registerForDraggedTypes([.hardwareCard])
        setAccessibilityLabel("Hardware popover layout editor")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let modes = HardwareMonitor.readEnergyModes()
            DispatchQueue.main.async {
                guard let self else { return }
                self.modes = modes
                self.renderLatest()
            }
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: content.popWidth, height: max(60, content.contentHeight))
    }
    override func layout() {
        super.layout()
        content.frame = bounds
        dropOverlay.frame = bounds
        content.shell.arrowCenterX = bounds.midX
    }

    func update(stats: HardwareStats, arrangement: HardwareCardLayout, hidden: Set<String>, samples: [Double]) {
        latest = (stats, arrangement, hidden, samples)
        renderLatest()
    }
    private func renderLatest() {
        guard !isDragging, let (stats, arrangement, hidden, samples) = latest else { return }
        self.arrangement = arrangement
        content.cardColumns = arrangement.columns
        content.moduleOrder = arrangement.order
        content.hiddenCards = hidden
        content.batteryCardSpan = arrangement.batterySpan
        content.batteryCardSide = arrangement.batterySide
        content.energyModes = modes
        content.rebuild(stats: stats, powerSamples: samples)
        let height = content.contentHeight
        content.frame = NSRect(x: 0, y: 0, width: content.popWidth, height: height)
        content.shell.arrowCenterX = content.popWidth / 2
        content.layoutSubtreeIfNeeded()
        invalidateIntrinsicContentSize()
        if abs(measuredHeight - height) > 0.5 {
            measuredHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.measuredHeight - height) < 0.5 else { return }
                self.onHeightChange?(height)
            }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        content.layoutSubtreeIfNeeded()
        dragID = content.cardFrames.first { $0.value.contains(point) }?.key
        downPoint = point
    }
    override func mouseUp(with event: NSEvent) {
        if !isDragging { dragID = nil; downPoint = nil }
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let id = dragID, let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        content.layoutSubtreeIfNeeded()
        frozenFrames = content.cardFrames
        guard let rect = frozenFrames[id] else { return }
        let item = NSPasteboardItem()
        item.setString(id, forType: .hardwareCard)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: rect.size)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: rect) {
            content.cacheDisplay(in: rect, to: bitmap)
            image.addRepresentation(bitmap)
        }
        dragging.setDraggingFrame(rect, contents: image)
        isDragging = true
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag()
    }
    private func finishDrag() {
        isDragging = false; dragID = nil; downPoint = nil
        frozenFrames = [:]; indicator = nil; destination = nil
        renderLatest()
    }

    private var composite: Bool {
        arrangement.columns.count >= 3 && arrangement.batterySpan == "2x2" && frozenFrames["battery"] != nil
            && frozenFrames.keys.contains { HardwareCardLayout.statistics.contains($0) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDestination(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDestination(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        destination = nil; indicator = nil; needsDisplay = true
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { destination != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dragged = sender.draggingPasteboard.string(forType: .hardwareCard),
              let (target, edge) = destination else { return false }
        var next = arrangement
        guard next.move(dragged, target: target, edge: edge, composite: composite) else { return false }
        // Commit once on drop. Hover never changes defaults or rebuilds views.
        finishDrag()
        onMove?(next)
        return true
    }
    private func updateDestination(_ sender: NSDraggingInfo) -> NSDragOperation {
        destination = nil; indicator = nil
        defer { needsDisplay = true }
        guard isDragging, (sender.draggingSource as? HardwarePopoverEditorView) === self,
              let dragged = sender.draggingPasteboard.string(forType: .hardwareCard) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.insetBy(dx: -8, dy: -8).contains(point) else { return [] }
        guard let drop = HardwareCardDrop.resolve(dragged: dragged, point: point, frames: frozenFrames,
                                                 arrangement: arrangement, composite: composite) else { return [] }
        destination = (drop.target, drop.edge)
        indicator = drop.indicator
        return .move
    }
}

private final class HardwareDropIndicatorView: NSView {
    var indicator: NSRect? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let indicator else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: indicator, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
