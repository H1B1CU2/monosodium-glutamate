import AppKit
import CoreGraphics
import CoreWLAN

/// The tabbed windows sharing either column on one display's current Desktop
/// — what a vertical trackpad swipe flips through.
struct TilingTabGroup {
    let displayUUID: String
    let screen: NSScreen
    /// In the bar's order.
    let tabs: [TilingBarWindow]
    /// The tab showing now.
    let currentIndex: Int
}

final class TilingControlBarController {
    var onRetile: (() -> Void)?
    var onTogglePause: ((String) -> Void)?
    var onToggleMaster: ((String, CGWindowID?) -> Void)?
    var onToggleFloating: ((String, CGWindowID?) -> Void)?
    var onActivateWindow: ((CGWindowID, pid_t, CGRect) -> Void)?
    var onToggleScope: (() -> Void)?
    var onSwitchSpace: ((String, Int) -> Void)?
    var onDeleteSpace: ((String, Int) -> Void)?
    var onAddSpace: ((String) -> Void)?
    var onReorderSpaces: ((String, [(from: Int, to: Int)], Int?) -> Void)?
    /// A window was dropped onto a Desktop in the space indicator and has
    /// moved there: the layout it left needs retiling, and so does the
    /// Desktop (given by its Space id) it arrived on.
    var onWindowMovedToSpace: ((CGWindowID, UInt64) -> Void)?
    var onMoveWindowToDesktop: ((CGWindowID, pid_t, String, Int?) -> Void)?

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    var mode: TilingControlBarMode = .fullWidth {
        didSet {
            guard mode != oldValue else { return }
            rebuildPanels()
            restartVisibilityTimer()
            restartPointerMonitoring()
            refreshVisibility()
        }
    }

    private var panels: [String: NSPanel] = [:]
    private var overflowCoverPanels: [String: NSPanel] = [:]
    private var backdropPanels: [String: MenubarBackdropPanel] = [:]
    private var views: [String: TilingControlBarView] = [:]
    private var backdropViews: [String: TilingMenubarBackdropView] = [:]
    private var screens: [String: NSScreen] = [:]
    private var snapshots: [String: TilingBarSnapshot] = [:]
    private var appearanceTimers: [String: Timer] = [:]
    private var nativeRevealDisplayUUIDs: Set<String> = []
    private var nativeConflictDisplayUUIDs: Set<String> = []
    private var nativeFadeGenerations: [String: Int] = [:]
    private var visibilityTimer: Timer?
    private var pointerMonitors: [Any] = []
    private var screenObserver: Any?
    private var appObserver: Any?
    private var lastSpaceChangeAt: TimeInterval = 0
    private var pointerLocationAtSpaceChange: CGPoint?
    private static var cachedBarHeights: [String: CGFloat] = [:]
    private var cachedMenuMaxXByScreenUUID: [String: CGFloat] = [:]
    private var lastMenuCheckTime: CFTimeInterval = 0
    private var lastFrontmostPID: pid_t = 0

    /// The hover-preview controller, stored loosely typed: a stored property
    /// can't carry an availability gate, and the card needs macOS 14.
    private var previewStorage: AnyObject?

    @available(macOS 14.0, *)
    private var preview: TilingBarPreviewController {
        if let existing = previewStorage as? TilingBarPreviewController { return existing }
        let created = TilingBarPreviewController()
        previewStorage = created
        return created
    }

    private func handleHover(_ window: TilingBarWindow?, icon: CGRect, bar: CGRect,
                             view: TilingControlBarView?) {
        guard #available(macOS 14.0, *) else { return }
        guard let window, let view else {
            if previewStorage != nil { preview.hover(nil) }
            return
        }
        let currentSpace = view.snapshot?.spaceNumber ?? window.spaceNumber
        var morphFrom: NSRect? = nil
        if spacePreviewStorage != nil && spacePreview.isVisible {
            morphFrom = spacePreview.currentPanelFrame
            spacePreview.dismiss(animated: false)
        }
        preview.hover(TilingBarPreviewController.Target(
            window: window, icon: icon, bar: bar, currentSpace: currentSpace,
            activate: { [weak view] in view?.activateFromPreview(window) },
            onCancel: { [weak view] in view?.resetHoverState() }
        ), morphFrom: morphFrom)
    }

    /// The Desktop-preview controller; loosely typed for the same reason.
    private var spacePreviewStorage: AnyObject?

    @available(macOS 14.0, *)
    private var spacePreview: TilingSpacePreviewController {
        if let existing = spacePreviewStorage as? TilingSpacePreviewController { return existing }
        let created = TilingSpacePreviewController()
        spacePreviewStorage = created
        return created
    }

    private func handleSpaceHover(_ spaceNumber: Int?, pill: CGRect, bar: CGRect,
                                  view: TilingControlBarView?) {
        guard #available(macOS 14.0, *) else { return }
        guard let spaceNumber, let view, let screen = screens[view.displayUUID] else {
            if spacePreviewStorage != nil { spacePreview.hover(nil) }
            return
        }
        var morphFrom: NSRect? = nil
        if previewStorage != nil && preview.isVisible {
            morphFrom = preview.currentPanelFrame
            preview.dismiss(animated: false)
        }
        spacePreview.hover(spaceTarget(spaceNumber, pill: pill, bar: bar, view: view, screen: screen),
                           morphFrom: morphFrom)
    }

    @available(macOS 14.0, *)
    private func spaceTarget(_ spaceNumber: Int, pill: CGRect, bar: CGRect,
                             view: TilingControlBarView, screen: NSScreen) -> TilingSpacePreviewController.Target {
        TilingSpacePreviewController.Target(
            displayUUID: view.displayUUID, screen: screen, spaceNumber: spaceNumber,
            pill: pill, indicator: view.spaceIndicatorRectOnScreen() ?? pill, bar: bar,
            currentSpaceNumber: view.snapshot?.spaceNumber,
            switchToDesktop: { [weak view] number in view?.selectSpace(number) },
            activateWindow: { [weak self] item in
                // Raising a window on another Desktop is what switches to it.
                self?.onActivateWindow?(item.id, item.pid, item.bounds)
            },
            onCancel: { [weak view] in view?.resetSpaceHoverState() },
            deleteDesktop: { [weak self, weak view] number in
                guard let uuid = view?.displayUUID else { return }
                self?.onDeleteSpace?(uuid, number)
            },
            addDesktop: { [weak self, weak view] in
                guard let uuid = view?.displayUUID else { return }
                self?.onAddSpace?(uuid)
            },
            reorderDesktops: { [weak self, weak view] moves, show in
                guard let uuid = view?.displayUUID else { return }
                self?.onReorderSpaces?(uuid, moves, show)
            }
        )
    }

    private func dismissPreview(animated: Bool = true) {
        guard #available(macOS 14.0, *) else { return }
        if spacePreviewStorage != nil { spacePreview.dismiss(animated: animated) }
        guard previewStorage != nil else { return }
        preview.dismiss(animated: animated)
    }

