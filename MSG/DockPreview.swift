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

    // MARK: Auto-hidden Dock
    //
    // With Dock auto-hide, the Dock slides away the instant the pointer leaves
    // its reveal strip for the preview card. That region belongs to the Dock and
    // no other process can extend it, so the Dock cannot be held open — instead
    // the card follows it down to the screen edge and stays usable there.

    /// Polls the Dock's own window while the pointer rests on the card.
    private var dockVisibilityTimer: Timer?
    /// The card has already been pulled to the edge for this hover session.
    private var didReattachForSession = false
    /// Frame the card occupied before it slid — see `isInsideActiveRegion`.
    private var reattachGraceFrame: CGRect?
    private var dockAutohideCache: (stamp: CFAbsoluteTime, value: Bool)?

    private func dockAutohide() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if let c = dockAutohideCache, now - c.stamp < 10 { return c.value }
        let value = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        dockAutohideCache = (now, value)
        return value
    }

    /// True while the Dock has a window on screen (i.e. it is revealed).
    private func dockIsRevealed() -> Bool {
        guard let dockPID = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.dock" })?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return true }   // can't tell → assume revealed, changing nothing
        return list.contains { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == dockPID
                && (info[kCGWindowLayer as String] as? Int) == 20   // kCGDockWindowLevel
        }
    }

    /// Starts watching once, when the pointer first rests on the card.
    private func startDockVisibilityWatchIfNeeded() {
        guard dockVisibilityTimer == nil, !didReattachForSession, dockAutohide() else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, self.isPanelVisible, self.panel?.isVisible == true else {
                t.invalidate(); self?.dockVisibilityTimer = nil; return
            }
            guard !self.dockIsRevealed() else { return }
            self.didReattachForSession = true
            self.reattachGraceFrame = self.panel?.reattachToScreenEdge(orientation: self.dockOrientation())
            t.invalidate()
            self.dockVisibilityTimer = nil
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        dockVisibilityTimer = timer
    }

    private func stopDockVisibilityWatch() {
        dockVisibilityTimer?.invalidate()
        dockVisibilityTimer = nil
        didReattachForSession = false
        reattachGraceFrame = nil
    }

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
        stopDockVisibilityWatch()
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
        if isInsideActiveRegion(mouse) {
            // The pointer has left the Dock's strip for the card, so an
            // auto-hidden Dock is about to slide away under it.
            if isInsidePanel(mouse) { startDockVisibilityWatchIfNeeded() }
            return
        }

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
            // The card may have just slid to the screen edge out from under a
            // stationary cursor (auto-hidden Dock). Until the pointer actually
            // moves off it, the frame it was resting on still counts as inside.
            if let grace = reattachGraceFrame {
                if region.contains(mouse) || grace.insetBy(dx: -2, dy: -2).contains(mouse) {
                    return true
                }
                reattachGraceFrame = nil
                return false
            }
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
        // The pointer is back on the Dock, so it is revealed again and the card
        // re-anchors to the new tile. Clear the reattach state or the next trip
        // into the card would never start a fresh watch.
        stopDockVisibilityWatch()
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
            pid: item.pid,
            onSelect: { [weak self] win in
                self?.activate(item: item, window: win)
            },
            onClose: { [weak self] win in
                self?.closeWindow(pid: item.pid, windowID: win.id)
            },
            onQuit: {
                NSRunningApplication(processIdentifier: item.pid)?.terminate()
            },
            onMinimize: { [weak self] win in
                self?.hide()
                Task { await WindowPreviewCapture.minimizeWindow(pid: item.pid, windowID: win.id) }
            },
            onFullscreen: { [weak self] win in
                self?.hide()
                Task {
                    await WindowPreviewCapture.toggleFullscreen(pid: item.pid, windowID: win.id, bounds: win.bounds)
                }
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
        stopDockVisibilityWatch()
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
                 pid: pid_t = 0,
                 onSelect: @escaping (CapturedWindow) -> Void = { _ in },
                 onClose: @escaping (CapturedWindow) -> Void = { _ in },
                 onQuit: @escaping () -> Void = {},
                 onMinimize: @escaping (CapturedWindow) -> Void = { _ in },
                 onFullscreen: @escaping (CapturedWindow) -> Void = { _ in },
                 onHoverChanged: @escaping (Bool) -> Void = { _ in }) {

        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }

        model.pid = pid
        model.panelFrame = { [weak self] in self?.frame ?? .zero }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onSelect = onSelect
        model.onMinimize = onMinimize
        model.onFullscreen = onFullscreen
        model.onClose = { [weak self] win in
            guard let self, self.model.windows.contains(where: { $0.id == win.id }) else { return }
            if self.model.windows.count == 1 { onQuit() } else { onClose(win) }
            do {
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

    /// Slides the card down into the strip an auto-hidden Dock just vacated.
    ///
    /// The Dock owns its auto-hide reveal region and no other process can extend
    /// it to cover this card, so the Dock *will* slide away the moment the
    /// pointer leaves its strip for the preview. Fighting that isn't possible;
    /// what is possible is making it not matter — the card moves to the screen
    /// edge so it stays attached and usable instead of floating over a gap where
    /// the Dock used to be.
    ///
    /// Returns the frame it moved away from, so the hover test can keep counting
    /// that rect as "inside" until the pointer actually moves (the card slides
    /// out from under a stationary cursor, which would otherwise read as leaving).
    @discardableResult
    func reattachToScreenEdge(orientation: String) -> CGRect? {
        guard let panel, panel.isVisible else { return nil }
        let old = panel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(old) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var frame = old
        switch orientation {
        case "left":  frame.origin.x = screen.frame.minX + 8
        case "right": frame.origin.x = screen.frame.maxX - old.width - 8
        default:      frame.origin.y = screen.frame.minY + 8   // bottom
        }
        // Keep the other axis inside the visible frame; only the Dock-facing one moves.
        frame.origin.x = min(max(frame.origin.x, vf.minX + 8), vf.maxX - frame.width - 8)
        guard frame != old else { return nil }
        // Not animated: the pointer is resting on this card and an animated slide
        // would drag it out from under the cursor over several frames.
        panel.setFrame(frame, display: true)
        return old
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
/// The label under a Dock preview thumbnail, or nil when it would only repeat
/// the panel's own header.
///
/// This used to be `window.title ?? appName`, so a window with no title always
/// restated the app name the header already shows — and so did any app whose
/// window title *is* its name (Claude's is literally "Claude"), which read as
/// the same word printed twice around a picture.
///
/// Deliberately keyed on the text, not on how many windows there are: a lone
/// window usually has the most useful title of all ("MSG — AppDelegate.swift",
/// "h1d3s1gn — -zsh — 111×40"), so hiding by count would throw away the good
/// case to fix the redundant one.
///
/// Shared with `rowHeight` so the card and the space reserved for it can't
/// disagree.
@available(macOS 14.0, *)
func dockPreviewCaption(for window: CapturedWindow, appName: String) -> String? {
    guard let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          !title.isEmpty,
          title.compare(appName.trimmingCharacters(in: .whitespacesAndNewlines),
                        options: .caseInsensitive) != .orderedSame
    else { return nil }
    return title
}

@available(macOS 14.0, *)
private final class DockPreviewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage? = nil
    @Published var windows: [CapturedWindow] = []
    @Published var thumbHeight: CGFloat = 140
    @Published var pid: pid_t = 0
    var panelFrame: () -> CGRect = { .zero }
    var onDismiss: () -> Void = {}
    /// Maximum width the card row may occupy before it becomes horizontally
    /// scrollable (derived from the anchor screen's visible width).
    @Published var maxContentWidth: CGFloat = 1200
    var onSelect: (CapturedWindow) -> Void = { _ in }
    var onClose: (CapturedWindow) -> Void = { _ in }
    var onMinimize: (CapturedWindow) -> Void = { _ in }
    var onFullscreen: (CapturedWindow) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }
}

@available(macOS 14.0, *)
private struct DockPreviewView: View {
    static let shadowInset: CGFloat = 10

    @ObservedObject var model: DockPreviewModel

    /// Same cap as the switcher: 1.9 was narrower than ordinary wide windows
    /// and cropped them. See MSGWindowSwitcher.maxCardAspect.
    private var maxThumbWidth: CGFloat { model.thumbHeight * 2.6 }

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

    /// Card outer height: framed thumbnail (image + 6pt frame padding either side),
    /// plus the VStack spacing and label row when any card actually shows one.
    /// Accounts for multiline (2-line) captions when text wraps.
    private var rowHeight: CGFloat {
        var maxCap: CGFloat = 0
        for win in model.windows {
            if let caption = dockPreviewCaption(for: win, appName: model.appName) {
                let font = NSFont.systemFont(ofSize: 10)
                let aspect = win.image.size.height > 0 ? win.image.size.width / win.image.size.height : 1.4
                let cardW = min(maxThumbWidth, max(80, model.thumbHeight * aspect)) + 12
                let attr = NSAttributedString(string: caption, attributes: [.font: font])
                let rect = attr.boundingRect(
                    with: CGSize(width: cardW, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                let capH: CGFloat = rect.height > 15 ? 28 : 14
                maxCap = max(maxCap, capH)
            }
        }
        if maxCap > 0 {
            return model.thumbHeight + 12 + 10 + maxCap
        } else {
            return model.thumbHeight + 16
        }
    }

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
                               },
                               onMinimize: { model.onMinimize(win) },
                               onFullscreen: { model.onFullscreen(win) },
                               closeQuitsApp: model.windows.count == 1,
                               pid: model.pid,
                               appIcon: model.appIcon,
                               sourcePanelFrame: model.panelFrame,
                               onDismissPanel: model.onDismiss,
                               isHidden: PreviewHiddenStyle.isHidden(pid: model.pid, windowID: win.id))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let appIcon = model.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(model.appName)
                    .font(.system(size: 12, weight: .semibold))
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

// MARK: - Hidden windows

/// How every preview shows a window that is out of sight — its app hidden
/// (⌘H), the window minimized, or ordered out by its app: still listed where
/// it lives, but greyed out and tagged, so hiding reads as a state of the
/// window rather than as the window having gone somewhere else. Clicking the
/// card brings it back — raising a window already unhides and unminimizes.
///
/// One definition, used by the Dock, Cmd-Tab, Notch, control bar, Desktop
/// and tab-switcher previews, so the treatment can't drift between them.
@available(macOS 14.0, *)
enum PreviewHiddenStyle {
    /// How much of the greyed picture shows through.
    static let opacity: CGFloat = 0.45
    /// Longest edge of a greyed copy, in pixels — cards are a few hundred
    /// points wide, and conversion cost grows with the source.
    private static let maxPixels: CGFloat = 1200

    /// See `WindowPreviewCapture.isWindowHidden`.
    static func isHidden(pid: pid_t, windowID: CGWindowID) -> Bool {
        WindowPreviewCapture.isWindowHidden(pid: pid, windowID: windowID)
    }

    /// The thumbnail to draw: the picture itself, or its greyed copy.
    ///
    /// The grey is baked into a bitmap rather than applied with SwiftUI's
    /// `.saturation`/`.opacity`. Those are layer filters, and a card's hover
    /// lift rebuilds its layers as the shadow comes and goes; Core Animation
    /// then animated the filter in from its identity, so leaving a card
    /// flashed it grey → colour → grey. A plain image has nothing to animate.
    static func image(_ source: NSImage, hidden: Bool) -> NSImage {
        guard hidden else { return source }
        if let cached = greyed.object(forKey: source) { return cached }
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let fit = min(1, maxPixels / CGFloat(max(cg.width, cg.height, 1)))
        let width = max(1, Int(CGFloat(cg.width) * fit))
        let height = max(1, Int(CGFloat(cg.height) * fit))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        context.interpolationQuality = .high
        context.setAlpha(opacity)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let grey = context.makeImage() else { return source }
        let result = NSImage(cgImage: grey, size: source.size)
        greyed.setObject(result, forKey: source)
        return result
    }

    /// Greyed copies by source image, released under memory pressure.
    private static let greyed: NSCache<NSImage, NSImage> = {
        let cache = NSCache<NSImage, NSImage>()
        cache.countLimit = 60
        return cache
    }()
}

/// The "Hidden" tag on a greyed-out thumbnail — the same capsule as the
/// previews' "Current" and "Other" labels, on material so it reads over any
/// window content.
@available(macOS 14.0, *)
struct PreviewHiddenBadge: View {
    var body: some View {
        Text("Hidden")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
    }
}

/// Unified macOS traffic-light style red close button for preview cards.
@available(macOS 14.0, *)
struct PreviewCloseButton: View {
    let action: () -> Void
    var helpText: String = "Close"
    var accessibilityText: String? = nil

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isHovering ? Color(red: 1, green: 0.30, blue: 0.27) : Color(white: 0.55).opacity(0.8))
                .overlay(
                    Circle().strokeBorder(
                        isHovering ? Color(red: 0.78, green: 0.24, blue: 0.21) : Color.white.opacity(0.20),
                        lineWidth: 0.5
                    )
                )
                .overlay {
                    Image(systemName: "xmark")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(Color(red: 0.36, green: 0.08, blue: 0.06))
                        .opacity(isHovering ? 1.0 : 0.0)
                }
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(isHovering ? 0.25 : 0.12), radius: 1, y: 0.5)
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .transition(.opacity)
        .help(helpText)
        .accessibilityLabel(accessibilityText ?? helpText)
    }
}

