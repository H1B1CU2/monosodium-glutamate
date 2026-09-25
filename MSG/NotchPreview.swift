import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - Notch Geometry

@available(macOS 14.0, *)
enum NotchGeometry {

    /// Determines the notch rect for the given screen in Cocoa coordinates (bottom-left origin).
    /// If the display features a hardware notch, computes its exact bounds between the auxiliary areas.
    /// Otherwise, falls back to a top-center 185x32 pt area at the top of the display.
    static func notchRect(for screen: NSScreen) -> CGRect {
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            return CGRect(
                x: left.maxX,
                y: left.minY,
                width: right.minX - left.maxX,
                height: left.height
            )
        }
        let width: CGFloat = 185
        let height: CGFloat = 32
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The hit area to detect pointer entering the notch.
    static func triggerRect(for screen: NSScreen) -> CGRect {
        let notch = notchRect(for: screen)
        return CGRect(
            x: notch.minX - 14,
            y: notch.minY - 4,
            width: notch.width + 28,
            height: (screen.frame.maxY - notch.minY) + 6
        )
    }
}

// MARK: - Mirrored Dock Item

@available(macOS 14.0, *)
struct NotchDockItem: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL?
    let icon: NSImage
    let isRunning: Bool
    let isSeparator: Bool
    let isTrash: Bool
    let element: AXUIElement?

    static func == (lhs: NotchDockItem, rhs: NotchDockItem) -> Bool {
        lhs.id == rhs.id && lhs.isRunning == rhs.isRunning
    }
}

// MARK: - Mirrored Dock Reader

@available(macOS 14.0, *)
enum NotchDockReader {