    static func hasNotch(for screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            if screen.safeAreaInsets.top > 0 {
                return true
            }
            if let notchHeight = screen.auxiliaryTopLeftArea?.height, notchHeight > 0 {
                return true
            }
        }
        return false
    }

    static func barHeight(for screen: NSScreen) -> CGFloat {
        if let uuid = screen.uuid, let cached = cachedBarHeights[uuid] {
            return cached
        }
        let h = computeBarHeight(for: screen)
        if let uuid = screen.uuid {
            cachedBarHeights[uuid] = h
        }
        return h
    }

    private static func computeBarHeight(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            if screen.safeAreaInsets.top > 0 {
                return screen.safeAreaInsets.top
            }
            if let notchHeight = screen.auxiliaryTopLeftArea?.height, notchHeight > 0 {
                return notchHeight
            }
        }
        let diff = screen.frame.maxY - screen.visibleFrame.maxY
        if diff > 0 {
            return diff
        }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let quartzBounds = displayID.map { CGDisplayBounds($0) }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 24,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            if let qb = quartzBounds, qb.intersection(rect).width > 100 {
                return rect.height
            }
        }
        return 30
    }

    /// On a native full-screen Space, macOS moves the menus right and shows the
    /// window's traffic lights at the left end of the menu bar — in a window
    /// below the backdrop, whose black strip painted over them. The backdrop
    /// leaves this much of its left end clear there (the system's own menu bar
    /// is black behind it, so nothing shows).
    private static let fullscreenControlsWidth: CGFloat = 100

    private static func isOnFullscreenSpace(_ screen: NSScreen) -> Bool {
        guard let current = WindowPreviewCapture.currentManagedSpaceID(for: screen) else { return false }
        return WindowPreviewCapture.managedSpaces(for: screen).contains { $0.id == current && $0.isFullscreen }
    }

    static func barFrame(for screen: NSScreen, mode: TilingControlBarMode) -> CGRect {
        let height = barHeight(for: screen).rounded()
        let full = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                          width: screen.frame.width.rounded(), height: height)
        guard mode == .hybridNotch else { return full }
        if #available(macOS 12.0, *), let left = screen.auxiliaryTopLeftArea,
           left.width > 100 {
            let width = max(100, (left.maxX - screen.frame.minX).rounded())
            return CGRect(x: screen.frame.minX, y: full.minY,
                          width: width, height: height)
        }
        let width = min(full.width * 0.58, 760).rounded()
        return CGRect(x: full.minX, y: full.minY,
                      width: width, height: height)
    }

    func start() {
        guard isEnabled else { return }
        if #available(macOS 14.0, *) {
            WindowPreviewDragController.shared.registerDropTargetProvider(self)
        }
        // The Duo indicator starts the monitor the first time it draws.
        NetworkStatusMonitor.shared.onChange = { [weak self] in
            guard AppSettings.shared.tilingControlBarDuoBatteryWifi else { return }
            self?.views.values.forEach { $0.needsDisplay = true }
        }
        rebuildPanels()
        if visibilityTimer == nil { restartVisibilityTimer() }
        if pointerMonitors.isEmpty { restartPointerMonitoring() }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Self.cachedBarHeights.removeAll()
                self?.rebuildPanels()
                self?.refreshVisibility()
            }
        }
        if appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard !SystemSearchOverlay.isAbout(note) else { return }
                self?.refreshVisibility()
            }
        }
        refreshVisibility()
    }

    private func restartVisibilityTimer() {
        visibilityTimer?.invalidate()
        // In hybridNotch mode, pointer event monitors already provide responsive
        // reveal detection. The timer is a fallback; 15fps is plenty for that.
        let interval: TimeInterval = mode == .hybridNotch ? 0.2 : 0.15
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshVisibility()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    private func restartPointerMonitoring() {
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors = []
        guard isEnabled, mode == .hybridNotch else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: {
            [weak self] event in
            self?.pointerMoved()
            return event
        }) {
            pointerMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: {
            [weak self] _ in
            self?.pointerMoved()
        }) {
            pointerMonitors.append(global)
        }
    }

    /// Only the top strip of a screen (the native-menu reveal zone) depends on
    /// the pointer. Mouse moves arrive 60-120×/s; running the whole visibility
    /// pass for each one anywhere on screen was pure overhead. Moves near a
    /// top edge refresh at once, plus one pass on the way out of the band.
    private var pointerWasNearTop = false
    private static let pointerBand: CGFloat = 60

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        let nearTop = NSScreen.screens.contains { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX &&
                point.y >= screen.frame.maxY - Self.pointerBand && point.y <= screen.frame.maxY + 2
        }
        guard nearTop || pointerWasNearTop || !nativeRevealDisplayUUIDs.isEmpty else { return }
        pointerWasNearTop = nearTop
        refreshVisibility()
    }

    func stop() {
        dismissPreview(animated: false)
        NetworkStatusMonitor.shared.stop()
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        if let obs = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appObserver = nil
        }
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors = []
        appearanceTimers.values.forEach { $0.invalidate() }
        appearanceTimers = [:]
        panels.values.forEach { $0.orderOut(nil) }
        overflowCoverPanels.values.forEach { $0.orderOut(nil) }
        backdropPanels.values.forEach { $0.orderOut(nil) }
        panels = [:]
        overflowCoverPanels = [:]
        backdropPanels = [:]
        views = [:]
        backdropViews = [:]
        screens = [:]
        snapshots = [:]
        nativeRevealDisplayUUIDs = []
        nativeConflictDisplayUUIDs = []
        nativeFadeGenerations = [:]
    }

    func snapshot(for displayUUID: String) -> TilingBarSnapshot? {
        snapshots[displayUUID]
    }

    /// The tabbed windows stacked on a display's current Desktop, on the side/column
    /// under the pointer, in the order the bar lists them. Nil below two: there is
    /// nothing to switch between on that side.
    func tabGroup(displayUUID: String, pointer: CGPoint? = nil) -> TilingTabGroup? {
        guard let entry = snapshots.first(where: {
            $0.key.caseInsensitiveCompare(displayUUID) == .orderedSame
        }), let screen = screens[entry.key] ?? NSScreen.screens.first(where: {
            $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
        }) else { return nil }
        let snapshot = entry.value

        let currentSpaceWindows = (snapshot.tabWindows ?? snapshot.windows).filter {
            ($0.status == .leftTabbed || $0.status == .rightTabbed || $0.status == .split)
                && $0.spaceNumber == snapshot.spaceNumber
        }
        guard currentSpaceWindows.count > 1 else { return nil }

        let targetTabs: [TilingBarWindow]
        if let pointer {
            let hovered = currentSpaceWindows.first {
                $0.frame.insetBy(dx: -8, dy: -8).contains(pointer)
            }
            if let hovered {
                if hovered.status == .rightTabbed {
                    targetTabs = currentSpaceWindows.filter { $0.status == .rightTabbed }
                } else if hovered.status == .leftTabbed {
                    targetTabs = currentSpaceWindows.filter { $0.status == .leftTabbed }
                } else {
                    let sameSide = currentSpaceWindows.filter { w in
                        if w.windowID == hovered.windowID { return true }
                        let overlapMin = max(w.frame.minX, hovered.frame.minX)
                        let overlapMax = min(w.frame.maxX, hovered.frame.maxX)
                        let overlapWidth = max(0, overlapMax - overlapMin)
                        let minWidth = min(w.frame.width, hovered.frame.width)
                        if minWidth > 0 && (overlapWidth / minWidth) > 0.4 {
                            return true
                        }
                        let hoveredMid = hovered.frame.midX
                        let wMid = w.frame.midX
                        let screenMid = screen.frame.midX
                        return (hoveredMid >= screenMid) == (wMid >= screenMid)
                            && abs(hoveredMid - wMid) < screen.frame.width * 0.25
                    }
                    targetTabs = sameSide
                }
            } else {
                let pointerOnRight = pointer.x >= screen.frame.midX
                let sameSide = currentSpaceWindows.filter { w in
                    (w.frame.midX >= screen.frame.midX) == pointerOnRight
                }
                targetTabs = sameSide
            }
        } else {
            let rightTabs = currentSpaceWindows.filter {
                $0.status == .rightTabbed && $0.spaceNumber == snapshot.spaceNumber
            }
            let leftTabs = currentSpaceWindows.filter {
                $0.status == .leftTabbed && $0.spaceNumber == snapshot.spaceNumber
            }
            targetTabs = rightTabs.count > 1 ? rightTabs : (leftTabs.count > 1 ? leftTabs : currentSpaceWindows)
        }

        guard targetTabs.count > 1 else { return nil }

        let current = targetTabs.firstIndex(where: \.isFocused)
            ?? targetTabs.firstIndex(where: \.isShownInLayout)
            ?? 0
        return TilingTabGroup(displayUUID: entry.key, screen: screen, tabs: targetTabs, currentIndex: current)
    }

    /// Brings a tab forward through its icon's own activation when the bar is
    /// up, so the shown pill pops and travels exactly as a click would.
    func activateTab(_ window: TilingBarWindow, displayUUID: String) {
        dismissPreview()
        if let view = views[displayUUID] {
            view.activateFromPreview(window)
        } else {
            onActivateWindow?(window.windowID, window.pid, window.frame)
        }
    }

    /// The Space Indicator on every bar changes into the volume/brightness HUD
    /// and back. False when no bar is on screen to show it.
    func showSystemHUD(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                       audioOutputKind: AudioOutputKind?) -> Bool {
        guard isEnabled, PresentationState.shared.canPresent else { return false }
        let showing = panels.contains { $0.value.isVisible && $0.value.alphaValue > 0.5 }
        guard showing else { return false }
        // The pill a Desktop card hangs from is about to turn into the HUD.
        if #available(macOS 14.0, *), spacePreviewStorage != nil { spacePreview.dismiss() }
        views.values.forEach {
            $0.showSystemHUD(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
        }
        return true
    }

    /// The Space Indicator on every bar changes into the input source (keyboard
    /// language) HUD and back. False when no bar is on screen to show it.
    func showInputSourceHUD(name: String) -> Bool {
        guard isEnabled, PresentationState.shared.canPresent else { return false }
        let showing = panels.contains { $0.value.isVisible && $0.value.alphaValue > 0.5 }
        guard showing else { return false }
        if #available(macOS 14.0, *), spacePreviewStorage != nil { spacePreview.dismiss() }
        views.values.forEach {
            $0.showInputSourceHUD(name: name)
        }
        return true
    }

    func handleSpaceChange() {
        // The icons are about to cross-fade to another Space's windows; a card
        // left hanging would describe an icon that is no longer there.
        dismissPreview()
        lastSpaceChangeAt = CACurrentMediaTime()
        pointerLocationAtSpaceChange = currentPointerLocation()
        nativeRevealDisplayUUIDs.removeAll()
        appearanceTimers.values.forEach { $0.invalidate() }
        appearanceTimers = [:]
        for (uuid, panel) in panels {
            nativeFadeGenerations[uuid, default: 0] += 1
            if let screen = screens[uuid] {
                let frame = Self.barFrame(for: screen, mode: mode)
                panel.setFrame(frame, display: false)
            }
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
        }
        for (uuid, bPanel) in backdropPanels {
            if let screen = screens[uuid] {
                backdropViews[uuid]?.leftHole = Self.isOnFullscreenSpace(screen) ? Self.fullscreenControlsWidth : 0
            }
            bPanel.orderFrontRegardless()
        }
    }

    func update(_ newSnapshots: [TilingBarSnapshot]) {
        for s in newSnapshots {
            snapshots[s.displayUUID] = s
        }
        let currentScreenUUIDs = Set(NSScreen.screens.compactMap(\.uuid))
        snapshots = snapshots.filter { currentScreenUUIDs.contains($0.key) }
        guard isEnabled else { return }
        let screenSetChanged = Set(panels.keys) != currentScreenUUIDs ||
            Set(backdropPanels.keys) != currentScreenUUIDs
        if screenSetChanged {
            rebuildPanels()
        } else if CACurrentMediaTime() - lastSpaceChangeAt > 1.2 {
            // Skip frame recalculation during space-change animations —
            // geometry doesn't change and the main thread should stay free.
            updatePanelFrames()
        }
        for (uuid, view) in views {
            view.snapshot = snapshots[uuid]
            // snapshot didSet already triggers needsDisplay for content changes
            // and starts pill/app animations. No extra redraw mark needed.
        }
        if #available(macOS 14.0, *), previewStorage != nil {
            preview.windowsChanged(Set(snapshots.values.flatMap { $0.windows.map(\.windowID) }))
        }
        refreshVisibility()
    }

    private func updateMenuLeakingInfo() {
        let now = CACurrentMediaTime()
        // A search overlay has no menu bar of its own; keep the app's behind it.
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier,
              !SystemSearchOverlay.contains(frontmost) else {
            return
        }
        if frontmost.processIdentifier == lastFrontmostPID && (now - lastMenuCheckTime) < 0.8 {
            return
        }
        lastFrontmostPID = frontmost.processIdentifier
        lastMenuCheckTime = now

        let axApp = AXUIElementCreateApplication(frontmost.processIdentifier)
        var menuBarVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarVal) == .success,
              let menuBar = menuBarVal as! AXUIElement? else {
            cachedMenuMaxXByScreenUUID.removeAll()
            return
        }

        var childrenVal: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenVal) == .success,
              let items = childrenVal as? [AXUIElement], !items.isEmpty else {
            cachedMenuMaxXByScreenUUID.removeAll()
            return
        }

        var itemMaxXs: [CGFloat] = []
        for item in items {
            var posVal: AnyObject?
            var sizeVal: AnyObject?
            AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &posVal)
            AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeVal)
            var pos = CGPoint.zero
            var size = CGSize.zero
            if let posVal = posVal as! AXValue? { AXValueGetValue(posVal, .cgPoint, &pos) }
            if let sizeVal = sizeVal as! AXValue? { AXValueGetValue(sizeVal, .cgSize, &size) }
            if size.width > 0 {
                itemMaxXs.append(pos.x + size.width)
            }
        }

        var newMaxXByUUID: [String: CGFloat] = [:]
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid else { continue }
            let screenMinX = screen.frame.minX
            let screenMaxX = screen.frame.maxX
            let onScreenMaxXs = itemMaxXs.filter { $0 >= screenMinX && $0 <= screenMaxX }
            if let maxOnScreen = onScreenMaxXs.max() {
                newMaxXByUUID[uuid] = maxOnScreen
            }
        }
        cachedMenuMaxXByScreenUUID = newMaxXByUUID
    }

    private func updateOverflowCoverPanels() {
        guard isEnabled, mode == .hybridNotch else {
            overflowCoverPanels.values.forEach { $0.orderOut(nil) }
            return
        }
        updateMenuLeakingInfo()

        for screen in NSScreen.screens {
            guard let uuid = screen.uuid else { continue }
            let leakStartX: CGFloat
            if #available(macOS 12.0, *), let right = screen.auxiliaryTopRightArea {
                leakStartX = right.minX
            } else if let panel = panels[uuid] {
                leakStartX = panel.frame.maxX
            } else {
                leakStartX = screen.frame.minX + min(screen.frame.width * 0.58, 760)
            }

            let maxOnScreen = cachedMenuMaxXByScreenUUID[uuid] ?? 0
            if maxOnScreen > leakStartX + 4 {
                let barH = Self.barHeight(for: screen).rounded()
                let y = screen.frame.maxY - barH
                let endX = min(maxOnScreen + 10, screen.frame.maxX - 160)
                let width = max(0, endX - leakStartX)
                guard width > 10 else {
                    overflowCoverPanels[uuid]?.orderOut(nil)
                    continue
                }
                let frame = CGRect(x: leakStartX, y: y, width: width, height: barH)
                let oPanel: NSPanel
                if let existing = overflowCoverPanels[uuid] {
                    oPanel = existing
                } else {
                    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                    p.level = .statusBar
                    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                    p.isOpaque = true
                    p.backgroundColor = .black
                    p.hasShadow = false
                    p.animationBehavior = .none
                    p.hidesOnDeactivate = false
                    p.ignoresMouseEvents = false
                    overflowCoverPanels[uuid] = p
                    oPanel = p
                }

                if abs(oPanel.frame.minX - frame.minX) > 1 ||
                   abs(oPanel.frame.minY - frame.minY) > 1 ||
                   abs(oPanel.frame.width - frame.width) > 1 ||
                   abs(oPanel.frame.height - frame.height) > 1 {
                    oPanel.setFrame(frame, display: true)
                }

                if !nativeRevealDisplayUUIDs.contains(uuid) {
                    if !oPanel.isVisible {
                        oPanel.alphaValue = 1
                        oPanel.ignoresMouseEvents = false
                        oPanel.orderFrontRegardless()
                    }
                }
            } else {
                overflowCoverPanels[uuid]?.orderOut(nil)
            }
        }
    }

    func refreshVisibility() {
        guard isEnabled else {
            panels.values.forEach { $0.orderOut(nil) }
            overflowCoverPanels.values.forEach { $0.orderOut(nil) }
            backdropPanels.values.forEach { $0.orderOut(nil) }
            return
        }
        // During the space-change cooldown the panels are already ordered front
        // with alpha 1 by handleSpaceChange(). Skip pointer tracking and native
        // menu bar scanning to keep the main thread free for pill/app animations.
        if CACurrentMediaTime() - lastSpaceChangeAt < 1.2 {
            return
        }
        updateOverflowCoverPanels()
        let nativeMenuBars = mode == .fullWidth
            ? WindowListScanner.scan().visibleMenuBarDisplayUUIDs
            : []
        let pointer = currentPointerLocation()
        for (uuid, panel) in panels {
            let bPanel = backdropPanels[uuid]
            let nativeConflict = mode == .fullWidth && nativeMenuBars.contains(uuid)
            let wasRevealingNative = nativeRevealDisplayUUIDs.contains(uuid)
            let wasConflicted = nativeConflictDisplayUUIDs.contains(uuid)
            let revealNativeLeft = shouldRevealNativeLeft(on: panel, displayUUID: uuid,
                                                          pointer: pointer)
            // SP8CE's page full screen is on this display's desktop Space, not one of its own
            // (which the bar isn't on), so the bar steps aside for it itself.
            let unavailable = !PresentationState.shared.canPresent || SystemState.pageFullscreenDisplay == uuid
            if unavailable {
                bPanel?.orderOut(nil)
            } else if bPanel?.isVisible != true {
                bPanel?.orderFrontRegardless()
            }

            if nativeConflict || unavailable {
                if nativeConflict && !wasConflicted {
                    nativeConflictDisplayUUIDs.insert(uuid)
                    HapticFeedback.performHarder()
                }
                nativeFadeGenerations[uuid, default: 0] += 1
                appearanceTimers.removeValue(forKey: uuid)?.invalidate()
                if panel.isVisible { dismissPreview(animated: false) }
                panel.alphaValue = 1
                panel.ignoresMouseEvents = false
                panel.orderOut(nil)
                overflowCoverPanels[uuid]?.orderOut(nil)
            }
            else {
                if wasConflicted {
                    nativeConflictDisplayUUIDs.remove(uuid)
                    HapticFeedback.performHarder()
                }
                if revealNativeLeft {
                    if !wasRevealingNative { fadeOutForNativeMenu(panel, displayUUID: uuid) }
                }
                else if wasRevealingNative {
                    fadeInControlBar(panel, displayUUID: uuid)
                }
                else if !panel.isVisible, let screen = screens[uuid] {
                    panel.setFrame(Self.barFrame(for: screen, mode: mode), display: false)
                    panel.alphaValue = 1
                    panel.ignoresMouseEvents = false
                    panel.orderFrontRegardless()
                }
            }
        }
    }

    private func fadeOutForNativeMenu(_ panel: NSPanel, displayUUID: String) {
        dismissPreview()
        HapticFeedback.performHarder()
        appearanceTimers.removeValue(forKey: displayUUID)?.invalidate()
        nativeFadeGenerations[displayUUID, default: 0] += 1
        let generation = nativeFadeGenerations[displayUUID]!
        panel.ignoresMouseEvents = true
        let oPanel = overflowCoverPanels[displayUUID]
        oPanel?.ignoresMouseEvents = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            oPanel?.alphaValue = 0
            oPanel?.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            oPanel?.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel, weak oPanel] in
            DispatchQueue.main.async {
                guard let self,
                      self.nativeFadeGenerations[displayUUID] == generation,
                      self.nativeRevealDisplayUUIDs.contains(displayUUID) else { return }
                panel?.orderOut(nil)
                oPanel?.orderOut(nil)
            }
        }
    }

    private func fadeInControlBar(_ panel: NSPanel, displayUUID: String) {
        HapticFeedback.performHarder()
        nativeFadeGenerations[displayUUID, default: 0] += 1
        let generation = nativeFadeGenerations[displayUUID]!
        if let screen = screens[displayUUID] {
            let frame = Self.barFrame(for: screen, mode: mode)
            panel.setFrame(frame, display: false)
        }
        panel.orderFrontRegardless()
        let oPanel = overflowCoverPanels[displayUUID]
        if let oPanel, let screen = screens[displayUUID] {
            let maxOnScreen = cachedMenuMaxXByScreenUUID[displayUUID] ?? 0
            let leakStartX: CGFloat
            if #available(macOS 12.0, *), let right = screen.auxiliaryTopRightArea {
                leakStartX = right.minX
            } else if let p = panels[displayUUID] {
                leakStartX = p.frame.maxX
            } else {
                leakStartX = screen.frame.minX + min(screen.frame.width * 0.58, 760)
            }
            if maxOnScreen > leakStartX + 4 {
                let barH = Self.barHeight(for: screen).rounded()
                let y = screen.frame.maxY - barH
                let endX = min(maxOnScreen + 10, screen.frame.maxX - 160)
                let width = max(0, endX - leakStartX)
                let frame = CGRect(x: leakStartX, y: y, width: width, height: barH)
                oPanel.setFrame(frame, display: false)
                oPanel.orderFrontRegardless()
            }
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            oPanel?.alphaValue = 1
            oPanel?.ignoresMouseEvents = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            oPanel?.animator().alphaValue = 1
        } completionHandler: { [weak self, weak panel, weak oPanel] in
            DispatchQueue.main.async {
                guard let self,
                      self.nativeFadeGenerations[displayUUID] == generation,
                      !self.nativeRevealDisplayUUIDs.contains(displayUUID) else { return }
                panel?.ignoresMouseEvents = false
                oPanel?.ignoresMouseEvents = false
            }
        }
    }

    private func currentPointerLocation() -> CGPoint {
        guard let quartzPoint = CGEvent(source: nil)?.location else { return NSEvent.mouseLocation }
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { continue }
            let quartzBounds = CGDisplayBounds(displayID)
            guard TilingLayout.containsIncludingEdges(quartzPoint, in: quartzBounds) else { continue }
            let scaleX = screen.frame.width / max(1, quartzBounds.width)
            let scaleY = screen.frame.height / max(1, quartzBounds.height)
            return CGPoint(x: screen.frame.minX + (quartzPoint.x - quartzBounds.minX) * scaleX,
                           y: screen.frame.maxY - (quartzPoint.y - quartzBounds.minY) * scaleY)
        }
        return NSEvent.mouseLocation
    }

    private func shouldRevealNativeLeft(on panel: NSPanel, displayUUID: String,
                                        pointer: CGPoint) -> Bool {
        guard mode == .hybridNotch else {
            nativeRevealDisplayUUIDs.remove(displayUUID)
            return false
        }
        let overflowPanel = overflowCoverPanels[displayUUID]
        let hasOverflow = overflowPanel?.isVisible == true
        let menuWidth = hasOverflow
            ? max(panel.frame.width, overflowPanel!.frame.maxX - panel.frame.minX)
            : panel.frame.width
        let menuArea = CGRect(x: panel.frame.minX, y: panel.frame.minY,
                              width: menuWidth, height: panel.frame.height)
        if nativeRevealDisplayUUIDs.contains(displayUUID) {
            let retainArea = CGRect(x: menuArea.minX, y: menuArea.minY - 5,
                                    width: menuArea.width, height: menuArea.height + 10)
            if TilingLayout.containsIncludingEdges(pointer, in: retainArea) { return true }
            nativeRevealDisplayUUIDs.remove(displayUUID)
            NSLog("MSG Tiling: restored left control bar on %@", displayUUID)
            return false
        }
        // Suppress trigger if space changed recently (1.2s cooldown to cover transition and settle)
        if CACurrentMediaTime() - lastSpaceChangeAt < 1.2 {
            return false
        }
        if let initialPt = pointerLocationAtSpaceChange {
            let dx = pointer.x - initialPt.x
            let dy = pointer.y - initialPt.y
            if dx * dx + dy * dy < 36 {
                return false
            }
        }
        // Mouse events provide immediate detection; use a 6px trigger strip with 2px over-edge
        // buffer to reliably match the native top-edge gesture across tracking speeds.
        let topTrigger = CGRect(x: menuArea.minX, y: menuArea.maxY - 6,
                                width: menuArea.width, height: 8)
        if TilingLayout.containsIncludingEdges(pointer, in: topTrigger) {
            nativeRevealDisplayUUIDs.insert(displayUUID)
            NSLog("MSG Tiling: revealing native left menu bar on %@", displayUUID)
            return true
        }
        return false
    }

    private func updatePanelFrames() {
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid,
                  let panel = panels[uuid],
                  let bPanel = backdropPanels[uuid],
                  let view = views[uuid],
                  let bView = backdropViews[uuid] else { continue }
            screens[uuid] = screen
            let barH = Self.barHeight(for: screen).rounded()
            let underBar = screen.isBuiltin ? AppSettings.shared.topCornersUnderMenuBar : AppSettings.shared.extTopCornersUnderMenuBar(for: uuid)
            let configuredR = screen.isBuiltin ? AppSettings.shared.cornerRadius : AppSettings.shared.extCornerRadius(for: uuid)
            let baseR = configuredR > 0 ? configuredR : 16
            let r: CGFloat = (!screen.isBuiltin || underBar) ? baseR : 0
            let curve: CornerCurve = screen.isBuiltin ? AppSettings.shared.cornerCurve : AppSettings.shared.extCornerCurve(for: uuid)
            let reach: CGFloat = r > 0 ? CornerGeometry.reach(for: r, curve: curve) : 0

            let bFrame = CGRect(x: screen.frame.minX,
                                y: screen.frame.maxY - (barH + reach),
                                width: screen.frame.width.rounded(),
                                height: barH + reach)
            if abs(bPanel.frame.minX - bFrame.minX) > 1 ||
               abs(bPanel.frame.minY - bFrame.minY) > 1 ||
               abs(bPanel.frame.width - bFrame.width) > 1 ||
               abs(bPanel.frame.height - bFrame.height) > 1 {
                bPanel.setFrame(bFrame, display: true)
                bView.frame = CGRect(origin: .zero, size: bFrame.size)
                bView.needsDisplay = true
            }
            if bView.cornerRadius != r || bView.cornerCurve != curve {
                bView.cornerRadius = r
                bView.cornerCurve = curve
                bView.needsDisplay = true
            }
            bView.leftHole = Self.isOnFullscreenSpace(screen) ? Self.fullscreenControlsWidth : 0

            let frame = Self.barFrame(for: screen, mode: mode)
            if abs(panel.frame.minX - frame.minX) > 1 ||
               abs(panel.frame.minY - frame.minY) > 1 ||
               abs(panel.frame.width - frame.width) > 1 ||
               abs(panel.frame.height - frame.height) > 1 {
                panel.setFrame(frame, display: true)
                view.frame = CGRect(origin: .zero, size: frame.size)
                view.needsDisplay = true
            }
            panel.isOpaque = mode == .hybridNotch
            panel.backgroundColor = mode == .hybridNotch ? .black : .clear
        }
    }

    private func showSlidingDown(_ panel: NSPanel, on screen: NSScreen, displayUUID: String) {
        let frame = Self.barFrame(for: screen, mode: mode)
        let destination = CGPoint(x: frame.minX,
                                  y: screen.frame.maxY - frame.height)
        let start = CGPoint(x: destination.x, y: screen.frame.maxY)
        appearanceTimers.removeValue(forKey: displayUUID)?.invalidate()
        panel.setFrame(frame, display: false)
        panel.setFrameOrigin(start)
        panel.orderFrontRegardless()
        let startedAt = CACurrentMediaTime()
        let duration: TimeInterval = 0.22
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self, weak panel] timer in
            guard let self, let panel else { timer.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - startedAt) / duration))
            let progress = Easing.outQuart(raw)
            panel.setFrameOrigin(CGPoint(x: destination.x,
                                         y: start.y + (destination.y - start.y) * progress))
            if raw >= 1 {
                timer.invalidate()
                panel.setFrameOrigin(destination)
                self.appearanceTimers[displayUUID] = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        appearanceTimers[displayUUID] = timer
    }

    private func rebuildPanels() {
        let currentScreenUUIDs = Set(NSScreen.screens.compactMap(\.uuid))
        for uuid in Array(panels.keys) where !currentScreenUUIDs.contains(uuid) {
            appearanceTimers.removeValue(forKey: uuid)?.invalidate()
            panels.removeValue(forKey: uuid)?.orderOut(nil)
            overflowCoverPanels.removeValue(forKey: uuid)?.orderOut(nil)
            backdropPanels.removeValue(forKey: uuid)?.orderOut(nil)
            views.removeValue(forKey: uuid)
            backdropViews.removeValue(forKey: uuid)
            screens.removeValue(forKey: uuid)
        }

        for screen in NSScreen.screens {
            guard let uuid = screen.uuid else { continue }
            screens[uuid] = screen
            let barH = Self.barHeight(for: screen).rounded()
            let underBar = screen.isBuiltin ? AppSettings.shared.topCornersUnderMenuBar : AppSettings.shared.extTopCornersUnderMenuBar(for: uuid)
            let configuredR = screen.isBuiltin ? AppSettings.shared.cornerRadius : AppSettings.shared.extCornerRadius(for: uuid)
            let baseR = configuredR > 0 ? configuredR : 16
            let r: CGFloat = (!screen.isBuiltin || underBar) ? baseR : 0
            let curve: CornerCurve = screen.isBuiltin ? AppSettings.shared.cornerCurve : AppSettings.shared.extCornerCurve(for: uuid)
            let reach: CGFloat = r > 0 ? CornerGeometry.reach(for: r, curve: curve) : 0

            let bFrame = CGRect(x: screen.frame.minX,
                                y: screen.frame.maxY - (barH + reach),
                                width: screen.frame.width.rounded(),
                                height: barH + reach)
            let frame = Self.barFrame(for: screen, mode: mode)

            if let bPanel = backdropPanels[uuid], let bView = backdropViews[uuid],
               let panel = panels[uuid], let view = views[uuid] {
                if abs(bPanel.frame.minX - bFrame.minX) > 1 ||
                   abs(bPanel.frame.minY - bFrame.minY) > 1 ||
                   abs(bPanel.frame.width - bFrame.width) > 1 ||
                   abs(bPanel.frame.height - bFrame.height) > 1 {
                    bPanel.setFrame(bFrame, display: true)
                    bView.frame = CGRect(origin: .zero, size: bFrame.size)
                    bView.needsDisplay = true
                }
                if bView.cornerRadius != r || bView.cornerCurve != curve {
                    bView.cornerRadius = r
                    bView.cornerCurve = curve
                    bView.needsDisplay = true
                }

                if abs(panel.frame.minX - frame.minX) > 1 ||
                   abs(panel.frame.minY - frame.minY) > 1 ||
                   abs(panel.frame.width - frame.width) > 1 ||
                   abs(panel.frame.height - frame.height) > 1 {
                    panel.setFrame(frame, display: true)
                    view.frame = CGRect(origin: .zero, size: frame.size)
                }
                view.mode = mode
                panel.isOpaque = mode == .hybridNotch
                panel.backgroundColor = mode == .hybridNotch ? .black : .clear
                continue
            }

            let bPanel = MenubarBackdropPanel(contentRect: bFrame, styleMask: [.borderless, .nonactivatingPanel],
                                              backing: .buffered, defer: false)
            bPanel.setFrame(bFrame, display: false)
            bPanel.level = NSWindow.Level(23)
            bPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
                                         .ignoresCycle]
            bPanel.isOpaque = false
            bPanel.backgroundColor = .clear
            bPanel.hasShadow = false
            bPanel.animationBehavior = .none
            bPanel.hidesOnDeactivate = false
            bPanel.ignoresMouseEvents = true
            let bView = TilingMenubarBackdropView(frame: CGRect(origin: .zero, size: bFrame.size))
            bView.autoresizingMask = [.width, .height]
            bView.cornerRadius = r
            bView.cornerCurve = curve
            bPanel.contentView = bView
            backdropPanels[uuid] = bPanel
            backdropViews[uuid] = bView

            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.setFrame(frame, display: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
                                        .ignoresCycle]
            panel.isOpaque = mode == .hybridNotch
            panel.backgroundColor = mode == .hybridNotch ? .black : .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            let view = TilingControlBarView(frame: CGRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            view.displayUUID = uuid
            view.onRetile = { [weak self] in self?.onRetile?() }
            view.onTogglePause = { [weak self] in self?.onTogglePause?(uuid) }
            view.onToggleMaster = { [weak self] winID in self?.onToggleMaster?(uuid, winID) }
            view.onToggleFloating = { [weak self] winID in self?.onToggleFloating?(uuid, winID) }
            view.onActivateWindow = { [weak self] windowID, pid, frame in
                self?.onActivateWindow?(windowID, pid, frame)
            }
            view.onToggleScope = { [weak self] in self?.onToggleScope?() }
            view.onSwitchSpace = { [weak self] spaceNumber in
                self?.onSwitchSpace?(uuid, spaceNumber)
            }
            view.onMoveWindowToDesktop = { [weak self] windowID, pid, destination in
                self?.onMoveWindowToDesktop?(windowID, pid, uuid, destination)
            }
            view.onHoverWindow = { [weak self, weak view] window, icon, bar in
                self?.handleHover(window, icon: icon, bar: bar, view: view)
            }
            view.onHoverSpace = { [weak self, weak view] spaceNumber, pill, bar in
                self?.handleSpaceHover(spaceNumber, pill: pill, bar: bar, view: view)
            }
            panel.acceptsMouseMovedEvents = true
            if let snap = snapshots[uuid] {
                view.snapshot = snap
            }
            panel.contentView = view
            view.mode = mode
            panels[uuid] = panel
            views[uuid] = view
            screens[uuid] = screen
        }
    }
}