/// Red, yellow and green lights for a preview card, in the order a window
/// shows them. Yellow and green appear only when the host can act on them and
/// the matching setting is on. As on a real window, pointing at any light
/// colours all three and shows their glyphs.
@available(macOS 14.0, *)
struct PreviewTrafficLights: View {
    let onClose: () -> Void
    var onMinimize: (() -> Void)? = nil
    var onFullscreen: (() -> Void)? = nil
    var closeHelp: String = "Close"
    var closeAccessibility: String? = nil

    @State private var isHovering = false

    static let lightSize: CGFloat = 17

    /// Width of the group a host with these actions draws, for hit-testing.
    static func width(minimize: Bool, fullscreen: Bool) -> CGFloat {
        let s = AppSettings.shared
        let count = 1 + (minimize && s.previewMinimizeButton ? 1 : 0) + (fullscreen && s.previewFullscreenButton ? 1 : 0)
        return CGFloat(count) * lightSize
    }

    private struct Light {
        let fill: Color
        let rim: Color
        let glyph: String
        let glyphSize: CGFloat
        let ink: Color
    }

    private static let red = Light(fill: Color(red: 1, green: 0.37, blue: 0.34), rim: Color(red: 0.78, green: 0.24, blue: 0.21),
                                   glyph: "xmark", glyphSize: 6.5, ink: Color(red: 0.36, green: 0.08, blue: 0.06))
    private static let yellow = Light(fill: Color(red: 1, green: 0.74, blue: 0.18), rim: Color(red: 0.80, green: 0.56, blue: 0.10),
                                      glyph: "minus", glyphSize: 7, ink: Color(red: 0.45, green: 0.26, blue: 0.0))
    private static let green = Light(fill: Color(red: 0.16, green: 0.78, blue: 0.25), rim: Color(red: 0.10, green: 0.58, blue: 0.16),
                                     glyph: "arrow.up.left.and.arrow.down.right", glyphSize: 5.5, ink: Color(red: 0.0, green: 0.30, blue: 0.04))