    /// Queries the live macOS Dock via Accessibility to read the exact ordered list of apps,
    /// separators, running states, and Trash.
    static func fetchDockItems() -> [NotchDockItem] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dockApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }

        var results: [NotchDockItem] = []
        let runningApps = NSWorkspace.shared.runningApplications

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == (kAXListRole as String) else { continue }
            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else { continue }

            for (idx, item) in items.enumerated() {
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String ?? ""
                if subrole == "AXSeparatorDockItem" {
                    results.append(NotchDockItem(
                        id: "sep-\(idx)",
                        title: "",
                        url: nil,
                        icon: NSImage(),
                        isRunning: false,
                        isSeparator: true,
                        isTrash: false,
                        element: item
                    ))
                    continue
                }

                var titleRef: CFTypeRef?
                var urlRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef)
                let title = titleRef as? String ?? ""
                let isTrash = subrole == "AXTrashDockItem" || title.caseInsensitiveCompare("Trash") == .orderedSame

                var fileURL: URL?
                if let u = urlRef as? URL {
                    fileURL = u
                } else if let s = urlRef as? String, !s.isEmpty {
                    fileURL = URL(fileURLWithPath: s)
                }

                var isRunning = false
                if let fileURL {
                    if let bundle = Bundle(url: fileURL), let bid = bundle.bundleIdentifier {
                        isRunning = runningApps.contains { $0.bundleIdentifier == bid }
                    } else {
                        let name = fileURL.deletingPathExtension().lastPathComponent
                        isRunning = runningApps.contains { $0.localizedName == name }
                    }
                } else if !title.isEmpty {
                    isRunning = runningApps.contains { $0.localizedName == title }
                }

                let icon: NSImage
                if isTrash {
                    icon = NSImage(named: NSImage.trashEmptyName)
                        ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Trash.app")
                } else if let fileURL {
                    icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                } else {
                    icon = NSImage(systemSymbolName: "app", accessibilityDescription: title) ?? NSImage()
                }

                results.append(NotchDockItem(
                    id: fileURL?.path ?? "\(title)-\(idx)",
                    title: title,
                    url: fileURL,
                    icon: icon,
                    isRunning: isRunning,
                    isSeparator: false,
                    isTrash: isTrash,
                    element: item
                ))
            }
        }
        return results
    }

    static func launchDockItem(_ item: NotchDockItem) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if let el = item.element {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        } else if item.isTrash {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Trash.app"))
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - NotchHoverController

@available(macOS 14.0, *)
final class NotchHoverController {

    private let settings: AppSettings

    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?

    private var hoverTimer: Timer?
    private var dismissTimer: Timer?

    private var isPanelVisible = false
    private var isCapturing = false
    private var captureToken = 0
    private var lastMoveStamp: CFAbsoluteTime = 0
    private var activeScreen: NSScreen?

    private var previewPanel: NotchPreviewPanel?
    private var dockPanel: NotchDockPanel?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() {
        guard globalMoveMonitor == nil else { return }

        let moveHandler: (NSEvent?) -> Void = { [weak self] _ in self?.handleMouseMoved() }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { moveHandler($0) }
        localMoveMonitor  = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { e in moveHandler(e); return e }

        let clickHandler: (NSEvent) -> Void = { [weak self] e in self?.handleMouseClick(e) }
        clickMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { clickHandler($0) }
        clickMonitorLocal  = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { e in clickHandler(e); return e }
    }

    func stop() {
        if let m = globalMoveMonitor { NSEvent.removeMonitor(m); globalMoveMonitor = nil }
        if let m = localMoveMonitor  { NSEvent.removeMonitor(m); localMoveMonitor = nil }
        if let m = clickMonitorGlobal { NSEvent.removeMonitor(m); clickMonitorGlobal = nil }
        if let m = clickMonitorLocal  { NSEvent.removeMonitor(m); clickMonitorLocal = nil }

        hoverTimer?.invalidate(); hoverTimer = nil
        dismissTimer?.invalidate(); dismissTimer = nil
        isPanelVisible = false
        isCapturing = false
        captureToken &+= 1
        previewPanel?.orderOut()
        dockPanel?.orderOut()
    }

    // MARK: Mouse Handling

    private func handleMouseMoved() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMoveStamp >= 0.025 else { return }
        lastMoveStamp = now

        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLoc) } ?? NSScreen.main
        guard let screen else { return }

        let triggerRect = NotchGeometry.triggerRect(for: screen)
        let isOverNotch = triggerRect.contains(mouseLoc)

        if isPanelVisible || isCapturing {
            let activeRegion = activeHitRegion(screen: screen)
            if activeRegion.contains(mouseLoc) {
                dismissTimer?.invalidate()
                dismissTimer = nil
            } else {
                let distance = distanceToRect(mouseLoc, rect: activeRegion)
                if distance > 60 {
                    dismiss()
                } else if dismissTimer == nil {
                    startDismissTimer()
                }
            }
            return
        }

        if isOverNotch {
            if hoverTimer == nil {
                activeScreen = screen
                startHoverTimer(delay: settings.notchPreviewHoverDelay)
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }

    private func handleMouseClick(_ event: NSEvent) {
        guard isPanelVisible else { return }
        let mouseLoc = NSEvent.mouseLocation
        let inPreview = previewPanel?.frame.contains(mouseLoc) ?? false
        let inDock = dockPanel?.frame.contains(mouseLoc) ?? false
        if !inPreview && !inDock {
            dismiss()
        }
    }

    // MARK: Region Math

    /// Unifies the notch trigger area, the preview panel, the mirrored app dock, and the bridge between them.
    private func activeHitRegion(screen: NSScreen) -> CGRect {
        let notchTrigger = NotchGeometry.triggerRect(for: screen)
        var minX = notchTrigger.minX
        var maxX = notchTrigger.maxX
        var minY = notchTrigger.minY
        var maxY = notchTrigger.maxY

        if let panel = previewPanel, panel.isVisible {
            let f = panel.frame.insetBy(dx: -14, dy: -8)
            minX = min(minX, f.minX)
            maxX = max(maxX, f.maxX)
            minY = min(minY, f.minY)
            maxY = max(maxY, f.maxY)
        }

        if let dock = dockPanel, dock.isVisible {
            let f = dock.frame.insetBy(dx: -14, dy: -8)
            minX = min(minX, f.minX)
            maxX = max(maxX, f.maxX)
            minY = min(minY, f.minY)
            maxY = max(maxY, f.maxY)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func distanceToRect(_ p: NSPoint, rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return hypot(dx, dy)
    }

    // MARK: Timers

    private func startHoverTimer(delay: TimeInterval) {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.05, delay), repeats: false) { [weak self] _ in
            self?.hoverTimer = nil
            self?.triggerCaptureAndPresent()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func startDismissTimer() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: 0.16, repeats: false) { [weak self] _ in
            self?.dismissTimer = nil
            guard let self = self, self.isPanelVisible else { return }
            let mouseLoc = NSEvent.mouseLocation
            let screen = self.activeScreen ?? NSScreen.main ?? NSScreen.screens[0]
            let region = self.activeHitRegion(screen: screen)
            if !region.contains(mouseLoc) {
                self.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    // MARK: Presentation & Dismissal

    private func triggerCaptureAndPresent() {
        guard !isPanelVisible, !isCapturing else { return }
        guard let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        isCapturing = true
        captureToken &+= 1
        let token = captureToken

        let includeOtherSpaces = settings.notchPreviewShowOtherSpaces

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.captureToken == token { self.isCapturing = false } }

            // Open on metadata and last-known thumbnails, then fill in live
            // shots. Waiting for every capture first is what made the panel
            // lag behind the hover. The window scan and the Dock read are both
            // AX round trips, so they run together and off the main thread.
            async let dockTask = Task.detached(priority: .userInitiated) {
                NotchDockReader.fetchDockItems()
            }.value
            let scan = await Task.detached(priority: .userInitiated) {
                WindowPreviewCapture.scanScreenWindows(screen: screen, includeOtherSpaces: includeOtherSpaces)
            }.value
            let dockItems = await dockTask
            guard self.captureToken == token else { return }
            let windows = scan.items

            if windows.isEmpty && dockItems.isEmpty {
                return
            }

            if self.previewPanel == nil {
                self.previewPanel = NotchPreviewPanel()
            }
            if self.dockPanel == nil {
                self.dockPanel = NotchDockPanel()
            }

            self.isPanelVisible = true
            let notchRect = NotchGeometry.notchRect(for: screen)

            // Present window preview panel
            let previewTargetFrame: NSRect?
            if !windows.isEmpty {
                previewTargetFrame = self.previewPanel?.present(
                    windows: windows,
                    thumbHeight: self.settings.notchPreviewThumbHeight,
                    screen: screen,
                    notchRect: notchRect,
                    onSelect: { [weak self] item in
                        self?.selectWindow(item)
                    },
                    onClose: { [weak self] item in
                        self?.closeWindow(item)
                    },
                    onDismiss: { [weak self] in
                        self?.dismiss()
                    },
                    onRelayout: { [weak self] in
                        self?.relayoutDockPanel(screen: screen, notchRect: notchRect)
                    }
                )
            } else {
                self.previewPanel?.orderOut()
                previewTargetFrame = nil
            }

            // Present mirrored dock panel directly underneath
            if self.settings.notchShowDock && !dockItems.isEmpty {
                self.dockPanel?.present(
                    items: dockItems,
                    screen: screen,
                    notchRect: notchRect,
                    previewFrame: previewTargetFrame,
                    onSelect: { [weak self] item in
                        self?.selectDockItem(item)
                    }
                )
            } else {
                self.dockPanel?.orderOut()
            }
            self.isCapturing = false

            guard !windows.isEmpty else { return }
            let live = await WindowPreviewCapture.liveThumbnails(for: scan)
            guard self.captureToken == token, self.isPanelVisible else { return }
            self.previewPanel?.updateImages(live, screen: screen, notchRect: notchRect)
            self.relayoutDockPanel(screen: screen, notchRect: notchRect)
        }
    }

    private func relayoutDockPanel(screen: NSScreen, notchRect: CGRect) {
        guard let dockPanel, dockPanel.isVisible else { return }
        let previewFrame = (previewPanel?.isVisible == true) ? previewPanel?.targetFrame : nil
        dockPanel.updatePosition(screen: screen, notchRect: notchRect, previewFrame: previewFrame)
    }

    private func dismiss() {
        hoverTimer?.invalidate(); hoverTimer = nil
        dismissTimer?.invalidate(); dismissTimer = nil
        isPanelVisible = false
        isCapturing = false
        captureToken &+= 1
        previewPanel?.dismiss()
        dockPanel?.dismiss()
    }

    private func selectWindow(_ item: NotchWindowItem) {
        dismiss()
        Task {
            await WindowPreviewCapture.raiseWindow(pid: item.pid, windowID: item.id, fallbackBounds: item.bounds)
        }
    }

    private func closeWindow(_ item: NotchWindowItem) {
        Task {
            await WindowPreviewCapture.closeWindow(pid: item.pid, windowID: item.id)
        }
    }

    private func selectDockItem(_ item: NotchDockItem) {
        dismiss()
        NotchDockReader.launchDockItem(item)
    }
}

// MARK: - NotchPreviewPanel

@available(macOS 14.0, *)
final class NotchPreviewPanel {

    private var panel: NSPanel?
    private var hosting: NSHostingController<NotchPreviewView>?
    private let model = NotchPreviewModel()

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }
    private(set) var targetFrame: NSRect = .zero

    @discardableResult
    func present(windows: [NotchWindowItem],
                 thumbHeight: CGFloat,
                 screen: NSScreen,
                 notchRect: CGRect,
                 onSelect: @escaping (NotchWindowItem) -> Void,
                 onClose: @escaping (NotchWindowItem) -> Void,
                 onDismiss: @escaping () -> Void = {},
                 onRelayout: @escaping () -> Void) -> NSRect {

        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return .zero }

        model.onSelect = onSelect
        model.onDismiss = onDismiss
        model.sourcePanelFrame = { [weak self] in self?.panel?.frame ?? .zero }
        model.onClose = { [weak self] item in
            onClose(item)
            guard let self else { return }
            withAnimation(.easeInOut(duration: 0.20)) {
                self.model.items.removeAll { $0.id == item.id }
            }
            if self.model.items.isEmpty {
                self.dismiss()
            } else {
                self.updateFrame(for: screen, notchRect: notchRect)
            }
            onRelayout()
        }

        let wasVisible = panel.isVisible
        let apply = {
            self.model.items = Self.grouped(windows)
            self.model.thumbHeight = thumbHeight
            self.model.maxContentWidth = max(400, screen.visibleFrame.width - 64)
        }

        if wasVisible {
            withAnimation(.easeInOut(duration: 0.20)) { apply() }
        } else {
            apply()
        }

        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let targetFrame = NSRect(origin: position(for: size, screen: screen, notchRect: notchRect), size: size)
        self.targetFrame = targetFrame

        if wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            }
            panel.orderFrontRegardless()
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

            let initialOrigin = NSPoint(x: targetFrame.origin.x, y: targetFrame.origin.y + 6)
            panel.setFrame(NSRect(origin: initialOrigin, size: targetFrame.size), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        return targetFrame
    }

    /// This Desktop before other Desktops, shown apps before hidden ones — and
    /// within that, each app's windows side by side, apps in the order their
    /// first window arrived, the way the ⌘Tab switcher lists them.
    private static func grouped(_ windows: [NotchWindowItem]) -> [NotchWindowItem] {
        func group(_ w: NotchWindowItem) -> String { "\(w.isOtherSpace)-\(w.pid)" }
        var firstIndex: [String: Int] = [:]
        for (i, w) in windows.enumerated() where firstIndex[group(w)] == nil {
            firstIndex[group(w)] = i
        }
        return windows.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.isOtherSpace != y.isOtherSpace { return !x.isOtherSpace }
            if x.isHidden != y.isHidden { return !x.isHidden }
            let (gx, gy) = (firstIndex[group(x)] ?? a.offset, firstIndex[group(y)] ?? b.offset)
            return gx != gy ? gx < gy : a.offset < b.offset
        }.map(\.element)
    }

    /// Swaps in live thumbnails for an already-open panel. Cards are sized by
    /// window bounds, so this normally leaves the frame where it is.
    func updateImages(_ images: [CGWindowID: NSImage], screen: NSScreen, notchRect: CGRect) {
        guard isVisible, !images.isEmpty else { return }
        var items = model.items
        for i in items.indices {
            if let img = images[items[i].id] { items[i].image = img }
        }
        model.items = items
        updateFrame(for: screen, notchRect: notchRect)
    }

    private func updateFrame(for screen: NSScreen, notchRect: CGRect) {
        guard let panel, let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let targetFrame = NSRect(origin: position(for: size, screen: screen, notchRect: notchRect), size: size)
        self.targetFrame = targetFrame

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    func orderOut() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let h = NSHostingController(rootView: NotchPreviewView(model: model))
        h.view.wantsLayer = true
        h.sizingOptions = [.intrinsicContentSize]
        hosting = h

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = h.view
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
    }

    private func position(for size: NSSize, screen: NSScreen, notchRect: CGRect) -> NSPoint {
        let gap: CGFloat = 4
        let x = notchRect.midX - size.width / 2
        let y = notchRect.minY - size.height - gap
        let clampedX = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
        let clampedY = max(screen.visibleFrame.minY + 12, y)
        return NSPoint(x: clampedX, y: clampedY)
    }
}

