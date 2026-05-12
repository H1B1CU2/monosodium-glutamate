import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Subsystems

    private let settings = Settings.shared
    private var indicator: Indicator!
    private var settingsMenu: SettingsMenu!

    // MARK: - Corner windows

    private var cornerWindows: [CornerWindow] = []

    // MARK: - Focus detection

    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?
    private var arrangementPollSource: DispatchSourceTimer?
    private var previousScreenFrames: [CGRect] = []
    private var previousVisibleFrames: [CGRect] = []

    private var pollTimer: Timer?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        indicator = Indicator(settings: settings)
        indicator.start()

        settingsMenu = SettingsMenu(settings: settings)

        settings.onChange = { [weak self] category in
            guard let self else { return }
            switch category {
            case .corners:
                self.redrawCornerWindows()
            case .indicator:
                self.indicator.applySettings()
                self.applyFocusDetectionMode()
            case .structural:
                self.rebuildCornerWindows()
            }
        }

        indicator.onStatusBarClicked = { [weak self] in
            self?.showSettingsMenu()
        }
        indicator.onMCStateChanged = { [weak self] in
            self?.redrawCornerWindows()
        }

        rebuildCornerWindows()

        // Screen changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildCornerWindows()
            self?.indicator.spaceWatcher.updateInfo()
            self?.settingsMenu.updateExternalMonitorVisibility()
            self?.checkScreenArrangement()
        }

        // CGDisplay callback for arrangement changes
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
            guard let ctx = userInfo else { return }
            let ad = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                ad.settingsMenu.updateExternalMonitorVisibility()
                ad.checkScreenArrangement()
            }
        }, ctx)

        previousScreenFrames = NSScreen.screens.map { $0.frame }
        previousVisibleFrames = NSScreen.screens.map { $0.visibleFrame }
        startArrangementPolling()
        applyFocusDetectionMode()
    }

    // MARK: - Settings menu

    private func showSettingsMenu() {
        let menu = settingsMenu.menu
        indicator.statusItem.menu = menu
        indicator.statusItem.button?.performClick(nil)
        indicator.statusItem.menu = nil
    }

    // MARK: - Corner windows

    private func rebuildCornerWindows() {
        for win in cornerWindows { win.orderOut(nil) }
        cornerWindows.removeAll()
        let screens = settings.externalMonitorCorners ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for screen in screens {
            let win = CornerWindow(screen: screen, settings: settings)
            win.orderFront(nil)
            cornerWindows.append(win)
            win.animateIn()
        }
    }

    private var wasFullscreen = false
    private var wasInMC = false

    private func isMissionControlActive() -> Bool {
        // Primary: Dock windows at positive layers
        if let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                guard (w[kCGWindowOwnerName as String] as? String) == "Dock" else { continue }
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                if layer > 0 && layer < 1000 { return true }
            }
        }
        // Backup: menu bar just appeared while in fullscreen = MC entering
        let fs = !NSMenu.menuBarVisible()
        if wasFullscreen && !fs { return true }
        wasFullscreen = fs
        return false
    }

    private var mcRedrawTimer: Timer?

    private func startMCRedrawPoll() {
        guard mcRedrawTimer == nil else { return }
        mcRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let inMC = self.isMissionControlActive()
            for win in self.cornerWindows {
                win.updateFrame()
                win.orderFrontRegardless()
                let isBuiltin = win.targetScreen.isBuiltin
                let underBar = isBuiltin ? self.settings.topCornersUnderMenuBar : self.settings.extTopCornersUnderMenuBar
                win.redraw(skipTop: inMC && underBar)
            }
            if !inMC {
                self.mcRedrawTimer?.invalidate()
                self.mcRedrawTimer = nil
                self.wasInMC = false
                for win in self.cornerWindows { win.animateIn() }
            }
        }
        if let t = mcRedrawTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func redrawCornerWindows() {
        let inMC = isMissionControlActive()
        let justExitedMC = wasInMC && !inMC
        wasInMC = inMC
        if inMC { startMCRedrawPoll() }
        for win in cornerWindows {
            win.updateFrame()
            win.orderFrontRegardless()
            let isBuiltin = win.targetScreen.isBuiltin
            let underBar = isBuiltin ? settings.topCornersUnderMenuBar : settings.extTopCornersUnderMenuBar
            win.redraw(skipTop: inMC && underBar)
        }
        if justExitedMC {
            for win in cornerWindows { win.animateIn() }
        }
    }

    // MARK: - Screen arrangement

    private func startArrangementPolling() {
        guard arrangementPollSource == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkScreenArrangement() }
        t.resume()
        arrangementPollSource = t
    }

    private func checkScreenArrangement() {
        let currentFrames = NSScreen.screens.map { $0.frame }
        let currentVisible = NSScreen.screens.map { $0.visibleFrame }
        let frameChanged = currentFrames != previousScreenFrames
        let visibleChanged = currentVisible != previousVisibleFrames

        if frameChanged || visibleChanged {
            previousScreenFrames = currentFrames
            previousVisibleFrames = currentVisible
            if frameChanged && settings.displayOrderMode == .physicalDetection { applyAutoOrder() }
            indicator.refresh()
            indicator.statusItem.button?.display()
        }
    }

    private func applyAutoOrder() {
        guard settings.displayOrderMode == .physicalDetection, NSScreen.screens.count >= 2 else { return }
        let screens = NSScreen.screens
        let builtIn = screens[0]
        var newOrder: [Int] = []
        var above: [(Int, CGFloat)] = []
        var below: [(Int, CGFloat)] = []
        var left:  [(Int, CGFloat)] = []
        var right: [(Int, CGFloat)] = []

        for (idx, screen) in screens.enumerated() where idx > 0 {
            let f = screen.frame, b = builtIn.frame
            if f.minY >= b.maxY       { above.append((idx, f.minX)) }
            else if f.maxY <= b.minY  { below.append((idx, f.minX)) }
            else if f.maxX <= b.minX  { left.append((idx, f.minY)) }
            else                       { right.append((idx, f.minY)) }
        }
        newOrder.append(contentsOf: above.map { $0.0 })
        newOrder.append(contentsOf: left.map  { $0.0 })
        newOrder.append(0)
        newOrder.append(contentsOf: right.map { $0.0 })
        newOrder.append(contentsOf: below.map { $0.0 })
        if newOrder != settings.displayOrder { settings.displayOrder = newOrder }
    }

    // MARK: - Focus detection

    private var focusPollTimer: Timer?

    private func applyFocusDetectionMode() {
        if let m = clickMonitorGlobal { NSEvent.removeMonitor(m); clickMonitorGlobal = nil }
        if let m = clickMonitorLocal  { NSEvent.removeMonitor(m); clickMonitorLocal = nil }
        pollTimer?.invalidate(); pollTimer = nil
        focusPollTimer?.invalidate(); focusPollTimer = nil
        stopFocusPolling()

        switch settings.focusDetectionMode {
        case .off:
            break
        case .click:
            clickMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
                self?.handleFocusClick(e)
            }
            clickMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
                self?.handleFocusClick(e)
                return e
            }
        case .dynamic:
            startFocusPolling()
        }
    }

    private var dynamicMouseMonitor: Any?
    private var lastDynamicUpdate: TimeInterval = 0

    private func startFocusPolling() {
        dynamicMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, self.settings.focusDetectionMode == .dynamic else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastDynamicUpdate > 0.1 else { return }
            self.lastDynamicUpdate = now
            let uuid = self.screenUUID(at: NSEvent.mouseLocation)
            guard let uuid, uuid != self.indicator.spaceWatcher.currentFocusedUUID else { return }
            self.indicator.spaceWatcher.currentFocusedUUID = uuid
            self.indicator.spaceWatcher.updateInfo()
        }
    }

    private func stopFocusPolling() {
        if let m = dynamicMouseMonitor { NSEvent.removeMonitor(m); dynamicMouseMonitor = nil }
    }

    private func handleFocusClick(_ event: NSEvent) {
        guard settings.focusDetectionMode == .click else { return }
        let uuid = screenUUID(at: NSEvent.mouseLocation)
        if uuid == indicator.spaceWatcher.currentFocusedUUID { return }
        indicator.spaceWatcher.currentFocusedUUID = uuid
        indicator.spaceWatcher.updateInfo()
    }

    private func screenUUID(at point: NSPoint) -> String? {
        Indicator.screenUUID(NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens[0])
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}
            

