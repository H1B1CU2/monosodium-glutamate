import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - DockItem

/// A live application tile in the real macOS Dock, resolved via Accessibility.
private struct DockItem: Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// Tile frame in Cocoa (bottom-left origin) global coordinates.
    let frame: CGRect

    /// Identity is the app, not the tile rect — with Dock magnification the same
    /// tile's frame changes on every mouse move, and frame-sensitive equality
    /// would re-trigger capture continuously while gliding.
    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        lhs.pid == rhs.pid
    }
}

// MARK: - DockHoverController

/// Watches the system Dock and shows a native-looking window-preview panel when
/// the cursor rests on a running app's tile. Clicking a thumbnail raises that
/// exact window and activates the app. Layers on top of the Dock — it never
/// touches or suppresses native Dock behavior. All AX/SkyLight window plumbing
/// lives in `WindowPreviewCapture`; this type only tracks hover state and owns
/// the panel UI.
@available(macOS 14.0, *)
final class DockHoverController {

    private let settings: AppSettings

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?

    private var hoverTimer: Timer?

    /// Item we're about to show (after the hover delay) or currently showing.
    private var pendingItem: DockItem?
    private var shownItem: DockItem?
    private var hoveredItem: DockItem?
    private var isPanelVisible = false
    /// Generation counter so a slow async capture for an abandoned tile is ignored.
    private var captureToken = 0

    private var lastMoveStamp: CFAbsoluteTime = 0
    private var dockOrientationCache: (stamp: CFAbsoluteTime, value: String)?

    private var panel: DockPreviewPanel?
    private var dockApp: AXUIElement?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() {
        guard globalMonitor == nil else { return }
        resolveDockElement()
        let handler: (NSEvent?) -> Void = { [weak self] _ in self?.handleMouseMoved() }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { handler($0) }
        localMonitor  = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in handler(e); return e }