// MARK: - NotchDockPanel (Mirrored App Dock)

@available(macOS 14.0, *)
final class NotchDockPanel {

    private var panel: NSPanel?
    private var hosting: NSHostingController<NotchDockView>?
    private let model = NotchDockModel()

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    func present(items: [NotchDockItem],
                 screen: NSScreen,
                 notchRect: CGRect,
                 previewFrame: CGRect?,
                 onSelect: @escaping (NotchDockItem) -> Void) {

        if panel == nil { buildPanel() }
        guard let panel, let hosting else { return }

        model.onSelect = onSelect
        let wasVisible = panel.isVisible

        if wasVisible {
            withAnimation(.easeInOut(duration: 0.20)) { self.model.items = items }
        } else {
            self.model.items = items
        }

        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let targetFrame = NSRect(origin: position(for: size, screen: screen, notchRect: notchRect, previewFrame: previewFrame),
                                 size: size)

        if wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
            }
            panel.orderFrontRegardless()
        } else {
            let initialOrigin = NSPoint(x: targetFrame.origin.x, y: targetFrame.origin.y + 6)
            panel.setFrame(NSRect(origin: initialOrigin, size: targetFrame.size), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }
    }

    func updatePosition(screen: NSScreen, notchRect: CGRect, previewFrame: CGRect?) {
        guard let panel, let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
        let targetFrame = NSRect(origin: position(for: size, screen: screen, notchRect: notchRect, previewFrame: previewFrame),
                                 size: size)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    func orderOut() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let h = NSHostingController(rootView: NotchDockView(model: model))
        h.view.wantsLayer = true
        h.sizingOptions = [.intrinsicContentSize]
        hosting = h

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.contentView = h.view
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p
    }

    private func position(for size: NSSize, screen: NSScreen, notchRect: CGRect, previewFrame: CGRect?) -> NSPoint {
        let gap: CGFloat = 8
        let x: CGFloat
        if let pf = previewFrame {
            x = pf.midX - size.width / 2
        } else {
            x = notchRect.midX - size.width / 2
        }
        let y: CGFloat
        if let pf = previewFrame {
            y = pf.minY - size.height - gap
        } else {
            y = notchRect.minY - size.height - 4
        }
        let clampedX = min(max(x, screen.visibleFrame.minX + 12), screen.visibleFrame.maxX - size.width - 12)
        let clampedY = max(screen.visibleFrame.minY + 12, y)
        return NSPoint(x: clampedX, y: clampedY)
    }
}

