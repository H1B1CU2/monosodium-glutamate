import AppKit
import ApplicationServices
import ServiceManagement

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
    private var inputSourceMonitor: InputSourceMonitor?
    private var systemHUDStatusItem: SystemHUDStatusItem?
    private let tilingController = TilingController.shared
    private var _dockHover: AnyObject?   // DockHoverController on macOS 14+

    @available(macOS 14.0, *)
    private var dockHover: DockHoverController {
        if let c = _dockHover as? DockHoverController { return c }
        let c = DockHoverController(settings: settings)
        _dockHover = c
        return c
    }

    private var _appSwitcherHover: AnyObject?   // AppSwitcherHoverController on macOS 14+

    @available(macOS 14.0, *)
    private var appSwitcherHover: AppSwitcherHoverController {
        if let c = _appSwitcherHover as? AppSwitcherHoverController { return c }
        let c = AppSwitcherHoverController(settings: settings)
        _appSwitcherHover = c
        return c
    }

    private var _notchHover: AnyObject?   // NotchHoverController on macOS 14+

    @available(macOS 14.0, *)
    private var notchHover: NotchHoverController {
        if let c = _notchHover as? NotchHoverController { return c }
        let c = NotchHoverController(settings: settings)
        _notchHover = c
        return c
    }

    // MARK: - Corner windows

    private var cornerWindows: [CornerWindow] = []
    private var wakeRebuildItem: DispatchWorkItem?

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
        MSGNativeHotkeys.apply(desired: []) // Recover any takeover left by an interrupted run.
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        // Diagnostics for the privileged fan daemon. Registration is a system
        // change (it installs a LaunchDaemon), so it stays opt-in rather than
        // happening on every launch: MSG_FAN=status reports, MSG_FAN=register
        // installs, MSG_FAN=unregister removes it again.
        if #available(macOS 14.0, *) {
            let mode = ProcessInfo.processInfo.environment["MSG_FAN"] ?? "status"
            let client = FanControlClient.shared
            var report = "mode=\(mode)\n"
            let service = SMAppService.daemon(plistName: FanHelperID.plistName)
            switch mode {
            case "register":
                do {
                    try service.register()
                    report += "register=ok\n"
                } catch {
                    report += "register=threw \(error)\n"
                }
            case "unregister":
                do { try service.unregister(); report += "unregister=ok\n" }
                catch { report += "unregister=threw \(error)\n" }
            default: break
            }
            report += "status=\(client.access)\nraw=\(service.status.rawValue)\n"
            report += "bundle=\(Bundle.main.bundlePath)\n"
            let plist = Bundle.main.bundlePath + "/Contents/Library/LaunchDaemons/" + FanHelperID.plistName
            report += "plistExists=\(FileManager.default.fileExists(atPath: plist))\n"
            try? report.write(toFile: "/tmp/msg_fan_report.txt", atomically: true, encoding: .utf8)
        }

        if #available(macOS 10.14, *) {
            appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
                let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let lightIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon")
                app.applicationIconImage = isDark
                    ? (NSImage(named: "AppIcon-Dark") ?? lightIcon)
                    : lightIcon
            }
        }

        musicMonitor = MusicMonitor(settings: settings)
        NotchHUD.shared.attachMusic(musicMonitor)
        musicMonitor.start()

        hardwareMonitor = HardwareMonitor.shared

        indicator = Indicator(settings: settings, musicMonitor: musicMonitor)
        indicator.systemState.slideInProgressProvider = { [weak self] in
            self?.menuBarPairActive == true || (self?.slidingDisplays.isEmpty == false)
        }
        applyHardwareStats()
        indicator.start()

        applySystemHUD()
        applyCalendarStatusItem()
        applyInputSourceHUD()

        // Liveness for WallpaperEngine's editing mode: the Cornermizer pane's
        // onDisappear does not fire when the settings window is merely closed,
        // so the engine polls this to release a latched isEditing.
        if #available(macOS 14.0, *) {
            WallpaperEngine.shared.editingWindowIsOpen = {
                SettingsWindowController.shared.isVisible
            }
        }

        WallpaperEngine.shared.start()
        LockScreenTouchIDController.shared.start()
        AgentLockScreen.shared.start()
        AgentNotchCard.shared.start()
        LimitResetNotice.shared.start()
        AgentDoneNotice.shared.start()
        ChargerNotchNotice.shared.start()
        SystemEventNotchNotice.shared.start()
        SystemNotificationNotch.shared.start()
        CortexActivityPill.shared.start()
        NotchDropZone.shared.isSuppressed = { AgentNotchCard.shared.isShowingTray || AgentNotchCard.shared.isSuppressedByCortex }
        if settings.notchDropTray { NotchDropZone.shared.start() }
        MusicEdgeHUD.shared.attach(to: musicMonitor)
        // Tiled windows stay above the strip (see TilingController.workArea).
        EdgeKeyStrip.shared.onReserveChanged = { [weak self] in self?.tilingController.settingsChanged() }
        EdgeKeyStrip.shared.onSwitchDesktop = { [weak self] number in
            self?.tilingController.switchToSpaceOnFocusedDisplay(number)
        }
        EdgeKeyStrip.shared.start(music: musicMonitor)
        FunctionRowCalibration.shared.start()
        if #available(macOS 14.0, *) {
            // Pictures for previews of windows that later get hidden or minimized.
            WindowThumbnailKeeper.shared.start()
        }

        // Fills the DDC input cache the menu and the settings pane read. The scan
        // is ~2 s of blocking I2C per panel, so it happens once here in the
        // background and again only when the display set changes.
        DisplayInputEngine.refresh {
            // Monitors listed: bring their backlight in line with the built-in panel.
            ExternalBrightnessSync.shared.displaysChanged()
        }

        if #available(macOS 14.0, *), settings.dockPreviewEnabled {
            dockHover.start()
        }

        if #available(macOS 14.0, *), settings.appSwitcherPreviewEnabled {
            appSwitcherHover.start()
        }

        if #available(macOS 14.0, *), settings.notchPreviewEnabled {
            notchHover.start()
        }

        NotificationCenter.default.addObserver(forName: .dockPreviewChanged, object: nil, queue: .main) { [weak self] _ in
            guard #available(macOS 14.0, *), let self else { return }
            if self.settings.dockPreviewEnabled {
                self.dockHover.start()
            } else {
                self.dockHover.stop()
            }
        }

        NotificationCenter.default.addObserver(forName: .notchPreviewChanged, object: nil, queue: .main) { [weak self] _ in
            guard #available(macOS 14.0, *), let self else { return }
            if self.settings.notchPreviewEnabled {
                self.notchHover.start()
            } else {
                self.notchHover.stop()
            }
        }

        NotificationCenter.default.addObserver(forName: .appSwitcherPreviewChanged, object: nil, queue: .main) { [weak self] _ in
            guard #available(macOS 14.0, *), let self else { return }
            if self.settings.appSwitcherPreviewEnabled {
                self.appSwitcherHover.start()
            } else {
                self.appSwitcherHover.stop()
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
                EdgeKeyStrip.shared.update()
            case .indicator:
                self.indicator.applySettings()
                self.applyFocusDetectionMode()
                self.musicMonitor.settingsChanged()
            case .tiling:
                self.tilingController.settingsChanged()
                // The baked wallpaper darkens the menu bar strip while the
                // control bar covers it (see WallpaperEngine.menuBarStripHeight).
                WallpaperEngine.shared.settingsChanged()
            case .structural:
                self.rebuildCornerWindows()
                self.applySlideDetection()
                self.applyDockIcon()
                self.indicator.spaceWatcher.updateInfo()
                WallpaperEngine.shared.settingsChanged()
                self.applyHardwareStats()
                self.applySystemHUD()
                self.applyCalendarStatusItem()
                self.applyInputSourceHUD()
                self.musicMonitor.settingsChanged()
                EdgeKeyStrip.shared.update()
            }
        }

        tilingController.start()

        indicator.onStatusBarClicked = { [weak self] in
            self?.showSettingsMenu()
        }

        indicator.onMCStateChanged = { [weak self] in
            guard let self else { return }
            self.applyCornerWindowTopState()
        }

        rebuildCornerWindows()
        applySlideDetection()

        // A soft-disabled display outlives the app (the config is .forSession), so a
        // display left dark by a crash, a force-quit, or a lost eject record is still
        // dark now. Heal once at launch, after the screen list has settled.
        DisplayLog.snapshot("launch")
        scheduleDisplayHeal()

        // Screen changes
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildCornerWindows()
            self?.checkScreenArrangement()
            self?.settingsMenu.updateExternalMonitorVisibility()
            self?.scheduleDisplayHeal()
            // A panel that just appeared has inputs to offer; one that left must
            // drop out of the menu. Listing needs no DDC, so it runs now; any DDC
            // waits out the settle window this opens.
            DisplayInputEngine.noteDisplayChange()
            DisplayInputEngine.refresh {
                ExternalBrightnessSync.shared.displaysChanged()
            }
        }

        PresentationState.shared.addObserver { [weak self] in
            guard PresentationState.shared.canPresent else { return }
            self?.scheduleCornerRecovery()
            // Awake again: the monitor may have lost its level while asleep.
            ExternalBrightnessSync.shared.resync()
        }

        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                DisplayInputEngine.noteDisplayChange()
                self?.scheduleCornerRecovery()
            }
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

        // SP8CE's page fullscreen covers a display without creating a native
        // fullscreen Space. Recheck the top corners as soon as that state flips.
        NotificationCenter.default.addObserver(
            forName: SystemState.pageFullscreenChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyCornerWindowTopState()
        }

        // CGDisplay callback for arrangement changes
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ display, flags, userInfo in
            // Log every reconfiguration, whoever caused it. When a monitor goes dark
            // this is the record of what actually happened to it, and whether the
            // change came out of one of our own display transactions.
            DisplayLog.write("reconfig id=\(display) \(DisplayLog.describe(flags))"
                             + (DisplayLog.inOurTransaction ? " [ours]" : ""))
            guard let ctx = userInfo else { return }
            // A monitor plugged in by hand (not one MSG just reconnected).
            if flags.contains(.addFlag), !DisplayLog.inOurTransaction {
                DispatchQueue.main.async { DisplaplacerEngine.resyncAfterPlug(display) }
            }
            let ad = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async {
                // Ours or not, the link is renegotiating: hold DDC off.
                DisplayInputEngine.noteDisplayChange()
                ad.settingsMenu.updateExternalMonitorVisibility()
                ad.checkScreenArrangement()
                // A panel handed to another machine comes back through here. Undo
                // the eject that went with the handover so pressing the monitor's
                // input button is the only step the user has to take.
                if !flags.contains(.beginConfigurationFlag) {
                    DisplayInputEngine.reconnectReturnedHandoverDisplays()
                    DisplayLog.snapshot("reconfig settled")
                }
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
        tilingController.stop()
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
        if #available(macOS 14.0, *) {
            (_appSwitcherHover as? AppSwitcherHoverController)?.stop()
            (_dockHover as? DockHoverController)?.stop()
            (_notchHover as? NotchHoverController)?.stop()
        }
        DisplayInputEngine.drainBeforeExit()
        return .terminateNow
    }

    private func applyHardwareStats() {
        let s = settings
        if s.hardwareStatsEnabled {
            hardwareMonitor.start()
            if hardwareStatusItem == nil {
                hardwareStatusItem = HardwareStatusItem()
                EdgeKeyStrip.shared.onStatsClicked = { [weak self] rect in
                    self?.hardwareStatusItem?.toggleStripPopover(above: rect)
                }
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
            hardwareStatusItem?.setShownInMenuBar(!EdgeKeyStrip.statsInTouchID)
            if !EdgeKeyStrip.statsInTouchID { EdgeKeyStrip.shared.showStats(nil) }

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
            hardwareMonitor.stop()
            hardwareStatusItem?.remove()
            hardwareStatusItem = nil
            batteryStatusItem?.remove()
            batteryStatusItem = nil
        }
    }

    /// A `CalendarStatusItem` (macOS 14+).
    private var calendarStatusItem: AnyObject?

    private func applyCalendarStatusItem() {
        guard #available(macOS 14.0, *) else { return }
        if settings.calendarStatusItem {
            if calendarStatusItem == nil {
                calendarStatusItem = CalendarStatusItem()
            } else {
                (calendarStatusItem as? CalendarStatusItem)?.refresh()
            }
        } else {
            (calendarStatusItem as? CalendarStatusItem)?.remove()
            calendarStatusItem = nil
        }
    }

    private func applySystemHUD() {
        if settings.systemHUDEnabled {
            if settings.systemHUDPresentationMode == .separate, systemHUDStatusItem == nil {
                systemHUDStatusItem = SystemHUDStatusItem(settings: settings)
            } else if settings.systemHUDPresentationMode != .separate {
                systemHUDStatusItem?.remove()
                systemHUDStatusItem = nil
            }
        } else {
            systemHUDStatusItem?.remove()
            systemHUDStatusItem = nil
        }
        if !settings.systemHUDEnabled || settings.systemHUDPresentationMode != .notch {
            NotchHUD.shared.hide(animated: false)
        }

        // One tap serves both features: the volume/brightness HUD and Apple
        // Music media-key routing. Either alone is reason enough to keep it up.
        if settings.systemHUDEnabled || settings.mediaKeyPriorityMusic || settings.edgeKeysMode == .strip {
            if systemHUDMonitor == nil {
                let monitor = SystemHUDMonitor(settings: settings)
                monitor.onChange = { [weak self] kind, value, muted, audioOutputKind in
                    guard let self else { return }
                    // Notch: out of the notch, like the TokenBar card. Without
                    // one (lid closed), the HUDs below as in Dynamic.
                    if self.settings.systemHUDPresentationMode == .notch,
                       NotchHUD.shared.show(kind: kind, value: value, muted: muted,
                                            audioOutputKind: audioOutputKind) { return }
                    // Right above the keys that changed it, on the built-in
                    // display; declines with the lid closed, then the HUDs
                    // below take over.
                    if EdgeKeyStrip.shared.showLevel(kind: kind, value: value, muted: muted,
                                                     audioOutputKind: audioOutputKind) { return }
                    if KeyEdgeHUD.shared.show(kind: kind, value: value, muted: muted,
                                              audioOutputKind: audioOutputKind) { return }
                    if self.settings.systemHUDPresentationMode == .separate {
                        if self.systemHUDStatusItem == nil {
                            self.systemHUDStatusItem = SystemHUDStatusItem(settings: self.settings)
                        }
                        self.systemHUDStatusItem?.show(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
                    } else if !(self.settings.systemHUDInTilingBar
                                && self.tilingController.showSystemHUD(kind: kind, value: value, muted: muted,
                                                                       audioOutputKind: audioOutputKind)) {
                        // The tiling bar declines when it isn't showing, so
                        // the HUD is never lost under a hidden bar.
                        self.indicator.showSystemHUD(kind: kind, value: value, muted: muted, audioOutputKind: audioOutputKind)
                    }
                }
                monitor.shouldRouteMediaKey = { [weak self] in
                    self?.musicMonitor.shouldRouteMediaKeysToAppleMusic ?? false
                }
                monitor.onMediaKey = { [weak self] action in
                    self?.musicMonitor.handleRoutedMediaKey(action)
                }
                // Previous / play-pause / next over F7–F9, like the
                // brightness and volume HUDs over their keys.
                monitor.onTransportAction = { action in
                    MusicEdgeHUD.shared.show(action: action)
                }
                monitor.onAuxKeyDown = { code, posted in
                    EdgeKeyStrip.shared.auxKeyDown(code, posted: posted)
                }
                monitor.auxKeyOverride = { code, isDown, isRepeat in
                    EdgeKeyStrip.shared.auxKeyOverride(code: code, isDown: isDown, isRepeat: isRepeat)
                }
                monitor.onTransportKey = { [weak self] in
                    self?.musicMonitor.pokeNow()
                }
                systemHUDMonitor = monitor
                NotchHUD.shared.levels = monitor
            }
            systemHUDMonitor?.start()
        } else {
            systemHUDMonitor?.stop()
            systemHUDMonitor = nil
        }
    }

    private func applyInputSourceHUD() {
        if settings.inputSourceHUDEnabled {
            if inputSourceMonitor == nil {
                let monitor = InputSourceMonitor()
                monitor.onChange = { [weak self] name in
                    guard let self else { return }
                    if self.settings.systemHUDPresentationMode == .notch,
                       NotchHUD.shared.showInputSource(label: name) { return }
                    if !(self.settings.systemHUDInTilingBar
                         && self.tilingController.showInputSourceHUD(name: name)) {
                        self.indicator.showInputSourceHUD(name: name)
                    }
                }
                inputSourceMonitor = monitor
            }
            inputSourceMonitor?.start()
        } else {
            inputSourceMonitor?.stop()
            inputSourceMonitor = nil
        }
    }

    private var quitInProgress = false

    @objc func requestQuit() {
        guard !quitInProgress else { return }
        quitInProgress = true
        tilingController.stop()
        systemHUDMonitor?.stop()
        // Right ⇧ is Shift again once MSG is gone.
        RightShiftRemap.set(false)
        EdgeKeyStrip.shared.releaseTouchIDLockBlock()
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
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
    private var splitViewPanePollingActive = false
    private var lastSplitViewPanePollAt: TimeInterval = 0
    private var slidingDisplays: Set<String> = []
    private var slidingDisplayStartedAt: [String: TimeInterval] = [:]
    /// WindowServer can leave IsAnimating stuck true across sleep/wake. Once a
    /// reading exceeds the maximum credible slide duration, ignore it until a
    /// real false edge arrives so it cannot repeatedly hide the corners.
    private var ignoredAnimatingDisplays: Set<String> = []
    private static let maximumSlideDuration: TimeInterval = 4

    private var lastActiveSpace = 0
    private var lastSpaceNotificationAt: TimeInterval = 0
    private var lastAnimatingEndAt: TimeInterval = 0
    private var menuBarPairActive = false
    private var menuBarPairSince: TimeInterval = 0
    private var lastScanCount = 1
    private var slideTicks = 0
    private var slideHeartbeatAt: TimeInterval = 0

    private static let slideDebugEnabled =
        UserDefaults.standard.bool(forKey: "MSGSlideDebug")

    // Temporary diagnostics for the "stops working after a while" report.
    // Rotates at 512KB so it can run for hours.
    private func slideLog(_ s: @autoclosure () -> String) {
        guard Self.slideDebugEnabled else { return }
        let url = URL(fileURLWithPath: "/tmp/msg_slide_debug.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date()) \(s())\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
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
        if wanted {
            indicator.systemState.onMenuBarWindowCount = { [weak self] count in
                self?.applyMenuBarPair(count: count)
            }
            indicator.systemState.rescheduleScan()
            if slidePollTimer == nil {
                let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    self?.pollSlideState()
                }
                RunLoop.main.add(t, forMode: .common)
                slidePollTimer = t
            }
        } else {
            indicator.systemState.onMenuBarWindowCount = nil
            indicator.systemState.rescheduleScan()
            slidePollTimer?.invalidate(); slidePollTimer = nil
            slidingDisplays.removeAll()
            slidingDisplayStartedAt.removeAll()
            ignoredAnimatingDisplays.removeAll()
            // Nothing feeds applyMenuBarPair() any more, so a true left here can
            // never be cleared — and it gates the corner watchdog.
            menuBarPairActive = false
        }
    }

    private func pollSlideState() {
        let now = ProcessInfo.processInfo.systemUptime
        if Self.slideDebugEnabled {
            slideTicks += 1
            if now - slideHeartbeatAt > 30 {
                slideHeartbeatAt = now
                slideLog("heartbeat ticks=\(slideTicks) mc=\(indicator.isMissionControl) pair=\(menuBarPairActive) lastCount=\(lastScanCount) windows=\(cornerWindows.count)")
                slideTicks = 0
            }
        }

        // MC's own transitions also animate; the MC exit path handles those.
        // No menu-bar/fullscreen guards here: both signals are transient at
        // slide start, and the fullscreen paths self-heal (the shared grow
        // timer and the hidden→shown top transition both converge to full).
        if indicator.isMissionControl {
            slidingDisplays.removeAll()
            slidingDisplayStartedAt.removeAll()
            ignoredAnimatingDisplays.removeAll()
            lastActiveSpace = SpaceWatcher.activeSpaceID()
            return
        }

        // Once Split View is detected, follow its live window bounds at 20 Hz.
        // That is frequent enough to catch divider dragging without making the
        // heavier CGS/window-list read part of every 30 Hz slide-poll tick.
        if splitViewPanePollingActive, now - lastSplitViewPanePollAt >= 0.05 {
            lastSplitViewPanePollAt = now
            refreshSplitViewPaneFrames()
        }

        // Active-space flip: the only begin signal that fires for transitions
        // to/from fullscreen-app spaces (IsAnimating stays false there). If the
        // flip trails the landing notification, the transition is already over
        // — hiding then would strand the corners hidden, so skip.
        let active = SpaceWatcher.activeSpaceID()
        if lastActiveSpace == 0 { lastActiveSpace = active }
        if active != lastActiveSpace {
            let isSpaceSwitch = SpaceWatcher.isSameDisplaySpaceSwitch(from: lastActiveSpace, to: active)
            lastActiveSpace = active
            // Suppress when another begin path already handled this switch:
            // for desktop↔desktop slides the flip lands ~5ms after the slide
            // ends and would re-hide the freshly growing corners. A pair state
            // older than 4s is stale (no slide lasts that long) — don't let it
            // keep suppressing this backup path.
            if isSpaceSwitch,
               now - lastSpaceNotificationAt > 0.3,
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
            if !sliding {
                ignoredAnimatingDisplays.remove(uuid)
                slidingDisplayStartedAt.removeValue(forKey: uuid)
                if slidingDisplays.remove(uuid) != nil {
                    lastAnimatingEndAt = now
                    win.spaceSlideEnded()
                }
            } else if !ignoredAnimatingDisplays.contains(uuid) {
                if slidingDisplays.insert(uuid).inserted {
                    slidingDisplayStartedAt[uuid] = now
                    win.spaceSlideBegan()
                } else if let startedAt = slidingDisplayStartedAt[uuid],
                          now - startedAt > Self.maximumSlideDuration {
                    slidingDisplays.remove(uuid)
                    slidingDisplayStartedAt.removeValue(forKey: uuid)
                    ignoredAnimatingDisplays.insert(uuid)
                    lastAnimatingEndAt = now
                    slideLog("end(stale-animation) uuid=\(uuid)")
                    win.spaceSlideEnded()
                }
            }
        }

        // A display unplugged mid-slide loses its window before the "stopped
        // animating" edge arrives, so its UUID would sit here forever — gating the
        // corner watchdog, keeping slideInProgressProvider true (which defeats
        // SystemState's idle gate and pins the scan at 30 Hz), and suppressing the
        // active-flip backup path. Keep only UUIDs we still have a window for.
        let liveDisplayUUIDs = Set(cornerWindows.compactMap(\.displayUUID))
        slidingDisplays.formIntersection(liveDisplayUUIDs)
        ignoredAnimatingDisplays.formIntersection(liveDisplayUUIDs)
        slidingDisplayStartedAt = slidingDisplayStartedAt.filter {
            liveDisplayUUIDs.contains($0.key)
        }
    }

    // MARK: - Mission Control

    /// systemUptime at which the current MC top-corner hide began, 0 when not hiding.
    private var topHiddenSince: TimeInterval = 0
    /// Set once the ceiling fires, so the hide is not immediately re-applied.
    /// Cleared when isMissionControl goes false — i.e. when the reading recovers.
    private var mcHideCeilingHit = false
    /// No real Mission Control session justifies hiding the corners this long.
    private static let mcHideCeilingSec: TimeInterval = 30

    /// Drives both top-corner inputs for every window:
    ///
    /// - **Mission Control** hides the under-menu-bar top corners, so leaving MC
    ///   produces a hidden→shown transition the corner view grows in.
    /// - **Fullscreen-only mode** hides them on a desktop space and brings them
    ///   back when that display enters a fullscreen space — the same hidden→shown
    ///   transition, so the grow-in comes free.
    ///
    /// Fullscreen is read per display from the CGS space type or SP8CE's page
    /// fullscreen signal. `SystemState.isFullscreen` is global to the frontmost
    /// app and would round the corners on other displays too.
    private func applyCornerWindowTopState() {
        let mc = indicator.isMissionControl
        if mc {
            if topHiddenSince == 0 { topHiddenSince = ProcessInfo.processInfo.systemUptime }
        } else {
            topHiddenSince = 0
            mcHideCeilingHit = false
        }
        let hideTop = mc && !mcHideCeilingHit
        // nil = CGS unreadable. Treat that as "fullscreen" so a failed read shows
        // the corners; the opposite default would silently delete the feature.
        let fsDisplays = SpaceWatcher.fullscreenDisplayUUIDs()
        for win in cornerWindows {
            let uuid = win.displayUUID ?? "_default"
            let isBuiltin = win.targetScreen.isBuiltin
            let underBar = isBuiltin
                ? settings.topCornersUnderMenuBar
                : settings.extTopCornersUnderMenuBar(for: uuid)
            let fullscreenOnly = isBuiltin
                ? settings.topCornersFullscreenOnly
                : settings.extTopCornersFullscreenOnly(for: uuid)
            // Fail open in both unknown cases — CGS unreadable, or a display whose
            // UUID won't resolve — so the corners show rather than silently vanish.
            let nativeFullscreen = fsDisplays.map { set in
                win.displayUUID.map(set.contains) ?? true
            } ?? true
            let pageFullscreen = SystemState.pageFullscreenDisplay.map {
                $0 == win.displayUUID
            } ?? false
            let isFullscreen = nativeFullscreen || pageFullscreen
            win.setSkipTop((hideTop && underBar) || (fullscreenOnly && !isFullscreen))
        }
        refreshSplitViewPaneFrames()
    }

    private func refreshSplitViewPaneFrames() {
        guard let splitViewPanes = SpaceWatcher.splitViewPaneFramesByDisplay() else { return }
        splitViewPanePollingActive = !splitViewPanes.isEmpty
        let primaryMouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        for win in cornerWindows {
            let uuid = win.displayUUID ?? "_default"
            win.setSplitViewPaneFrames(splitViewPanes[uuid] ?? [])
            win.updateSplitViewResizeInteraction(primaryMouseDown: primaryMouseDown)
        }
    }

    /// `isMissionControl` can latch true (see MissionControlDetector: an unnamed
    /// positive-layer WindowManager window is indistinguishable from MC without
    /// Screen Recording). A latched reading hides the top corners for good, so
    /// give the hide a ceiling: worst case the corners paint over a genuinely
    /// open Mission Control, which is cosmetic and self-correcting on exit.
    private func releaseStuckTopHideIfNeeded() {
        guard indicator.isMissionControl, !mcHideCeilingHit, topHiddenSince > 0 else { return }
        guard ProcessInfo.processInfo.systemUptime - topHiddenSince > Self.mcHideCeilingSec else { return }
        mcHideCeilingHit = true
        applyCornerWindowTopState()   // un-skips → hidden→shown → normal grow-in
    }

    // MARK: - Corner windows

    /// Re-establish a clean overlay state after display wake, unlock, or fast
    /// user switching. Those transitions can invalidate NSScreen objects and
    /// strand private WindowServer animation flags without delivering an end
    /// edge. All callers land here and are coalesced into one settled rebuild.
    private func scheduleCornerRecovery() {
        wakeRebuildItem?.cancel()
        slidingDisplays.removeAll()
        slidingDisplayStartedAt.removeAll()
        ignoredAnimatingDisplays.removeAll()
        menuBarPairActive = false
        for win in cornerWindows { win.spaceSlideEnded() }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastActiveSpace = SpaceWatcher.activeSpaceID()
            self.rebuildCornerWindows()
        }
        wakeRebuildItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    /// True when every corner window still maps to the live screen at its index.
    /// NSScreen objects are invalidated by display reconfiguration and sleep/wake;
    /// a window holding a dead one reports frame .zero and paints nothing, and the
    /// frame-vs-frame test in redrawCornerWindows() cannot see that.
    private func cornerWindowsMatchScreens() -> Bool {
        let live = NSScreen.screens
        guard cornerWindows.count == live.count else { return false }
        for (win, screen) in zip(cornerWindows, live) {
            guard win.targetScreen.frame.width > 0,
                  win.targetScreen.frame == screen.frame,
                  win.displayUUID == screen.uuid else { return false }
        }
        return true
    }

    private func rebuildCornerWindows() {
        for win in cornerWindows { win.orderOverlaysOut() }
        cornerWindows.removeAll()
        guard settings.cornersEnabled else { return }
        for screen in NSScreen.screens {
            let win = CornerWindow(screen: screen, settings: settings)
            win.setFrame(screen.frame, display: false)
            win.orderOverlaysFront()
            win.redraw()
            cornerWindows.append(win)
        }
        applyCornerWindowTopState()
    }

    private func redrawCornerWindows() {
        guard settings.cornersEnabled else { return }
        guard cornerWindowsMatchScreens(),
              cornerWindows.map(\.frame) == NSScreen.screens.map(\.frame) else {
            rebuildCornerWindows()
            return
        }
        for win in cornerWindows {
            win.updateFrame()
            win.orderOverlaysFront()
            win.redraw()
        }
        applyCornerWindowTopState()
    }

    // MARK: - Corner watchdog

    /// 0.5 s arrangement-poll ticks since the last watchdog pass (→ ~2 s period).
    private var cornerWatchdogTick = 0

    /// Everything in Cornermizer is edge-triggered, so a missed edge stays wrong
    /// until relaunch. This is the only thing that re-checks: it re-asserts window
    /// ordering, rebuilds on a stale screen identity (C2), releases a stuck MC
    /// top-corner hide (C4), and heals a stranded grow (C3).
    private func cornerWatchdog() {
        // C4 runs first — it is the one check that must happen *during* MC.
        releaseStuckTopHideIfNeeded()

        guard settings.cornersEnabled, !cornerWindows.isEmpty else { return }
        // Never contend with WindowServer mid-animation: MC owns the screen, and a
        // slide in flight is deliberately showing hidden corners.
        // A pair older than 4 s is stale — no slide lasts that long — and must not
        // keep the watchdog gated (see the same rule in pollSlideState).
        // Same for Mission Control: `mcHideCeilingHit` means the reading has been
        // true past the ceiling, i.e. it is not trustworthy — never let a latched
        // MC reading switch off the one thing that heals every other latch.
        let pairFresh = menuBarPairActive
            && ProcessInfo.processInfo.systemUptime - menuBarPairSince <= 4
        let mcTrusted = indicator.isMissionControl && !mcHideCeilingHit
        guard !mcTrusted, !pairFresh, slidingDisplays.isEmpty else { return }

        // C2: a window holding a dead NSScreen paints nothing — rebuild instead.
        guard cornerWindowsMatchScreens() else {
            rebuildCornerWindows()
            return
        }

        for win in cornerWindows {
            // Unconditional: a foreign window sitting *above* ours leaves both
            // `isVisible` and `level` untouched, so there is nothing to test.
            win.healOverlayOrdering()
            win.healStrandedGrow()   // C3
        }

        // Heal a missed fullscreen edge (e.g. the space changed while Mission
        // Control was up, so the activeSpaceDidChange observer skipped it). One
        // CGS read at 0.086 ms, and setSkipTop only repaints on a real change.
        applyCornerWindowTopState()
    }

    // MARK: - Screen arrangement

    private func startArrangementPolling() {
        guard arrangementPollSource == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.checkScreenArrangement() }
        t.resume()
        arrangementPollSource = t
    }

    private var displayHealItem: DispatchWorkItem?

    // Debounced: plugging a monitor in emits a burst of screen-parameter changes and
    // the panel reads as inactive mid-negotiation, so healing on the first one would
    // fight macOS while it is still bringing the display up.
    private func scheduleDisplayHeal() {
        displayHealItem?.cancel()
        let item = DispatchWorkItem { DisplaplacerEngine.healStuckDisplays() }
        displayHealItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
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

        cornerWatchdogTick += 1
        if cornerWatchdogTick >= 4 {   // ~2 s
            cornerWatchdogTick = 0
            cornerWatchdog()
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
            
