import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Subsystems

    private let settings = AppSettings.shared
    private var indicator: Indicator!
    private var settingsMenu: SettingsMenu!
    private var musicMonitor: MusicMonitor!
    private var _trayPanel: AnyObject?   // TrayPanel on macOS 14+

    @available(macOS 14.0, *)
    private var trayPanel: TrayPanel {
        if let p = _trayPanel as? TrayPanel { return p }
        let state = TrayState(settings: settings, musicMonitor: musicMonitor)
        let p = TrayPanel(state: state)
        _trayPanel = p
        return p
    }

    // MARK: - Corner windows

    private var cornerWindows: [CornerWindow] = []

    // MARK: - Focus detection

    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?
    private var arrangementPollSource: DispatchSourceTimer?
    private var previousScreenFrames: [CGRect] = []
    private var previousVisibleFrames: [CGRect] = []

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        musicMonitor = MusicMonitor(settings: settings)
        musicMonitor.start()

        indicator = Indicator(settings: settings, musicMonitor: musicMonitor)
        indicator.start()

        WallpaperEngine.shared.start()

        if #available(macOS 14.0, *), settings.trayEnabled {
            trayPanel.registerHotkey()
            trayPanel.state.prepare()
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
                WallpaperEngine.shared.settingsChanged()
            case .indicator:
                self.indicator.applySettings()
                self.applyFocusDetectionMode()
            case .structural:
                self.rebuildCornerWindows()
                self.applyDockIcon()
                self.indicator.spaceWatcher.updateInfo()
                WallpaperEngine.shared.settingsChanged()
            }
        }

        indicator.onStatusBarClicked = { [weak self] in
            self?.showSettingsMenu()
        }

        indicator.onMCStateChanged = { [weak self] in
            guard let self else { return }
            self.applyCornerWindowMCState(self.indicator.isMissionControl)
        }

        rebuildCornerWindows()

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

    private var allowTermination = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !allowTermination {
            // System-initiated termination (logout, shutdown, killall). Never
            // block it — clean up the wallpaper best-effort and let it through.
            // restore() is idempotent, so the requestQuit path isn't affected.
            WallpaperEngine.shared.restore()
            DisplaplacerEngine.reconnectAll()
        }
        return .terminateNow
    }

    @objc func requestQuit() {
        WallpaperEngine.shared.restore()
        DisplaplacerEngine.reconnectAll()
        allowTermination = true
        NSApp.terminate(nil)
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
        let menu = settingsMenu.menu
        indicator.statusItem.menu = menu
        indicator.statusItem.button?.performClick(nil)
        indicator.statusItem.menu = nil
    }

    // MARK: - Mission Control

    private func applyCornerWindowMCState(_ inMC: Bool) {
        for win in cornerWindows {
            let uuid = win.displayUUID ?? "_default"
            let underBar = win.targetScreen.isBuiltin
                ? settings.topCornersUnderMenuBar
                : settings.extTopCornersUnderMenuBar(for: uuid)
            win.setSkipTop(inMC && underBar)
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
    }

    private func redrawCornerWindows() {
        guard settings.cornersEnabled else { return }
        for win in cornerWindows {
            win.updateFrame()
            win.orderFrontRegardless()
            win.redraw()
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
            