// MARK: - NotchDockModel

@available(macOS 14.0, *)
private final class NotchDockModel: ObservableObject {
    @Published var items: [NotchDockItem] = []
    var onSelect: (NotchDockItem) -> Void = { _ in }
}

// MARK: - DockIconCenterPreferenceKey

private struct DockIconCenterPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - NotchDockView

@available(macOS 14.0, *)
private struct NotchDockView: View {
    @ObservedObject var model: NotchDockModel
    @State private var mouseLocation: CGPoint? = nil
    @State private var iconCenters: [String: CGFloat] = [:]

    private let baseIconSize: CGFloat = 48
    private let maxScale: CGFloat = 1.38
    private let influenceRadius: CGFloat = 135
    private let maxLift: CGFloat = 8

    private func magnification(for itemId: String) -> (scale: CGFloat, lift: CGFloat, zIndex: Double) {
        guard let mouseX = mouseLocation?.x,
              let center = iconCenters[itemId] else {
            return (1.0, 0.0, 0.0)
        }
        let distance = abs(mouseX - center)
        if distance < influenceRadius {
            let progress = distance / influenceRadius
            let factor = 0.5 * (1.0 + cos(.pi * progress))
            let scale = 1.0 + (maxScale - 1.0) * factor
            let lift = maxLift * factor
            return (scale, lift, Double(factor * 10))
        }
        return (1.0, 0.0, 0.0)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(model.items) { item in
                if item.isSeparator {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 32)
                        .padding(.horizontal, 4)
                } else {
                    let mag = magnification(for: item.id)
                    NotchDockIcon(
                        item: item,
                        baseSize: baseIconSize,
                        scale: mag.scale,
                        lift: mag.lift,
                        onSelect: { model.onSelect(item) }
                    )
                    .zIndex(mag.zIndex)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: DockIconCenterPreferenceKey.self,
                                value: [item.id: geo.frame(in: .named("NotchDockContainer")).midX]
                            )
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .coordinateSpace(name: "NotchDockContainer")
        .onPreferenceChange(DockIconCenterPreferenceKey.self) { centers in
            self.iconCenters = centers
        }
        .onContinuousHover(coordinateSpace: .named("NotchDockContainer")) { phase in
            switch phase {
            case .active(let location):
                withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.82)) {
                    mouseLocation = location
                }
            case .ended:
                withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                    mouseLocation = nil
                }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

// MARK: - NotchDockIcon

@available(macOS 14.0, *)
private struct NotchDockIcon: View {
    let item: NotchDockItem
    let baseSize: CGFloat
    let scale: CGFloat
    let lift: CGFloat
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: baseSize, height: baseSize)
                    .scaleEffect(scale)
                    .offset(y: -lift)
                    .shadow(
                        color: .black.opacity(scale > 1.05 ? 0.38 : 0.15),
                        radius: scale > 1.05 ? 8 : 2,
                        y: scale > 1.05 ? 4 : 1
                    )

