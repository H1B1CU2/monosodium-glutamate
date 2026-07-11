import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Subsystems

    private let settings = AppSettings.shared
    private var indicator: Indicator!
    private var settingsMenu: SettingsMenu!
    private var musicMonitor: MusicMonitor!
    private var hardwareMonitor: HardwareMonitor!
    private var hardwareStatusItem: HardwareStatusItem?
    private var batteryStatusItem: BatteryStatusItem?
    private var systemHUDMonitor: SystemHUDMonitor?
    private var systemHUDStatusItem: SystemHUDStatusItem?
    private var _trayPanel: AnyObject?   // TrayPanel on macOS 14+

    @available(macOS 14.0, *)
    private var trayPanel: TrayPanel {
        if let p = _trayPanel as? TrayPanel { return p }
        let state = TrayState(settings: settings, musicMonitor: musicMonitor)
        let p = TrayPanel(state: state)
        _trayPanel = p
        return p
    }

    private var _dockHover: AnyObject?   // DockHoverController on macOS 14+

    @available(macOS 14.0, *)
    private var dockHover: DockHoverController {
        if let c = _dockHover as? DockHoverController { return c }
        let c = DockHoverController(settings: settings)
        _dockHover = c
        return c
    }

    // MARK: - Corner windows

    private var cornerWindows: [CornerWindow] = []

    // MARK: - Focus detection

    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?
    private var arrangementPollSource: DispatchSourceTimer?
    private var previousScreenFrames: [CGRect] = []
    private var previousVisibleFrames: [CGRect] = []
    private var appearanceObserver: NSKeyValueObservation?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        if #available(macOS 10.14, *) {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
                let isDark = NSApp.effectiveAppearance.name == .darkAqua
                NSApp.applicationIconImage = isDark ? NSImage(named: "AppIcon-Dark") : nil
            }
        }

        musicMonitor = MusicMonitor(settings: settings)

        musicMonitor.start()

        hardwareMonitor = HardwareMonitor.shared
        hardwareMonitor.start()

        indicator = Indicator(settings: settings, musicMonitor: musicMonitor)
        applyHardwareStats()
        indicator.start()

        applySystemHUD()

        WallpaperEngine.shared.start()

        if #available(macOS 14.0, *), settings.trayEnabled {
            trayPanel.registerHotkey()
            trayPanel.state.prepare()
        }

        if #available(macOS 14.0, *), settings.dockPreviewEnabled {
            dockHover.start()
        }

        NotificationCenter.default.addObserver(forName: .trayEnabledChanged, object: nil, queue: .main) { [weak self] _ in
            guard #available(macOS 14.0, *), let self else { return }
            if self.settings.trayEnabled {
                self.trayPanel.registerHotkey()
                self.trayPanel.state.prepare()
            } else {
                self.trayPanel.unregisterHotkey()
            }
        }

        NotificationCenter.default.addObserver(forName: .dockPreviewChanged, object: nil, queue: .main) { [weak self] _ in
            guard #available(macOS 14.0, *), let self else { return }
            if self.settings.dockPreviewEnabled {
                self.dockHover.start()
            } else {
                self.dockHover.stop()
            }
        }

        // Main menu with Cmd+, → Settings
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem(title: "MSG", action: nil, keyEquivalent: "")
        let appSub = NSMenu()
        appSub.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: "s"))
        appSub.addItem(.separator())
        appSub.addItem(NSMenuItem(title: "Quit MSG", action: #selector(requestQuit), keyEquivalent: "q"))
        appMenu.submenu = appSub
        mainMenu.addItem(appMenu)
        NSApp.mainMenu = mainMenu

        settingsMenu = SettingsMenu(settings: settings)
        settingsMenu.onOpenSettings = { [weak self] in self?.showSettingsWindow() }

        settings.onChange = { [weak self] category in
            guard let self else { return }
            switch category {
            case .corners:
                self.redrawCornerWindows()
                self.applySlideDetection()
                WallpaperEngine.shared.settingsChanged()
            case .indicator:
                self.indicator.applySettings()
                self.applyFocusDetectionMode()
            case .structural:
                self.rebuildCornerWindows()
                self.applySlideDetection()
                self.applyDockIcon()
                self.indicator.spaceWatcher.updateInfo()
                WallpaperEngine.shared.settingsChanged()
                self.applyHardwareStats()
                self.applySystemHUD()
            }
        }

        indicator.onStatusBarClicked = { [weak self] in
            self?.showSettingsMenu()
        }

        indicator.onMCStateChanged = { [weak self] in
            guard let self else { return }
            self.applyCornerWindowTopState()
        }

        rebuildCornerWindows()
        applySlideDetection()

        // Screen changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildCornerWindows()
            self?.checkScreenArrangement()
            self?.settingsMenu.updateExternalMonitorVisibility()
        }

        // Space / fullscreen transitions: re-assert corner window ordering and
        // redraw so NSMenu.menuBarVisible() is re-evaluated for the new state.
        // Skip during MC — corner windows aren't visible and orderFrontRegardless
        // would contend with WindowServer during the MC animation.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, !self.indicator.isMissionControl else { return }
            // Landing: grow any corners the slide-begin hid. Fires ~at the end
            // of the transition for every switch type, including fullscreen
            // spaces where IsAnimating never reports an end.
            self.lastSpaceNotificationAt = ProcessInfo.processInfo.systemUptime
            self.lastActiveSpace = SpaceWatcher.activeSpaceID()
            self.slideLog("end(notification)")
            for win in self.cornerWindows { win.spaceSlideEnded() }
            self.redrawCornerWindows()
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

    // MARK: - Termination

    /// Kill any other running MSG instances (stale copies left over from
    /// previous Xcode runs, a copy in /Applications, a login item, …). Each
    /// instance owns its own status items, so duplicates stack up in the menu
    /// bar and quitting one just reveals the next. The freshly launched
    /// instance wins.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        guard !others.isEmpty else { return }
        for app in others { app.terminate() }
        // Graceful terminate goes through the old instance's cleanup
        // (wallpaper restore etc.); force-kill anything still alive after 2s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            for app in others where !app.isTerminated { app.forceTerminate() }
        }
    }

    private var allowTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !allowTermination {
            // System-initiated termination (logout, shutdown, killall). Never
            // block it — clean up best-effort and let it through. Removing the
            // status items here is what keeps MenuBarAgent from relaunching
            // the app after a killall. All of this is idempotent, so the
            // requestQuit path isn't affected.
            removeAllStatusItems()
            WallpaperEngine.shared.restore()
            DisplaplacerEngine.reconnectAll()
            hardwareMonitor.fanQuitCleanup()
        }
        return .terminateNow
    }

    private func applyHardwareStats() {
        let s = settings
        if s.hardwareStatsEnabled {
            if hardwareStatusItem == nil {
                hardwareStatusItem = HardwareStatusItem()
            }
            let batterySeparate = s.hardwareStatsShowBattery && s.hardwareStatsBatterySeparate
            if let bv = hardwareStatusItem?.barView {
                bv.showCPU    = s.hardwareStatsShowCPU
                bv.showGPU    = s.hardwareStatsShowGPU
                bv.showMemory = s.hardwareStatsShowMemory
                bv.showTemp   = s.hardwareStatsShowTemp
                bv.showFPS       = s.hardwareStatsShowFPS
                bv.showFan       = s.hardwareStatsShowFan
                bv.showPower     = s.hardwareStatsShowPower
                bv.showBattery   = s.hardwareStatsShowBattery && !batterySeparate
                bv.cpuRaw        = s.hardwareStatsCPURaw
                bv.gpuRaw        = s.hardwareStatsGPURaw
                bv.memoryRaw     = s.hardwareStatsMemoryRaw
                bv.tempRaw       = s.hardwareStatsTempRaw
                bv.fanRaw        = s.hardwareStatsFanRaw
                bv.powerRaw      = s.hardwareStatsPowerRaw
                bv.batteryStyle  = s.hardwareStatsBatteryStyle
                bv.moduleOrder   = s.hardwareStatsModuleOrder
                bv.barStyle      = s.hardwareStatsBarStyle
                bv.labelPosition = s.hardwareStatsLabelPos
                bv.colorScale    = s.hardwareStatsColorScale
                bv.updateSize()
                hardwareMonitor.updateInterval(s.hardwareStatsInterval)
                hardwareStatusItem?.refreshImage()
            }
            hardwareStatusItem?.hidesBatteryCard = batterySeparate

            if batterySeparate {
                if batteryStatusItem == nil {
                    batteryStatusItem = BatteryStatusItem()
                }
                batteryStatusItem?.barView.batteryStyle = s.hardwareStatsBatteryStyle
                batteryStatusItem?.barView.barStyle = s.hardwareStatsBarStyle
                batteryStatusItem?.barView.labelPosition = s.hardwareStatsLabelPos
                batteryStatusItem?.barView.colorScale = s.hardwareStatsColorScale
                batteryStatusItem?.refreshImage()
            } else {
                batteryStatusItem?.remove()
                batteryStatusItem = nil
            }
        } else {
            hardwareStatusItem?.remove()
            hardwareStatusItem = nil
            batteryStatusItem?.remove()
            batteryStatusItem = nil
        }
    }

    private func applySystemHUD() {
        if settings.systemHUDEnabled {
            if settings.systemHUDPresentationMode == .separate, systemHUDStatusItem == nil {
                systemHUDStatusItem = SystemHUDStatusItem(settings: settings)
            } else if settings.systemHUDPresentationMode == .dynamic {
                systemHUDStatusItem?.remove()
                systemHUDStatusItem = nil
            }
            if systemHUDMonitor == nil {
                let monitor = SystemHUDMonitor(settings: settings)
                monitor.onChange = { [weak self] kind, value, muted, audioOutputKind in
                    guard let self else { return }
                    if self.settings.systemHUDPresentationMode == .separate {
                        if self.systemHUDStatusItem == nil {
                            self.systemHUDStatusItem = SystemHUDStatusItem(settings: self.settings)
                        }
                        self.systemHUDStatusItem?.show(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
                    } else {
                        self.indicator.showSystemHUD(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
                    }
                }
                systemHUDMonitor = monitor
            }
            systemHUDMonitor?.start()
        } else {
            systemHUDMonitor?.stop()
            systemHUDMonitor = nil
            systemHUDStatusItem?.remove()
            systemHUDStatusItem = nil
        }
    }

    private var quitInProgress = false

    @objc func requestQuit() {
        guard !quitInProgress else { return }
        quitInProgress = true
        systemHUDMonitor?.stop()
        removeAllStatusItems()
        WallpaperEngine.shared.restore()
        DisplaplacerEngine.reconnectAll()
        hardwareMonitor.fanQuitCleanup()
        allowTermination = true
        // Don't terminate in the same runloop turn: the status-item scene
        // removals must reach MenuBarAgent first, otherwise macOS 26 sees
        // orphaned scenes on exit and relaunches the app to restore them
        // (the "quit but it reappears" bug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }

    private func removeAllStatusItems() {
        systemHUDStatusItem?.remove()
        systemHUDStatusItem = nil
        hardwareStatusItem?.remove()
        hardwareStatusItem = nil
        batteryStatusItem?.remove()
        batteryStatusItem = nil
        indicator.removeFromMenuBar()
    }

    // MARK: - AppSettings window

    @objc private func showSettingsWindow() {
        if #available(macOS 14.0, *) {
            SettingsWindowController.shared.show()
        }
    }

    private func applyDockIcon() {
        if settings.dockIcon {
            NSApp.setActivationPolicy(.regular)
        } else if #available(macOS 14.0, *), SettingsWindowController.shared.isVisible {
            // Settings window is open — don't demote to .accessory mid-interaction.
            // windowShouldClose restores .accessory when the window actually closes.
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - AppSettings menu

    private func showSettingsMenu() {
        guard let button = indicator.statusItem.button else { return }
        settingsMenu.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    // MARK: - Space-switch grow-in

    /// 30Hz poll of CGSManagedDisplayIsAnimating. It flips true at the START of
    /// a space-switch slide (~500ms before activeSpaceDidChangeNotification,
    /// which only fires at landing) — the only signal early enough to hide the
    /// corners while the slide masks the change, then grow them in at landing.
    private var slidePollTimer: Timer?
    private var slidingDisplays: Set<String> = []

    private var lastActiveSpace = 0
    private var lastSpaceNotificationAt: TimeInterval = 0
    private var lastAnimatingEndAt: TimeInterval = 0
    private let slideScanQueue = DispatchQueue(label: "msg.slidescan", qos: .userInteractive)
    private var slideScanInFlight = false
    private var slideScanStartedAt: TimeInterval = 0
    private var menuBarPairActive = false
    private var menuBarPairSince: TimeInterval = 0
    private var lastScanCount = 1
    private var slideTicks = 0
    private var slideHeartbeatAt: TimeInterval = 0

    // Temporary diagnostics for the "stops working after a while" report.
    // Rotates at 512KB so it can run for hours.
    private func slideLog(_ s: String) {
        let url = URL(fileURLWithPath: "/tmp/msg_slide_debug.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Number of onscreen Window Server menu bar windows (layer 24). Each
    /// space carries its own; during a space slide both the source and the
    /// destination space are onscreen, so the count jumps to ≥2 at slide
    /// start (measured ~0.5–1s before the landing signals) and returns to 1
    /// at landing. Works for fullscreen-app spaces where IsAnimating doesn't.
    private static func menuBarWindowCount() -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return 1 }
        return list.filter {
            ($0[kCGWindowOwnerName as String] as? String) == "Window Server"
                && ($0[kCGWindowLayer as String] as? Int) == 24
        }.count
    }

    private func applyMenuBarPair(count: Int) {
        lastScanCount = count
        let pair = count >= 2
        guard pair != menuBarPairActive else { return }
        menuBarPairActive = pair
        if pair { menuBarPairSince = ProcessInfo.processInfo.systemUptime }
        guard !indicator.isMissionControl else {
            slideLog("pair=\(pair) count=\(count) suppressed(mc)")
            return
        }
        if pair {
            slideLog("begin(menubar-pair) count=\(count)")
            for win in cornerWindows { win.spaceSlideBegan() }
        } else {
            slideLog("end(menubar-pair)")
            for win in cornerWindows { win.spaceSlideEnded() }
        }
    }

    private func applySlideDetection() {
        let wanted = settings.cornersEnabled && settings.cornerGrowEnabled
        if wanted, slidePollTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.pollSlideState()
            }
            RunLoop.main.add(t, forMode: .common)
            slidePollTimer = t
        } else if !wanted {
            slidePollTimer?.invalidate(); slidePollTimer = nil
            slidingDisplays.removeAll()
        }
    }

    private func pollSlideState() {
        let now = ProcessInfo.processInfo.systemUptime
        slideTicks += 1

        // Diagnostics heartbeat every 30s: tick rate exposes timer throttling,
        // the rest exposes stuck state.
        if now - slideHeartbeatAt > 30 {
            slideHeartbeatAt = now
            slideLog("heartbeat ticks=\(slideTicks) mc=\(indicator.isMissionControl) pair=\(menuBarPairActive) inflight=\(slideScanInFlight) lastCount=\(lastScanCount) windows=\(cornerWindows.count)")
            slideTicks = 0
        }

        // Watchdog: a scan that never came back would silence the pair path
        // for good — reset after 2s and let the next tick rescan.
        if slideScanInFlight, now - slideScanStartedAt > 2 {
            slideScanInFlight = false
            slideLog("watchdog: scan reset")
        }

        // MC's own transitions also animate; the MC exit path handles those.
        // No menu-bar/fullscreen guards here: both signals are transient at
        // slide start, and the fullscreen paths self-heal (the shared grow
        // timer and the hidden→shown top transition both converge to full).
        if indicator.isMissionControl {
            slidingDisplays.removeAll()
            lastActiveSpace = SpaceWatcher.activeSpaceID()
            return
        }

        // Active-space flip: the only begin signal that fires for transitions
        // to/from fullscreen-app spaces (IsAnimating stays false there). If the
        // flip trails the landing notification, the transition is already over
        // — hiding then would strand the corners hidden, so skip.
        let active = SpaceWatcher.activeSpaceID()
        if lastActiveSpace == 0 { lastActiveSpace = active }
        if active != lastActiveSpace {
            lastActiveSpace = active
            // Suppress when another begin path already handled this switch:
            // for desktop↔desktop slides the flip lands ~5ms after the slide
            // ends and would re-hide the freshly growing corners. A pair state
            // older than 4s is stale (no slide lasts that long) — don't let it
            // keep suppressing this backup path.
            if now - lastSpaceNotificationAt > 0.3,
               now - lastAnimatingEndAt > 0.3,
               slidingDisplays.isEmpty,
               !menuBarPairActive || now - menuBarPairSince > 4 {
                slideLog("begin(active-flip) space=\(active)")
                for win in cornerWindows { win.spaceSlideBegan() }
            } else {
                slideLog("skip(active-flip) space=\(active) pair=\(menuBarPairActive)")
            }
        }

        for win in cornerWindows {
            guard let uuid = win.displayUUID else { continue }
            let sliding = SpaceWatcher.isDisplayAnimating(uuid: uuid)
            if sliding, !slidingDisplays.contains(uuid) {
                slidingDisplays.insert(uuid)
                win.spaceSlideBegan()
            } else if !sliding, slidingDisplays.contains(uuid) {
                slidingDisplays.remove(uuid)
                lastAnimatingEndAt = now
                win.spaceSlideEnded()
            }
        }

        // Menu-bar-pair scan (CGWindowList) off the main thread, one in
        // flight at a time — same pattern as SystemState's MC detection.
        guard !slideScanInFlight else { return }
        slideScanInFlight = true
        slideScanStartedAt = now
        slideScanQueue.async { [weak self] in
            let count = Self.menuBarWindowCount()
            DispatchQueue.main.async {
                guard let self else { return }
                self.slideScanInFlight = false
                self.applyMenuBarPair(count: count)
            }
        }
    }

    // MARK: - Mission Control

    /// Hide the under-menu-bar top corners while Mission Control is active so that
    /// leaving it produces a hidden→shown transition the corner view grows in.
    private func applyCornerWindowTopState() {
        let hideTop = indicator.isMissionControl
        for win in cornerWindows {
            let uuid = win.displayUUID ?? "_default"
            let underBar = win.targetScreen.isBuiltin
                ? settings.topCornersUnderMenuBar
                : settings.extTopCornersUnderMenuBar(for: uuid)
            win.setSkipTop(hideTop && underBar)
        }
    }

    // MARK: - Corner windows

    private func rebuildCornerWindows() {
        for win in cornerWindows { win.orderOut(nil) }
        cornerWindows.removeAll()
        guard settings.cornersEnabled else { return }
        for screen in NSScreen.screens {
            let win = CornerWindow(screen: screen, settings: settings)
            win.setFrame(screen.frame, display: false)
            win.orderFrontRegardless()
            win.redraw()
            cornerWindows.append(win)
        }
        applyCornerWindowTopState()
    }

    private func redrawCornerWindows() {
        guard settings.cornersEnabled else { return }
        let screenFrames = NSScreen.screens.map(\.frame)
        let windowFrames = cornerWindows.map(\.frame)
        if cornerWindows.count != NSScreen.screens.count || windowFrames != screenFrames {
            rebuildCornerWindows()
            return
        }
        for win in cornerWindows {
            win.updateFrame()
            win.orderFrontRegardless()
            win.redraw()
        }
        applyCornerWindowTopState()
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
            redrawCornerWindows()
            indicator.refresh()
            indicator.statusItem.button?.display()
        }

    }

    private func applyAutoOrder() {
        guard settings.displayOrderMode == .physicalDetection, NSScreen.screens.count >= 2 else { return }
        let screens = NSScreen.screens
        // Sort by xOrigin (left→right), then yOrigin (top→bottom)
        let indexed = screens.enumerated().sorted { a, b in
            if abs(a.element.frame.minX - b.element.frame.minX) > 1 {
                return a.element.frame.minX < b.element.frame.minX
            }
            return a.element.frame.minY > b.element.frame.minY
        }
        let newOrder = indexed.map { $0.offset }
        if newOrder != settings.displayOrder { settings.displayOrder = newOrder }
    }

    // MARK: - Focus detection

    private var focusPollTimer: Timer?

    private func applyFocusDetectionMode() {
        if let m = clickMonitorGlobal { NSEvent.removeMonitor(m); clickMonitorGlobal = nil }
        if let m = clickMonitorLocal  { NSEvent.removeMonitor(m); clickMonitorLocal = nil }
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
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens[0]).uuid
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}
            