        let clickHandler: (NSEvent) -> Void = { [weak self] e in self?.handleMouseClick(e) }
        clickMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { clickHandler($0) }
        clickMonitorLocal  = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in clickHandler(e); return e }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = clickMonitorGlobal { NSEvent.removeMonitor(m); clickMonitorGlobal = nil }
        if let m = clickMonitorLocal  { NSEvent.removeMonitor(m); clickMonitorLocal = nil }
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingItem = nil
        shownItem = nil
        hoveredItem = nil
        isPanelVisible = false
        captureToken &+= 1
        panel?.orderOut()
    }

    // MARK: Mouse tracking

    private func handleMouseMoved() {
        // Mouse-moved events stream at display refresh rate; 40 Hz is plenty for
        // hover intent and caps the per-move work.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveStamp < 0.025 { return }
        lastMoveStamp = now

        let mouse = NSEvent.mouseLocation

        // Only AX-hit-test the Dock when the cursor is inside the band of screen
        // the Dock occupies — moves everywhere else cost a few rect checks.
        if isNearDock(mouse) {
            switch dockHit(at: mouse) {
            case .app(let item):
                // Same tile already hovered/shown/queued — just refresh its frame
                // (magnification inflates it while the cursor rides the tile).
                if item == hoveredItem {
                    hoveredItem = item
                    return
                }
                hoveredItem = item

                // Gliding onto a tile whose app has no previewable windows: drop
                // any visible/queued preview immediately (don't let the previous
                // app's card linger).
                if !WindowPreviewCapture.hasPreviewableWindows(pid: item.pid) {
                    cancelPendingShow()
                    let savedItem = hoveredItem
                    if shownItem != nil { hide() }
                    hoveredItem = savedItem
                    return
                }

                if isPanelVisible {
                    // A preview is already up → glide to the new tile instantly.
                    switchTo(item)
                } else {
                    // First appearance → wait out the hover-intent delay.
                    scheduleShow(for: item)
                }
                return

            case .otherTile:
                // Over a Dock tile that can never have a preview (a non-running
                // app, folder, Trash, a minimized-window tile). Hide immediately —
                // the bridge region below must not keep the previous app's card
                // alive across foreign tiles.
                hoveredItem = nil
                cancelPendingShow()
                if shownItem != nil { hide() }
                return

            case .none:
                break
            }
        }

        // Not over a tile — keep alive only while inside the panel (or the small
        // bridge to its tile). Anywhere else hides instantly (with the fade).
        if isInsideActiveRegion(mouse) { return }

        hoveredItem = nil
        cancelPendingShow()
        if shownItem != nil { hide() }
    }

    /// True when the cursor is over the visible panel or the gap bridging it to
    /// the tile it belongs to — i.e. still "within" the preview.
    private func isInsideActiveRegion(_ mouse: NSPoint) -> Bool {
        if isPanelVisible, let p = panel, p.isVisible {
            var region = p.frame.insetBy(dx: -2, dy: -2)
            if let tile = shownItem?.frame { region = region.union(tile) }
            return region.contains(mouse)
        } else if let tile = shownItem?.frame {
            let dx = max(0, max(tile.minX - mouse.x, mouse.x - tile.maxX))
            let dy = max(0, max(tile.minY - mouse.y, mouse.y - tile.maxY))
            let dist = sqrt(dx * dx + dy * dy)
            return dist <= 80
        }
        return false
    }

    private func handleMouseClick(_ event: NSEvent) {
        guard shownItem != nil else { return }
        // A right-click inside the panel closes just that window's card (handled by
        // the card itself) and keeps the preview open — so don't dismiss here. Any
        // click outside the panel dismisses the whole preview.
        if !isInsidePanel(NSEvent.mouseLocation) {
            hide()
        }
    }

    private func isInsidePanel(_ mouse: NSPoint) -> Bool {
        guard let p = panel, p.isVisible else { return false }
        return p.frame.contains(mouse)
    }

    // MARK: Show scheduling

    private func scheduleShow(for item: DockItem) {
        pendingItem = item
        hoverTimer?.invalidate()
        let delay = max(0.05, settings.dockPreviewHoverDelay)
        hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.beginCapture(for: item)
        }
    }

    /// Immediate (no-delay) switch to another tile while a preview is on screen.
    private func switchTo(_ item: DockItem) {
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingItem = item
        beginCapture(for: item)
    }

    private func cancelPendingShow() {
        hoverTimer?.invalidate(); hoverTimer = nil
        pendingItem = nil
    }

    private func beginCapture(for item: DockItem) {
        guard pendingItem == item else { return }
        captureToken &+= 1
        let token = captureToken
        let pid = item.pid
        Task { @MainActor [weak self] in
            let windows = await WindowPreviewCapture.capture(pid: pid)
            guard let self, self.captureToken == token, self.pendingItem == item else { return }

            let isWindowed = !windows.isEmpty && !(windows.count == 1 && windows[0].id == 0)
            if isWindowed {
                self.present(item: item, windows: windows)
            } else {
                self.shownItem = nil
                self.pendingItem = nil
                self.isPanelVisible = false
                self.panel?.dismiss()
            }
        }
    }

    private func present(item: DockItem, windows: [CapturedWindow]) {
        shownItem = item
        pendingItem = nil
        isPanelVisible = true

        if panel == nil { panel = DockPreviewPanel() }
        let icon = item.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.icon }

        // Budget the card row to the anchor screen's visible width (minus card
        // chrome + edge margins) so overflowing rows scroll instead of spilling.
        let screen = NSScreen.screens.first { $0.frame.intersects(item.frame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let maxContentWidth = max(320, screen.visibleFrame.width - 100)

        panel?.present(
            appName: item.name,
            appIcon: icon,
            windows: windows,
            thumbHeight: settings.dockPreviewThumbHeight,
            maxContentWidth: maxContentWidth,
            placement: .dockTile(anchor: item.frame, offset: settings.dockPreviewOffset),
            onSelect: { [weak self] win in
                self?.activate(item: item, window: win)
            },
            onClose: { [weak self] win in
                self?.closeWindow(pid: item.pid, windowID: win.id)
            },
            // Re-evaluate on every panel enter/exit so leaving it hides instantly.
            onHoverChanged: { [weak self] _ in self?.handleMouseMoved() }
        )
    }

    private func hide() {
        shownItem = nil
        pendingItem = nil
        hoveredItem = nil
        isPanelVisible = false
        panel?.dismiss()
    }

    // MARK: Activation

    private func activate(item: DockItem, window: CapturedWindow) {
        let pid = item.pid
        let windowID = window.id
        let bounds = window.bounds
        hide()
        // The AX lookup may brute-force remote tokens (slow sync IPC) — keep it
        // off the main thread; the backend hops to main only where required.
        Task {
            await WindowPreviewCapture.raiseWindow(pid: pid, windowID: windowID, fallbackBounds: bounds)
        }
    }

    private func closeWindow(pid: pid_t, windowID: CGWindowID) {
        Task {
            await WindowPreviewCapture.closeWindow(pid: pid, windowID: windowID)
        }
    }

    // MARK: Dock Accessibility

    private func resolveDockElement() {
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        }
    }

    /// True when the point sits in the strip of any screen the Dock occupies
    /// (pinned inset plus magnification headroom; a fixed reveal band when the
    /// Dock auto-hides). Gates the per-move AX hit-test.
    private func isNearDock(_ p: NSPoint) -> Bool {
        let orientation = dockOrientation()
        for screen in NSScreen.screens {
            let f = screen.frame
            let v = screen.visibleFrame
            let band: CGRect
            switch orientation {
            case "left":
                let inset = max(0, v.minX - f.minX)
                let thickness = inset > 0 ? inset + 100 : 150
                band = CGRect(x: f.minX, y: f.minY, width: thickness, height: f.height)
            case "right":
                let inset = max(0, f.maxX - v.maxX)
                let thickness = inset > 0 ? inset + 100 : 150
                band = CGRect(x: f.maxX - thickness, y: f.minY, width: thickness, height: f.height)
            default: // bottom
                let inset = max(0, v.minY - f.minY)
                let thickness = inset > 0 ? inset + 100 : 150
                band = CGRect(x: f.minX, y: f.minY, width: f.width, height: thickness)
            }
            if band.contains(p) { return true }
        }
        return false
    }

    private func dockOrientation() -> String {
        let now = CFAbsoluteTimeGetCurrent()
        if let c = dockOrientationCache, now - c.stamp < 10 { return c.value }
        let value = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        dockOrientationCache = (now, value)
        return value
    }

    /// What sits under the cursor in the Dock.
    private enum DockHit {
        /// A running application's tile — the only thing that gets a preview.
        case app(DockItem)
        /// Some other Dock tile: a non-running app, folder, Trash, a minimized
        /// window, the separator. A preview can never belong to it, so hovering
        /// one must drop any visible card.
        case otherTile
        /// No Dock tile at all under the point.
        case none
    }

    /// Hit-tests the Dock for the tile under the given Cocoa point.
    private func dockHit(at cocoaPoint: NSPoint) -> DockHit {
        if dockApp == nil { resolveDockElement() }
        guard let dockApp else { return .none }

        let axPoint = Self.cocoaToAX(cocoaPoint)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockApp, Float(axPoint.x), Float(axPoint.y), &element) == .success,
              let el = element else { return .none }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleRef)
        guard let subrole = subroleRef as? String, subrole.hasSuffix("DockItem") else { return .none }
        guard subrole == "AXApplicationDockItem" else { return .otherTile }

        guard let frame = WindowPreviewCapture.axFrame(of: el) else { return .otherTile }
        let cocoaFrame = Self.axRectToCocoa(frame)

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
        let title = (titleRef as? String) ?? ""

        // Resolve the running app behind the tile via its file URL, falling back
        // to a name match. Only running apps (with a pid) get a preview — an app
        // tile without one (app not launched) is just another foreign tile.
        var urlRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &urlRef)
        let bundleID: String? = (urlRef as? URL).flatMap { Bundle(url: $0)?.bundleIdentifier }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID ?? "").first
            ?? NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.localizedName == title
            }
        guard let app = running,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .otherTile }

        return .app(DockItem(pid: app.processIdentifier,
                             bundleID: app.bundleIdentifier ?? bundleID,
                             name: app.localizedName ?? title,
                             frame: cocoaFrame))
    }

    // MARK: Coordinate conversion (Cocoa bottom-left ⇄ AX/Quartz top-left)

    private static var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    private static func cocoaToAX(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    private static func axRectToCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - PreviewPlacement

/// Where a preview card sits relative to the thing it describes. Both cases keep
/// the card fully on the anchor's screen; `offset` is the user's extra gap.
@available(macOS 14.0, *)
enum PreviewPlacement {
    /// Adjacent to a Dock tile, on the side facing away from the screen edge the
    /// Dock hugs (above for a bottom Dock, beside for a left/right one).
    case dockTile(anchor: CGRect, offset: CGFloat)
    /// Below the whole app-switcher panel, horizontally centered on the selected
    /// tile — flipping above the switcher when there is no room beneath it.
    case appSwitcher(switcher: CGRect, selected: CGRect, offset: CGFloat)

    /// The rect the card belongs to — used to pick the screen it is placed on.
    var anchorRect: CGRect {
        switch self {
        case .dockTile(let anchor, _):       return anchor
        case .appSwitcher(let switcher, _, _): return switcher
        }
    }
}

// MARK: - DockPreviewPanel

/// Borderless, non-activating floating panel that hosts the SwiftUI preview card
/// and positions itself against a `PreviewPlacement`. Shared by the Dock hover
/// preview and the app-switcher preview so both draw the identical card.
///
/// `interactive: false` makes the panel click- and hover-through (the app
/// switcher owns the mouse while it is up, so the card must never intercept it).
@available(macOS 14.0, *)
final class DockPreviewPanel {

    private var panel: NSPanel?
    private var hosting: NSHostingController<DockPreviewView>?
    private let model = DockPreviewModel()
    private let interactive: Bool
    private let level: NSWindow.Level

    init(interactive: Bool = true, level: NSWindow.Level = .statusBar) {
        self.interactive = interactive
        self.level = level
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    func present(appName: String,
                 appIcon: NSImage?,
                 windows: [CapturedWindow],
                 thumbHeight: CGFloat,
                 maxContentWidth: CGFloat,
                 placement: PreviewPlacement,
                 onSelect: @escaping (CapturedWindow) -> Void = { _ in },
                 onClose: @escaping (CapturedWindow) -> Void = { _ in },
                 onHoverChanged: @escaping (Bool) -> Void = { _ in }) {

        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }

        model.onSelect = onSelect
        model.onClose = { [weak self] win in
            onClose(win)
            if let self {
                withAnimation(.easeInOut(duration: 0.22)) {
                    self.model.windows.removeAll(where: { $0.id == win.id })
                }
                if self.model.windows.isEmpty {
                    self.dismiss()
                } else {
                    self.hosting?.view.layoutSubtreeIfNeeded()
                    if let fitting = self.hosting?.view.fittingSize {
                        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
                        let targetFrame = NSRect(origin: self.position(for: size, placement: placement),
                                                 size: size)
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.22
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            ctx.allowsImplicitAnimation = true
                            self.panel?.animator().setFrame(targetFrame, display: true)
                        }
                    }
                }
            }
        }
        model.onHoverChanged = onHoverChanged

        let wasVisible = panel.isVisible
        let apply = {
            self.model.appName = appName
            self.model.appIcon = appIcon
            self.model.windows = windows
            self.model.thumbHeight = thumbHeight
            self.model.maxContentWidth = maxContentWidth
        }

        // When already visible, mutate the model inside an animation so the
        // content cross-fades/morphs; otherwise set it plainly.
        if wasVisible {
            withAnimation(.easeInOut(duration: 0.22)) { apply() }
        } else {
            apply()
        }

        // Final intrinsic size for the new content.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let targetFrame = NSRect(origin: position(for: size, placement: placement),
                                 size: size)

        if wasVisible {
            // Morph: glide + resize the panel toward the new tile in step with
            // the SwiftUI content animation above.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            }
            // The app switcher re-orders its own window on every Tab, so re-assert
            // the card's position in the stack even when it is already up.
            panel.orderFrontRegardless()
        } else {
            panel.setFrame(targetFrame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    func orderOut() { panel?.orderOut(nil) }

    private func buildPanel() {
        let h = NSHostingController(rootView: DockPreviewView(model: model))
        h.view.wantsLayer = true
        h.sizingOptions = [.intrinsicContentSize]
        hosting = h

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = h.view
        p.isFloatingPanel = true
        p.level = level
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = interactive
        p.ignoresMouseEvents = !interactive
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
    }

    private func position(for size: NSSize, placement: PreviewPlacement) -> NSPoint {
        let anchor = placement.anchorRect
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        switch placement {
        case .dockTile(let tile, let offset):
            return positionByDock(size: size, anchor: tile, offset: offset, screen: screen)
        case .appSwitcher(let switcher, let selected, let offset):
            return positionBySwitcher(size: size, switcher: switcher, selected: selected,
                                      offset: offset, screen: screen)
        }
    }

    /// Places the card adjacent to the tile on the side facing away from the
    /// screen edge the Dock hugs (above for a bottom Dock, beside for left/right).
    private func positionByDock(size: NSSize, anchor: CGRect, offset: CGFloat, screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        // Base gap between the tile and the card, plus the user `offset` which
        // pushes the card further from the Dock.
        let gap: CGFloat = 8 + offset
        let edge: CGFloat = 24

        var x: CGFloat
        var y: CGFloat

        if anchor.minY <= screen.frame.minY + edge {
            // Bottom Dock → card above the tile, horizontally centered.
            x = anchor.midX - size.width / 2
            y = anchor.maxY + gap
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
            y = min(max(y, screen.frame.minY + 8), vf.maxY - size.height - 8)
        } else if anchor.minX <= screen.frame.minX + edge {
            // Left Dock → card to the right, vertically centered.
            x = anchor.maxX + gap
            y = anchor.midY - size.height / 2
            x = min(max(x, screen.frame.minX + 8), vf.maxX - size.width - 8)
            y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        } else {
            // Right Dock → card to the left.
            x = anchor.minX - gap - size.width
            y = anchor.midY - size.height / 2
            x = min(max(x, vf.minX + 8), screen.frame.maxX - size.width - 8)
            y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        return NSPoint(x: x, y: y)
    }

    /// Places the card clear of the whole switcher panel — beneath it by default,
    /// above it when the card is taller than the room below — and centers it on
    /// the selected tile so the card visibly "belongs" to the highlighted app.
    private func positionBySwitcher(size: NSSize, switcher: CGRect, selected: CGRect,
                                    offset: CGFloat, screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let gap: CGFloat = 16 + offset

        let x = min(max(selected.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)

        let below = switcher.minY - gap - size.height
        let above = switcher.maxY + gap
        var y: CGFloat
        if below >= vf.minY + 8 {
            y = below
        } else if above + size.height <= vf.maxY - 8 {
            y = above
        } else {
            // Neither side fits: sit as low as the screen allows, overlapping the
            // switcher rather than falling off the display.
            y = vf.minY + 8
        }
        y = min(max(y, vf.minY + 8), max(vf.minY + 8, vf.maxY - size.height - 8))
        return NSPoint(x: x, y: y)
    }
}

// MARK: - DockPreviewView

/// Observable backing for the card so glide-switches animate (cross-fade /
/// resize) instead of hard-swapping the hosting controller's root view.
@available(macOS 14.0, *)
private final class DockPreviewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage? = nil
    @Published var windows: [CapturedWindow] = []
    @Published var thumbHeight: CGFloat = 140
    /// Maximum width the card row may occupy before it becomes horizontally
    /// scrollable (derived from the anchor screen's visible width).
    @Published var maxContentWidth: CGFloat = 1200
    var onSelect: (CapturedWindow) -> Void = { _ in }
    var onClose: (CapturedWindow) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }
}

@available(macOS 14.0, *)
private struct DockPreviewView: View {
    static let shadowInset: CGFloat = 10

    @ObservedObject var model: DockPreviewModel

    private var maxThumbWidth: CGFloat { model.thumbHeight * 1.9 }

    /// Outer width a single card occupies (image width + its 8pt side padding).
    private func cardOuterWidth(for win: CapturedWindow) -> CGFloat {
        let aspect = win.image.size.height > 0 ? win.image.size.width / win.image.size.height : 1.4
        let w = min(maxThumbWidth, max(80, model.thumbHeight * aspect))
        return w + 16
    }

    /// Natural (unclamped) width of the whole card row.
    private var naturalRowWidth: CGFloat {
        let cards = model.windows.reduce(0) { $0 + cardOuterWidth(for: $1) }
        let spacing = 10 * CGFloat(max(0, model.windows.count - 1))
        return cards + spacing + 8   // + the row's 4pt horizontal padding
    }

    /// Card outer height: framed thumbnail (image + 8pt frame padding) + spacing + label.
    private var rowHeight: CGFloat { model.thumbHeight + 42 }

    @ViewBuilder private var cardsStack: some View {
        HStack(spacing: 10) {
            ForEach(model.windows) { win in
                DockWindowCard(window: win,
                               appName: model.appName,
                               height: model.thumbHeight,
                               maxWidth: maxThumbWidth,
                               action: {
                                   model.onSelect(win)
                               },
                               onClose: {
                                   model.onClose(win)
                               })
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    /// The card row, scrollable horizontally when it would overflow the screen.
    @ViewBuilder private var cardRow: some View {
        if naturalRowWidth > model.maxContentWidth {
            ScrollView(.horizontal, showsIndicators: false) {
                cardsStack
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)   // room for hover scale/shadow
            }
            .frame(width: model.maxContentWidth, height: rowHeight + 12)
        } else {
            cardsStack
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let appIcon = model.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text(model.appName)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 6)

            cardRow
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        .padding(Self.shadowInset)   // breathing room for the panel's drop shadow
        .onHover { model.onHoverChanged($0) }
    }
}

/// A single window rendered as its own card: rounded thumbnail (radius 10) with
/// the window's title beneath it.
@available(macOS 14.0, *)
private struct DockWindowCard: View {
    let window: CapturedWindow
    let appName: String
    let height: CGFloat
    let maxWidth: CGFloat
    let action: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    private var aspect: CGFloat {
        guard window.image.size.height > 0 else { return 1.4 }
        return window.image.size.width / window.image.size.height
    }

    private var width: CGFloat { min(maxWidth, max(80, height * aspect)) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(nsImage: window.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.10 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(hovering ? Color.accentColor : Color.white.opacity(0.12),
                                          lineWidth: hovering ? 2 : 1)
                    )
                    .shadow(color: .black.opacity(hovering ? 0.30 : 0.0),
                            radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
                    .scaleEffect(hovering ? 1.02 : 1.0)

                Text(window.title ?? appName)
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: width + 16)
            }
        }
        .buttonStyle(.plain)
        // Right-click anywhere on the card closes that window immediately (no
        // context menu); left-click/hover still reach the button beneath.
        .overlay(RightClickCatcher(onRightClick: onClose))
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

/// Transparent overlay that turns a right-click into an immediate action while
/// staying invisible to every other mouse event — left-click select, hover, and
/// scroll all pass straight through to the SwiftUI button beneath it.
@available(macOS 14.0, *)
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void = {}

        override func rightMouseDown(with event: NSEvent) { onRightClick() }

        // Only claim the right mouse button; return nil for anything else so the
        // underlying button keeps receiving left-clicks, hovers, and scrolls.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }
    }
}