                // Running indicator dot
                Circle()
                    .fill(item.isRunning ? Color.white.opacity(0.85) : Color.clear)
                    .frame(width: 4.5, height: 4.5)
            }
            .frame(width: baseSize + 6, height: baseSize + 12)
        }
        .buttonStyle(.plain)
        .help(item.title)
    }
}

// MARK: - NotchPreviewModel

@available(macOS 14.0, *)
private final class NotchPreviewModel: ObservableObject {
    @Published var items: [NotchWindowItem] = []
    @Published var thumbHeight: CGFloat = 140
    @Published var maxContentWidth: CGFloat = 1000
    /// The card under the pointer; its app's name lights up over the group.
    @Published var hoveredID: CGWindowID?
    var onSelect: (NotchWindowItem) -> Void = { _ in }
    var onClose: (NotchWindowItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var sourcePanelFrame: () -> CGRect = { .zero }
}

// MARK: - NotchPreviewView

@available(macOS 14.0, *)
private struct NotchPreviewView: View {
    @ObservedObject var model: NotchPreviewModel

    private var maxThumbWidth: CGFloat { model.thumbHeight * 2.6 }
    /// Softens the ScrollView's rectangular clipping edge when the row is
    /// wider than the display. Keep this narrow so it reads as overflow rather
    /// than dimming a meaningful part of the first and last cards.
    private let overflowFadeWidth: CGFloat = 18