// MARK: - Window drops onto a Desktop

/// While a window card is carried, each Desktop pill is a drop target, and so
/// is the Desktop card it spring-loads: rest the card on a pill and that
/// Desktop's preview opens beneath it, highlighted as the destination.
@available(macOS 14.0, *)
extension TilingControlBarController: WindowDropTargetProvider {

    private struct DesktopHit {
        let view: TilingControlBarView
        let screen: NSScreen
        let spaceNumber: Int
        let pill: CGRect
        let bar: CGRect
    }

    /// The pill under a screen point, on a bar that is actually showing.
    private func desktopHit(at point: NSPoint) -> DesktopHit? {
        for (uuid, panel) in panels where panel.isVisible && panel.alphaValue > 0.5 {
            // The pointer can rest on the screen's very top edge, which a
            // strict `contains` leaves out.
            guard panel.frame.insetBy(dx: 0, dy: -1).contains(point),
                  let view = views[uuid], let screen = screens[uuid],
                  let hit = view.spaceHit(atScreenPoint: point) else { continue }
            return DesktopHit(view: view, screen: screen, spaceNumber: hit.number,
                              pill: hit.pill, bar: panel.frame)
        }
        return nil
    }

    /// The Desktop a release at `point` would move `windowID` to: a pill, or
    /// a tile in the open Desktop strip. Never a fullscreen app's Space, and
    /// never the Space the window is already on.
    private func resolveDropTarget(at point: NSPoint, windowID: CGWindowID)
        -> (target: WindowDropTarget, displayUUID: String, spaceNumber: Int)? {
        guard isEnabled else { return nil }
        let displayUUID: String
        let screen: NSScreen
        let spaceNumber: Int
        if let hit = desktopHit(at: point) {
            (displayUUID, screen, spaceNumber) = (hit.view.displayUUID, hit.screen, hit.spaceNumber)
        } else if spacePreviewStorage != nil, let shown = spacePreview.shown, shown.addDesktop != nil,
                  spacePreview.isOverNewDesktop(atScreenPoint: point) {
            // The plus tile: a Desktop that doesn't exist yet.
            let target = WindowDropTarget(spaceID: 0, label: "New Desktop",
                                          newSpaceDisplayUUID: shown.displayUUID,
                                          landingRect: spacePreview.newDesktopScreenRect)
            return (target, shown.displayUUID, TilingSpacePreviewLayout.newDesktopKey)
        } else if spacePreviewStorage != nil, let shown = spacePreview.shown,
                  let tile = spacePreview.spaceNumber(atScreenPoint: point) {
            (displayUUID, screen, spaceNumber) = (shown.displayUUID, shown.screen, tile)
        } else {
            return nil
        }
        guard let space = WindowPreviewCapture.managedSpace(for: screen, number: spaceNumber),
              !space.isFullscreen,
              !WindowPreviewCapture.window(windowID, isOnManagedSpace: space.id) else { return nil }
        return (WindowDropTarget(spaceID: space.id, label: "Desktop \(spaceNumber)"), displayUUID, spaceNumber)
    }