    var body: some View {
        let s = AppSettings.shared
        HStack(spacing: 0) {
            light(Self.red, help: closeHelp, accessibility: closeAccessibility ?? closeHelp, action: onClose)
            if let onMinimize, s.previewMinimizeButton {
                light(Self.yellow, help: "Minimize", accessibility: "Minimize window", action: onMinimize)
            }
            if let onFullscreen, s.previewFullscreenButton {
                light(Self.green, help: "Full Screen", accessibility: "Toggle full screen", action: onFullscreen)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func light(_ l: Light, help: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(isHovering ? l.fill : Color(white: 0.55).opacity(0.8))
                .overlay(Circle().strokeBorder(isHovering ? l.rim : Color.white.opacity(0.20), lineWidth: 0.5))
                .overlay {
                    Image(systemName: l.glyph)
                        .font(.system(size: l.glyphSize, weight: .bold))
                        .foregroundStyle(l.ink)
                        .opacity(isHovering ? 1.0 : 0.0)
                }
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(isHovering ? 0.25 : 0.12), radius: 1, y: 0.5)
                .frame(width: Self.lightSize, height: Self.lightSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(accessibility)
    }
}

/// A single window rendered as its own card: rounded thumbnail (radius 10) with
/// the window's title beneath it.
@available(macOS 14.0, *)
struct DockWindowCard: View {
    let window: CapturedWindow
    let appName: String
    let height: CGFloat
    let maxWidth: CGFloat
    let action: () -> Void
    let onClose: () -> Void
    /// Yellow and green lights; nil hides that light on this card.
    var onMinimize: (() -> Void)? = nil
    var onFullscreen: (() -> Void)? = nil
    var closeQuitsApp: Bool = false
    var selected: Bool = false
    /// Keep the caption line's height even when there is no caption to draw.
    ///
    /// The Dock preview shows one app's windows in a single row, so a card with
    /// no title can simply be shorter. The switcher lays cards out in a grid,
    /// where one captionless card in a row makes that whole row a different
    /// height and the grid stops reading as columns — there it reserves the line.
    var reservesCaption: Bool = false
    var captionHeight: CGFloat? = nil
    var canHover: Bool = true
    var onHoverChanged: ((Bool) -> Void)? = nil
    var pid: pid_t = 0
    var appIcon: NSImage? = nil
    var sourcePanelFrame: () -> CGRect = { .zero }
    var onDismissPanel: () -> Void = {}
    /// The window's app is hidden; see `PreviewHiddenStyle`.
    var isHidden: Bool = false

    @State private var hovering = false

    private var aspect: CGFloat {
        guard window.image.size.height > 0 else { return 1.4 }
        return window.image.size.width / window.image.size.height
    }

    private var width: CGFloat { min(maxWidth, max(80, height * aspect)) }

    private var caption: String? { dockPreviewCaption(for: window, appName: appName) }

    /// Pointer hover and keyboard selection are the same thing to the eye — both
    /// mean "this is the window you are about to raise" — so they drive one
    /// state and get the same motion. Previously only `hovering` animated and
    /// `selected` snapped, which made Cmd-Tab feel stepped next to the mouse.
    private var isActive: Bool { (canHover && hovering) || selected }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                Image(nsImage: PreviewHiddenStyle.image(window.image, hidden: isHidden))
                    .resizable()
                    // `.fill` cropped any window wider than `maxWidth` allows —
                    // a 920x436 Finder window wants 317pt at this height and was
                    // clamped to 285, losing a tenth of its width off the sides.
                    // `.fit` letterboxes that case instead; when the frame does
                    // match the aspect, which is the norm, the two are identical.
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(isActive ? 0.12 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? Color.accentColor : Color.white.opacity(0.12),
                                          lineWidth: isActive ? 2 : 1)
                    )

                HStack(alignment: .center) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .trailing) {
                        if window.id != 0 && canHover && hovering {
                            PreviewTrafficLights(
                                onClose: onClose,
                                onMinimize: onMinimize,
                                onFullscreen: onFullscreen,
                                closeHelp: closeQuitsApp ? "Quit \(appName)" : "Close window",
                                closeAccessibility: closeQuitsApp ? "Quit \(appName)" : "Close \(window.title ?? appName) window"
                            )
                            .transition(.opacity)
                        } else if isHidden {
                            PreviewHiddenBadge()
                                .transition(.opacity)
                        }
                    }
                }
                .padding(6)
            }
            // Lift: a shadow that grows as the card rises reads as
            // distance from the panel, which scale alone does not.
            .shadow(color: .black.opacity(isActive ? 0.34 : 0.0),
                    radius: isActive ? 12 : 0, y: isActive ? 5 : 0)
            .scaleEffect(isActive ? 1.045 : 1.0)
            .offset(y: isActive ? -3 : 0)

            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: width + 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: captionHeight, alignment: .top)
            } else if reservesCaption {
                Color.clear.frame(height: 14)
            }
        }
        .contentShape(Rectangle())
        // A spring rather than a fixed curve: Cmd-Tab can step through cards
        // faster than any duration-based ease can finish.
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isActive)
        // CardInteractionCatcher handles left clicks and drag to deskspace
        .overlay(
            CardInteractionCatcher(
                onClick: action,
                onBeginDrag: { startMouse, cardScreenRect in
                    WindowPreviewDragController.shared.beginDrag(
                        window: window,
                        pid: pid,
                        appName: appName,
                        appIcon: appIcon,
                        cardFrameOnScreen: cardScreenRect,
                        sourcePanelFrame: sourcePanelFrame(),
                        startMouseLocation: startMouse,
                        onDismissSource: onDismissPanel
                    )
                },
                isHitExcluded: { point, bounds in
                    guard canHover && hovering && window.id != 0 else { return false }
                    // Let the traffic lights in the top-trailing corner receive clicks
                    let lights = PreviewTrafficLights.width(minimize: onMinimize != nil, fullscreen: onFullscreen != nil)
                    return point.x > bounds.width - (lights + 15) && point.y > bounds.height - 32
                }
            )
        )
        .onHover { h in
            guard canHover else {
                hovering = false
                return
            }
            hovering = h
            onHoverChanged?(h)
        }
        .onChange(of: canHover) { _, allowed in
            if !allowed {
                hovering = false
                onHoverChanged?(false)
            }
        }
    }
}