    private func cardWidth(for item: NotchWindowItem) -> CGFloat {
        min(maxThumbWidth, max(80, model.thumbHeight * item.previewAspect))
    }

    private func cardOuterWidth(for item: NotchWindowItem) -> CGFloat {
        cardWidth(for: item) + 12
    }

    private var hasSpaceDivider: Bool {
        guard let idx = model.items.firstIndex(where: \.isOtherSpace) else { return false }
        return idx > 0
    }

    /// The first card of each app's run carries the app's name, as in the ⌘Tab
    /// switcher. The "Other" divider starts fresh runs.
    private func startsRun(_ index: Int) -> Bool {
        let items = model.items
        return index == 0 || items[index].pid != items[index - 1].pid
            || items[index].isOtherSpace != items[index - 1].isOtherSpace
    }

    /// Space before the card at `index` (> 0). The divider separates the
    /// Desktops by itself, so it sits at the tighter gap.
    private func gap(before index: Int) -> CGFloat {
        if hasSpaceDivider, index == model.items.firstIndex(where: \.isOtherSpace) {
            return WindowGroupSpacing.sameApp
        }
        return startsRun(index) ? WindowGroupSpacing.betweenApps : WindowGroupSpacing.sameApp
    }

    private var hoveredPID: pid_t? {
        model.hoveredID.flatMap { id in model.items.first { $0.id == id }?.pid }
    }