    func windowDragMoved(to point: NSPoint, windowID: CGWindowID) {
        guard isEnabled else { return }
        if let hit = desktopHit(at: point) {
            spacePreview.hover(spaceTarget(hit.spaceNumber, pill: hit.pill, bar: hit.bar,
                                           view: hit.view, screen: hit.screen))
        } else if spacePreviewStorage != nil, spacePreview.cardFrame?.contains(point) != true {
            spacePreview.hover(nil)
        }
        guard spacePreviewStorage != nil, let shown = spacePreview.shown else { return }
        // The tile under the card follows the pointer whether or not it can take
        // this window; only a valid destination gets the drop ring.
        let pointed = spacePreview.spaceNumber(atScreenPoint: point)
        let resolved = resolveDropTarget(at: point, windowID: windowID)
        let onThisStrip = resolved?.displayUUID.caseInsensitiveCompare(shown.displayUUID) == .orderedSame
        spacePreview.setDropTarget(onThisStrip ? resolved?.spaceNumber : nil, highlighting: pointed)
    }

    func windowDropTarget(at point: NSPoint, windowID: CGWindowID) -> WindowDropTarget? {
        resolveDropTarget(at: point, windowID: windowID)?.target
    }

    func windowDragEnded(droppedOn target: WindowDropTarget?) {
        guard spacePreviewStorage != nil else { return }
        spacePreview.setDropTarget(nil, highlighting: nil)
        // A drop onto a Desktop keeps its card open to show the window arrive;
        // anything else lets it close once the pointer is away from it.
        if target == nil { spacePreview.hover(nil) }
    }

    func windowDropCreateSpace(for target: WindowDropTarget) -> Bool {
        guard let displayUUID = target.newSpaceDisplayUUID, let onAddSpace else { return false }
        if spacePreviewStorage != nil { spacePreview.setAddingDesktop(true) }
        onAddSpace(displayUUID)
        return true
    }

    func windowMoved(_ windowID: CGWindowID, to target: WindowDropTarget, moved: Bool) {
        // A Desktop may have just been added for this drop: rebuild the strip
        // so it slides in (and the plus tile stops spinning). Existing Desktop
        // drops are recaptured only after their layout has finished; capturing
        // here would preserve the window's pre-tile size until the strip closes.
        if target.newSpaceDisplayUUID != nil, spacePreviewStorage != nil {
            spacePreview.refreshDesktops()
        }
        guard moved else { return }
        onWindowMovedToSpace?(windowID, target.spaceID)
    }

    /// Recaptures the open Desktop card, if any — after a Desktop that isn't
    /// showing was retiled, so the card shows the windows at their new sizes.
    func reloadSpacePreview() {
        if spacePreviewStorage != nil { spacePreview.reload() }
    }
}

final class MenubarBackdropPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

final class TilingMenubarBackdropView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet {
            if cornerRadius != oldValue {
                needsDisplay = true
            }
        }
    }
    var cornerCurve: CornerCurve = .g2 {
        didSet {
            if cornerCurve != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Width left clear at the left end of the menu bar strip (see
    /// `fullscreenControlsWidth`); 0 for none.
    var leftHole: CGFloat = 0 {
        didSet {
            if leftHole != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool {
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        let w = bounds.width
        let r = cornerRadius
        let reach = r > 0 ? CornerGeometry.reach(for: r, curve: cornerCurve) : 0
        let h = bounds.height - reach
        guard h > 0, w > 0 else { return }

        let path = NSBezierPath()

        if r <= 0 {
            path.appendRect(NSRect(x: 0, y: 0, width: w, height: bounds.height))
        } else {
            path.appendRect(NSRect(x: 0, y: reach, width: w, height: h))

            if cornerCurve == .g2 {
                let pL = NSBezierPath()
                let cornerPointL = CGPoint(x: 0, y: reach)
                pL.move(to: cornerPointL)
                pL.line(to: CGPoint(x: 0, y: 0))
                pL.curve(
                    to: CGPoint(x: CornerGeometry.k4 * r, y: reach - CornerGeometry.k3 * r),
                    controlPoint1: CGPoint(x: 0, y: reach - CornerGeometry.k1 * r),
                    controlPoint2: CGPoint(x: 0, y: reach - CornerGeometry.k2 * r)
                )
                pL.curve(
                    to: CGPoint(x: CornerGeometry.k3 * r, y: reach - CornerGeometry.k4 * r),
                    controlPoint1: CGPoint(x: CornerGeometry.k6 * r, y: reach - CornerGeometry.k5 * r),
                    controlPoint2: CGPoint(x: CornerGeometry.k5 * r, y: reach - CornerGeometry.k6 * r)
                )
                pL.curve(
                    to: CGPoint(x: reach, y: reach),
                    controlPoint1: CGPoint(x: CornerGeometry.k2 * r, y: reach),
                    controlPoint2: CGPoint(x: CornerGeometry.k1 * r, y: reach)
                )
                pL.line(to: cornerPointL)
                pL.close()
                path.append(pL)

                let pR = NSBezierPath()
                let cornerPointR = CGPoint(x: w, y: reach)
                pR.move(to: cornerPointR)
                pR.line(to: CGPoint(x: w, y: 0))
                pR.curve(
                    to: CGPoint(x: w - CornerGeometry.k4 * r, y: reach - CornerGeometry.k3 * r),
                    controlPoint1: CGPoint(x: w, y: reach - CornerGeometry.k1 * r),
                    controlPoint2: CGPoint(x: w, y: reach - CornerGeometry.k2 * r)
                )
                pR.curve(
                    to: CGPoint(x: w - CornerGeometry.k3 * r, y: reach - CornerGeometry.k4 * r),
                    controlPoint1: CGPoint(x: w - CornerGeometry.k6 * r, y: reach - CornerGeometry.k5 * r),
                    controlPoint2: CGPoint(x: w - CornerGeometry.k5 * r, y: reach - CornerGeometry.k6 * r)
                )
                pR.curve(
                    to: CGPoint(x: w - reach, y: reach),
                    controlPoint1: CGPoint(x: w - CornerGeometry.k2 * r, y: reach),
                    controlPoint2: CGPoint(x: w - CornerGeometry.k1 * r, y: reach)
                )
                pR.line(to: cornerPointR)
                pR.close()
                path.append(pR)
            } else {
                let pL = NSBezierPath()
                pL.move(to: NSPoint(x: 0, y: reach))
                pL.line(to: NSPoint(x: 0, y: 0))
                pL.curve(to: NSPoint(x: reach, y: reach),
                         controlPoint1: NSPoint(x: 0, y: reach * 0.55228475),
                         controlPoint2: NSPoint(x: reach * 0.44771525, y: reach))
                pL.close()
                path.append(pL)

                let pR = NSBezierPath()
                pR.move(to: NSPoint(x: w, y: reach))
                pR.line(to: NSPoint(x: w, y: 0))
                pR.curve(to: NSPoint(x: w - reach, y: reach),
                         controlPoint1: NSPoint(x: w, y: reach * 0.55228475),
                         controlPoint2: NSPoint(x: w - reach * 0.44771525, y: reach))
                pR.close()
                path.append(pR)
            }
        }

        NSColor.black.setFill()
        path.fill()

        if leftHole > 0 {
            // Only the strip itself: the corner fillet below it stays.
            let strip = r > 0 ? NSRect(x: 0, y: reach, width: leftHole, height: h)
                              : NSRect(x: 0, y: 0, width: leftHole, height: bounds.height)
            NSGraphicsContext.current?.cgContext.clear(strip)
        }
    }
}

private final class TilingControlBarView: NSView {
    var displayUUID = ""
    var snapshot: TilingBarSnapshot? {
        didSet {
            let oldSpace = oldValue?.spaceNumber
            let newSpace = snapshot?.spaceNumber
            let oldApps = oldValue?.windows ?? []
            let newApps = snapshot?.windows ?? []
            let oldBundles = oldApps.map(\.windowID)
            let newBundles = newApps.map(\.windowID)
            let oldShown = Set(oldApps.filter(\.isShownInLayout).map(\.windowID))
            let newShown = Set(newApps.filter(\.isShownInLayout).map(\.windowID))
            let clickedPopArrived = requestedPillPopID.map { newShown.contains($0) } ?? false

            let spaceChanged = (oldSpace != nil && newSpace != nil &&
                                oldValue?.displayUUID == snapshot?.displayUUID &&
                                oldSpace != newSpace &&
                                (snapshot?.spaceCount ?? 0) > 1)
            // A click-owned transition stays locked to its requested Space
            // until that Space actually arrives. The old two-second timeout
            // made slow WindowServer updates fall back into the normal slide
            // animation, so the same click could animate on one attempt and
            // snap on another.
            let clickedSpaceTarget = pendingClickedSpaceNumber

            if oldValue == nil {
                shownPillAlphas = Dictionary(uniqueKeysWithValues: newShown.map { ($0, CGFloat(1)) })
            } else if oldShown != newShown {
                if clickedPopArrived {
                    // An app-icon click is direct manipulation: put the pill at
                    // its destination immediately and use only the click pop.
                    settleShownPills(newShown)
                } else {
                    let shouldTravel = snapshot?.pillScope == .currentSpace &&
                        !oldShown.isEmpty && !newShown.isEmpty
                    if shouldTravel {
                        startShownPillTravel(from: oldApps, to: newApps,
                                             oldShown: oldShown, newShown: newShown)
                    } else {
                        startShownPillAnimation(from: oldShown, to: newShown)
                    }
                }
            }
            if let requestedID = requestedPillPopID, newShown.contains(requestedID) {
                requestedPillPopID = nil
                startClickedPillPop(windowID: requestedID)
            }

            if let clickedSpaceTarget, newSpace == clickedSpaceTarget {
                scheduleClickedSpaceUnlock(spaceNumber: clickedSpaceTarget)
            }

            if spaceChanged {
                if let clickedSpaceTarget {
                    // Keep the clicked destination locked through every
                    // intermediate WindowServer snapshot. None may animate it.
                    setSpaceIndicatorImmediately(clickedSpaceTarget)
                } else {
                    animateSpaceChange(from: oldSpace!, to: newSpace!)
                }
                if oldBundles != newBundles {
                    startAppFade(from: oldApps, to: newApps)
                }
            } else {
                if let clickedSpaceTarget {
                    setSpaceIndicatorImmediately(clickedSpaceTarget)
                } else if pillAnimationTimer == nil {
                    animatedPillIndex = CGFloat(newSpace ?? 1)
                    animatedStretch = 0
                }
                if oldBundles != newBundles, oldValue?.displayUUID == snapshot?.displayUUID, !oldApps.isEmpty {
                    startAppFade(from: oldApps, to: newApps)
                } else if appAnimationTimer == nil {
                    outgoingApps = []
                    outgoingPlacements = [:]
                    appTransitionProgress = 1.0
                }
                needsDisplay = true
            }
        }
    }
    var onRetile: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onToggleMaster: ((CGWindowID?) -> Void)?
    var onToggleFloating: ((CGWindowID?) -> Void)?
    var onActivateWindow: ((CGWindowID, pid_t, CGRect) -> Void)?
    var onToggleScope: (() -> Void)?
    var onSwitchSpace: ((Int) -> Void)?
    var onMoveWindowToDesktop: ((CGWindowID, pid_t, Int?) -> Void)?
    /// The icon under the pointer — its window, the icon's rect and the bar's
    /// frame, both on screen — or nil once the pointer is on no icon.
    var onHoverWindow: ((TilingBarWindow?, CGRect, CGRect) -> Void)?
    /// The Desktop pill under the pointer — its number, the pill's column and
    /// the bar's frame, both on screen — or nil once the pointer is on none.
    var onHoverSpace: ((Int?, CGRect, CGRect) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hoveredWindowID: CGWindowID?
    private var hoveredSpaceNumber: Int?
    /// Each pill's click column, as last drawn, in view coordinates.
    private var spaceHitRects: [(number: Int, rect: CGRect)] = []
    private var actions: [(CGRect, () -> Void)] = []
    private var pressedAction: (CGRect, () -> Void)?

    private struct PlacedItem {
        let window: TilingBarWindow
        let rect: CGRect
        let leadingDividerX: CGFloat?
    }
    private var placedItems: [PlacedItem] = []
    private var animatedPillIndex: CGFloat = 1.0
    private var animatedStretch: CGFloat = 0.0
    private var animatedDirection: CGFloat = 1.0
    private var pillAnimationTimer: Timer?
    private var pendingClickedSpaceNumber: Int?
    private var clickedSpaceTransitionGeneration = 0

    private typealias AppTuple = TilingBarWindow
    private var outgoingApps: [AppTuple] = []
    private var outgoingPlacements: [CGWindowID: CGRect] = [:]
    private var appTransitionProgress: CGFloat = 1.0
    private var appAnimationTimer: Timer?
    private var shownPillAlphas: [CGWindowID: CGFloat] = [:]
    private var shownPillAnimationTimer: Timer?
    private var shownPillTravelStarts: [CGWindowID: CGRect] = [:]
    private var shownPillTravelProgress: CGFloat = 1
    private var requestedPillPopID: CGWindowID?
    private var clickedPillPopID: CGWindowID?
    private var clickedPillPopProgress: CGFloat = 1
    private var clickedPillPopTimer: Timer?

    var mode: TilingControlBarMode = .hybridNotch

    private var animationStyle: AnimationStyle { AppSettings.shared.animationStyle }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.activeAlways`: MSG is almost never the active app, and the bar is a
        // non-activating panel, so an active-app-only area would never fire.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        reportHover(nil)
        reportSpaceHover(nil)
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            reportHover(nil)
            reportSpaceHover(nil)
            return
        }
        // The pills' click columns, so hovering and clicking a Desktop always
        // agree on which one the pointer means.
        if let space = spaceHitRects.first(where: { $0.rect.contains(point) }) {
            reportHover(nil)
            reportSpaceHover(space)
            return
        }
        reportSpaceHover(nil)
        // The icon's whole column, spacing included: the bar is short, and a
        // pointer resting anywhere in the column or in the gap still means that icon.
        let item = placedItems.first { item in
            point.x >= item.rect.minX - 3.5 && point.x <= item.rect.maxX + 3.5
        }
        reportHover(item)
    }

    private func reportHover(_ item: PlacedItem?) {
        guard item?.window.windowID != hoveredWindowID else { return }
        hoveredWindowID = item?.window.windowID
        guard let barWindow = window else { return }
        let icon: CGRect
        if let item {
            // Span the full bar height for the column so pointer movement within
            // the bar doesn't falsely fall out of the icon's vertical bounds.
            let colRect = CGRect(x: item.rect.minX - 3.5, y: 0, width: item.rect.width + 7, height: bounds.height)
            icon = barWindow.convertToScreen(convert(colRect, to: nil))
        } else {
            icon = .zero
        }
        onHoverWindow?(item?.window, icon, barWindow.frame)
    }

    func resetHoverState() {
        hoveredWindowID = nil
    }

    private func reportSpaceHover(_ hit: (number: Int, rect: CGRect)?) {
        guard hit?.number != hoveredSpaceNumber else { return }
        hoveredSpaceNumber = hit?.number
        guard let barWindow = window else { return }
        let pill = hit.map { barWindow.convertToScreen(convert($0.rect, to: nil)) } ?? .zero
        onHoverSpace?(hit?.number, pill, barWindow.frame)
    }

    func resetSpaceHoverState() {
        hoveredSpaceNumber = nil
    }

    /// The Desktop pill at a point on screen, with its column on screen — for a
    /// window drag, which the bar never sees as mouse-moved events.
    func spaceHit(atScreenPoint point: NSPoint) -> (number: Int, pill: CGRect)? {
        guard let barWindow = window else { return nil }
        let local = convert(barWindow.convertPoint(fromScreen: point), from: nil)
        guard let hit = spaceHitRects.first(where: { $0.rect.contains(local) }) else { return nil }
        return (hit.number, barWindow.convertToScreen(convert(hit.rect, to: nil)))
    }

    /// The whole pill row's click area on screen — the Desktop strip centres
    /// under it — or nil while no pills are drawn.
    func spaceIndicatorRectOnScreen() -> CGRect? {
        guard let barWindow = window, let first = spaceHitRects.first else { return nil }
        let row = spaceHitRects.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        return barWindow.convertToScreen(convert(row, to: nil))
    }

    /// Switches to a Desktop exactly as clicking its pill does, indicator
    /// feedback included — shared by the pill and the Desktop preview card.
    func selectSpace(_ spaceNumber: Int) {
        prepareForClickedSpaceChange(spaceNumber)
        onSwitchSpace?(spaceNumber)
    }

    /// A click on the hover card: exactly what clicking the icon does, pill pop
    /// included, so the two can never drift apart.
    func activateFromPreview(_ window: TilingBarWindow) {
        requestClickedPillPop(windowID: window.windowID)
        onActivateWindow?(window.windowID, window.pid, window.frame)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        actions = []
        spaceHitRects = []
        if mode == .hybridNotch {
            NSColor.black.setFill()
            bounds.fill()
        }
        guard let snapshot else { return }

        var x: CGFloat = 12
        if AppSettings.shared.tilingControlBarDuoBatteryWifi {
            x += drawDuoBatteryWifi(at: x) + 8
        }
        x += drawLeadingIndicator(total: snapshot.spaceCount, at: x) + 14

        drawAppList(at: x, maxX: bounds.width - 10)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let item = placedItems.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) {
            return makeWindowMenu(for: item.window)
        }
        return makeBarMenu()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let menu = menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        _ = menu.popUp(positioning: nil, at: point, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            let point = convert(event.locationInWindow, from: nil)
            if let menu = menu(for: event) {
                _ = menu.popUp(positioning: nil, at: point, in: self)
            }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        pressedAction = actions.first(where: { $0.0.contains(point) })
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedAction
        pressedAction = nil
        guard let pressed, snapshot != nil,
              pressed.0.contains(convert(event.locationInWindow, from: nil)) else { return }
        // The tiling engine intentionally defers writes while a button is down.
        // Match native buttons: activate on release inside the original hit area.
        pressed.1()
    }

    private func animateSpaceChange(from oldSpace: Int, to newSpace: Int) {
        pillAnimationTimer?.invalidate()

        // Match the menu-bar indicator: always animate from the true previous
        // space (oldSpace), never from the possibly mid-flight `animatedPillIndex`.
        // Using the live value made a rapid space change start from wherever the
        // previous animation happened to be, so the pill slid the wrong distance.
        let fromValue = CGFloat(oldSpace)
        let style = animationStyle
        let duration = SpacePillAnimationPipeline.duration(style: style, from: oldSpace, to: newSpace)
        let direction: CGFloat = newSpace > oldSpace ? 1.0 : -1.0
        let startTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: SpacePillAnimationPipeline.frameInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let raw = min(1.0, CGFloat(elapsed / duration))
            let p = SpacePillAnimationPipeline.easedProgress(raw, style: style)
            self.animatedPillIndex = fromValue + (CGFloat(newSpace) - fromValue) * p
            self.animatedStretch = SpacePillAnimationPipeline.stretch(progress: p, style: style)
            self.animatedDirection = direction
            self.needsDisplay = true
            if raw >= 1.0 {
                t.invalidate()
                self.pillAnimationTimer = nil
                self.animatedPillIndex = CGFloat(newSpace)
                self.animatedStretch = 0.0
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pillAnimationTimer = timer
    }

    private func setSpaceIndicatorImmediately(_ spaceNumber: Int) {
        pillAnimationTimer?.invalidate()
        pillAnimationTimer = nil
        animatedPillIndex = CGFloat(spaceNumber)
        animatedStretch = 0
        needsDisplay = true
    }

    private func prepareForClickedSpaceChange(_ spaceNumber: Int) {
        clickedSpaceTransitionGeneration &+= 1
        let generation = clickedSpaceTransitionGeneration
        guard snapshot?.spaceNumber != spaceNumber else {
            pendingClickedSpaceNumber = nil
            setSpaceIndicatorImmediately(spaceNumber)
            return
        }
        pendingClickedSpaceNumber = spaceNumber
        // Give immediate click feedback before macOS begins switching Spaces.
        setSpaceIndicatorImmediately(spaceNumber)

        // A failed system switch must not leave the indicator stuck forever.
        // Clear by request identity, never by an animation timeout: even this
        // recovery snaps to the real Space instead of starting a slide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self,
                  self.clickedSpaceTransitionGeneration == generation,
                  self.pendingClickedSpaceNumber == spaceNumber else { return }
            self.pendingClickedSpaceNumber = nil
            self.setSpaceIndicatorImmediately(self.snapshot?.spaceNumber ?? spaceNumber)
        }
    }

    private func scheduleClickedSpaceUnlock(spaceNumber: Int) {
        let generation = clickedSpaceTransitionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self,
                  self.clickedSpaceTransitionGeneration == generation,
                  self.pendingClickedSpaceNumber == spaceNumber,
                  self.snapshot?.spaceNumber == spaceNumber else { return }
            self.pendingClickedSpaceNumber = nil
            self.setSpaceIndicatorImmediately(spaceNumber)
        }
    }

    private func startAppFade(from oldApps: [AppTuple], to newApps: [AppTuple]) {
        appAnimationTimer?.invalidate()
        appAnimationTimer = nil
        let oldWindowIDs = oldApps.map(\.windowID)
        let newWindowIDs = newApps.map(\.windowID)
        guard oldWindowIDs != newWindowIDs else {
            outgoingApps = []
            outgoingPlacements = [:]
            appTransitionProgress = 1.0
            return
        }

        outgoingApps = oldApps
        // Capture the previous layout so removed apps fade out at the exact slot
        // they occupied, instead of jumping to a new window's position.
        outgoingPlacements = Dictionary(placedItems.map { ($0.window.windowID, $0.rect) },
                                        uniquingKeysWith: { first, _ in first })
        appTransitionProgress = 0.0

        let startTime = CACurrentMediaTime()
        let duration: TimeInterval = 0.22

        let timer = Timer(timeInterval: TilingDisplayClock.interval(for: window?.screen),
                          repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            let raw = min(1.0, CGFloat(elapsed / duration))
            self.appTransitionProgress = raw
            self.needsDisplay = true
            if raw >= 1.0 {
                t.invalidate()
                self.appAnimationTimer = nil
                self.outgoingApps = []
                self.outgoingPlacements = [:]
                self.appTransitionProgress = 1.0
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        appAnimationTimer = timer
    }

    private func startShownPillAnimation(from oldShown: Set<CGWindowID>,
                                         to newShown: Set<CGWindowID>) {
        shownPillAnimationTimer?.invalidate()
        shownPillAnimationTimer = nil
        shownPillTravelStarts = [:]
        shownPillTravelProgress = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            shownPillAlphas = Dictionary(uniqueKeysWithValues: newShown.map { ($0, CGFloat(1)) })
            needsDisplay = true
            return
        }

        let ids = oldShown.union(newShown)
        let starts = Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, shownPillAlphas[id] ?? (oldShown.contains(id) ? 1 : 0))
        })
        let duration: TimeInterval = 0.18
        let startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: TilingDisplayClock.interval(for: window?.screen),
                          repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - startTime) / duration))
            let progress = 0.5 - 0.5 * cos(raw * .pi)
            for id in ids {
                let start = starts[id] ?? 0
                let target: CGFloat = newShown.contains(id) ? 1 : 0
                self.shownPillAlphas[id] = start + (target - start) * progress
            }
            self.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
                self.shownPillAnimationTimer = nil
                self.shownPillAlphas = Dictionary(
                    uniqueKeysWithValues: newShown.map { ($0, CGFloat(1)) }
                )
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shownPillAnimationTimer = timer
    }

    private func startShownPillTravel(from oldApps: [AppTuple], to newApps: [AppTuple],
                                      oldShown: Set<CGWindowID>, newShown: Set<CGWindowID>) {
        shownPillAnimationTimer?.invalidate()
        shownPillAnimationTimer = nil

        let oldRects = Dictionary(placedItems.map { ($0.window.windowID, $0.rect) },
                                  uniquingKeysWith: { first, _ in first })
        let originalCandidates = oldApps.filter { oldShown.contains($0.windowID) }
        var available = originalCandidates
        var starts: [CGWindowID: CGRect] = [:]
        for incoming in newApps where newShown.contains(incoming.windowID) {
            let outgoing: AppTuple?
            if let match = available.firstIndex(where: { $0.status == incoming.status }) {
                outgoing = available.remove(at: match)
            } else if !available.isEmpty {
                outgoing = available.removeFirst()
            } else {
                // One visible window can become two on the destination Space.
                // Reuse its origin so both pills visibly split and travel out
                // from the previous pill instead of the second one appearing.
                outgoing = originalCandidates.first(where: { $0.status == incoming.status }) ??
                    originalCandidates.first
            }
            guard let outgoing else { continue }
            if let rect = oldRects[outgoing.windowID] {
                starts[incoming.windowID] = rect
            }
        }

        guard !starts.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            shownPillTravelStarts = [:]
            shownPillTravelProgress = 1
            shownPillAlphas = Dictionary(uniqueKeysWithValues: newShown.map { ($0, CGFloat(1)) })
            needsDisplay = true
            return
        }

        shownPillTravelStarts = starts
        shownPillTravelProgress = 0
        shownPillAlphas = Dictionary(uniqueKeysWithValues: newShown.map { ($0, CGFloat(1)) })
        let startTime = CACurrentMediaTime()
        let duration: TimeInterval = 0.28
        let timer = Timer(timeInterval: TilingDisplayClock.interval(for: window?.screen),
                          repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - startTime) / duration))
            self.shownPillTravelProgress = 0.5 - 0.5 * cos(raw * .pi)
            self.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
                self.shownPillAnimationTimer = nil
                self.shownPillTravelStarts = [:]
                self.shownPillTravelProgress = 1
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shownPillAnimationTimer = timer
    }

    private func settleShownPills(_ shown: Set<CGWindowID>) {
        shownPillAnimationTimer?.invalidate()
        shownPillAnimationTimer = nil
        shownPillTravelStarts = [:]
        shownPillTravelProgress = 1
        shownPillAlphas = Dictionary(uniqueKeysWithValues: shown.map { ($0, CGFloat(1)) })
        needsDisplay = true
    }

    private func requestClickedPillPop(windowID: CGWindowID) {
        let isAlreadyShown = snapshot?.windows.first(where: { $0.windowID == windowID })?
            .isShownInLayout == true
        if isAlreadyShown {
            requestedPillPopID = nil
            startClickedPillPop(windowID: windowID)
        } else {
            // Start at the destination snapshot. This avoids drawing a second
            // pill before the clicked tab has actually become visible.
            requestedPillPopID = windowID
        }
    }

    private func startClickedPillPop(windowID: CGWindowID) {
        clickedPillPopTimer?.invalidate()
        clickedPillPopTimer = nil
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clickedPillPopID = nil
            clickedPillPopProgress = 1
            return
        }

        clickedPillPopID = windowID
        clickedPillPopProgress = 0
        let startTime = CACurrentMediaTime()
        let duration: TimeInterval = 0.24
        let timer = Timer(timeInterval: TilingDisplayClock.interval(for: window?.screen),
                          repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - startTime) / duration))
            self.clickedPillPopProgress = raw
            self.needsDisplay = true
            if raw >= 1 {
                timer.invalidate()
                self.clickedPillPopTimer = nil
                self.clickedPillPopID = nil
                self.clickedPillPopProgress = 1
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clickedPillPopTimer = timer
    }

    private func drawIcon(_ icon: NSImage, in rect: CGRect, alpha: CGFloat) {
        icon.draw(in: rect, from: NSRect.zero, operation: .sourceOver,
                  fraction: alpha, respectFlipped: true,
                  hints: nil as [NSImageRep.HintKey: Any]?)
    }

    private func drawAppList(at startX: CGFloat, maxX: CGFloat) {
        guard maxX > startX else {
            placedItems = []
            return
        }
        let clipRect = CGRect(x: startX, y: 0, width: maxX - startX, height: bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clipRect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let iconY = (bounds.height - 20) / 2
        let iconSize: CGFloat = 20
        let groupInsetX: CGFloat = 3.5
        let intraGroupSpacing: CGFloat = 6
        let interGroupGap: CGFloat = 9
        let standaloneToGroupGap: CGFloat = 8
        let standaloneSpacing: CGFloat = 7
        let dividerMargin: CGFloat = 8
        let dividerWidth: CGFloat = 2
        let isAllSpaces = snapshot?.scope == .allSpaces
        let maxCount = isAllSpaces ? 24 : 18
        let currentWindows = Array((snapshot?.windows ?? []).prefix(maxCount))

        // Pre-compute group IDs for tabbed windows:
        // Consecutive windows sharing the same column side and Desktop form a tab stack.
        func tabSide(_ status: TilingWindowStatus) -> Int? {
            switch status {
            case .leftTabbed: return 0
            case .rightTabbed: return 1
            default: return nil
            }
        }
        var groupForIndex: [Int: Int] = [:]
        var currentGroupID = 0
        var scan = 0
        while scan < currentWindows.count {
            guard let side = tabSide(currentWindows[scan].status) else {
                scan += 1
                continue
            }
            let spaceNumber = currentWindows[scan].spaceNumber
            var end = scan + 1
            while end < currentWindows.count,
                  tabSide(currentWindows[end].status) == side,
                  currentWindows[end].spaceNumber == spaceNumber {
                end += 1
            }
            if end - scan >= 2 {
                for i in scan..<end {
                    groupForIndex[i] = currentGroupID
                }
                currentGroupID += 1
            }
            scan = end
        }

        var placed: [PlacedItem] = []
        var curX = startX + 4
        if groupForIndex[0] != nil {
            curX += groupInsetX
        }

        for (index, window) in currentWindows.enumerated() {
            var divX: CGFloat? = nil
            if index > 0 {
                let previous = currentWindows[index - 1]
                let spaceChanged = isAllSpaces && window.spaceNumber != previous.spaceNumber
                let prevGroup = groupForIndex[index - 1]
                let currGroup = groupForIndex[index]

                if spaceChanged {
                    let leftPad = (prevGroup != nil ? groupInsetX : 0) + dividerMargin
                    let rightPad = dividerMargin + (currGroup != nil ? groupInsetX : 0)
                    if let prevRect = placed.last?.rect {
                        divX = prevRect.maxX + leftPad
                        curX = divX! + dividerWidth + rightPad
                    } else {
                        curX += dividerMargin
                        divX = curX
                        curX += dividerWidth + rightPad
                    }
                } else {
                    let spacing: CGFloat
                    if prevGroup != nil && currGroup != nil && prevGroup == currGroup {
                        // Same tab stack
                        spacing = intraGroupSpacing
                    } else if prevGroup != nil && currGroup != nil && prevGroup != currGroup {
                        // Adjacent distinct tab stacks: ample space so capsules never overlap
                        spacing = groupInsetX + interGroupGap + groupInsetX
                    } else if prevGroup != nil && currGroup == nil {
                        // Exiting tab stack to standalone window
                        spacing = groupInsetX + standaloneToGroupGap
                    } else if prevGroup == nil && currGroup != nil {
                        // Entering tab stack from standalone window
                        spacing = standaloneToGroupGap + groupInsetX
                    } else {
                        // Both standalone windows
                        spacing = standaloneSpacing
                    }
                    curX += spacing
                }
            }

            guard curX + iconSize + 2 <= maxX else { break }
            let rect = CGRect(x: curX, y: iconY, width: iconSize, height: iconSize)
            placed.append(PlacedItem(window: window, rect: rect, leadingDividerX: divX))
            curX += iconSize
        }

        // FLIP-style repositioning: surviving icons begin at their currently
        // presented positions and glide to the new Desktop/order positions.
        // Attaching a divider to the icon after it keeps both moving together.
        if appAnimationTimer != nil, appTransitionProgress < 1,
           !outgoingPlacements.isEmpty {
            let raw = min(1, max(0, appTransitionProgress))
            let progress = 0.5 - 0.5 * cos(raw * .pi)
            placed = placed.map { item in
                guard let oldRect = outgoingPlacements[item.window.windowID] else { return item }
                let targetRect = item.rect
                let animatedRect = CGRect(
                    x: oldRect.minX + (targetRect.minX - oldRect.minX) * progress,
                    y: oldRect.minY + (targetRect.minY - oldRect.minY) * progress,
                    width: oldRect.width + (targetRect.width - oldRect.width) * progress,
                    height: oldRect.height + (targetRect.height - oldRect.height) * progress
                )
                let animatedDivider = item.leadingDividerX.map {
                    $0 + animatedRect.minX - targetRect.minX
                }
                return PlacedItem(window: item.window, rect: animatedRect,
                                  leadingDividerX: animatedDivider)
            }
        }

        placedItems = placed

        // Tint only actual tab stacks (two or more windows in one column).
        // A lone window stays unframed even when the opposite column exists.
        // Keep groups scoped to a Desktop, separate from Space dividers.
        var groupStart = 0
        while groupStart < placed.count {
            guard let side = tabSide(placed[groupStart].window.status) else {
                groupStart += 1
                continue
            }
            let spaceNumber = placed[groupStart].window.spaceNumber
            var groupEnd = groupStart + 1
            while groupEnd < placed.count,
                  tabSide(placed[groupEnd].window.status) == side,
                  placed[groupEnd].window.spaceNumber == spaceNumber {
                groupEnd += 1
            }
            if groupEnd - groupStart >= 2 {
                let groupRect = placed[groupStart..<groupEnd]
                    .map(\.rect)
                    .reduce(CGRect.null) { $0.union($1) }
                    .insetBy(dx: -groupInsetX, dy: -3)
                NSColor.white.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: groupRect, xRadius: 7, yRadius: 7).fill()
            }
            groupStart = groupEnd
        }

        // Register button actions matching the exact calculated frame
        for item in placed {
            let hitRect = item.rect.insetBy(dx: -2, dy: -2)
            actions.append((hitRect, { [weak self] in
                self?.requestClickedPillPop(windowID: item.window.windowID)
                self?.onActivateWindow?(item.window.windowID, item.window.pid, item.window.frame)
            }))
        }

        func drawShownPill(for item: PlacedItem, alpha: CGFloat) {
            let progress = min(1, max(0, shownPillAlphas[item.window.windowID]
                ?? (item.window.isShownInLayout ? 1 : 0)))
            guard progress > 0.001 else { return }
            let startRect = shownPillTravelStarts[item.window.windowID]
            let motionStart = startRect.flatMap { rect in
                let positionChanged = abs(rect.midX - item.rect.midX) > 0.75 ||
                    abs(rect.midY - item.rect.midY) > 0.75
                return positionChanged ? rect : nil
            }
            let travel = motionStart == nil ? 1 : min(1, max(0, shownPillTravelProgress))
            let centerX = motionStart.map { $0.midX + (item.rect.midX - $0.midX) * travel }
                ?? item.rect.midX
            let movementStretch = motionStart == nil ? 0 : 4 * sin(travel * .pi)
            let clickStretch = clickedPillPopID == item.window.windowID
                ? 4 * sin(min(1, max(0, clickedPillPopProgress)) * .pi)
                : 0
            let stretch = max(movementStretch, clickStretch)
            let width: CGFloat = 3 + 4 * progress + stretch
            let height: CGFloat = 2
            let targetY = min(bounds.height - height - 1, item.rect.maxY)
            let startY = motionStart.map { min(bounds.height - height - 1, $0.maxY) } ?? targetY
            let y = startY + (targetY - startY) * travel
            let rect = CGRect(x: centerX - width / 2, y: y,
                              width: width, height: height)
            NSColor.white.withAlphaComponent(0.32 * progress * alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        // Draw vertical category / space dividers
        for item in placed {
            if let divX = item.leadingDividerX {
                let divH: CGFloat = 10
                let divW: CGFloat = 2
                let divY = (bounds.height - divH) / 2
                let divRect = CGRect(x: round(divX), y: divY, width: divW, height: divH)
                NSColor.white.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: divRect, xRadius: divW / 2, yRadius: divW / 2).fill()
            }
        }

        // Resting / finished state: draw incoming apps at full opacity
        if appTransitionProgress >= 1.0 || outgoingApps.isEmpty || appAnimationTimer == nil {
            for item in placed {
                if let icon = item.window.icon {
                    drawIcon(icon, in: item.rect, alpha: 1.0)
                }
                drawShownPill(for: item, alpha: 1.0)
            }
            return
        }

        // Smooth cosine ease-in-out curve for silky crossfade without movement
        let raw = min(1.0, max(0.0, appTransitionProgress))
        let t = 0.5 - 0.5 * cos(raw * .pi)
        let outAlpha = max(0.0, 1.0 - t)
        let inAlpha = min(1.0, t)

        // Match by window ID, not list index: a window that survives a
        // reorder/insertion stays solid instead of dimming and blinking.
        let incomingIDs = Set(placed.map(\.window.windowID))
        let outgoingByID = Dictionary(outgoingApps.map { ($0.windowID, $0) },
                                      uniquingKeysWith: { first, _ in first })

        for item in placed {
            let inApp = item.window
            let persists = outgoingByID[inApp.windowID] != nil
            let iconAlpha = persists ? 1.0 : inAlpha
            if let icon = inApp.icon ?? outgoingByID[inApp.windowID]?.icon {
                drawIcon(icon, in: item.rect, alpha: iconAlpha)
            }
            drawShownPill(for: item, alpha: iconAlpha)
        }

        // Removed windows fade out at the slot they occupied before the change.
        if outAlpha > 0.01 {
            for outApp in outgoingApps where !incomingIDs.contains(outApp.windowID) {
                guard let icon = outApp.icon,
                      let rect = outgoingPlacements[outApp.windowID],
                      rect.width > 0, rect.height > 0 else { continue }
                drawIcon(icon, in: rect, alpha: outAlpha)
            }
        }
    }

    private func drawSpaceIndicator(total: Int, at startX: CGFloat,
                                    alpha: CGFloat = 1, interactive: Bool = true) -> CGFloat {
        let count = max(1, total)
        let currentPillIdx = max(1.0, min(CGFloat(count), animatedPillIndex))
        let dot: CGFloat = 5.25
        let basePillWidth: CGFloat = 26
        let pillHeight: CGFloat = 8
        let spacing: CGFloat = 5.25
        let metrics = SpacePillMetrics(
            dotD: dot, pillW: basePillWidth, pillH: pillHeight,
            clampedIdx: currentPillIdx, countFloat: CGFloat(count),
            rowStretch: 0, stretch: animatedStretch
        )
        // Same palette as the menu-bar indicator's focused pill (dark-mode base
        // plus the per-state alpha settings) so the two read identically.
        let base = NSColor(white: 0.90, alpha: 1)
        let bright = base.withAlphaComponent(AppSettings.shared.brightFocusAlpha)
        let dim = base.withAlphaComponent(AppSettings.shared.dimFocusAlpha)
        SpacePillAnimationPipeline.drawRow(
            metrics: metrics, count: count, spacing: spacing,
            originX: startX, originY: 0, rowHeight: bounds.height,
            bright: bright, dim: dim, rowAlpha: alpha,
            direction: animatedDirection
        )

        spaceHitRects = []
        guard interactive else {
            return SpacePillAnimationPipeline.rowWidth(metrics: metrics, count: count, spacing: spacing)
        }
        var hitX = startX + metrics.stretch * animatedDirection * 0.35
        for i in 1...count {
            let width = metrics.width(i)
            let hitLeft = hitX - (i == 1 ? 6 : spacing / 2)
            let hitRight = hitX + width + (i == count ? 6 : spacing / 2)
            let hitRect = CGRect(x: hitLeft, y: 0, width: hitRight - hitLeft, height: bounds.height)
            actions.append((hitRect, { [weak self] in self?.selectSpace(i) }))
            spaceHitRects.append((i, hitRect))
            hitX += width + spacing
        }

        return SpacePillAnimationPipeline.rowWidth(metrics: metrics, count: count, spacing: spacing)
    }

    // MARK: System & Input Source HUD

    /// The HUD geometry, matching the menu bar indicator's HUD frame
    /// (`IndicatorRenderer.makeSystemHUDFrame`) so the two read alike.
    private enum HUDMetrics {
        static let iconSlot: CGFloat = 18
        static let gap: CGFloat = 6
        static let trackWidth: CGFloat = 70
        static let trackHeight: CGFloat = 4
        /// SF Symbol variants in one family share a bottom bearing; anchoring to
        /// this height keeps the glyph from drifting as the symbol swaps.
        static let referenceIconHeight: CGFloat = 14
        static var systemWidth: CGFloat { iconSlot + gap + trackWidth }
        /// Each half of the swap — the outgoing content fading away, then the
        /// incoming one fading in — the menu bar indicator's HUD fade length.
        static let fadeDuration: CFTimeInterval = 0.2
        static let fillDuration: CFTimeInterval = 0.18
        /// Like the native OSD: gone this long after the last change.
        static let linger: TimeInterval = 1.5
    }

    /// True from a HUD event until it expires; `hudMorph` trails it.
    private var hudActive = false
    private var isInputSourceHUD = false
    private var hudInputSourceName = ""
    private var hudKind: SystemHUDKind = .volume
    private var hudMuted = false
    private var hudIcon: NSImage?
    private var hudValue: CGFloat = 0
    /// 0 draws the Space Indicator, 1 the HUD. Runs linearly in time; the
    /// drawing derives each fade and the slot's width from it, so a HUD event
    /// arriving mid-way back simply turns the transition around.
    private var hudMorph: CGFloat = 0
    private var hudMorphTimer: Timer?
    private var hudFillTimer: Timer?
    private var hudExpireTimer: Timer?
    private var hudWidthFrom: CGFloat?
    private var hudWidthTo: CGFloat?
    private var hudWidthProgress: CGFloat = 1
    private var hudWidthTimer: Timer?

    private func inputSourceHUDWidth(for name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attr = NSAttributedString(string: name, attributes: [.font: font])
        let textW = min(ceil(attr.size().width), 160)
        return HUDMetrics.iconSlot + HUDMetrics.gap + textW + 2
    }

    private var currentHUDTargetWidth: CGFloat {
        if isInputSourceHUD {
            return inputSourceHUDWidth(for: hudInputSourceName)
        } else {
            return HUDMetrics.systemWidth
        }
    }

    private var currentHUDWidth: CGFloat {
        if let from = hudWidthFrom, let to = hudWidthTo {
            return from + (to - from) * hudWidthProgress
        }
        return currentHUDTargetWidth
    }

    private func animateHUDWidth(to targetWidth: CGFloat) {
        let currentW = currentHUDWidth
        guard abs(currentW - targetWidth) > 0.5, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hudWidthTimer?.invalidate()
            hudWidthTimer = nil
            hudWidthFrom = nil
            hudWidthTo = nil
            hudWidthProgress = 1
            needsDisplay = true
            return
        }
        hudWidthTimer?.invalidate()
        hudWidthFrom = currentW
        hudWidthTo = targetWidth
        hudWidthProgress = 0

        let duration: CFTimeInterval = HUDMetrics.fillDuration
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: SpacePillAnimationPipeline.frameInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - began) / duration))
            self.hudWidthProgress = Easing.outQuart(raw)
            self.needsDisplay = true
            if raw >= 1 {
                t.invalidate()
                self.hudWidthTimer = nil
                self.hudWidthFrom = nil
                self.hudWidthTo = nil
                self.hudWidthProgress = 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudWidthTimer = timer
    }

    /// Show or update the volume/brightness HUD. The first event morphs the Space
    /// Indicator into it; later ones only animate the fill.
    func showSystemHUD(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?) {
        let v = max(0, min(1, value))
        let color = NSColor(white: 0.90, alpha: 1)
        let wasInputSource = isInputSourceHUD
        isInputSourceHUD = false
        hudKind = kind
        hudMuted = muted
        hudIcon = IndicatorRenderer.systemHUDIcon(kind: kind, value: v, muted: muted,
                                                  audioOutputKind: audioOutputKind,
                                                  deviceIcons: AppSettings.shared.systemHUDDeviceIcons,
                                                  pointSize: 12, color: color)
        if hudActive {
            if wasInputSource {
                animateHUDWidth(to: HUDMetrics.systemWidth)
            }
            animateHUDFill(to: v)
        } else {
            hudActive = true
            // The pill under the pointer is going away; hovering it again once
            // the indicator returns should count as a fresh hover.
            resetSpaceHoverState()
            hudFillTimer?.invalidate()
            hudFillTimer = nil
            hudWidthTimer?.invalidate()
            hudWidthTimer = nil
            hudWidthFrom = nil
            hudWidthTo = nil
            hudWidthProgress = 1
            hudValue = v
            animateHUDMorph(to: 1)
        }

        resetHUDExpire()
        needsDisplay = true
    }

    /// Show or update the input source (keyboard language) HUD in the Space Indicator.
    func showInputSourceHUD(name: String) {
        let color = NSColor(white: 0.90, alpha: 1)
        isInputSourceHUD = true
        hudInputSourceName = name
        hudIcon = IndicatorRenderer.inputSourceHUDIcon(pointSize: 12, color: color)
        let targetWidth = inputSourceHUDWidth(for: name)

        if hudActive {
            hudFillTimer?.invalidate()
            hudFillTimer = nil
            animateHUDWidth(to: targetWidth)
        } else {
            hudActive = true
            resetSpaceHoverState()
            hudFillTimer?.invalidate()
            hudFillTimer = nil
            hudWidthTimer?.invalidate()
            hudWidthTimer = nil
            hudWidthFrom = nil
            hudWidthTo = nil
            hudWidthProgress = 1
            animateHUDMorph(to: 1)
        }

        resetHUDExpire()
        needsDisplay = true
    }

    private func resetHUDExpire() {
        hudExpireTimer?.invalidate()
        let timer = Timer(timeInterval: HUDMetrics.linger, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hudExpireTimer = nil
            self.hudActive = false
            self.animateHUDMorph(to: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        hudExpireTimer = timer
    }

    private func animateHUDMorph(to target: CGFloat) {
        hudMorphTimer?.invalidate()
        hudMorphTimer = nil
        let start = hudMorph
        guard abs(target - start) > 0.001, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hudMorph = target
            if target == 0 {
                hudWidthTimer?.invalidate()
                hudWidthTimer = nil
                hudWidthFrom = nil
                hudWidthTo = nil
                hudWidthProgress = 1
                isInputSourceHUD = false
            }
            needsDisplay = true
            return
        }
        // A partial transition takes its share of the full length, so turning
        // around mid-way never speeds up or stalls.
        let duration = HUDMetrics.fadeDuration * 2 * CFTimeInterval(abs(target - start))
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: SpacePillAnimationPipeline.frameInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - began) / duration))
            self.hudMorph = start + (target - start) * raw
            self.needsDisplay = true
            if raw >= 1 {
                t.invalidate()
                self.hudMorphTimer = nil
                self.hudMorph = target
                if target == 0 {
                    self.hudWidthTimer?.invalidate()
                    self.hudWidthTimer = nil
                    self.hudWidthFrom = nil
                    self.hudWidthTo = nil
                    self.hudWidthProgress = 1
                    self.isInputSourceHUD = false
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudMorphTimer = timer
    }

    private func animateHUDFill(to target: CGFloat) {
        hudFillTimer?.invalidate()
        hudFillTimer = nil
        let start = hudValue
        guard abs(target - start) > 0.0001 else {
            hudValue = target
            needsDisplay = true
            return
        }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: SpacePillAnimationPipeline.frameInterval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1, CGFloat((CACurrentMediaTime() - began) / HUDMetrics.fillDuration))
            self.hudValue = start + (target - start) * Easing.outQuart(raw)
            self.needsDisplay = true
            if raw >= 1 {
                t.invalidate()
                self.hudFillTimer = nil
                self.hudValue = target
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudFillTimer = timer
    }

    /// The bar's leading slot: the Space Indicator, the HUD, or — mid-swap —
    /// the menu bar indicator's transition: the outgoing content fades away,
    /// the incoming one fades in, and the slot's width eases between the two
    /// across both halves so the app icons glide instead of jumping at the
    /// swap. Returns the slot's width.
    private func drawLeadingIndicator(total: Int, at startX: CGFloat) -> CGFloat {
        guard hudMorph > 0 else { return drawSpaceIndicator(total: total, at: startX) }
        let m = min(1, hudMorph)
        // The pills stay clickable only while a HUD isn't on its way in or up.
        let pillsWidth = drawSpaceIndicator(total: total, at: startX,
                                            alpha: Easing.inOutQuart(max(0, 1 - m * 2)), interactive: false)
        let hudW = currentHUDWidth
        let width = pillsWidth + (hudW - pillsWidth) * Easing.inOutQuart(m)
        drawHUD(at: startX, width: width, alpha: Easing.inOutQuart(max(0, m * 2 - 1)))
        return width
    }

    private func drawHUD(at startX: CGFloat, width: CGFloat, alpha: CGFloat) {
        guard alpha > 0, width > 0, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        // Clip to the slot, so the track is revealed as the slot opens rather
        // than drawn out past the app icons.
        NSBezierPath(rect: CGRect(x: startX, y: 0, width: width, height: bounds.height)).addClip()

        let m = HUDMetrics.self
        if let icon = hudIcon {
            // Flipped view: anchor the glyph's bottom edge where the menu bar
            // frame does, measured down from the top — or center it, for the
            // glyphs the menu bar frame centers too.
            let bottom = (bounds.height + m.referenceIconHeight) / 2
            let centered = !isInputSourceHUD && IndicatorRenderer.centersSystemHUDIcon(kind: hudKind)
            let rect = centered
                ? CGRect(x: startX + (m.iconSlot - icon.size.width) / 2, y: (bounds.height - icon.size.height) / 2,
                         width: icon.size.width, height: icon.size.height)
                : CGRect(x: startX + 1, y: bottom - icon.size.height,
                         width: icon.size.width, height: icon.size.height)
            icon.draw(in: rect,
                      from: .zero, operation: .sourceOver, fraction: alpha,
                      respectFlipped: true, hints: nil)
        }

        let base = NSColor(white: 0.90, alpha: 1)
        if isInputSourceHUD {
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let attr = NSAttributedString(string: hudInputSourceName, attributes: [
                .font: font,
                .foregroundColor: base.withAlphaComponent(alpha)
            ])
            let textX = startX + m.iconSlot + m.gap
            let maxTextW: CGFloat = 160
            let textW = min(ceil(attr.size().width), maxTextW)
            context.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: textX, y: 0, width: textW, height: bounds.height)).addClip()
            let textY = (bounds.height - attr.size().height) / 2
            attr.draw(at: NSPoint(x: textX, y: textY))
            context.restoreGraphicsState()
        } else {
            let track = CGRect(x: startX + m.iconSlot + m.gap, y: (bounds.height - m.trackHeight) / 2,
                               width: m.trackWidth, height: m.trackHeight)
            let radius = m.trackHeight / 2
            base.withAlphaComponent(0.22 * alpha).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            // Muted volume shows an empty track, as the menu bar HUD does.
            let fill = hudMuted && hudKind == .volume ? 0 : hudValue
            guard fill > 0 else { return }
            var fillRect = track
            fillRect.size.width = max(m.trackHeight, m.trackWidth * fill)
            base.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
        }
    }

    private static func outQuartEase(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 4)
    }

    private func makeWindowMenu(for window: TilingBarWindow) -> NSMenu {
        let menu = NSMenu(title: "Window Actions")
        menu.autoenablesItems = false

        let isAllSpaces = snapshot?.scope == .allSpaces
        let rawTitle = window.name.isEmpty
            ? (window.bundleID.components(separatedBy: ".").last ?? "Window")
            : window.name
        let title = isAllSpaces ? "\(rawTitle) — Desktop \(window.spaceNumber)" : rawTitle
        let headerItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon = window.icon {
            let itemIcon = icon.copy() as? NSImage ?? icon
            itemIcon.size = NSSize(width: 16, height: 16)
            headerItem.image = itemIcon
        }
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let isColumnTab = window.status == .leftTabbed || window.status == .rightTabbed
        let hasOtherTiledWindow = snapshot?.windows.contains {
            $0.windowID != window.windowID &&
                $0.spaceNumber == window.spaceNumber &&
                ($0.status == .leftTabbed || $0.status == .rightTabbed)
        } == true
        if isColumnTab && hasOtherTiledWindow {
            let columnTitle = window.status == .leftTabbed
                ? "Move to Right Column" : "Move to Left Column"
            let columnItem = NSMenuItem(title: columnTitle,
                                        action: #selector(setMasterAction(_:)),
                                        keyEquivalent: "")
            columnItem.target = self
            columnItem.tag = Int(window.windowID)
            columnItem.isEnabled = true
            menu.addItem(columnItem)
        }

        let floatingTitle = window.floatingIsAutomatic ? "Floating (Automatic)" : "Floating"
        let floatingItem = NSMenuItem(title: floatingTitle, action: #selector(setFloatingAction(_:)), keyEquivalent: "")
        floatingItem.target = self
        floatingItem.tag = Int(window.windowID)
        floatingItem.isEnabled = !window.floatingIsAutomatic
        floatingItem.state = window.status == .floating ? .on : .off
        menu.addItem(floatingItem)

        if let screen = NSScreen.screens.first(where: {
            $0.uuid?.caseInsensitiveCompare(displayUUID) == .orderedSame
        }) {
            let desktops = WindowPreviewCapture.managedSpaces(for: screen)
            menu.addItem(NSMenuItem.separator())
            let newDesktop = NSMenuItem(title: "Move to New Desktop",
                                        action: #selector(moveWindowToDesktopAction(_:)), keyEquivalent: "")
            newDesktop.target = self
            newDesktop.representedObject = NSNumber(value: window.windowID)
            newDesktop.isEnabled = true
            menu.addItem(newDesktop)
            for (index, desktop) in desktops.enumerated()
                where !desktop.isFullscreen && index + 1 != window.spaceNumber {
                let item = NSMenuItem(title: "Move to Desktop \(index + 1)",
                                      action: #selector(moveWindowToDesktopAction(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index + 1
                item.representedObject = NSNumber(value: window.windowID)
                item.isEnabled = true
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let retileItem = NSMenuItem(title: "Retile", action: #selector(retileAction(_:)), keyEquivalent: "")
        retileItem.target = self
        retileItem.isEnabled = true
        menu.addItem(retileItem)

        let isPaused = snapshot?.paused ?? false
        let pauseTitle = isPaused ? "Resume Tiling" : "Pause Tiling"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePauseAction(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = true
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let scopeTitle = isAllSpaces ? "Show Current Desktop Only" : "Show All Desktops"
        let scopeItem = NSMenuItem(title: scopeTitle, action: #selector(toggleScopeAction(_:)), keyEquivalent: "")
        scopeItem.target = self
        scopeItem.isEnabled = true
        menu.addItem(scopeItem)

        menu.addItem(NSMenuItem.separator())

        let app = NSRunningApplication(processIdentifier: window.pid)
        let appName = app?.localizedName
            ?? (window.name.isEmpty ? (window.bundleID.components(separatedBy: ".").last ?? "") : window.name)
        let quitTitle = appName.isEmpty ? "Quit App" : "Quit \(appName)"
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitAppAction(_:)), keyEquivalent: "")
        quitItem.target = self
        quitItem.tag = Int(window.pid)
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        let forceQuitTitle = appName.isEmpty ? "Force Quit App" : "Force Quit \(appName)"
        let forceQuitItem = NSMenuItem(title: forceQuitTitle, action: #selector(forceQuitAppAction(_:)), keyEquivalent: "")
        forceQuitItem.target = self
        forceQuitItem.tag = Int(window.pid)
        forceQuitItem.isAlternate = true
        forceQuitItem.keyEquivalentModifierMask = [.option]
        forceQuitItem.isEnabled = true
        menu.addItem(forceQuitItem)

        return menu
    }

    private func makeBarMenu() -> NSMenu {
        let menu = NSMenu(title: "Tiling Actions")
        menu.autoenablesItems = false

        let retileItem = NSMenuItem(title: "Retile", action: #selector(retileAction(_:)), keyEquivalent: "")
        retileItem.target = self
        retileItem.isEnabled = true
        menu.addItem(retileItem)

        let isPaused = snapshot?.paused ?? false
        let pauseTitle = isPaused ? "Resume Tiling" : "Pause Tiling"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePauseAction(_:)), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = true
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let isAllSpaces = snapshot?.scope == .allSpaces
        let scopeTitle = isAllSpaces ? "Show Current Desktop Only" : "Show All Desktops"
        let scopeItem = NSMenuItem(title: scopeTitle, action: #selector(toggleScopeAction(_:)), keyEquivalent: "")
        scopeItem.target = self
        scopeItem.isEnabled = true
        menu.addItem(scopeItem)

        return menu
    }

    @objc func toggleScopeAction(_ sender: NSMenuItem) {
        NSLog("MSG Tiling: toggleScopeAction")
        onToggleScope?()
    }

    @objc func setMasterAction(_ sender: NSMenuItem) {
        let winID = sender.tag > 0 ? CGWindowID(sender.tag) : nil
        NSLog("MSG Tiling: setMasterAction for winID=%u", winID ?? 0)
        onToggleMaster?(winID)
    }

    @objc func setFloatingAction(_ sender: NSMenuItem) {
        let winID = sender.tag > 0 ? CGWindowID(sender.tag) : nil
        NSLog("MSG Tiling: setFloatingAction for winID=%u", winID ?? 0)
        onToggleFloating?(winID)
    }

    @objc func moveWindowToDesktopAction(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber,
              let window = snapshot?.windows.first(where: { $0.windowID == number.uint32Value }) else { return }
        onMoveWindowToDesktop?(window.windowID, window.pid, sender.tag > 0 ? sender.tag : nil)
    }

    @objc func retileAction(_ sender: NSMenuItem) {
        NSLog("MSG Tiling: retileAction")
        onRetile?()
    }

    @objc func togglePauseAction(_ sender: NSMenuItem) {
        NSLog("MSG Tiling: togglePauseAction")
        onTogglePause?()
    }

    @objc func quitAppAction(_ sender: NSMenuItem) {
        let pid = pid_t(sender.tag)
        guard pid > 0 else { return }
        NSLog("MSG Tiling: quitAppAction for pid=%d", pid)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        }
    }

    @objc func forceQuitAppAction(_ sender: NSMenuItem) {
        let pid = pid_t(sender.tag)
        guard pid > 0 else { return }
        NSLog("MSG Tiling: forceQuitAppAction for pid=%d", pid)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.forceTerminate()
        }
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return menuItem.isEnabled
    }

    // MARK: Duo Battery & Wi-Fi

    /// Geometry of the iPhone Duo-style indicator. Angles are visual, in
    /// degrees clockwise from 12 o'clock.
    private enum DuoIndicator {
        static let diameter: CGFloat = 18
        // Proportions measured off the iPhone Duo reference, as shares of the
        // ring's diameter, so resizing the ring keeps its look.
        static var lineWidth: CGFloat { diameter * 0.067 }
        /// The glyph's width inside the ring.
        static var iconWidth: CGFloat { diameter * 0.42 }
        /// The glyph sits above the ring's centre, into the closed top.
        static var iconLift: CGFloat { diameter * 0.09 }
        /// The battery arc opens at the bottom: it starts just below 8 o'clock
        /// and runs clockwise over the top to just below 4 o'clock.
        static let arcStart: CGFloat = 247
        static let arcSweep: CGFloat = 226
        static let base = NSColor(white: 0.90, alpha: 1)
    }

    /// Draws the iPhone Duo-style merged indicator: a battery gauge arc open
    /// at the bottom, and the Wi-Fi — or
    /// Personal Hotspot — glyph inside. Returns the width consumed.
    private func drawDuoBatteryWifi(at startX: CGFloat) -> CGFloat {
        guard let context = NSGraphicsContext.current?.cgContext else { return 0 }
        let duo = DuoIndicator.self
        let network = NetworkStatusMonitor.shared
        if !network.isRunning { network.start() }
        let wifi = network.status
        let stats = HardwareMonitor.shared.stats

        let radius = duo.diameter / 2 - duo.lineWidth / 2
        let center = CGPoint(x: startX + duo.diameter / 2, y: bounds.height / 2)

        let hitRect = CGRect(x: startX - 2, y: 0, width: duo.diameter + 4, height: bounds.height)
        actions.append((hitRect, { [weak self] in self?.toggleWiFiMenu(icon: hitRect) }))

        // This view is flipped (y grows downward), so a CG angle increases
        // clockwise on screen, and 12 o'clock is -90°.
        func cgAngle(_ degrees: CGFloat) -> CGFloat { (degrees - 90) * .pi / 180 }

        context.saveGState()
        context.setLineWidth(duo.lineWidth)
        context.setLineCap(.round)

        // Track: the whole gauge, dim.
        context.setStrokeColor(duo.base.withAlphaComponent(0.18).cgColor)
        context.addArc(center: center, radius: radius, startAngle: cgAngle(duo.arcStart),
                       endAngle: cgAngle(duo.arcStart + duo.arcSweep), clockwise: false)
        context.strokePath()

        // Battery: from the start of the gauge, clockwise, by charge.
        let charge = min(1, max(0, CGFloat(stats.batteryPercent ?? 0) / 100))
        if charge > 0 {
            let color: NSColor
            if stats.isCharging == true {
                color = .systemGreen
            } else if charge <= 0.10 {
                color = .systemRed
            } else if charge <= 0.20 {
                color = .systemOrange
            } else {
                color = duo.base
            }
            context.setStrokeColor(color.cgColor)
            context.addArc(center: center, radius: radius, startAngle: cgAngle(duo.arcStart),
                           endAngle: cgAngle(duo.arcStart + duo.arcSweep * charge), clockwise: false)
            context.strokePath()
        }

        context.restoreGState()

        let symbolName = !wifi.powerOn ? "wifi.slash" : (wifi.hotspot ? "personalhotspot" : "wifi")
        let config = NSImage.SymbolConfiguration(pointSize: duo.diameter, weight: .semibold)
            .applying(.init(paletteColors: [duo.base.withAlphaComponent(wifi.connected || !wifi.powerOn ? 1 : 0.5)]))
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config), symbol.size.width > 0 {
            // Scaled to a width, not a point size: glyphs differ in width, and
            // the reference fixes the glyph's share of the ring.
            let scale = duo.iconWidth / symbol.size.width
            let size = CGSize(width: duo.iconWidth, height: symbol.size.height * scale)
            let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2 - duo.iconLift,
                              width: size.width, height: size.height)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
        }
        return duo.diameter
    }

    /// MSG's own Wi-Fi menu, hanging from the Duo indicator.
    private func toggleWiFiMenu(icon: CGRect) {
        guard #available(macOS 14.0, *), let barWindow = window else { return }
        let onScreen = barWindow.convertToScreen(convert(icon, to: nil))
        WiFiMenuController.shared.toggle(below: onScreen, bar: barWindow.frame)
    }
}