    private var naturalRowWidth: CGFloat {
        let cards = model.items.reduce(0) { $0 + cardOuterWidth(for: $1) }
        let gaps = model.items.indices.dropFirst().reduce(0) { $0 + gap(before: $1) }
        let dividerExtra: CGFloat = hasSpaceDivider ? 28 : 0
        return cards + gaps + dividerExtra + 16
    }

    /// Unified caption height across all cards in the row, ensuring pixel-perfect baseline alignment.
    private var maxCaptionHeight: CGFloat {
        var hasMultiline = false
        var hasAnyCaption = false
        for item in model.items {
            if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasAnyCaption = true
                let w = cardWidth(for: item) + 12
                let font = NSFont.systemFont(ofSize: 10)
                let attr = NSAttributedString(string: title, attributes: [.font: font])
                let rect = attr.boundingRect(
                    with: CGSize(width: w, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                if rect.height > 15 {
                    hasMultiline = true
                    break
                }
            }
        }
        if hasMultiline {
            return 28
        } else if hasAnyCaption {
            return 14
        } else {
            return 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if naturalRowWidth > model.maxContentWidth {
                ScrollView(.horizontal, showsIndicators: false) {
                    cardsStack
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                .frame(width: model.maxContentWidth)
                .mask(horizontalOverflowMask)
            } else {
                cardsStack
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// Fade the card row itself, not the panel, so the material background and
    /// rounded outline stay solid while clipped thumbnails taper away.
    private var horizontalOverflowMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: overflowFadeWidth)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: overflowFadeWidth)
        }
    }

    @ViewBuilder private var cardsStack: some View {
        let firstOtherIdx = model.items.firstIndex(where: \.isOtherSpace)
        let hoveredPID = hoveredPID
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Spacer().frame(width: gap(before: index))
                }
                if hasSpaceDivider && index == firstOtherIdx {
                    spaceDivider
                    Spacer().frame(width: WindowGroupSpacing.sameApp)
                }
                NotchWindowCard(
                    item: item,
                    height: model.thumbHeight,
                    maxWidth: maxThumbWidth,
                    captionHeight: maxCaptionHeight,
                    showsAppLabel: startsRun(index),
                    appActive: hoveredPID == item.pid,
                    sourcePanelFrame: model.sourcePanelFrame,
                    onDismissPanel: model.onDismiss,
                    onSelect: { model.onSelect(item) },
                    onClose: { model.onClose(item) },
                    onHoverChanged: { hovering in
                        if hovering {
                            model.hoveredID = item.id
                        } else if model.hoveredID == item.id {
                            model.hoveredID = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    @ViewBuilder private var spaceDivider: some View {
        VStack(spacing: 8) {
            Text("Other")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .frame(height: 22)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: model.thumbHeight + 12)
        }
        .padding(.horizontal, 4)
        .transition(.opacity)
    }
}

// MARK: - NotchWindowCard

@available(macOS 14.0, *)
private struct NotchWindowCard: View {
    let item: NotchWindowItem
    let height: CGFloat
    let maxWidth: CGFloat
    let captionHeight: CGFloat
    /// Only the first card of an app's run names the app; the rest keep the
    /// row empty so every thumbnail stays on one line.
    let showsAppLabel: Bool
    /// The pointer is on one of this app's cards.
    let appActive: Bool
    let sourcePanelFrame: () -> CGRect
    let onDismissPanel: () -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false

    private var aspect: CGFloat { item.previewAspect }

    private var width: CGFloat { min(maxWidth, max(80, height * aspect)) }

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            // App identity row - leading like cmd+tab
            HStack(spacing: 6) {
                if showsAppLabel {
                    if let icon = item.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .scaleEffect(appActive ? 1.08 : 1.0)
                            .shadow(color: .black.opacity(appActive ? 0.35 : 0.0), radius: appActive ? 3 : 0, y: appActive ? 1 : 0)
                    }
                    Text(item.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(appActive ? .primary : .secondary)
                        .opacity(appActive ? 1.0 : 0.78)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .animation(.easeOut(duration: 0.16), value: appActive)
            .frame(width: width + 12, height: 22, alignment: .leading)
            .padding(.leading, 2)

            // Thumbnail image container - framed & aligned
            ZStack(alignment: .top) {
                Image(nsImage: PreviewHiddenStyle.image(item.image, hidden: item.isHidden))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(isHovering ? 0.12 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                isHovering ? Color.accentColor : Color.white.opacity(0.12),
                                lineWidth: isHovering ? 2 : 1
                            )
                    )

                HStack(alignment: .center) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .trailing) {
                        if isHovering {
                            PreviewCloseButton(
                                action: onClose,
                                helpText: "Close window",
                                accessibilityText: "Close \(item.title ?? item.appName) window"
                            )
                            .transition(.opacity)
                        } else if item.isHidden {
                            PreviewHiddenBadge()
                                .transition(.opacity)
                        }
                    }
                }
                .padding(6)
            }
            .shadow(
                color: .black.opacity(isHovering ? 0.34 : 0.0),
                radius: isHovering ? 12 : 0,
                y: isHovering ? 5 : 0
            )
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .offset(y: isHovering ? -3 : 0)

            // Window Title - centered and aligned with reserved caption height
            if let title = item.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.tail)
                    .frame(width: width + 12, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: captionHeight > 0 ? captionHeight : nil, alignment: .top)
            } else if captionHeight > 0 {
                Color.clear
                    .frame(width: width + 12, height: captionHeight)
            }
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.26, dampingFraction: 0.74), value: isHovering)
        .overlay(
            CardInteractionCatcher(
                onClick: onSelect,
                onBeginDrag: { startMouse, cardScreenRect in
                    let captured = CapturedWindow(
                        id: item.id,
                        image: item.image,
                        title: item.title,
                        bounds: item.bounds
                    )
                    WindowPreviewDragController.shared.beginDrag(
                        window: captured,
                        pid: item.pid,
                        appName: item.appName,
                        appIcon: item.appIcon,
                        cardFrameOnScreen: cardScreenRect,
                        sourcePanelFrame: sourcePanelFrame(),
                        startMouseLocation: startMouse,
                        onDismissSource: onDismissPanel
                    )
                },
                isHitExcluded: { point, bounds in
                    guard isHovering else { return false }
                    // In Cocoa coordinates (bottom-left origin):
                    // Top identity row is height 22 + spacing 8 = 30 from the top of the card
                    // Close button is in top-trailing of thumbnail, padding 6, size 17 (circle 13)
                    let topEdge = bounds.height - 30
                    return point.x > bounds.width - 32 && point.y <= topEdge && point.y >= topEdge - 32
                }
            )
        )
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged(hovering)
        }
    }
}
