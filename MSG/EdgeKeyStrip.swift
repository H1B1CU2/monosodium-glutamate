import AppKit
import CoreAudio
import QuartzCore
import SwiftUI

// MARK: - Mode

/// Which of the two edge presentations answers a function-row key.
enum EdgeKeys {
    static var mode: EdgeKeysMode { AppSettings.shared.edgeKeysMode }

    /// The pop-up HUDs serve in Pop-up mode, and in Strip mode while the
    /// strip is hidden (a full-screen app), so a key press is never silent.
    static var popupsActive: Bool {
        switch mode {
        case .off:   return false
        case .popup: return true
        case .strip: return !EdgeKeyStrip.shared.isVisible
        }
    }
}

// MARK: - Pointer hit testing

struct EdgeKeyPointerWindow {
    let id: CGWindowID
    let pid: pid_t
    let bundle: String?
    let regular: Bool
    let layer: Int
    let bounds: CGRect
    let alpha: Double

    func isDockSurface(displayBounds: [CGRect]) -> Bool {
        bundle == "com.apple.dock" && layer == 20
            && displayBounds.contains { bounds.insetBy(dx: -1, dy: -1).contains($0) }
    }

    /// WindowServer lists the Dock's transparent full-display surface above normal windows.
    /// Its bounds are not the Dock's interactive hit area; use the AX hit when it is present.
    static func target(in windows: [Self], at point: CGPoint, ignoring pid: pid_t,
                       displayBounds: [CGRect], pointerOnDock: Bool) -> Self? {
        for window in windows where window.bounds.contains(point) && window.pid != pid && window.alpha > 0 {
            if window.isDockSurface(displayBounds: displayBounds) {
                if pointerOnDock { return nil }
                continue
            }
            guard window.layer == 0 else {
                if window.layer >= 20, window.regular || window.bundle == "com.apple.dock" { return nil }
                continue
            }
            if window.regular { return window }
        }
        return nil
    }
}

// MARK: - Strip

/// A Touch Bar–like strip across the built-in display's bottom edge, one
/// keycap drawn right above each physical function-row key (see
/// `FunctionRow`), so blank keycaps can take their labels from the screen.
/// Pressing a key lights its cap; brightness and volume merge their two caps
/// into a level bar, the way the Touch Bar expanded its sliders.
final class EdgeKeyStrip {
    static let shared = EdgeKeyStrip()

    private(set) var isVisible = false
    /// Fired when the height kept free for the strip changes, so tiling can
    /// lay windows out above it.
    var onReserveChanged: (() -> Void)?
    /// The hardware stats in the Touch ID spot were clicked (their rect on screen).
    var onStatsClicked: ((CGRect) -> Void)?

    private var window: NSPanel?
    private var view: EdgeKeyStripView?
    /// The strip's own SkyLight space: a window that joins every Space slides
    /// out and back in with each Space switch; one in a space above them all
    /// stays still, like the menu bar. Below the lock screen (300).
    private var space: UInt64?
    static let spaceLevel: Int32 = 100
    private weak var music: MusicMonitor?
    private var touchIDPrompt = false
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private var started = false
    private var lastReserve: CGFloat = 0
    private var recheck: DispatchWorkItem?
    /// After a play/pause press, the player's old state is not believed for a moment.
    private var playingExpectation: (playing: Bool, until: CFTimeInterval)?
    /// Switches the focused display to Desktop n (wired to tiling).
    var onSwitchDesktop: ((Int) -> Void)?

    // Second row: shown while the layer modifier is held on its own.
    /// The modifier is down with no other modifier.
    private var layerHeld = false
    /// A shortcut (⌘C…) was typed during this hold: not a layer hold.
    private var layerSuppressed = false
    private var layerShown = false
    /// Tapped up in full screen: stays until tapped again or full screen ends.
    private var shownInFullscreen = false
    /// Tapped away on the desktop: stays away, and gives its space back to
    /// the windows, until tapped again.
    private var hiddenByTap = false
    private var layerShowWork: DispatchWorkItem?
    /// Keys whose press ran a second-row action; their releases are taken too.
    private var takenKeyCodes: [UInt16: EdgeKeyAction] = [:]
    private var takenAuxCodes: [Int: EdgeKeyAction] = [:]
    private var shownSecondRow: [Int: EdgeKeyAction] = [:]
    private var shownFirstRow: [Int: EdgeKeyAction]?
    private var shownTrigger = ""
    private var amphetamineActive: Bool?
    private var amphetaminePoll: Timer?
    private var amphetamineQueryInFlight = false
    private var warpPoll: Timer?
    private var microphoneState: (exists: Bool, muted: Bool, inUse: Bool) = (false, false, false)
    private var microphonePoll: Timer?
    private var audioInputSnapshot = AudioDeviceRouting.Snapshot(devices: [], selectedUID: nil)
    private var audioOutputSnapshot = AudioDeviceRouting.Snapshot(devices: [], selectedUID: nil)
    private var audioRoutePoll: Timer?
    private var audioChooser: (direction: AudioDeviceRouting.Direction, page: Int,
                               timeout: DispatchWorkItem)?

    private init() {}

    func start(music: MusicMonitor) {
        guard !started else { return }
        started = true
        self.music = music
        EdgeKeyActions.isPlaying = { [weak music] in music?.isPlaying ?? false }
        EdgeKeyActions.onAmphetamineToggled = { [weak self] in self?.refreshAmphetamineState() }
        EdgeKeyActions.onMicrophoneToggled = { [weak self] in self?.refreshMicrophoneState() }
        EdgeKeyActions.onAudioRouteChanged = { [weak self] in self?.refreshAudioRoutes() }
        CloudflareWARP.shared.onChange = { [weak self] in self?.refreshWARPView() }
        CloudflareWARP.shared.onToggleFailure = { message in
            let alert = NSAlert()
            alert.messageText = "Cloudflare WARP"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        music.addObserver { [weak self] in
            DispatchQueue.main.async { self?.syncPlaying() }
        }
        MusicEdgeHUD.shared.onState = { [weak self] state in
            // Once the player list is available it owns the strip's artwork.
            // MusicEdgeHUD reads a separate Now Playing snapshot, which can
            // briefly contain only a generic WebKit/app icon on play/pause.
            guard let self, !self.playersKnown, self.selectedSource == nil else { return }
            self.view?.updateMedia(state)
        }
        WeatherMonitor.shared.start()
        WeatherMonitor.shared.addObserver { [weak self] in
            DispatchQueue.main.async {
                self?.view?.updateWeather(WeatherMonitor.shared.currentWeather)
            }
        }
        // The next event or reminder, for the esc-spot widget.
        CalendarFeed.shared.addObserver { [weak self] in self?.view?.updateCalendar() }
        // AI usage from TokenBar, for the esc-spot widget.
        AIUsageFeed.shared.start()
        AIUsageFeed.shared.addObserver { [weak self] snapshot in self?.view?.updateUsage(snapshot) }
        PresentationState.shared.addObserver { [weak self] in self?.updateUsageWatching() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                EdgeKeyAppKeys.resetDiaSearchState()
                self?.scheduleUpdate()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Only the built-in panel's own changes rebuild the strip (size,
            // Align Keyboard); an external display coming or going mustn't
            // reset it mid-hold — that dropped the second row.
            self?.update()
        }
        NotificationCenter.default.addObserver(forName: SystemState.touchIDPromptChanged,
                                               object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.touchIDPrompt = note.userInfo?["visible"] as? Bool ?? false
            self.view?.setTouchIDPrompt(self.touchIDPrompt)
        }
        // Preview the full-screen slide without a full-screen app: sinks,
        // then rises again, e.g. from a script or the terminal.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("H1D3S1GN.MSG.previewEdgeKeysSlide"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.hide(animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.update() }
        }
        // Preview the left widget's side swipe (music → weather → calendar → AI usage), e.g. from a script or the terminal.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("H1D3S1GN.MSG.previewLeftWidgetSwipe"), object: nil, queue: .main
        ) { [weak self] note in
            self?.view?.switchLeftWidget(forward: (note.object as? String) != "back")
        }
        // Preview the Touch ID prompt look on the strip for three seconds.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("H1D3S1GN.MSG.previewEdgeKeysTouchID"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.view?.setTouchIDPrompt(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self else { return }
                self.view?.setTouchIDPrompt(self.touchIDPrompt)
            }
        }
        // While SP8CE's window is out of sight, the player shows its video: SP8CE
        // reports what plays (and again every few seconds), the player makes
        // room, and SP8CE draws the live video over that slot from a window of
        // its own. Objects carry JSON text: SP8CE is sandboxed and can't send userInfo.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sp8ce.pip.state"), object: nil, queue: .main
        ) { [weak self] note in
            self?.receiveVideo(note.object as? String)
        }
        workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                              queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Self.sp8ceBundleID {
                self?.receiveVideo(nil)
                if Self.sp8ceFullscreenDisplay != nil {
                    SystemState.setPageFullscreen(display: nil)
                    self?.update()
                }
            }
        }
        // SP8CE's page full screen covers a display without a full screen Space of its own, so
        // it says so: {"on": true, "display": "<UUID>"} or {"on": false}.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.sp8ce.pageFullscreen"), object: nil, queue: .main
        ) { [weak self] note in
            let object = (note.object as? String)?.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let display = object?["on"] as? Bool == true ? object?["display"] as? String : nil
            SystemState.setPageFullscreen(display: display)
            self?.update()
        }
        // It counts only on the Space it went full screen on: switching away brings the strip back.
        NotificationCenter.default.addObserver(forName: SystemState.pageFullscreenChanged, object: nil,
                                               queue: .main) { [weak self] _ in self?.update() }
        // An app's menu reaching down over the strip would open under it
        // (the strip's space sits above every Space): drop below menus meanwhile.
        for name in ["com.apple.HIToolbox.beginMenuTrackingNotification",
                     "com.apple.HIToolbox.endMenuTrackingNotification"] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil,
                                                                queue: .main) { [weak self] _ in
                self?.watchMenus()
            }
        }
        // MSG's own menus (Settings pickers) too.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.watchMenus() }
        EdgeKeyAppKeys.shared.onMenusRead = { [weak self] pid in self?.refreshAppKeys(pid: pid) }
        update()
    }

    // MARK: SP8CE's video

    private static let sp8ceBundleID = "com.kite.Kite"
    /// What SP8CE plays while it floats its video in the player.
    private var hostedVideo: EdgeVideo?

    private func receiveVideo(_ text: String?) {
        // Off in Settings: nowhere to draw, so SP8CE keeps its video in its window.
        let video = AppSettings.shared.edgeKeysSP8CEVideo ? text.flatMap(EdgeVideo.init(json:)) : nil
        guard video != nil || hostedVideo != nil else { return }
        hostedVideo = video
        view?.setVideo(video)
        // Answered either way: with no video, SP8CE takes down whatever it still shows.
        postVideoSlot(always: true)
    }

    /// Tells SP8CE where to draw its video (the slot in screen points, and its
    /// corner radius), or that there's nowhere to draw it right now.
    private func postVideoSlot(always: Bool = false) {
        guard hostedVideo != nil || always else { return }
        var text = "{\"visible\":false}"
        if isVisible, let window, let (rect, radius) = view?.videoSlotRect() {
            let r = window.convertToScreen(rect)
            text = String(format: "{\"visible\":true,\"x\":%.2f,\"y\":%.2f,\"w\":%.2f,\"h\":%.2f,\"radius\":%.2f}",
                          r.minX, r.minY, r.width, r.height, radius)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.msg.edgekeys.videoSlot"), object: text, userInfo: nil, deliverImmediately: true)
    }

    /// The menu bar's hardware stats live where the Touch ID key would be.
    static var statsInTouchID: Bool {
        let s = AppSettings.shared
        return s.edgeKeysStatsInTouchID && !s.edgeKeysShowTouchID && EdgeKeys.mode == .strip
            && s.hardwareStatsEnabled
    }

    /// The stats modules as the menu bar draws them; nil takes them off the strip.
    func showStats(_ images: [NSImage]?) {
        view?.setStats(images)
    }

    /// The player specifically lives where esc would be: esc key off, player in esc setting on.
    static var playerInEsc: Bool {
        let s = AppSettings.shared
        return !s.edgeKeysShowEsc && s.edgeKeysPlayerInEsc
    }

    /// The esc spot hosts a widget (player, weather, or AI usage).
    static var leftWidgetInEsc: Bool {
        let s = AppSettings.shared
        return !s.edgeKeysShowEsc && (s.edgeKeysPlayerInEsc || s.edgeKeysWeatherInEsc
                                      || s.edgeKeysCalendarInEsc || s.edgeKeysUsageInEsc)
    }

    /// The display SP8CE's page full screen covers, if any (kept with the system state, which counts
    /// it as full screen for the rest of MSG too).
    private static var sp8ceFullscreenDisplay: String? { SystemState.pageFullscreenDisplay }

    /// A full screen app on the display: its own Space, or SP8CE's page full screen.
    private static func isFullscreen(_ uuid: String) -> Bool {
        uuid == sp8ceFullscreenDisplay || SpaceWatcher.fullscreenDisplayUUIDs()?.contains(uuid) == true
    }

    private static var builtinIsFullscreen: Bool {
        guard let uuid = NSScreen.screens.first(where: \.isBuiltin)?.uuid else { return false }
        return isFullscreen(uuid)
    }

    /// The strip's height: the menu bar's, or the one chosen in Settings.
    static func height(for screen: NSScreen) -> CGFloat {
        let settings = AppSettings.shared
        guard settings.edgeKeysStripMatchMenuBar else { return CGFloat(settings.edgeKeysStripHeight).rounded() }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return max(24, bar, screen.safeAreaInsets.top).rounded()
    }

    /// Space kept free at the bottom of `screen` for the strip.
    func reservedHeight(on screen: NSScreen) -> CGFloat {
        guard EdgeKeys.mode == .strip, screen.isBuiltin, !hiddenByTap else { return 0 }
        return Self.height(for: screen) + EdgeKeyStripView.backgroundTopExtension
    }

    /// Space and app switches settle a moment after the notification; check
    /// again once they have, so a full-screen app is seen.
    private func scheduleUpdate() {
        update()
        recheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        recheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func update(rebuild: Bool = false) {
        let settings = AppSettings.shared
        RightShiftRemap.set(EdgeKeys.mode == .strip && settings.edgeKeysLayerModifier == .rightShift
                            && settings.edgeKeysRightShiftExclusive)
        let screen = NSScreen.screens.first(where: \.isBuiltin)
        let reserve = screen.map(reservedHeight(on:)) ?? 0
        let baseHeight = screen.map { Self.height(for: $0) } ?? 0
        if reserve != lastReserve {
            lastReserve = reserve
            onReserveChanged?()
        }
        guard EdgeKeys.mode == .strip, let screen else {
            stopKeyMonitor()
            updatePointerMonitor()
            hide(animated: false)
            discard()
            return
        }
        startKeyMonitor()
        updatePointerMonitor()
        // Full screen hides the strip — unless the second-row modifier is
        // held, which peeks it up until released.
        let fullscreen = screen.uuid.map(Self.isFullscreen) ?? false
        if !fullscreen { shownInFullscreen = false }
        let hiddenHere = fullscreen
            ? AppSettings.shared.edgeKeysHideInFullscreen && !shownInFullscreen
            : hiddenByTap
        if hiddenHere, !layerShown {
            hide(animated: true)
            return
        }
        let rounded = true
        let r = screen.uuid.map { uuid in
            screen.isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
        } ?? settings.cornerRadius
        let curve = screen.uuid.map { uuid in
            screen.isBuiltin ? settings.cornerCurve : settings.extCornerCurve(for: uuid)
        } ?? settings.cornerCurve
        let reach: CGFloat = (rounded && r > 0) ? CornerGeometry.reach(for: r, curve: curve) : 0
        let totalHeight = reserve + reach
        let frame = CGRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: screen.frame.width, height: totalHeight)
        let signature = Self.layoutSignature(width: frame.width, stripHeight: baseHeight,
                                             scale: screen.backingScaleFactor)
        if rebuild || view?.layoutSignature != signature {
            discard()
        }
        if window == nil {
            build(frame: frame, stripHeight: baseHeight, radius: r, curve: curve, roundedCorners: rounded, scale: screen.backingScaleFactor)
        } else {
            if window?.frame != frame { window?.setFrame(frame, display: false) }
            view?.updateFillets(stripHeight: baseHeight, radius: r, curve: curve, roundedCorners: rounded)
        }
        let firstRow = effectiveFirstRow()
        if firstRow != shownFirstRow {
            shownFirstRow = firstRow
            view?.setFirstRow(firstRow)
            syncPlaying()
        }
        let secondRow = AppSettings.shared.edgeKeysSecondRow
        if secondRow != shownSecondRow {
            shownSecondRow = secondRow
            view?.setSecondRow(secondRow)
        }
        // The trigger key's ⌘ glyph follows the trigger settings.
        let settingsNow = AppSettings.shared
        let trigger = "\(settingsNow.edgeKeysLayerModifier.rawValue)-\(settingsNow.edgeKeysTriggerKey)-\(settingsNow.edgeKeysTriggerTapActs)"
        if trigger != shownTrigger {
            shownTrigger = trigger
            view?.setFirstRow(firstRow)
            view?.setSecondRow(secondRow)
        }
        refreshDisplayStates()
        view?.setAmphetamineActive(amphetamineActive)
        refreshWARPView()
        refreshMicrophoneState()
        updateAudioRoutePolling()
        view?.setPlayerEnabled(AppSettings.shared.edgeKeysMediaPlayer || Self.playerInEsc)
        view?.setPlayerInEsc(Self.leftWidgetInEsc)
        view?.setPinnedPlayer((AppSettings.shared.edgeKeysMediaPlayer && AppSettings.shared.edgeKeysPinnedPlayer)
                              || Self.playerInEsc)
        if !AppSettings.shared.edgeKeysSP8CEVideo, hostedVideo != nil {
            hostedVideo = nil
            postVideoSlot(always: true)
        }
        view?.setVideo(hostedVideo)
        view?.updateWeather(WeatherMonitor.shared.currentWeather)
        view?.updateUsage(AIUsageFeed.shared.snapshot, reevaluate: false)
        view?.updateCalendar(reevaluate: false)
        view?.updateLeftWidget()
        updateMediaPolling()
        guard !isVisible else {
            updateAmphetaminePolling()
            updateWARPPolling()
            updateMicrophonePolling()
            updateAudioRoutePolling()
            updateExtrasPolling()
            updateUsageWatching()
            postVideoSlot()
            return
        }
        isVisible = true
        updateAmphetaminePolling()
        updateWARPPolling()
        updateMicrophonePolling()
        updateAudioRoutePolling()
        updateExtrasPolling()
        updateUsageWatching()
        syncPlaying()
        view?.prepareShow()
        window?.alphaValue = 1
        if let space { SkyLightSpace.setShown(space, true) } else { window?.orderFrontRegardless() }
        view?.playShow()
        KeyEdgeHUD.shared.dismissAll(animated: true)
        // A pinned player showed before the strip counted as visible.
        updateMediaPolling()
        postVideoSlot()
    }

    /// The geometry the caps were laid out with; display size, scale, strip height
    /// and Align Keyboard changes recreate every cap and widget together. Merely
    /// moving a display or changing its corner fillets keeps the existing view.
    private static func layoutSignature(width: CGFloat, stripHeight: CGFloat, scale: CGFloat) -> [CGFloat] {
        [width, stripHeight, scale,
         FunctionRow.left, FunctionRow.right, FunctionRow.escUnits, FunctionRow.faceRatio,
         CGFloat(EdgeKeysKeyPlacement.allCases.firstIndex(of: AppSettings.shared.edgeKeysKeyPlacement) ?? 0),
         AppSettings.shared.edgeKeysShowEsc ? 1 : 0, AppSettings.shared.edgeKeysShowTouchID ? 1 : 0]
    }

    private func build(frame: CGRect, stripHeight: CGFloat, radius: CGFloat, curve: CornerCurve, roundedCorners: Bool, scale: CGFloat) {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Clear, so the strip can slide in and out of it.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the Dock, below the pop-up HUDs and the lock screen.
        panel.level = .statusBar
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        let view = EdgeKeyStripView(frame: CGRect(origin: .zero, size: frame.size),
                                   stripHeight: stripHeight,
                                   radius: radius,
                                   curve: curve,
                                   roundedCorners: roundedCorners,
                                   scale: scale)
        view.layoutSignature = Self.layoutSignature(width: frame.width, stripHeight: stripHeight, scale: scale)
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        space = SkyLightSpace.present(panel, level: Self.spaceLevel)
        loweredForMenu = false
        if space == nil { panel.collectionBehavior.insert(.canJoinAllSpaces) }
        window = panel
        self.view = view
        shownSecondRow = [:]
        shownFirstRow = nil
        shownTrigger = ""
        view.setTouchIDPrompt(touchIDPrompt)
        view.onMediaShown = { [weak self] in self?.updateMediaPolling() }
        view.onAudioChooserKey = { [weak self] key in self?.chooseAudioDevice(key: key) }
        view.onStatsClick = { [weak self] rect in self?.onStatsClicked?(rect) }
        view.onMediaGesture = { [weak self] gesture in
            guard let self else { return }
            switch gesture {
            case .playPause: self.playPause()
            case .skip(let forward): _ = self.mediaControl(forward ? .next : .previous, physical: false)
            case .source(let forward): self.cycleSource(forward: forward)
            }
        }
        if layerShown { view.showSecondRow(true, modifier: AppSettings.shared.edgeKeysLayerModifier) }
        busyKeys.forEach { view.setBusy($0.key, secondRow: $0.value) }
        isVisible = false
    }

    private func hide(animated: Bool) {
        guard isVisible, let window else { return }
        isVisible = false
        postVideoSlot()
        stopAmphetaminePolling()
        stopWARPPolling()
        stopMicrophonePolling()
        stopAudioRoutePolling()
        stopExtrasPolling()
        updateUsageWatching()
        cancelAudioChooser()
        guard animated, let view else { conceal(window); return }
        view.playHide { [weak self, weak window] in
            // Shown again before the slide finished.
            guard let self, !self.isVisible, let window else { return }
            self.conceal(window)
        }
    }

    /// Hides the space rather than ordering the window out, which would
    /// bring it back on an ordinary Space next time.
    private func conceal(_ window: NSWindow) {
        window.alphaValue = 0
        if let space { SkyLightSpace.setShown(space, false) } else { window.orderOut(nil) }
    }

    private func discard() {
        stopAmphetaminePolling()
        stopWARPPolling()
        stopMicrophonePolling()
        stopAudioRoutePolling()
        stopExtrasPolling()
        cancelAudioChooser()
        if let space { SkyLightSpace.dismiss(space) }
        space = nil
        window?.orderOut(nil)
        window = nil
        view?.setLeftWidgetTicking(false)
        view = nil
        isVisible = false
        updateUsageWatching()
        postVideoSlot()
    }

    // MARK: Keys

    /// A hardware aux key went down (NX key codes, see SystemHUDMonitor).
    /// `posted`: sent by an Edge Keys action, whose own key already lit up.
    func auxKeyDown(_ code: Int, posted: Bool) {
        guard isVisible, let key = Self.functionKey(forAux: code) else { return }
        // Previous, play/pause, next: their keys turn into the player. A skip
        // the player can't do (a lone video) doesn't swipe — nothing changes.
        if [16, 17, 18, 19, 20].contains(code) {
            let forward = code == 17 || code == 19
            if code != 16, canSkip(forward: forward) {
                view?.swipeMedia(forward: forward)
            } else {
                view?.revealMedia()
            }
        }
        if !posted { view?.flash(key: key) }
        if code == 16 {
            let now = music?.isPlaying ?? false
            let expected = !(playingExpectation.map { CACurrentMediaTime() < $0.until ? $0.playing : now } ?? now)
            playingExpectation = (expected, CACurrentMediaTime() + 1.2)
            view?.setPlaying(expected)
        }
    }

    /// The F key (1…12) an aux key code comes from.
    private static func functionKey(forAux code: Int) -> Int? {
        switch code {
        case 3:  return 1    // brightness down
        case 2:  return 2    // brightness up
        case 18, 20: return 7  // previous / rewind
        case 16: return 8    // play/pause
        case 17, 19: return 9  // next / fast forward
        case 7:  return 10   // mute
        case 1:  return 11   // volume down
        case 0:  return 12   // volume up
        case 6:  return 13   // power (the Touch ID key)
        default: return nil
        }
    }

    /// Brightness, volume and media keys run their second-row action while
    /// the layer modifier is held, and their first-row one when it's been
    /// reassigned (see SystemHUDMonitor).
    // MARK: Volume chord

    /// Volume keys (aux 0 up, 1 down) physically held right now.
    private var heldVolumeKeys: Set<Int> = []
    /// Both were down together: that was a mute, not a volume change.
    private var volumeChord = false
    private var mutedBeforeChord = false

    /// The default output's mute switch.
    private static func outputMuted() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return false }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Down and up pressed together mute (or unmute). The first key already
    /// stepped the volume; that step is taken back before muting. Nil lets
    /// the key go on to its usual handling.
    private func volumeChordKey(code: Int, isDown: Bool, isRepeat: Bool) -> Bool? {
        guard code == 0 || code == 1, !layerHeld else { return nil }
        if !isDown {
            heldVolumeKeys.remove(code)
            if volumeChord {
                if heldVolumeKeys.isEmpty { volumeChord = false }
                takenAuxCodes.removeValue(forKey: code)
                return true
            }
            return nil
        }
        if isRepeat { return volumeChord ? true : nil }
        let other = code == 0 ? 1 : 0
        // Read before the first key reaches the system: a volume key unmutes.
        if heldVolumeKeys.isEmpty { mutedBeforeChord = Self.outputMuted() }
        heldVolumeKeys.insert(code)
        guard heldVolumeKeys.contains(other), !volumeChord else { return volumeChord ? true : nil }
        volumeChord = true
        EdgeKeyActions.postAuxKey(code)   // the opposite of the first key's step
        // Muted before: the first key has already unmuted, which is the
        // point — the chord toggles. Not muted: mute now.
        if !mutedBeforeChord { EdgeKeyActions.postAuxKey(7) }
        if let key = Self.functionKey(forAux: code), isVisible { view?.flash(key: key) }
        return true
    }

    func auxKeyOverride(code: Int, isDown: Bool, isRepeat: Bool) -> Bool {
        guard EdgeKeys.mode == .strip else { return false }
        if let handled = volumeChordKey(code: code, isDown: isDown, isRepeat: isRepeat) { return handled }
        // The layer key must receive both edges, even while a chooser is up.
        // Otherwise its release is swallowed and the second row stays latched.
        if let key = Self.functionKey(forAux: code), isTrigger(key) {
            if isDown, !isRepeat, audioChooser != nil { cancelAudioChooser() }
            triggerKey(key, isDown: isDown, isRepeat: isRepeat, replay: .aux(code))
            return true
        }
        if let key = Self.functionKey(forAux: code), audioChooser != nil, isDown, !isRepeat {
            chooseAudioDevice(key: key)
            takenAuxCodes[code] = EdgeKeyAction.none
            return true
        }
        if !isDown { return takenAuxCodes.removeValue(forKey: code) != nil }
        if let taken = takenAuxCodes[code] {
            if isRepeat { repeatIfStepping(taken) }
            return true
        }
        guard let key = Self.functionKey(forAux: code) else { return false }
        if let action = layerHeld ? runSecondRow(key: key) : runFirstRow(key: key) {
            takenAuxCodes[code] = action
            return true
        }
        guard handleMediaKey(code) else { return false }
        takenAuxCodes[code] = .keyDefault
        return true
    }

    // MARK: Media sources

    // Several apps can have a player at once (Control Center lists them all).
    // Play/pause pressed twice quickly steps the strip's player to the next
    // one; the media keys then work that one. A single press waits out the
    // double-press window (a setting, 0.15 s by default) before it plays or pauses.

    /// The app the player shows and the keys work; nil follows the system's own.
    private var selectedSource: String?
    private var pendingPlayPause: DispatchWorkItem?
    private let playersAdapter = MediaRemoteAdapter()
    private var playersKnown = false
    private var readingPlayers = false
    private var players: [MediaRemoteAdapter.Player] = []
    private var mediaPoll: Timer?
    private var artCache: [URL: NSImage] = [:]
    private var scriptArtCache: [String: NSImage] = [:]
    /// The last cover shown, and its track metadata. The same browser video can
    /// briefly move between the app and WebKit players during play/pause.
    private var lastArt: (title: String, artist: String, image: NSImage)?
    private var scriptArtPending: Set<String> = []

    /// Physical previous / play-pause / next (first row, own function).
    private func handleMediaKey(_ code: Int) -> Bool {
        guard !layerHeld else { return false }
        let control: EdgeKeyAction.Control
        switch code {
        case 16: control = .playPause
        case 17: control = .next
        case 18: control = .previous
        default: return false
        }
        if isVisible, let key = Self.functionKey(forAux: code) { view?.flash(key: key) }
        return mediaControl(control, physical: true)
    }

    /// `physical`: the real media key, which can simply go through when the
    /// system's own source is chosen; a reassigned key replays it instead.
    private func mediaControl(_ control: EdgeKeyAction.Control, physical: Bool) -> Bool {
        switch control {
        case .playPause:
            let window = AppSettings.shared.edgeKeysDoublePressWindow
            guard window > 0 else {
                // Double press off: plays or pauses at once.
                playPause()
                return true
            }
            if let pending = pendingPlayPause {
                pending.cancel()
                pendingPlayPause = nil
                cycleSource()
                return true
            }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingPlayPause = nil
                self?.playPause()
            }
            pendingPlayPause = work
            DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
            return true
        case .next, .previous:
            guard canSkip(forward: control == .next) else {
                view?.revealMedia()
                return true
            }
            guard let bundle = selectedSource else {
                // The system's own source: as the real key.
                if physical { return false }
                EdgeKeyActions.postAuxKey(control == .next ? 17 : 18)
                return true
            }
            MediaRemoteAdapter.sendCommand(control == .next ? 4 : 5, toBundle: bundle) { [weak self] reached in
                if !reached { self?.view?.nudgeMedia() }
            }
            view?.swipeMedia(forward: control == .next)
            readPlayers(after: 0.5)
            return true
        default:
            return false
        }
    }

    private func playPause() {
        let now = music?.isPlaying ?? false
        let expected = !(playingExpectation.map { CACurrentMediaTime() < $0.until ? $0.playing : now } ?? now)
        playingExpectation = (expected, CACurrentMediaTime() + 1.2)
        view?.setPlaying(expected)

        if let bundle = selectedSource {
            // Play or pause outright, never toggle: if the app won't take it
            // and the system hands it to the other player, a play there is
            // a no-op instead of stopping it.
            let playing = players.first { $0.bundle == bundle }?.nowPlaying.playing ?? false
            MediaRemoteAdapter.sendCommand(playing ? 1 : 0, toBundle: bundle) { [weak self] reached in
                if !reached { self?.view?.nudgeMedia() }
            }
            view?.revealMedia()
            readPlayers(after: 0.35)
        } else {
            // Replayed as the real key: the system, the HUD and Music routing
            // take it from here exactly as before.
            EdgeKeyActions.postAuxKey(16)
        }
    }

    /// Next player along, wrapping round; back to following the system when
    /// it comes to the system's own.
    private func cycleSource(forward: Bool = true) {
        view?.revealMedia()
        readPlayers(slide: true) { [weak self] players in
            guard let self, players.count > 1 else { return false }
            let current = self.selectedSource ?? players.first(where: \.active)?.bundle
            let index = players.firstIndex { $0.bundle == current } ?? (forward ? -1 : 0)
            let next = players[(index + (forward ? 1 : players.count - 1)) % players.count]
            self.selectedSource = next.active ? nil : next.bundle
            return true
        }
    }

    /// `then` may pick another player first; returning true slides it in.
    private func readPlayers(after delay: TimeInterval = 0, slide: Bool = false,
                             then: (([MediaRemoteAdapter.Player]) -> Bool)? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.readingPlayers || then != nil else { return }
            self.readingPlayers = true
            self.playersAdapter.queryPlayers { found in
                self.readingPlayers = false
                let players = MediaRemoteAdapter.withoutWebKitTwins(found)
                self.players = players
                self.playersKnown = true
                // No player left at all: back to plain media keys.
                self.view?.setMediaAvailable(!players.isEmpty)
                // The chosen app's player went away: follow the system again.
                if let selected = self.selectedSource, !players.contains(where: { $0.bundle == selected }) {
                    self.selectedSource = nil
                }
                let switched = then?(players) ?? false
                self.showSelectedPlayer(slide: slide && switched)
            }
        }
    }

    /// Whether the player on screen has a next (or previous) to go to.
    private func canSkip(forward: Bool) -> Bool {
        let shownBundle = selectedSource ?? players.first(where: \.active)?.bundle
        guard let player = players.first(where: { $0.bundle == shownBundle }) else { return true }
        return forward ? player.canSkipForward : player.canSkipBack
    }

    /// The player on screen, from the last read of every player.
    private func showSelectedPlayer(slide: Bool) {
        guard let view else { return }
        let shownBundle = selectedSource ?? players.first(where: \.active)?.bundle
        let index = players.firstIndex { $0.bundle == shownBundle }
        let previous = view.mediaPagerIndex
        view.setMediaPager(index: index ?? 0, count: players.count)
        guard let player = index.map({ players[$0] }) else { return }
        // Down the pager: the content rises; wrapping back to the top: it drops.
        if slide { view.slideMediaSource(down: (index ?? 0) > previous) }
        view.updateMedia(state(from: player))
    }

    private func state(from player: MediaRemoteAdapter.Player) -> MusicEdgeHUD.State {
        let np = player.nowPlaying
        let app = np.pid > 0 ? NSRunningApplication(processIdentifier: np.pid) : nil
        var art = np.art
        if art == nil, let url = np.artURL {
            if let cached = artCache[url] {
                art = cached
            } else {
                URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.artCache[url] = image
                        self?.showSelectedPlayer(slide: false)
                    }
                }.resume()
            }
        }
        if art == nil, np.artURL == nil, ["com.apple.Music", "com.spotify.client"].contains(player.bundle) {
            // Now Playing sent no cover (Music often doesn't for its own
            // library): ask the app itself, once per song.
            let key = player.bundle + "|" + (np.title ?? "") + "|" + (np.artist ?? "")
            if let cached = scriptArtCache[key] {
                art = cached
            } else if !scriptArtPending.contains(key) {
                scriptArtPending.insert(key)
                MusicMonitor.scriptArtwork(bundle: player.bundle) { [weak self] image in
                    guard let self else { return }
                    self.scriptArtPending.remove(key)
                    guard let image else { return }
                    if self.scriptArtCache.count > 30 { self.scriptArtCache.removeAll() }
                    self.scriptArtCache[key] = image
                    self.showSelectedPlayer(slide: false)
                }
            }
        }
        // A read right after play or pause often comes without its artwork: for
        // the same track, keep the cover already showing instead of flicking to
        // the app's icon and back.
        let title = np.title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let artist = np.artist?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let art, !title.isEmpty {
            lastArt = (title, artist, art)
        } else if let lastArt, !title.isEmpty, lastArt.title == title,
                  (lastArt.artist.isEmpty || artist.isEmpty || lastArt.artist == artist) {
            art = lastArt.image
        }
        return MusicEdgeHUD.State(title: np.title, artist: np.artist, source: player.name ?? app?.localizedName,
                                  art: art, appIcon: MediaRemoteAdapter.applicationIcon(for: player), playing: np.playing,
                                  duration: np.duration, elapsed: np.elapsed, rate: np.rate, timestamp: np.timestamp)
    }

    /// While the player is up, read every 2 s: a song that changes by itself
    /// shows, and so does a player that comes or goes.
    /// Pinned, it keeps reading even while there's nothing to show, to bring
    /// the player back when something starts.
    private var wantsMediaPolling: Bool {
        let escMedia = Self.playerInEsc
        let keysMedia = AppSettings.shared.edgeKeysMediaPlayer && AppSettings.shared.edgeKeysPinnedPlayer
        return isVisible && (escMedia || keysMedia || view?.isMediaShown == true)
    }

    private func updateMediaPolling() {
        guard mediaPoll == nil, wantsMediaPolling else { return }
        readPlayers()
        startWatcher()
        // A backup to the watcher, which is only ever a nudge.
        mediaPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.wantsMediaPolling else {
                self.mediaPoll?.invalidate()
                self.mediaPoll = nil
                self.stopWatcher()
                return
            }
            // Nothing playing: every third tick is plenty.
            self.idleTicks = self.players.contains(where: \.nowPlaying.playing) ? 0 : self.idleTicks + 1
            guard self.idleTicks % 3 == 0 else { return }
            self.readPlayers()
        }
    }
    private var idleTicks = 0

    /// Told the moment Now Playing changes (a new video, play, pause), so the
    /// player follows at once instead of on the next backup read.
    private var watcher: Process?
    private var watchNudge: DispatchWorkItem?

    private func startWatcher() {
        guard watcher == nil else { return }
        watcher = MediaRemoteAdapter.watch { [weak self] in
            guard let self else { return }
            // A burst of changes (item, then artwork, then state): read once
            // it settles a little.
            self.watchNudge?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.readPlayers() }
            self.watchNudge = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        watcher?.terminationHandler = { [weak self] _ in
            // Gone (crashed, or stopped on purpose): bring it back while wanted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.watcher = nil
                if self.mediaPoll != nil { self.startWatcher() }
            }
        }
    }

    private func stopWatcher() {
        let process = watcher
        watcher = nil
        process?.terminationHandler = nil
        process?.terminate()
    }

    /// A held key keeps stepping brightness or volume, like the real keys.
    private func repeatIfStepping(_ action: EdgeKeyAction) {
        guard case .control(let control) = action, control.repeats else { return }
        EdgeKeyActions.run(action, switchDesktop: onSwitchDesktop)
    }

    // MARK: F key trigger

    // One F key held opens the second row, like a modifier. A quick tap —
    // let go before the row showed, nothing else pressed — can still do
    // that key's own first-row job (a setting), run on release.

    private enum TriggerReplay { case aux(Int), keyCode(UInt16) }

    private var triggerIsFunctionKey: Bool { AppSettings.shared.edgeKeysLayerModifier == .functionKey }
    private var triggerDownAt: CFTimeInterval = 0
    /// Something happened during this hold: not a tap.
    private var triggerUsed = false

    private func isTrigger(_ key: Int) -> Bool {
        triggerIsFunctionKey && key == AppSettings.shared.edgeKeysTriggerKey
    }

    private func triggerKey(_ key: Int, isDown: Bool, isRepeat: Bool, replay: TriggerReplay) {
        if isDown {
            guard !isRepeat else { return }
            triggerDownAt = CACurrentMediaTime()
            triggerUsed = false
            view?.setKeyHeld(key, true)
            setLayerHeld(true)
            return
        }
        view?.setKeyHeld(key, false)
        let wasShown = layerShown
        let held = CACurrentMediaTime() - triggerDownAt
        setLayerHeld(false)
        let tapLimit = max(AppSettings.shared.edgeKeysLayerHoldDelay, 0.25)
        // A tap puts the strip away or brings it back on its first row — in
        // full screen, where it starts hidden, and on the desktop, where it
        // starts shown. Holding still peeks the second row either way.
        if !triggerUsed, held < tapLimit {
            if Self.builtinIsFullscreen, AppSettings.shared.edgeKeysHideInFullscreen {
                shownInFullscreen.toggle()
            } else {
                hiddenByTap.toggle()
            }
            update()
            return
        }
        guard AppSettings.shared.edgeKeysTriggerTapActs, !triggerUsed, !wasShown || held < tapLimit,
              held < tapLimit else { return }
        // A tap: the key's own first-row action, or its own function.
        if isVisible { view?.flash(key: key) }
        guard runFirstRow(key: key) == nil else { return }
        switch replay {
        case .aux(let code):
            EdgeKeyActions.postAuxKey(code)
        case .keyCode(let code):
            // Posted by MSG, so the key tap lets it through to the system.
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    /// Runs F`key`'s reassigned first-row action; nil when it keeps its own.
    private func runFirstRow(key: Int) -> EdgeKeyAction? {
        let action = effectiveFirstRow()[key] ?? .keyDefault
        guard action != .keyDefault else { return nil }
        if isVisible, action != .none { view?.flash(key: key) }
        perform(action, key: key, secondRow: false)
        return action
    }

    /// Runs F`key`'s second-row action; nil when it has none.
    private func runSecondRow(key: Int) -> EdgeKeyAction? {
        guard let action = AppSettings.shared.edgeKeysSecondRow[key], action != .none, action != .keyDefault else { return nil }
        triggerUsed = true
        if isVisible { view?.flash(key: key) }
        // Keep the row up for a follow-up press.
        showLayerNow()
        perform(action, key: key, secondRow: true)
        return action
    }

    /// Connected / disconnected / unplugged, for each display a key toggles.
    private func refreshDisplayStates() {
        guard let view else { return }
        let settings = AppSettings.shared
        var uuids: Set<String> = []
        for action in Array(settings.edgeKeysFirstRow.values) + Array(settings.edgeKeysSecondRow.values) {
            if case .displayToggle(let uuid) = action { uuids.insert(uuid) }
        }
        guard !uuids.isEmpty else { view.setDisplayStates([:]); return }
        let externals = DisplaplacerEngine.externalDisplays()
        var states: [String: DisplayLinkState] = [:]
        for uuid in uuids {
            if uuid == "all" {
                states[uuid] = externals.isEmpty ? .absent : externals.contains(where: \.enabled) ? .connected : .disconnected
            } else if let display = externals.first(where: { $0.uuid == uuid }) {
                states[uuid] = display.enabled ? .connected : .disconnected
            } else {
                states[uuid] = .absent
            }
        }
        view.setDisplayStates(states)
    }

    private var wantsAmphetaminePolling: Bool {
        isVisible && (shownFirstRow?.values.contains(.amphetamineToggle) == true
            || layerShown && shownSecondRow.values.contains(.amphetamineToggle))
    }

    private func updateAmphetaminePolling() {
        guard wantsAmphetaminePolling else { stopAmphetaminePolling(); return }
        guard amphetaminePoll == nil else { return }
        refreshAmphetamineState()
        amphetaminePoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshAmphetamineState()
        }
    }

    private func stopAmphetaminePolling() {
        amphetaminePoll?.invalidate()
        amphetaminePoll = nil
    }

    private func refreshAmphetamineState() {
        guard !amphetamineQueryInFlight else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.if.Amphetamine").isEmpty else {
            amphetamineActive = false
            view?.setAmphetamineActive(false)
            return
        }
        amphetamineQueryInFlight = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"com.if.Amphetamine\" to session is active"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] finished in
            let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let active = finished.terminationStatus == 0 ? value.flatMap { text -> Bool? in
                switch text {
                case "true": return true
                case "false": return false
                default: return nil
                }
            } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.amphetamineQueryInFlight = false
                self.amphetamineActive = active
                self.view?.setAmphetamineActive(active)
            }
        }
        do { try process.run() } catch {
            amphetamineQueryInFlight = false
            amphetamineActive = nil
            view?.setAmphetamineActive(nil)
            NSLog("[MSG] EdgeKeys: couldn't read Amphetamine session: \(error.localizedDescription)")
        }
    }

    private var wantsWARPPolling: Bool {
        let row = layerShown ? shownSecondRow : (shownFirstRow ?? [:])
        return isVisible && row.values.contains(.cloudflareWARPToggle)
    }

    private func updateWARPPolling() {
        guard wantsWARPPolling else { stopWARPPolling(); return }
        guard warpPoll == nil else { return }
        CloudflareWARP.shared.refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.wantsWARPPolling else { self?.stopWARPPolling(); return }
            CloudflareWARP.shared.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        warpPoll = timer
    }

    private func stopWARPPolling() {
        warpPoll?.invalidate()
        warpPoll = nil
    }

    private func refreshWARPView() {
        let warp = CloudflareWARP.shared
        view?.setWARPState(warp.state, busy: warp.commandInFlight)
    }

    private var wantsMicrophonePolling: Bool {
        isVisible && (shownFirstRow?.values.contains(.microphoneToggle) == true
            || layerShown && shownSecondRow.values.contains(.microphoneToggle))
    }

    private func updateMicrophonePolling() {
        guard wantsMicrophonePolling else { stopMicrophonePolling(); return }
        guard microphonePoll == nil else { return }
        refreshMicrophoneState()
        microphonePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshMicrophoneState()
        }
    }

    /// The usage widget's file check and the left widget's re-evaluation run while the strip is
    /// on screen with something to switch between, and stop with the screen locked or asleep.
    private func updateUsageWatching() {
        let s = AppSettings.shared
        let visible = isVisible && PresentationState.shared.canPresent
        let hasLeftWidget = Self.leftWidgetInEsc
        let switching = hasLeftWidget && (s.edgeKeysWeatherInEsc || s.edgeKeysCalendarInEsc || s.edgeKeysUsageInEsc)
        AIUsageFeed.shared.setWatching(visible && hasLeftWidget && s.edgeKeysUsageInEsc)
        // The calendar's countdown ticks even when it's the only widget.
        view?.setLeftWidgetTicking(visible && (switching || hasLeftWidget && s.edgeKeysCalendarInEsc))
        view?.setUsagePulse(visible)
    }

    /// Shuffle, repeat… keys read the player while they show.
    private var extrasPoll: Timer?
    private var wantsExtrasPolling: Bool {
        func has(_ row: [Int: EdgeKeyAction]?) -> Bool {
            row?.values.contains { if case .control(let c) = $0 { return c.isPlayerExtra }; return false } ?? false
        }
        return isVisible && (has(shownFirstRow) || layerShown && has(shownSecondRow))
    }

    private func updateExtrasPolling() {
        guard wantsExtrasPolling else { stopExtrasPolling(); return }
        guard extrasPoll == nil else { return }
        PlayerExtras.shared.onChange = { [weak self] in
            guard let self else { return }
            if let first = self.shownFirstRow { self.view?.setFirstRow(first) }
            self.view?.setSecondRow(self.shownSecondRow)
        }
        PlayerExtras.shared.refresh()
        extrasPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            PlayerExtras.shared.refresh()
        }
    }

    private func stopExtrasPolling() {
        extrasPoll?.invalidate()
        extrasPoll = nil
    }

    private func stopMicrophonePolling() {
        microphonePoll?.invalidate()
        microphonePoll = nil
    }

    private func refreshMicrophoneState() {
        let state = MicrophoneMute.state()
        guard state != microphoneState else { return }
        microphoneState = state
        view?.setMicrophoneState(exists: state.exists, muted: state.muted, inUse: state.inUse)
    }

    private var wantsAudioRoutePolling: Bool {
        isVisible && audioChooser != nil
    }

    private func updateAudioRoutePolling() {
        guard wantsAudioRoutePolling else { stopAudioRoutePolling(); return }
        refreshAudioRoutes()
        guard audioRoutePoll == nil else { return }
        audioRoutePoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshAudioRoutes()
        }
    }

    private func stopAudioRoutePolling() {
        audioRoutePoll?.invalidate()
        audioRoutePoll = nil
    }

    private func refreshAudioRoutes() {
        let input = AudioDeviceRouting.snapshot(.input)
        let output = AudioDeviceRouting.snapshot(.output)
        let changed = input != audioInputSnapshot || output != audioOutputSnapshot
        audioInputSnapshot = input
        audioOutputSnapshot = output
        view?.setAudioRouteSnapshots(input: input, output: output)
        if changed { renderAudioChooser() }
    }

    fileprivate func openAudioChooser(direction: AudioDeviceRouting.Direction) {
        guard isVisible, view != nil else {
            AudioRouteMenu.shared.show(direction: direction)
            return
        }
        audioChooser?.timeout.cancel()
        refreshAudioRoutes()
        let timeout = DispatchWorkItem { [weak self] in self?.cancelAudioChooser() }
        audioChooser = (direction, 0, timeout)
        renderAudioChooser()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func renderAudioChooser() {
        guard let chooser = audioChooser else { return }
        let snapshot = chooser.direction == .input ? audioInputSnapshot : audioOutputSnapshot
        let reserved = AppSettings.shared.edgeKeysLayerModifier == .functionKey
            ? AppSettings.shared.edgeKeysTriggerKey : nil
        let page = AudioDeviceRouting.page(snapshot.devices, reservedKey: reserved, number: chooser.page)
        view?.showAudioChooser(snapshot: snapshot, page: page)
    }

    private func cancelAudioChooser() {
        audioChooser?.timeout.cancel()
        audioChooser = nil
        view?.hideAudioChooser()
    }

    private func chooseAudioDevice(key: Int) {
        guard let chooser = audioChooser else { return }
        if key == 0 { cancelAudioChooser(); return }
        let snapshot = chooser.direction == .input ? audioInputSnapshot : audioOutputSnapshot
        let reserved = AppSettings.shared.edgeKeysLayerModifier == .functionKey
            ? AppSettings.shared.edgeKeysTriggerKey : nil
        if key == reserved { cancelAudioChooser(); return }
        let page = AudioDeviceRouting.page(snapshot.devices, reservedKey: reserved, number: chooser.page)
        if key == page.moreKey {
            audioChooser?.page = (page.number + 1) % page.count
            renderAudioChooser()
            return
        }
        guard let device = page.devicesByKey[key] else { return }
        if AudioDeviceRouting.select(chooser.direction, uid: device.uid) {
            cancelAudioChooser()
            refreshAudioRoutes()
        } else {
            refreshAudioRoutes()
        }
    }

    /// Keys waiting on a display to connect or disconnect → whether the
    /// action is on the second row. They show a spinner until it's done.
    private var busyKeys: [Int: Bool] = [:]

    private func perform(_ action: EdgeKeyAction, key: Int, secondRow: Bool) {
        if case .shortcut(let shortcut) = action {
            if let bundle = appKeysTarget()?.bundleIdentifier {
                EdgeKeyAppKeys.shared.recordPress(shortcut, bundle: bundle)
            }
            focusPointerAppIfNeeded { shortcut.post() }
            return
        }
        if action == .cycleAudioInput || action == .cycleAudioOutput {
            openAudioChooser(direction: action == .cycleAudioInput ? .input : .output)
            return
        }
        // Media controls put on any key share the physical keys' handling:
        // double press, and working the chosen player.
        if case .control(let control) = action, [.previous, .playPause, .next].contains(control) {
            _ = mediaControl(control, physical: false)
            return
        }
        guard case .displayToggle = action else {
            EdgeKeyActions.run(action, switchDesktop: onSwitchDesktop)
            return
        }
        guard busyKeys[key] == nil else { return }
        busyKeys[key] = secondRow
        view?.setBusy(key, secondRow: secondRow)
        let screensBefore = NSScreen.screens.count
        EdgeKeyActions.run(action, switchDesktop: onSwitchDesktop)
        // Done once the screen list changes and settles, or after 10 s.
        let started = CACurrentMediaTime()
        var changedAt: CFTimeInterval?
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = CACurrentMediaTime()
            if changedAt == nil, NSScreen.screens.count != screensBefore { changedAt = now }
            let settled = changedAt.map { now - $0 > 0.6 } ?? false
            guard settled || now - started > 10 else { return }
            timer.invalidate()
            self.busyKeys[key] = nil
            self.view?.setBusy(key, secondRow: nil)
            self.refreshDisplayStates()
        }
    }

    // MARK: Second row

    private static func flag(for modifier: EdgeKeysModifier) -> CGEventFlags {
        switch modifier {
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .control: return .maskControl
        case .shift, .rightShift: return .maskShift
        case .fn:      return .maskSecondaryFn
        // Not a flag: the key's own down and up (see triggerKey).
        case .functionKey: return []
        }
    }

    /// Held on its own: other modifiers make it a shortcut, not the row.
    private func isLayerHold(_ flags: CGEventFlags) -> Bool {
        let modifier = AppSettings.shared.edgeKeysLayerModifier
        let wanted = Self.flag(for: modifier)
        var others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        others.remove(wanted)
        // Device-dependent bits (IOLLEvent.h) tell the two Shift keys apart.
        let rightShiftBit: UInt64 = 0x04
        if modifier == .rightShift, flags.rawValue & rightShiftBit == 0 { return false }
        return flags.contains(wanted) && flags.intersection(others).isEmpty
    }

    private func modifiersChanged(_ flags: CGEventFlags) {
        // Remapped, Right ⇧ comes as its own key (see handleKey), not a flag.
        guard !RightShiftRemap.isOn, !triggerIsFunctionKey else { return }
        setLayerHeld(isLayerHold(flags))
    }

    private func setLayerHeld(_ held: Bool) {
        guard held != layerHeld else { return }
        layerHeld = held
        updateTouchIDLockBlock()
        layerShowWork?.cancel()
        if held {
            layerSuppressed = false
            // A beat before showing, so a quick ⌘C never flickers the strip.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.layerHeld, !self.layerSuppressed else { return }
                self.showLayerNow()
            }
            layerShowWork = work
            let delay = AppSettings.shared.edgeKeysLayerHoldDelay
            if delay <= 0 { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }
        } else {
            setLayerShown(false)
        }
    }

    private func showLayerNow() {
        layerShowWork?.cancel()
        guard layerHeld else { return }
        setLayerShown(true)
    }

    private func setLayerShown(_ shown: Bool) {
        guard shown != layerShown else { return }
        layerShown = shown
        view?.showSecondRow(shown, modifier: AppSettings.shared.edgeKeysLayerModifier)
        // In full screen the hold peeks the strip up, and letting go sinks it.
        // Hidden (full screen, or tapped away): the hold peeks the strip up,
        // and letting go sinks it again.
        if shown ? !isVisible : (hiddenByTap || Self.builtinIsFullscreen) {
            update()
        }
        updateAmphetaminePolling()
        updateWARPPolling()
        updateMicrophonePolling()
        updateAudioRoutePolling()
        updateExtrasPolling()
    }

    /// Key codes for the function row's keyboard events: the system keys
    /// (Mission Control, Spotlight, Dictation, Do Not Disturb) and, with fn
    /// or "Use F1, F2… as standard function keys", the plain F keys.
    private static let keyCodes: [UInt16: Int] = [
        53: 0,
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
        98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        160: 3, 131: 3, 177: 4, 176: 5, 178: 6,
    ]

    /// The key codes F3–F6 send without fn (Mission Control, Spotlight,
    /// Dictation, Do Not Disturb), taken when reassigned in the first row.
    private static let systemKeyCodes: [UInt16: Int] = [160: 3, 131: 3, 177: 4, 176: 5, 178: 6]

    /// A session tap rather than a global monitor: it has to take F3–F5 away
    /// from Mission Control, Spotlight and Dictation, not just watch them.
    private func startKeyMonitor() {
        guard keyTap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<EdgeKeyStrip>.fromOpaque(refcon).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { me.handleKey(type: type, event: event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[MSG] EdgeKeys: failed to create key tap — Accessibility permission required.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyTap = tap
        keyTapSource = source
        startTouchIDTap()
    }

    // MARK: Touch ID key

    // The Touch ID key never reaches a session tap: loginwindow takes the
    // press and locks at once. So while the second row is held and the key
    // has an action there, MSG asks loginwindow not to lock (a private
    // assertion lasting up to 60 s, renewed while held), and catches the
    // press at the HID level, where it shows as system-defined subtype 16.

    private var hidTap: CFMachPort?
    private var hidTapSource: CFRunLoopSource?
    private var lockBlocked = false
    private var lockBlockRenewal: Timer?
    private var lastTouchIDPress: CFTimeInterval = 0

    private enum TouchIDLockBlock {
        typealias Call = @convention(c) () -> Int32
        private static let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_NOW)
        private static func call(_ name: String) {
            guard let handle, let symbol = dlsym(handle, name) else { return }
            _ = unsafeBitCast(symbol, to: Call.self)()
        }
        static func assert() { call("SACAssertScreenLockViaTouchIDBlocked") }
        static func remove() { call("SACRemoveAssertScreenLockViaTouchIDBlocked") }
    }

    private func updateTouchIDLockBlock() {
        let wanted = layerHeld && hidTap != nil && (AppSettings.shared.edgeKeysSecondRow[13] ?? .none) != .none
        guard wanted != lockBlocked else { return }
        lockBlocked = wanted
        lockBlockRenewal?.invalidate()
        lockBlockRenewal = nil
        if wanted {
            TouchIDLockBlock.assert()
            lockBlockRenewal = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in TouchIDLockBlock.assert() }
        } else {
            TouchIDLockBlock.remove()
        }
    }

    /// Touch ID locks as usual again (quitting, or the strip going away).
    func releaseTouchIDLockBlock() {
        layerHeld = false
        updateTouchIDLockBlock()
    }

    private func startTouchIDTap() {
        guard hidTap == nil else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 16 {
                let me = Unmanaged<EdgeKeyStrip>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { me.touchIDKeyPressed() }
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                let me = Unmanaged<EdgeKeyStrip>.fromOpaque(refcon).takeUnretainedValue()
                DispatchQueue.main.async { if let tap = me.hidTap { CGEvent.tapEnable(tap: tap, enable: true) } }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(1) << 14, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("[MSG] EdgeKeys: failed to create the Touch ID key tap.")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        hidTap = tap
        hidTapSource = source
    }

    private func stopTouchIDTap() {
        if let hidTap { CGEvent.tapEnable(tap: hidTap, enable: false) }
        if let hidTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), hidTapSource, .commonModes) }
        hidTap = nil
        hidTapSource = nil
    }

    /// One press sends several of these; act once per press.
    private func touchIDKeyPressed() {
        guard lockBlocked else { return }
        let now = CACurrentMediaTime()
        guard now - lastTouchIDPress > 0.6 else { return }
        lastTouchIDPress = now
        _ = runSecondRow(key: 13)
    }

    private func stopKeyMonitor() {
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
        if let keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), keyTapSource, .commonModes) }
        keyTap = nil
        keyTapSource = nil
        stopTouchIDTap()
        releaseTouchIDLockBlock()
        if triggerIsFunctionKey { view?.setKeyHeld(AppSettings.shared.edgeKeysTriggerKey, false) }
        setLayerHeld(false)
        setLayerShown(false)
    }

    /// True to consume the event.
    @MainActor
    private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        // Clean Keyboard has the keys; presses that get this far aren't acted on.
        if KeyboardCleaner.shared.isLocked, type == .keyDown { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
            if triggerIsFunctionKey { view?.setKeyHeld(AppSettings.shared.edgeKeysTriggerKey, false) }
            setLayerHeld(false)
            return false
        }
        // Keys MSG posts itself — the ⌃-number shortcut a Desktop switch
        // sends — aren't the user typing, and mustn't end the hold.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
        if type == .flagsChanged {
            modifiersChanged(event.flags)
            return false
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = type == .keyDown
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // App keys learn which shortcuts are used in each app (⌘/⌃ only).
        if isDown, !isRepeat, Self.keyCodes[code] == nil {
            if code == 36 || code == 53 { EdgeKeyAppKeys.resetDiaSearchState() }
            EdgeKeyAppKeys.shared.record(keyCode: code, flags: event.flags, event: event)
        }
        // Right ⇧ remapped: the hold is its own key's down and up, kept from apps.
        if RightShiftRemap.isOn, code == RightShiftRemap.keyCode {
            if !isRepeat { setLayerHeld(isDown) }
            return true
        }
        if let key = Self.keyCodes[code], isTrigger(key) {
            if isDown, !isRepeat, audioChooser != nil { cancelAudioChooser() }
            triggerKey(key, isDown: isDown, isRepeat: isRepeat, replay: .keyCode(code))
            return true
        }
        if !isDown, takenKeyCodes.removeValue(forKey: code) != nil { return true }
        if let key = Self.keyCodes[code], audioChooser != nil, isDown, !isRepeat {
            chooseAudioDevice(key: key)
            takenKeyCodes[code] = EdgeKeyAction.none
            return true
        }
        if isDown, let taken = takenKeyCodes[code] {
            if isRepeat { repeatIfStepping(taken) }
            return true
        }
        if layerHeld, isDown, let key = Self.keyCodes[code] {
            if let action = runSecondRow(key: key) {
                takenKeyCodes[code] = action
                return true
            }
        } else if layerHeld, isDown, !RightShiftRemap.isOn, !triggerIsFunctionKey {
            // A shortcut, not a hold for the second row. A remapped Right ⇧
            // or an F key is no modifier, so typing while holding keeps the row.
            layerSuppressed = true
            layerShowWork?.cancel()
            setLayerShown(false)
        }
        if isDown, !isRepeat, let key = Self.keyCodes[code], let action = runFirstRow(key: key) {
            takenKeyCodes[code] = action
            return true
        }
        if isDown, !isRepeat, isVisible, let key = Self.keyCodes[code] {
            view?.flash(key: key)
        }
        return false
    }

    // MARK: Levels and playback

    /// Shows a brightness or volume change over its two keys; false while
    /// the strip is hidden, so the caller falls back to a pop-up.
    @discardableResult
    func showLevel(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                   audioOutputKind: AudioOutputKind?) -> Bool {
        guard isVisible, let view else { return false }
        return view.showLevel(kind: kind, value: value, muted: muted,
                              audioOutputKind: audioOutputKind)
    }

    // MARK: Menus

    private var menuWatch: Timer?
    private var menuWatchUntil: CFTimeInterval = 0
    private var loweredForMenu = false

    /// A menu opened or closed somewhere: check a few times a second, while
    /// menus are up, whether one overlaps the strip.
    private func watchMenus() {
        menuWatchUntil = CACurrentMediaTime() + 0.6
        checkMenus()
        guard menuWatch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkMenus() }
        RunLoop.main.add(timer, forMode: .common)
        menuWatch = timer
    }

    private func checkMenus() {
        guard let window, let space, let primary = NSScreen.screens.first else {
            menuWatch?.invalidate()
            menuWatch = nil
            return
        }
        let f = window.frame
        let strip = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var anyMenu = false, overlaps = false
        for info in list where (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)) {
            guard let dict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
            anyMenu = true
            if bounds.intersects(strip) { overlaps = true }
        }
        if overlaps != loweredForMenu {
            loweredForMenu = overlaps
            SkyLightSpace.setLevel(space, overlaps ? 0 : Self.spaceLevel)
        }
        if !anyMenu, CACurrentMediaTime() > menuWatchUntil {
            menuWatch?.invalidate()
            menuWatch = nil
        }
    }

    // MARK: App keys

    /// The front app's keys, ranked when it came forward and kept until it
    /// goes — so they never reshuffle while you're using the app.
    private var appRow: [Int: EdgeKeyAction] = [:]
    private var appRowFor: String?

    /// The first row as it stands: the settings, with F3–F9 taken by the
    /// target app's keys when it has any.
    private func effectiveFirstRow() -> [Int: EdgeKeyAction] {
        let base = AppSettings.shared.edgeKeysFirstRow
        guard AppSettings.shared.edgeKeysAppKeys, let app = appKeysTarget() else { return base }
        let tag = "\(app.processIdentifier)"
        if tag != appRowFor {
            appRowFor = tag
            appRow = EdgeKeyAppKeys.shared.row(for: app)
        }
        return base.merging(appRow) { _, app in app }
    }

    // MARK: Pointer

    /// The app whose window the pointer is over (a setting), else the front app.
    private func appKeysTarget() -> NSRunningApplication? {
        if AppSettings.shared.edgeKeysAppKeysFollowPointer, let pointerApp, !pointerApp.isTerminated {
            return pointerApp
        }
        return NSWorkspace.shared.frontmostApplication
    }

    private var pointerApp: NSRunningApplication?
    /// The window the pointer was last over, raised when one of its keys is pressed.
    private var pointerWindow: CGWindowID = 0
    private var pointerMonitors: [Any] = []
    private var pointerPoll: Timer?
    private var lastPointerCheck: CFTimeInterval = 0
    private var pointerCheckWork: DispatchWorkItem?

    /// Mouse moves, a few checks a second at most: which app's window is
    /// under the pointer. Over the desktop, the strip or a menu, the last
    /// app stands.
    private func updatePointerMonitor() {
        let wanted = AppSettings.shared.edgeKeysAppKeys && AppSettings.shared.edgeKeysAppKeysFollowPointer
            && EdgeKeys.mode == .strip
        if wanted, pointerPoll == nil {
            let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
                self?.pointerMoved()
                return event
            }) {
                pointerMonitors.append(monitor)
            }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
                self?.pointerMoved()
            }) {
                pointerMonitors.append(monitor)
            }
            // Local events don't reach a global monitor. Window/Space changes can also put
            // another app under a stationary pointer, so events alone cannot keep this current.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pointerMoved()
                self?.writePointerDiagnostics()
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerPoll = timer
            // Resolve the current position on startup without waiting for a mouse move.
            DispatchQueue.main.async { [weak self] in
                self?.pointerMoved()
                self?.writePointerDiagnostics()
            }
        } else if !wanted {
            pointerMonitors.forEach { NSEvent.removeMonitor($0) }
            pointerMonitors = []
            pointerPoll?.invalidate()
            pointerPoll = nil
            pointerCheckWork?.cancel()
            pointerCheckWork = nil
            lastPointerCheck = 0
            pointerApp = nil
            pointerWindow = 0
        }
    }

    private func pointerMoved() {
        guard AppSettings.shared.edgeKeysAppKeys, AppSettings.shared.edgeKeysAppKeysFollowPointer,
              EdgeKeys.mode == .strip else { return }
        let now = CACurrentMediaTime()
        guard now - lastPointerCheck > 0.12 else {
            // Catch where it comes to rest.
            if pointerCheckWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pointerCheckWork = nil
                    self?.pointerMoved()
                }
                pointerCheckWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
            }
            return
        }
        lastPointerCheck = now
        guard let (app, window) = Self.appUnderPointer() else { return }
        pointerWindow = window
        guard app.processIdentifier != pointerApp?.processIdentifier else { return }
        pointerApp = app
        guard isVisible else { return }
        appRowFor = nil
        update()
    }

    /// The frontmost ordinary window under the pointer, and its app.
    private static func appUnderPointer() -> (NSRunningApplication, CGWindowID)? {
        let mouse = NSEvent.mouseLocation
        // Over the strip itself: the keys stay whose they were.
        if let strip = EdgeKeyStrip.shared.window, strip.isVisible, strip.frame.contains(mouse) { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let point = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = getpid()
        let displays = NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: primary.frame.maxY - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }
        let windows: [EdgeKeyPointerWindow] = list.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            // MSG's own windows are see-through overlays that cover whole
            // displays (corners, dividers, the bar): look past them.
            guard pid != me else { return nil }
            let owner = NSRunningApplication(processIdentifier: pid)
            return EdgeKeyPointerWindow(id: id, pid: pid, bundle: owner?.bundleIdentifier,
                                        regular: owner?.activationPolicy == .regular, layer: layer,
                                        bounds: bounds, alpha: info[kCGWindowAlpha as String] as? Double ?? 1)
        }
        var pointerOnDock = false
        if windows.contains(where: { $0.isDockSurface(displayBounds: displays) }) {
            var hit: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.05)
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
               let hit {
                var hitPID: pid_t = 0
                if AXUIElementGetPid(hit, &hitPID) == .success {
                    pointerOnDock = NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier == "com.apple.dock"
                }
            }
        }
        guard let target = EdgeKeyPointerWindow.target(in: windows, at: point, ignoring: me,
                                                       displayBounds: displays, pointerOnDock: pointerOnDock),
              let app = NSRunningApplication(processIdentifier: target.pid) else { return nil }
        return (app, target.id)
    }

    /// Opt-in development snapshot of the selection and displayed row; no event contents.
    private func writePointerDiagnostics() {
        guard ProcessInfo.processInfo.environment["MSG_EDGE_POINTER_DIAGNOSTICS"] == "1" else { return }
        let mouse = NSEvent.mouseLocation
        let cg = CGEvent(source: nil)?.location ?? .zero
        let lookup = Self.appUnderPointer()
        let frame = window?.frame ?? .zero
        let report: [String: Any] = [
            "time": Date().timeIntervalSince1970,
            "mouse": [mouse.x, mouse.y], "cgMouse": [cg.x, cg.y],
            "stripFrame": [frame.minX, frame.minY, frame.width, frame.height],
            "visible": isVisible, "panelVisible": window?.isVisible ?? false,
            "pointerApp": pointerApp?.bundleIdentifier ?? "",
            "pointerWindow": pointerWindow,
            "lookupApp": lookup?.0.bundleIdentifier ?? "", "lookupWindow": lookup?.1 ?? 0,
            "frontApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "rowFor": appRowFor ?? "",
            "shownRow": (shownFirstRow ?? [:]).reduce(into: [String: String]()) {
                $0[String($1.key)] = EdgeKeyActions.title($1.value)
            }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/msg-edge-pointer-\(getpid()).json"), options: .atomic)
        }
    }

    /// An app key for a window the pointer is over but that isn't in front:
    /// bring that window forward first, so the shortcut lands in it.
    private func focusPointerAppIfNeeded(then post: @escaping () -> Void) {
        guard AppSettings.shared.edgeKeysAppKeysFollowPointer, let app = pointerApp, !app.isTerminated,
              app.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            post()
            return
        }
        if pointerWindow != 0, let window = WindowPreviewCapture.axWindow(pid: app.processIdentifier, windowID: pointerWindow) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: post)
    }

    /// Re-rank now: the app's menu has just been read, naming learned keys.
    func refreshAppKeys(pid: pid_t) {
        guard appKeysTarget()?.processIdentifier == pid else { return }
        appRowFor = nil
        update()
    }

    /// Centre of the keys a level belongs over, as a fraction of the display
    /// width — for the pop-up shown while the strip is hidden.
    func levelCenter(for kind: SystemHUDKind) -> CGFloat? {
        guard EdgeKeys.mode == .strip,
              let keys = EdgeKeyActions.levelKeys(for: kind, in: AppSettings.shared.edgeKeysFirstRow, firstRow: true)
        else { return nil }
        return (FunctionRow.center(of: keys.lowerBound) + FunctionRow.center(of: keys.upperBound)) / 2
    }

    /// The first-row keys that skip back, play/pause and skip forward, in
    /// that order — where the media pop-up belongs while the strip is hidden.
    /// Nil unless the strip is in use and all three are assigned.
    func mediaPopupKeys() -> [Int]? {
        guard EdgeKeys.mode == .strip else { return nil }
        let row = AppSettings.shared.edgeKeysFirstRow
        let keys = [EdgeKeyAction.Control.previous, .playPause, .next].compactMap { wanted in
            (1...12).first { EdgeKeyActions.control(at: $0, in: row, firstRow: true) == wanted }
        }
        return keys.count == 3 ? keys : nil
    }

    private func syncPlaying() {
        // Once the player knows what's playing, its state drives the keys
        // (see updateMedia); the system's own flag can be another app's.
        if playingExpectation == nil, view?.hasMediaState == true { return }
        let reported = music?.isPlaying ?? false
        if let expectation = playingExpectation {
            if CACurrentMediaTime() < expectation.until, reported != expectation.playing { return }
            playingExpectation = nil
        }
        view?.setPlaying(reported)
    }
}

/// A native menu when a full-screen app hides the Edge Keys strip.
private final class AudioRouteMenu: NSObject {
    static let shared = AudioRouteMenu()
    private var direction: AudioDeviceRouting.Direction = .output

    func show(direction: AudioDeviceRouting.Direction) {
        DispatchQueue.main.async {
            self.direction = direction
            let snapshot = AudioDeviceRouting.snapshot(direction)
            let menu = NSMenu(title: direction == .input ? "Audio Input" : "Audio Output")
            if snapshot.devices.isEmpty {
                let empty = NSMenuItem(title: "No Available Devices", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for device in snapshot.devices {
                let item = NSMenuItem(title: device.name, action: #selector(self.select(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = device.uid == snapshot.selectedUID ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func select(_ item: NSMenuItem) {
        guard let uid = item.representedObject as? String else { return }
        if AudioDeviceRouting.select(direction, uid: uid) {
            EdgeKeyActions.onAudioRouteChanged?()
        }
    }
}

// MARK: - Right Shift remap

/// Turns the built-in keyboard's Right ⇧ into F18 (a key nothing uses) with
/// `hidutil`, so it's only the Edge Keys trigger and no longer Shift. The
/// mapping lasts until logout, so MSG takes it off when it quits or the
/// setting goes, and on launch after a crash. Other mappings are kept.
enum RightShiftRemap {
    private static let rightShift: UInt64 = 0x7_0000_00E5
    private static let f18: UInt64 = 0x7_0000_006D
    /// kVK_F18.
    static let keyCode: UInt16 = 79
    private static let builtIn = #"{"Built-In":true}"#
    private(set) static var isOn = false
    private static var synced = false

    static func set(_ on: Bool) {
        guard !synced || on != isOn else { return }
        synced = true
        isOn = on
        var pairs = currentPairs().filter { on ? $0.src != rightShift : !($0.src == rightShift && $0.dst == f18) }
        if on { pairs.append((rightShift, f18)) }
        let entries = pairs.map { #"{"HIDKeyboardModifierMappingSrc":\#($0.src),"HIDKeyboardModifierMappingDst":\#($0.dst)}"# }
        _ = hidutil(["property", "--matching", builtIn, "--set", #"{"UserKeyMapping":["# + entries.joined(separator: ",") + "]}"])
    }

    /// Mappings already on the built-in keyboard, from whoever set them.
    private static func currentPairs() -> [(src: UInt64, dst: UInt64)] {
        let output = hidutil(["property", "--matching", builtIn, "--get", "UserKeyMapping"])
        var seen = Set<[UInt64]>()
        var pairs: [(src: UInt64, dst: UInt64)] = []
        let blocks = output.components(separatedBy: "{").dropFirst()
        for block in blocks {
            func value(_ key: String) -> UInt64? {
                guard let range = block.range(of: key + " = ") else { return nil }
                return UInt64(block[range.upperBound...].prefix { $0.isNumber })
            }
            guard let src = value("HIDKeyboardModifierMappingSrc"),
                  let dst = value("HIDKeyboardModifierMappingDst"),
                  seen.insert([src, dst]).inserted else { continue }
            pairs.append((src, dst))
        }
        return pairs
    }

    private static func hidutil(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - App keys

/// Apps on Edge Keys: a press brings the app forward — to its Space if it's
/// on another — or launches it; the cap shows its logo in one color.
enum EdgeKeyApps {
    static func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Also reopens a window if the app is running with none open.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { NSLog("[MSG] EdgeKeys: couldn't open \(bundleID): \(error.localizedDescription)") }
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    /// The app's logo in one color: the menu bar template it ships, or else
    /// the bright logo lifted off its dark icon tile.
    static func monotoneIcon(_ bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bundle = Bundle(url: url)
        var image: NSImage?
        for name in ["TrayIconTemplate", "chatgptTemplate", "StatusBarIconTemplate", "MenuBarIconTemplate"] {
            if let found = bundle?.image(forResource: name) { image = trimmed(found); break }
        }
        if image == nil { image = logoMask(of: NSWorkspace.shared.icon(forFile: url.path)) }
        image?.isTemplate = true
        if let image { iconCache[bundleID] = image }
        return image
    }

    /// Bright pixels of an icon as a white mask, cropped to the logo.
    private static func logoMask(of icon: NSImage) -> NSImage? {
        let side = 128
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        // Only a logo on a dark tile lifts off cleanly; others get a grey icon.
        var total: CGFloat = 0, count: CGFloat = 0
        for y in stride(from: side / 5, to: side * 4 / 5, by: 2) {
            for x in stride(from: side / 5, to: side * 4 / 5, by: 2) {
                let i = (y * side + x) * 4
                guard pixels[i + 3] > 200 else { continue }
                total += (0.2126 * CGFloat(pixels[i]) + 0.7152 * CGFloat(pixels[i + 1]) + 0.0722 * CGFloat(pixels[i + 2])) / 255
                count += 1
            }
        }
        guard count > 0, total / count < 0.4 else { return nil }
        // Rows in memory run top-down, as the crop rect does.
        var minX = side, minY = side, maxX = -1, maxY = -1
        // Skip the tile's rim, which catches light.
        let inset = side / 8
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                var alpha: CGFloat = 0
                if x >= inset, x < side - inset, y >= inset, y < side - inset, pixels[i + 3] > 0 {
                    // Unpremultiply before judging brightness.
                    let a = CGFloat(pixels[i + 3]) / 255
                    let r = CGFloat(pixels[i]) / 255 / a
                    let g = CGFloat(pixels[i + 1]) / 255 / a
                    let b = CGFloat(pixels[i + 2]) / 255 / a
                    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // The logo is colorful; the tile's rim highlights are grey.
                    let saturation = max(r, g, b) - min(r, g, b)
                    let colorful = max(0, min(1, (lum - 0.22) / 0.2)) * max(0, min(1, (saturation - 0.15) / 0.2))
                    // Pale parts of the logo are bright enough on their own.
                    let bright = max(0, min(1, (lum - 0.55) / 0.15))
                    alpha = max(colorful, bright) * a
                }
                let v = UInt8(alpha * 255)
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = v
                if alpha > 0.1 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY, let full = ctx.makeImage(),
              let logo = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return NSImage(cgImage: logo, size: CGSize(width: logo.width / 4, height: logo.height / 4))
    }

    /// The image cropped to its opaque pixels, so logos with and without
    /// padding come out the same size.
    private static func trimmed(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let crop = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        let pointsPerPixel = image.size.width / CGFloat(w)
        return NSImage(cgImage: crop, size: CGSize(width: CGFloat(crop.width) * pointsPerPixel,
                                                   height: CGFloat(crop.height) * pointsPerPixel))
    }

    /// A template image filled with `color`, scaled to `height` points.
    static func tinted(_ image: NSImage, height: CGFloat, color: NSColor) -> NSImage? {
        guard image.size.height > 0 else { return nil }
        let size = CGSize(width: (image.size.width * height / image.size.height).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Second-row actions

/// A display, hardware control or VPN a key reports status for: active/in-use
/// (green), changing (yellow), muted/error (red), idle (grey), or absent (dimmed).
enum DisplayLinkState { case connected, disconnected, connecting, muted, absent }

/// The hardware mute of the currently selected input, plus detection of whether
/// any app is actively recording audio.
private enum MicrophoneMute {
    private static var previousVolume: Float32 = 0.5

    static func defaultDevice() -> AudioDeviceID? {
        var source = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &source,
                                         0, nil, &deviceSize, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func current() -> (device: AudioDeviceID, address: AudioObjectPropertyAddress, value: UInt32)? {
        guard let device = defaultDevice() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return nil }
        var value: UInt32 = 0
        var valueSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &valueSize, &value) == noErr else { return nil }
        return (device, address, value)
    }

    static func muted() -> Bool? {
        if let state = current() { return state.value != 0 }
        guard let device = defaultDevice() else { return nil }
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &volAddress, 0, nil, &volSize, &vol) == noErr {
            return vol == 0
        }
        return nil
    }

    static func toggle() -> Bool? {
        if var state = current() {
            var next: UInt32 = state.value == 0 ? 1 : 0
            guard AudioObjectSetPropertyData(state.device, &state.address, 0, nil,
                                             UInt32(MemoryLayout<UInt32>.size), &next) == noErr else { return nil }
            return muted()
        }
        guard let device = defaultDevice() else { return nil }
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 0
        var volSize = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volAddress, 0, nil, &volSize, &vol) == noErr else { return nil }
        var nextVol: Float32 = 0
        if vol > 0 {
            previousVolume = vol
            nextVol = 0
        } else {
            nextVol = max(0.2, previousVolume)
        }
        guard AudioObjectSetPropertyData(device, &volAddress, 0, nil, volSize, &nextVol) == noErr else {
            return nil
        }
        return muted()
    }

    static func isAnyAppUsingMicrophone() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procs) == noErr else {
            return false
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for p in procs {
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var runningInput: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(p, &inAddr, 0, nil, &rSize, &runningInput) == noErr, runningInput != 0 else {
                continue
            }
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(p, &pidAddr, 0, nil, &pSize, &pid) == noErr, pid == myPID {
                continue
            }
            return true
        }
        return false
    }

    static func state() -> (exists: Bool, muted: Bool, inUse: Bool) {
        guard defaultDevice() != nil else {
            return (exists: false, muted: false, inUse: false)
        }
        let isMuted = muted() ?? false
        let isInUse = isAnyAppUsingMicrophone()
        return (exists: true, muted: isMuted, inUse: isInUse)
    }
}

/// A quiet native macOS key-feedback tick after the microphone changes state.
/// It uses the current output device, independently of input mute.
private enum MicrophoneFeedback {
    private static let sound = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        byReference: true)

    static func play() {
        sound?.volume = 0.45
        sound?.stop()
        sound?.play()
    }
}

/// Running, naming and drawing an `EdgeKeyAction`.
enum EdgeKeyActions {
    private static var amphetamineToggleInProgress = false
    static var onAmphetamineToggled: (() -> Void)?
    static var onMicrophoneToggled: (() -> Void)?
    static var onAudioRouteChanged: (() -> Void)?
    static var isPlaying: (() -> Bool)?

    static func run(_ action: EdgeKeyAction, switchDesktop: ((Int) -> Void)?) {
        switch action {
        case .none, .keyDefault:
            break
        case .app(let bundleID):
            EdgeKeyApps.open(bundleID)
        case .desktop(let number):
            switchDesktop?(number)
        case .screenshot(let kind):
            // -p: the user's own screenshot settings (folder, name, thumbnail).
            let args: [String]
            switch kind {
            case .fullScreen:           args = ["-p"]
            case .selection:            args = ["-i", "-s", "-p"]
            case .window:               args = ["-i", "-W", "-p"]
            case .fullScreenToClipboard: args = ["-c"]
            case .selectionToClipboard: args = ["-i", "-s", "-c"]
            case .toolbar:              args = ["-i", "-U", "-p"]
            }
            launch("/usr/sbin/screencapture", args)
        case .control(let control):
            let code: Int
            switch control {
            case .brightnessDown: code = 3
            case .brightnessUp:   code = 2
            case .volumeDown:     code = 1
            case .volumeUp:       code = 0
            case .mute:           code = 7
            case .previous:       code = 18
            case .playPause:      code = 16
            case .next:           code = 17
            case .shuffle, .repeatMode, .favorite, .lyrics, .queue:
                PlayerExtras.shared.toggle(control)
                return
            }
            postAuxKey(code)
        case .system(let system):
            switch system {
            case .missionControl:
                openApp(at: "/System/Applications/Mission Control.app")
            case .showDesktop:
                launch("/System/Applications/Mission Control.app/Contents/MacOS/Mission Control", ["1"])
            case .apps:
                openApp(at: "/System/Applications/Apps.app")
            case .lockScreen:
                lockScreen()
            case .sleepDisplay:
                launch("/usr/bin/pmset", ["displaysleepnow"])
            // The macOS confirmation, not an immediate power-off: a stray
            // key press shouldn't end the session.
            case .forceQuitFrontApp:
                // The app in front — never MSG itself, whose strip doesn't take focus.
                if let app = NSWorkspace.shared.frontmostApplication,
                   app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    app.forceTerminate()
                }
            case .restart:
                askLoginWindow("rrst")
            case .shutDown:
                askLoginWindow("rsdn")
            case .cleanKeyboard:
                KeyboardCleaner.shared.start()
            }
        case .displayToggle(let uuid):
            toggleDisplay(uuid)
        case .amphetamineToggle:
            toggleAmphetamine()
        case .cloudflareWARPToggle:
            CloudflareWARP.shared.toggle()
        case .microphoneToggle:
            if MicrophoneMute.toggle() != nil {
                DispatchQueue.main.async { MicrophoneFeedback.play() }
            } else {
                NSLog("[MSG] EdgeKeys: the default input does not support microphone mute.")
            }
            onMicrophoneToggled?()
        case .cycleAudioInput:
            EdgeKeyStrip.shared.openAudioChooser(direction: .input)
        case .cycleAudioOutput:
            EdgeKeyStrip.shared.openAudioChooser(direction: .output)
        case .shortcut(let shortcut):
            shortcut.post()
        case .usage:
            break
        case .settings(let pane):
            DispatchQueue.main.async {
                if #available(macOS 14.0, *) {
                    let section = pane.flatMap { SettingsSection(rawValue: $0) }
                    SettingsWindowController.shared.show(pane: section)
                }
            }
        }
    }

    /// Presses a brightness, volume or media key, as the keyboard would: the
    /// system HUD, Now Playing app and everything else answer it as usual.
    static func postAuxKey(_ code: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Sends loginwindow a "show the restart / shut down dialog" Apple event.
    private static func askLoginWindow(_ eventID: String) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow")
                .first?.processIdentifier else { return }
        let code = eventID.utf8.reduce(FourCharCode(0)) { $0 << 8 | FourCharCode($1) }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: code,
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do { _ = try event.sendEvent(options: [.noReply], timeout: 5) } catch {
            NSLog("[MSG] EdgeKeys: loginwindow refused \(eventID): \(error.localizedDescription)")
        }
    }

    /// Flips one external display (Displays' soft disconnect), or for "all":
    /// disconnects every connected one, or reconnects them when none is.
    private static func toggleDisplay(_ uuid: String) {
        let externals = DisplaplacerEngine.externalDisplays()
        if uuid == "all" {
            let connected = externals.filter(\.enabled)
            if connected.isEmpty {
                DisplaplacerEngine.reconnectAll()
            } else {
                connected.forEach { DisplaplacerEngine.setEnabled($0.uuid, enabled: false) }
            }
        } else {
            let enabled = externals.first(where: { $0.uuid == uuid })?.enabled ?? false
            DisplaplacerEngine.setEnabled(uuid, enabled: !enabled)
        }
    }

    /// Amphetamine owns the sleep assertion and closed-lid handling. Run its
    /// AppleScript in a separate process so it cannot race NSAppleScript in the
    /// music monitor or stall the function-key event tap.
    private static func toggleAmphetamine() {
        guard !amphetamineToggleInProgress else { return }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.if.Amphetamine") != nil else {
            NSLog("[MSG] EdgeKeys: Amphetamine is not installed.")
            return
        }
        amphetamineToggleInProgress = true
        let script = """
        tell application id "com.if.Amphetamine"
            if session is active then
                end session
            else
                start new session with options {duration:0, interval:0, displaySleepAllowed:false}
                enable closed display mode
            end if
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown AppleScript error"
                NSLog("[MSG] EdgeKeys: Amphetamine toggle failed: \(detail)")
            }
            DispatchQueue.main.async {
                amphetamineToggleInProgress = false
                onAmphetamineToggled?()
                SystemEventNotchNotice.shared.amphetamineToggled()
            }
        }
        do { try process.run() } catch {
            amphetamineToggleInProgress = false
            NSLog("[MSG] EdgeKeys: couldn't run Amphetamine toggle: \(error.localizedDescription)")
        }
    }

    private static func launch(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do { try process.run() } catch { NSLog("[MSG] EdgeKeys: couldn't run \(path): \(error.localizedDescription)") }
    }

    private static func openApp(at path: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }

    private static func lockScreen() {
        typealias Lock = @convention(c) () -> Void
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        unsafeBitCast(symbol, to: Lock.self)()
    }

    /// The control a key sends in a row, its own function counted.
    static func control(at key: Int, in row: [Int: EdgeKeyAction], firstRow: Bool) -> EdgeKeyAction.Control? {
        let action = row[key] ?? (firstRow ? .keyDefault : .none)
        if case .control(let control) = action { return control }
        guard action == .keyDefault else { return nil }
        let own: [Int: EdgeKeyAction.Control] = [1: .brightnessDown, 2: .brightnessUp, 7: .previous, 8: .playPause,
                                                  9: .next, 10: .mute, 11: .volumeDown, 12: .volumeUp]
        return own[key]
    }

    /// The keys a brightness or volume level shows over: its down and up
    /// keys when they sit side by side, else the longest run of them (for
    /// volume, mute alone if nothing else). Nil when no key controls it.
    static func levelKeys(for kind: SystemHUDKind, in row: [Int: EdgeKeyAction], firstRow: Bool) -> ClosedRange<Int>? {
        func keys(_ controls: Set<EdgeKeyAction.Control>) -> [Int] {
            (1...12).filter { control(at: $0, in: row, firstRow: firstRow).map(controls.contains) ?? false }
        }
        var found = kind == .brightness ? keys([.brightnessDown, .brightnessUp]) : keys([.volumeDown, .volumeUp])
        if found.isEmpty, kind == .volume { found = keys([.mute]) }
        guard let first = found.first else { return nil }
        var runs: [ClosedRange<Int>] = []
        var start = first, end = first
        for key in found.dropFirst() {
            if key == end + 1 { end = key } else { runs.append(start...end); start = key; end = key }
        }
        runs.append(start...end)
        return runs.max { $0.count < $1.count }
    }

    static func title(_ action: EdgeKeyAction) -> String {
        switch action {
        case .none: return "Nothing"
        case .keyDefault: return "Default"
        case .control(let control):
            switch control {
            case .brightnessDown: return "Brightness Down"
            case .brightnessUp:   return "Brightness Up"
            case .volumeDown:     return "Volume Down"
            case .volumeUp:       return "Volume Up"
            case .mute:           return "Mute"
            case .previous:       return "Previous Track"
            case .playPause:      return "Play/Pause"
            case .next:           return "Next Track"
            case .shuffle:        return "Shuffle"
            case .repeatMode:     return "Repeat"
            case .favorite:       return "Favorite"
            case .lyrics:         return "Lyrics"
            case .queue:          return "Playing Next"
            }
        case .app(let bundleID):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "Missing App" }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        case .desktop(let number): return "Desktop \(number)"
        case .screenshot(let kind):
            switch kind {
            case .fullScreen:           return "Screenshot: Full Screen"
            case .selection:            return "Screenshot: Selection"
            case .window:               return "Screenshot: Window"
            case .fullScreenToClipboard: return "Screenshot: Full Screen to Clipboard"
            case .selectionToClipboard: return "Screenshot: Selection to Clipboard"
            case .toolbar:              return "Screenshot Toolbar"
            }
        case .system(let system):
            switch system {
            case .missionControl: return "Mission Control"
            case .showDesktop:    return "Show Desktop"
            case .apps:           return "Apps"
            case .lockScreen:     return "Lock Screen"
            case .sleepDisplay:   return "Sleep Display"
            case .forceQuitFrontApp: return "Force Quit Front App"
            case .restart:        return "Restart…"
            case .shutDown:       return "Shut Down…"
            case .cleanKeyboard:  return "Clean Keyboard"
            }
        case .displayToggle(let uuid):
            if uuid == "all" { return "Connect/Disconnect All Displays" }
            let name = DisplaplacerEngine.externalDisplays().first(where: { $0.uuid == uuid })?.name ?? "Display"
            return "Connect/Disconnect \(name)"
        case .amphetamineToggle: return "Amphetamine: Keep Awake"
        case .cloudflareWARPToggle: return "Cloudflare WARP: VPN"
        case .microphoneToggle: return "Mute/Unmute Microphone"
        case .cycleAudioInput: return "Choose Audio Input"
        case .cycleAudioOutput: return "Choose Audio Output"
        case .shortcut(let shortcut):
            return shortcut.title.isEmpty ? shortcut.id : shortcut.title
        case .usage:
            return "Usage Limit"
        case .settings(let pane):
            if let pane, let section = SettingsSection(rawValue: pane) {
                return "MSG Settings: \(section.title)"
            }
            return "MSG Settings"
        }
    }

    static func symbolName(_ action: EdgeKeyAction) -> String? {
        switch action {
        case .none, .app, .keyDefault: return nil
        case .control(let control):
            switch control {
            case .brightnessDown: return "sun.min.fill"
            case .brightnessUp:   return "sun.max.fill"
            case .volumeDown:     return "speaker.wave.1.fill"
            case .volumeUp:       return "speaker.wave.3.fill"
            case .mute:           return "speaker.slash.fill"
            case .previous:       return "backward.fill"
            case .playPause:
                let active = isPlaying?() ?? MusicMonitor.shared?.isPlaying ?? false
                return active ? "pause.fill" : "play.fill"
            case .next:           return "forward.fill"
            case .shuffle, .repeatMode, .favorite, .lyrics, .queue:
                let extras = PlayerExtras.shared
                return PlayerExtras.symbol(control, on: extras.isOn(control), repeatMode: extras.state.repeatMode)
            }
        case .desktop(let number): return number <= 50 ? "\(number).square" : "square"
        case .screenshot(let kind):
            switch kind {
            case .fullScreen:           return "camera.viewfinder"
            case .selection:            return "rectangle.dashed"
            case .window:               return "macwindow"
            case .fullScreenToClipboard: return "camera.on.rectangle"
            case .selectionToClipboard: return "rectangle.dashed.and.paperclip"
            case .toolbar:              return "camera.badge.ellipsis"
            }
        case .system(let system):
            switch system {
            case .missionControl: return "rectangle.3.group"
            case .showDesktop:    return "menubar.dock.rectangle"
            case .apps:           return "square.grid.3x3.fill"
            case .lockScreen:     return "lock.fill"
            case .sleepDisplay:   return "moon.zzz.fill"
            case .forceQuitFrontApp: return "xmark"
            case .restart:        return "arrow.clockwise"
            case .shutDown:       return "power"
            case .cleanKeyboard:  return "keyboard"
            }
        case .displayToggle(let uuid):
            return uuid == "all" ? "display.2" : "display"
        case .amphetamineToggle: return "cup.and.saucer.fill"
        case .cloudflareWARPToggle: return "cloud.fill"
        case .microphoneToggle: return "mic.fill"
        case .cycleAudioInput: return "mic.fill"
        case .cycleAudioOutput: return "speaker.wave.2.fill"
        case .shortcut(let shortcut):
            return shortcut.symbol
        case .usage:
            return nil
        case .settings(let pane):
            if let pane, let section = SettingsSection(rawValue: pane) {
                return section.icon
            }
            return "gearshape.fill"
        }
    }

    /// One-color glyph `height` points tall: a symbol, an app's monotone logo,
    /// or its icon in grey when it has no logo to lift.
    static func glyph(_ action: EdgeKeyAction, height: CGFloat, color: NSColor) -> NSImage? {
        if action == .cycleAudioInput || action == .cycleAudioOutput {
            let input = action == .cycleAudioInput
            let name = input ? "mic.fill" : "speaker.wave.2.fill"
            let label = input ? "IN" : "OUT"
            guard let icon = EdgeKeyStripView.symbolImage(name, size: height * 0.95, color: color) else { return nil }
            let font = NSFont.systemFont(ofSize: max(7, height * 0.52), weight: .bold)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let iconWidth = height * 0.95
            let textSize = text.size()
            let width = ceil(iconWidth + 3 + textSize.width)
            return NSImage(size: CGSize(width: width, height: height), flipped: false) { _ in
                icon.draw(in: CGRect(x: 0, y: 0, width: iconWidth, height: height))
                text.draw(at: CGPoint(x: iconWidth + 3, y: (height - textSize.height) / 2))
                return true
            }
        }
        if case .control(let control) = action, PlayerExtras.usesBadge(control),
           PlayerExtras.shared.isOn(control), let name = symbolName(action),
           let symbol = EdgeKeyStripView.symbolImage(name, size: height * 0.8, color: .black) {
            // On: the glyph cut out of a filled rounded square, as in Music.
            let side = ceil(height * 1.45)
            return NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: side * 0.24, yRadius: side * 0.24).fill()
                let s = symbol.size
                symbol.draw(in: CGRect(x: (side - s.width) / 2, y: (side - s.height) / 2, width: s.width, height: s.height),
                            from: .zero, operation: .destinationOut, fraction: 1)
                return true
            }
        }
        if case .control(.lyrics) = action, PlayerExtras.shared.isOn(.lyrics),
           let base = NSImage(systemSymbolName: "quote.bubble.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: height * 0.95, weight: .medium)) {
            // Drawn monochrome and tinted after: a one-color palette fills the
            // quote marks in too, leaving a blank blob.
            return NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        if let name = symbolName(action) {
            return EdgeKeyStripView.symbolImage(name, size: height * 0.95, color: color)
        }
        if case .usage(let source) = action {
            return AIUsage.glyph(source: source, height: height, color: color)
        }
        if case .shortcut(let shortcut) = action {
            // A learned shortcut with no fitting symbol: its menu name, short.
            let name = shortcut.title.isEmpty ? shortcut.id : shortcut.title
            let label = name.count > 12 ? String(name.prefix(11)) + "…" : name
            let font = NSFont.systemFont(ofSize: max(8, height * 0.62), weight: .medium)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            return NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
                text.draw(at: .zero)
                return true
            }
        }
        guard case .app(let bundleID) = action else { return nil }
        if let logo = EdgeKeyApps.monotoneIcon(bundleID) {
            return EdgeKeyApps.tinted(logo, height: height, color: color)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return greyIcon(NSWorkspace.shared.icon(forFile: url.path), side: height * 1.25)
    }

    private static func greyIcon(_ icon: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext,
                  let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            ctx.draw(cg, in: rect)
            ctx.clip(to: rect, mask: cg)
            ctx.setBlendMode(.saturation)
            ctx.setFillColor(NSColor.gray.cgColor)
            ctx.fill(rect)
            return true
        }
    }
}

// MARK: - Strip view

private final class EdgeKeyStripView: NSView {
    var layoutSignature: [CGFloat] = []

    private static let capColor = NSColor(white: 1, alpha: 0.14)
    private static let pressedColor = NSColor(white: 1, alpha: 0.42)
    private static let glyphColor = NSColor(white: 1, alpha: 0.88)

    /// Symbols for esc…Touch ID, as printed on a MacBook's function row.
    private static let symbols: [String?] = [
        nil, "sun.min.fill", "sun.max.fill", "rectangle.3.group", "magnifyingglass", "mic.fill",
        "moon.fill", "backward.fill", "play.fill", "forward.fill", "speaker.slash.fill",
        "speaker.wave.1.fill", "speaker.wave.3.fill", "touchid",
    ]

    private let scale: CGFloat
    private var caps: [CALayer] = []
    private var glyphs: [CALayer] = []
    /// The second row's glyph on each cap (esc's shows the modifier).
    private var rowGlyphs: [CALayer] = []
    private var secondRow: [Int: EdgeKeyAction] = [:]
    private var rowShown = false
    private var levels: [SystemHUDKind: LevelCap] = [:]
    private var levelSpans: [SystemHUDKind: ClosedRange<Int>] = [:]
    private var playing = EdgeKeyActions.isPlaying?() ?? MusicMonitor.shared?.isPlaying ?? false
    private var audioInputSnapshot = AudioDeviceRouting.Snapshot(devices: [], selectedUID: nil)
    private var audioOutputSnapshot = AudioDeviceRouting.Snapshot(devices: [], selectedUID: nil)
    private var audioChooserLayer: CALayer?
    private var audioChooserKeys: Set<Int> = []
    private var audioChooserTargets: [(frame: CGRect, key: Int)] = []
    var onAudioChooserKey: ((Int) -> Void)?

    enum MediaGesture { case playPause, skip(forward: Bool), source(forward: Bool) }
    /// Trackpad and mouse on the player: click plays or pauses, a sideways
    /// swipe skips, scrolling up or down goes to another player.
    var onMediaGesture: ((MediaGesture) -> Void)?
    /// A click on the hardware stats, with where they are on screen.
    var onStatsClick: ((CGRect) -> Void)?
    private var statsPressed = false

    private func overStats(_ event: NSEvent) -> Bool {
        guard audioChooserLayer == nil, let stats = statsLayer, stats.opacity > 0.5, let root = layer else { return false }
        let point = strip.convert(convert(event.locationInWindow, from: nil), from: root)
        return stats.frame.contains(point)
    }

    /// The stats on screen, up to just under the strip's top, as the usage widget's.
    private var statsScreenRect: CGRect? {
        guard let stats = statsLayer, let root = layer, let window else { return nil }
        let onScreen = window.convertToScreen(convert(root.convert(stats.frame, from: strip), to: nil))
        return CGRect(x: onScreen.minX, y: window.frame.minY, width: onScreen.width, height: stripHeight - 2)
    }

    private func setStatsPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(pressed ? 0.09 : 0.2)
        statsLayer?.sublayers?.forEach { $0.opacity = pressed ? 0.6 : 1 }
        CATransaction.commit()
    }
    private var scrollSum = CGSize.zero
    private var scrollFired = false
    private var lastWheelStep: CFTimeInterval = 0
    /// Background extends 6 pt above the keys (extended by 4 pt more from 2 pt).
    static let backgroundTopExtension: CGFloat = 6

    private var stripHeight: CGFloat
    private var cornerRadius: CGFloat
    private var cornerCurve: CornerCurve
    private var roundedCornersEnabled: Bool

    /// Everything that slides: the black strip and the caps on it.
    private let strip = CALayer()
    private let backgroundLayer = CAShapeLayer()

    private var glyphPointSize: CGFloat { max(11, min(16, stripHeight * 0.36)) }

    init(frame: CGRect, stripHeight: CGFloat, radius: CGFloat, curve: CornerCurve, roundedCorners: Bool, scale: CGFloat) {
        self.stripHeight = stripHeight
        self.cornerRadius = radius
        self.cornerCurve = curve
        self.roundedCornersEnabled = roundedCorners
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        // The fill's overscan below the edge must draw when the rise lifts it.
        clipsToBounds = false
        strip.frame = bounds
        strip.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(strip)

        backgroundLayer.frame = strip.bounds
        backgroundLayer.fillColor = NSColor.black.cgColor
        backgroundLayer.path = Self.makeStripPath(
            width: bounds.width,
            stripHeight: stripHeight + Self.backgroundTopExtension,
            radius: roundedCornersEnabled ? cornerRadius : 0,
            curve: cornerCurve
        )
        strip.addSublayer(backgroundLayer)

        buildCaps()
    }

    func updateFillets(stripHeight: CGFloat, radius: CGFloat, curve: CornerCurve, roundedCorners: Bool) {
        self.stripHeight = stripHeight
        self.cornerRadius = radius
        self.cornerCurve = curve
        self.roundedCornersEnabled = roundedCorners

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bounds and position, never frame: frame is read through the
        // transform, so setting it while the strip was parked below the edge
        // (or mid-slide) moved it up by the slide — it then rose too high
        // and snapped down on the next update.
        strip.bounds = CGRect(origin: .zero, size: bounds.size)
        strip.position = CGPoint(x: bounds.midX, y: bounds.midY)
        backgroundLayer.frame = strip.bounds
        backgroundLayer.path = Self.makeStripPath(
            width: bounds.width,
            stripHeight: stripHeight + Self.backgroundTopExtension,
            radius: roundedCornersEnabled ? cornerRadius : 0,
            curve: cornerCurve
        )
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard point.y <= stripHeight + Self.backgroundTopExtension else { return nil }
        return super.hitTest(point)
    }

    // MARK: Show and hide

    /// Down by the strip's own height only: the keys are below the edge but
    /// the fillets sit right on it, over the display's own rounded corners.
    /// So the corners are already there and ride up with the strip, rather
    /// than the screen's corners showing first and new ones rising after.
    private var parked: CATransform3D { CATransform3DMakeTranslation(0, -(stripHeight + Self.backgroundTopExtension), 0) }

    /// Parks the strip below the screen edge, ready to slide up.
    func prepareShow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.removeAllAnimations()
        strip.transform = parked
        caps.forEach { $0.opacity = 0 }
        CATransaction.commit()
    }

    /// Rises out of the bottom edge; the caps land a beat later, from the
    /// middle outward, like keys settling.
    func playShow() {
        let from = strip.presentation()?.transform ?? strip.transform
        strip.removeAllAnimations()
        strip.transform = CATransform3DIdentity
        let rise = CASpringAnimation(keyPath: "transform")
        rise.fromValue = from
        rise.toValue = CATransform3DIdentity
        rise.damping = 26
        rise.stiffness = 260
        rise.duration = rise.settlingDuration
        strip.add(rise, forKey: "slide")

        let now = CACurrentMediaTime()
        for (key, cap) in caps.enumerated() {
            let fromOpacity = cap.presentation()?.opacity ?? cap.opacity
            cap.removeAnimation(forKey: "fade")
            cap.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = 1
            fade.beginTime = now + 0.05 + Double(abs(CGFloat(key) - 6.5)) * 0.012
            fade.duration = 0.2
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cap.add(fade, forKey: "fade")
        }
    }

    /// Caps fade from the ends inward while the strip sinks below the edge.
    func playHide(completion: @escaping () -> Void) {
        let duration: TimeInterval = 0.32
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let now = CACurrentMediaTime()
        for (key, cap) in caps.enumerated() {
            let fromOpacity = cap.presentation()?.opacity ?? cap.opacity
            cap.removeAnimation(forKey: "fade")
            cap.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = 0
            fade.beginTime = now + Double(6.5 - abs(CGFloat(key) - 6.5)) * 0.01
            fade.duration = 0.14
            fade.fillMode = .backwards
            cap.add(fade, forKey: "fade")
        }
        let from = strip.presentation()?.transform ?? strip.transform
        let to = parked
        strip.removeAllAnimations()
        strip.transform = to
        let sink = CABasicAnimation(keyPath: "transform")
        sink.fromValue = from
        sink.toValue = to
        sink.beginTime = now + 0.06
        sink.duration = duration - 0.06
        sink.fillMode = .backwards
        sink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
        strip.add(sink, forKey: "slide")
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    enum LeftWidgetMode {
        case media
        case weather
        case calendar
        case usage
    }

    private var leftWidgetMode: LeftWidgetMode = .media
    /// When the user last chose a widget or page by hand: their choice holds for five minutes, after
    /// which the widget follows what's going on again (see `preferredLeftWidget`).
    private var leftWidgetChosenAt: CFTimeInterval?
    private static let leftWidgetHold: CFTimeInterval = 300

    /// Whether a window point lies on the player while it shows.
    private func overMedia(_ event: NSEvent) -> Bool {
        guard audioChooserLayer == nil, leftWidgetMode == .media,
              let cap = mediaCap, cap.isShown, let root = layer else { return false }
        let point = strip.convert(convert(event.locationInWindow, from: nil), from: root)
        return cap.frame.contains(point)
    }

    private func overWeather(_ event: NSEvent) -> Bool {
        guard audioChooserLayer == nil, leftWidgetMode == .weather,
              let cap = weatherCap, cap.isShown, let root = layer else { return false }
        let point = strip.convert(convert(event.locationInWindow, from: nil), from: root)
        return cap.frame.contains(point)
    }

    /// The usage widget on screen, for TokenBar to open its window above.
    /// Up to the strip's visible top plus its corner fillets — not the window's
    /// (taller, mostly clear) top — so TokenBar opens just clear of the strip,
    /// which sits in a space above TokenBar's window.
    private var usageScreenRect: CGRect? {
        guard let cap = usageCap, let root = layer, let window else { return nil }
        let inView = root.convert(cap.frame, from: strip)
        let onScreen = window.convertToScreen(convert(inView, to: nil))
        // Flush with the display's left edge, and about 8 above the keys: the
        // strip's black top merges into what's behind, so the eye measures from
        // the keycaps, not the strip's edge.
        return CGRect(x: window.frame.minX, y: window.frame.minY, width: onScreen.width, height: stripHeight - 2)
    }

    private func overUsage(_ event: NSEvent) -> Bool {
        guard audioChooserLayer == nil, leftWidgetMode == .usage,
              let cap = usageCap, cap.isShown, let root = layer else { return false }
        let point = strip.convert(convert(event.locationInWindow, from: nil), from: root)
        return cap.frame.contains(point)
    }

    private func overCalendar(_ event: NSEvent) -> Bool {
        guard audioChooserLayer == nil, leftWidgetMode == .calendar,
              let cap = calendarCap, cap.isShown, let root = layer else { return false }
        let point = strip.convert(convert(event.locationInWindow, from: nil), from: root)
        return cap.frame.contains(point)
    }

    private func overLeftWidget(_ event: NSEvent) -> Bool {
        return overMedia(event) || overWeather(event) || overCalendar(event) || overUsage(event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mediaPressed = false
    private var weatherPressed = false
    private var calendarPressed = false
    private var usagePressed = false

    override func mouseUp(with event: NSEvent) {
        if statsPressed {
            statsPressed = false
            setStatsPressed(false)
            if overStats(event), let rect = statsScreenRect { onStatsClick?(rect) }
            return
        }
        if usagePressed {
            usagePressed = false
            usageCap?.setPressed(false)
            if overUsage(event) { AIUsageFeed.showPopover(anchor: usageScreenRect) }
            return
        }
        if calendarPressed {
            calendarPressed = false
            calendarCap?.setPressed(false)
            if overCalendar(event) { CalendarFeed.openApp(reminders: calendarEntry?.isReminder == true) }
            return
        }
        if weatherPressed {
            weatherPressed = false
            weatherCap?.setPressed(false)
            if overWeather(event) {
                WeatherMonitor.shared.openWeatherApp()
                WeatherMonitor.shared.refresh()
            }
            return
        }
        guard mediaPressed else { return }
        mediaPressed = false
        mediaCap?.setPressed(false)
        guard overMedia(event) else { return }
        // Pausing shouldn't send the player away at once.
        if leftWidgetSwitching { leftWidgetChosenAt = CACurrentMediaTime() }
        onMediaGesture?(.playPause)
    }

    override func scrollWheel(with event: NSEvent) {
        guard overLeftWidget(event) else { return }
        // A mouse wheel: one step per notch, a moment apart.
        guard event.hasPreciseScrollingDeltas else {
            let now = CACurrentMediaTime()
            guard event.scrollingDeltaY != 0, now - lastWheelStep > 0.35 else { return }
            lastWheelStep = now
            if leftWidgetMode == .weather {
                WeatherMonitor.shared.refresh()
            } else if leftWidgetMode == .usage {
                flipUsagePage(down: event.scrollingDeltaY < 0)
            } else if leftWidgetMode == .media {
                onMediaGesture?(.source(forward: event.scrollingDeltaY < 0))
            }
            return
        }
        // Trackpad: one action per gesture, momentum ignored.
        if event.phase == .began || event.phase == .mayBegin {
            scrollSum = .zero
            scrollFired = false
        }
        guard event.momentumPhase == [], !scrollFired, event.phase != .ended, event.phase != .cancelled else { return }
        scrollSum.width += event.scrollingDeltaX
        scrollSum.height += event.scrollingDeltaY
        let threshold: CGFloat = 28
        if abs(scrollSum.width) > threshold, abs(scrollSum.width) > abs(scrollSum.height) * 1.2 {
            scrollFired = true
            // Content follows the fingers: a swipe to the left brings the next widget/song.
            let forward = (scrollSum.width < 0) == event.isDirectionInvertedFromDevice
            if leftWidgetSwipeable {
                switchLeftWidget(forward: forward)
            } else if leftWidgetMode == .media {
                onMediaGesture?(.skip(forward: forward))
            }
            // A lone weather, calendar or usage widget stays put: the player's skip would bring
            // up an empty player in its place.
        } else if abs(scrollSum.height) > threshold, abs(scrollSum.height) > abs(scrollSum.width) * 1.2 {
            scrollFired = true
            let down = (scrollSum.height < 0) == event.isDirectionInvertedFromDevice
            if leftWidgetMode == .weather {
                WeatherMonitor.shared.refresh()
            } else if leftWidgetMode == .usage {
                flipUsagePage(down: down)
            } else if leftWidgetMode == .media {
                // Fingers up: the next player rises from below.
                onMediaGesture?(.source(forward: down))
            }
        }
    }

    // The temporary audio page is clickable as well as keyboard-driven.
    override func mouseDown(with event: NSEvent) {
        if overStats(event) {
            statsPressed = true
            setStatsPressed(true)
            return
        }
        if overMedia(event) {
            mediaPressed = true
            mediaCap?.setPressed(true)
            return
        }
        if overWeather(event) {
            weatherPressed = true
            weatherCap?.setPressed(true)
            return
        }
        if overCalendar(event) {
            calendarPressed = true
            calendarCap?.setPressed(true)
            return
        }
        if overUsage(event) {
            usagePressed = true
            usageCap?.setPressed(true)
            return
        }
        guard audioChooserLayer != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let target = audioChooserTargets.first(where: { $0.frame.contains(point) }) {
            onAudioChooserKey?(target.key)
        }
    }

    func setAudioRouteSnapshots(input: AudioDeviceRouting.Snapshot,
                                output: AudioDeviceRouting.Snapshot) {
        guard input != audioInputSnapshot || output != audioOutputSnapshot else { return }
        audioInputSnapshot = input
        audioOutputSnapshot = output
        setFirstRow(firstRow)
        setSecondRow(secondRow)
    }

    func showAudioChooser(snapshot: AudioDeviceRouting.Snapshot, page: AudioDeviceRouting.Page) {
        hideAudioChooser()
        let overlay = CALayer()
        overlay.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight + Self.backgroundTopExtension)
        overlay.backgroundColor = NSColor.black.cgColor
        overlay.contentsScale = scale
        let keyFont = max(10, min(12, glyphPointSize * 0.78))
        var clickableKeys: Set<Int> = [0]
        var targets: [(frame: CGRect, key: Int)] = []

        // Cancel on Esc (key 0)
        let escFrame = capFrame(0)
        let escCap = CALayer()
        escCap.frame = escFrame
        escCap.cornerRadius = capRadius
        escCap.cornerCurve = .continuous
        escCap.maskedCorners = Self.roundedCorners
        escCap.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
        overlay.addSublayer(escCap)

        let escText = CATextLayer()
        escText.string = "Cancel"
        escText.font = NSFont.systemFont(ofSize: keyFont, weight: .medium)
        escText.fontSize = keyFont
        escText.foregroundColor = NSColor(white: 1, alpha: 0.82).cgColor
        escText.alignmentMode = .center
        escText.truncationMode = .end
        escText.contentsScale = scale
        escText.frame = CGRect(x: 6, y: (escCap.bounds.height - keyFont * 1.45) / 2,
                               width: escCap.bounds.width - 12, height: keyFont * 1.45)
        escCap.addSublayer(escText)
        targets.append((escFrame, 0))

        // Device and More items on the function key row
        for item in page.items {
            let label: String
            let selected: Bool
            if item.isMore {
                label = "More ›"
                selected = false
            } else if let device = item.device {
                label = device.name
                selected = device.uid == snapshot.selectedUID
            } else {
                continue
            }

            for k in item.keys {
                clickableKeys.insert(k)
            }

            let frame: CGRect
            if item.keys.count > 1 {
                frame = capFrame(item.keys.lowerBound).union(capFrame(item.keys.upperBound))
            } else {
                frame = capFrame(item.keys.lowerBound)
            }
            targets.append((frame, item.keys.lowerBound))

            let cap = CALayer()
            cap.frame = frame
            cap.cornerRadius = capRadius
            cap.cornerCurve = .continuous
            cap.maskedCorners = Self.roundedCorners
            cap.backgroundColor = NSColor(white: 1, alpha: selected ? 0.21 : 0.09).cgColor
            if selected {
                cap.borderWidth = 1
                cap.borderColor = NSColor(white: 1, alpha: 0.55).cgColor
            }
            overlay.addSublayer(cap)

            let pad: CGFloat = item.keys.count > 1 ? 10 : 6
            let text = CATextLayer()
            text.string = label
            text.font = NSFont.systemFont(ofSize: keyFont, weight: selected ? .semibold : .medium)
            text.fontSize = keyFont
            text.foregroundColor = NSColor(white: 1, alpha: selected ? 1 : 0.82).cgColor
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = scale
            text.frame = CGRect(x: pad, y: (cap.bounds.height - keyFont * 1.45) / 2,
                                width: max(10, cap.bounds.width - pad * 2), height: keyFont * 1.45)
            cap.addSublayer(text)
        }

        strip.addSublayer(overlay)
        audioChooserLayer = overlay
        audioChooserKeys = clickableKeys
        audioChooserTargets = targets
    }

    func hideAudioChooser() {
        audioChooserLayer?.removeFromSuperlayer()
        audioChooserLayer = nil
        audioChooserKeys.removeAll()
        audioChooserTargets.removeAll()
    }

    private func capFrame(_ key: Int) -> CGRect {
        let width = bounds.width
        let gap = FunctionRow.unit - FunctionRow.face
        let capWidth = (key == 0 ? FunctionRow.escUnits * FunctionRow.unit - gap : FunctionRow.face) * width
        let inset = max(3, (stripHeight * 0.12).rounded())
        let x = (FunctionRow.center(of: key) * width - capWidth / 2).rounded()
        switch AppSettings.shared.edgeKeysKeyPlacement {
        case .floating:
            return CGRect(x: x, y: inset, width: capWidth.rounded(), height: stripHeight - inset * 2)
        case .touching:
            // Rounded all round, down onto the edge, 6 pt clear of the top.
            return CGRect(x: x, y: 0, width: capWidth.rounded(), height: stripHeight - 6)
        case .rising:
            // Squared into the edge, the same gap above as floating keys.
            return CGRect(x: x, y: 0, width: capWidth.rounded(), height: stripHeight - inset)
        }
    }

    /// How far the strip's fill carries on below the screen's bottom edge.
    static let overscan: CGFloat = 40

    static func makeStripPath(width w: CGFloat, stripHeight h: CGFloat, radius: CGFloat, curve: CornerCurve) -> CGPath {
        let path = CGMutablePath()
        guard w > 0, h > 0 else { return path }

        let r = radius > 0 ? radius : 0
        let reach = r > 0 ? CornerGeometry.reach(for: r, curve: curve) : 0

        // One outline — the strip, run on below the screen edge so the rise's
        // overshoot lifts more strip into view, and the fillets rounding the
        // display's corners above it. As separate shapes, the fillets met the
        // strip along an edge that antialiased twice and showed as a flickering
        // hairline whenever the strip sat between pixels mid-slide.
        path.move(to: CGPoint(x: 0, y: -overscan))
        path.addLine(to: CGPoint(x: w, y: -overscan))
        guard reach > 0 else {
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
            return path
        }
        path.addLine(to: CGPoint(x: w, y: h + reach))

        if curve == .g2 {
            let k = CornerGeometry.self
            // Right fillet, down the display's edge into the strip's top.
            path.addCurve(to: CGPoint(x: w - k.k4 * r, y: h + k.k3 * r),
                          control1: CGPoint(x: w, y: h + k.k1 * r),
                          control2: CGPoint(x: w, y: h + k.k2 * r))
            path.addCurve(to: CGPoint(x: w - k.k3 * r, y: h + k.k4 * r),
                          control1: CGPoint(x: w - k.k6 * r, y: h + k.k5 * r),
                          control2: CGPoint(x: w - k.k5 * r, y: h + k.k6 * r))
            path.addCurve(to: CGPoint(x: w - reach, y: h),
                          control1: CGPoint(x: w - k.k2 * r, y: h),
                          control2: CGPoint(x: w - k.k1 * r, y: h))
            path.addLine(to: CGPoint(x: reach, y: h))
            // Left fillet, the same curve traced back up the other edge.
            path.addCurve(to: CGPoint(x: k.k3 * r, y: h + k.k4 * r),
                          control1: CGPoint(x: k.k1 * r, y: h),
                          control2: CGPoint(x: k.k2 * r, y: h))
            path.addCurve(to: CGPoint(x: k.k4 * r, y: h + k.k3 * r),
                          control1: CGPoint(x: k.k5 * r, y: h + k.k6 * r),
                          control2: CGPoint(x: k.k6 * r, y: h + k.k5 * r))
            path.addCurve(to: CGPoint(x: 0, y: h + reach),
                          control1: CGPoint(x: 0, y: h + k.k2 * r),
                          control2: CGPoint(x: 0, y: h + k.k1 * r))
        } else {
            // G1 (circular).
            let c = reach * 0.44771525
            path.addCurve(to: CGPoint(x: w - reach, y: h),
                          control1: CGPoint(x: w, y: h + c),
                          control2: CGPoint(x: w - c, y: h))
            path.addLine(to: CGPoint(x: reach, y: h))
            path.addCurve(to: CGPoint(x: 0, y: h + reach),
                          control1: CGPoint(x: c, y: h),
                          control2: CGPoint(x: 0, y: h + c))
        }
        path.closeSubpath()
        return path
    }

    /// Keys from the edge round only their top corners; the edge squares off the bottom.
    static var roundedCorners: CACornerMask {
        AppSettings.shared.edgeKeysKeyPlacement == .rising
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    private var capRadius: CGFloat { min(8, capFrame(1).height * 0.26) }

    private func buildCaps() {
        let root = strip
        for key in 0...13 {
            let cap = CALayer()
            cap.frame = capFrame(key)
            cap.cornerRadius = capRadius
            cap.cornerCurve = .continuous
            cap.maskedCorners = Self.roundedCorners
            cap.backgroundColor = Self.capColor.cgColor
            root.addSublayer(cap)
            caps.append(cap)
            // esc and the Touch ID key can be left off the strip (settings).
            if key == 0 { cap.isHidden = !AppSettings.shared.edgeKeysShowEsc }
            if key == 13 { cap.isHidden = !AppSettings.shared.edgeKeysShowTouchID }

            let glyph = CALayer()
            glyph.frame = cap.bounds
            glyph.contentsGravity = .center
            glyph.contentsScale = scale
            cap.addSublayer(glyph)
            glyphs.append(glyph)

            let rowGlyph = CALayer()
            rowGlyph.frame = cap.bounds
            rowGlyph.contentsGravity = .center
            rowGlyph.contentsScale = scale
            rowGlyph.opacity = 0
            cap.addSublayer(rowGlyph)
            rowGlyphs.append(rowGlyph)
            if key == 0 {
                glyph.contents = Self.textImage("esc", size: glyphPointSize * 0.85)?
                    .layerContents(forContentsScale: scale)
            } else if key == 13 {
                // The Touch ID key locks the Mac when pressed; it shows the
                // fingerprint only while something asks for one.
                setSymbol("lock.fill", on: key)
                glyph.transform = CATransform3DIdentity
            }
        }
    }

    /// Where a level shows: over the keys that change it in the row on screen.
    func levelKeys(for kind: SystemHUDKind) -> ClosedRange<Int>? {
        rowShown
            ? EdgeKeyActions.levelKeys(for: kind, in: secondRow, firstRow: false)
            : EdgeKeyActions.levelKeys(for: kind, in: firstRow, firstRow: true)
    }

    private func setRowSymbol(_ name: String, on key: Int, secondRow: Bool, alpha: CGFloat = 1) {
        guard key >= 0 else { return }
        let target = secondRow ? (rowGlyphs.indices.contains(key) ? rowGlyphs[key] : nil)
                               : (glyphs.indices.contains(key) ? glyphs[key] : nil)
        target?.contents = Self.symbolImage(name, size: glyphPointSize,
                                            color: Self.glyphColor.withAlphaComponent(0.88 * alpha))?
            .layerContents(forContentsScale: scale)
    }

    private func setSymbol(_ name: String, on key: Int, alpha: CGFloat = 1) {
        setRowSymbol(name, on: key, secondRow: false, alpha: alpha)
    }

    private static let youtubeBaseImage: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 3 24 18" width="24" height="18" fill="white">
        <path d="M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.377.505 9.377.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z"/>
        </svg>
        """
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }()

    static func youtubeGlyph(size: CGFloat, color: NSColor) -> NSImage? {
        guard let base = youtubeBaseImage else { return nil }
        let aspect: CGFloat = 24.0 / 18.0
        let h = size
        let w = ceil(h * aspect)
        return NSImage(size: CGSize(width: w, height: h), flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        if name == "youtube" {
            return youtubeGlyph(size: size, color: color)
        }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private static func textImage(_ text: String, size: CGFloat) -> NSImage? {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: glyphColor,
        ])
        let bounds = string.size()
        return NSImage(size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)), flipped: false) { _ in
            string.draw(at: .zero)
            return true
        }
    }

    /// Lights a cap and lets it fade back, with a small press on its glyph.
    func flash(key: Int) {
        guard caps.indices.contains(key) else { return }
        let cap = caps[key]
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = Self.pressedColor.cgColor
        fade.toValue = Self.capColor.cgColor
        fade.duration = 0.45
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap.add(fade, forKey: "flash")

        let press = CASpringAnimation(keyPath: "transform.scale")
        press.fromValue = 0.82
        press.toValue = 1
        press.damping = 14
        press.stiffness = 320
        press.duration = press.settlingDuration
        (rowShown ? rowGlyphs : glyphs)[key].add(press, forKey: "press")
    }

    // MARK: Second row

    func setSecondRow(_ actions: [Int: EdgeKeyAction]) {
        secondRow = actions
        let height = (glyphPointSize * 1.05).rounded()
        // esc keeps showing the modifier unless it has an action of its own.
        for key in 0...13 where key > 0 || (actions[0] ?? .none) != .none {
            if EdgeKeyActions.control(at: key, in: actions, firstRow: false) == .playPause {
                setRowSymbol(playing ? "pause.fill" : "play.fill", on: key, secondRow: true)
            } else {
                rowGlyphs[key].contents = actions[key].flatMap { EdgeKeyActions.glyph($0, height: height, color: glyphColor(for: $0)) }?
                    .layerContents(forContentsScale: scale)
            }
        }
        // The trigger F key keeps its first-row ⌘ glyph (it doesn't flip).
        if let trigger = triggerKey { rowGlyphs[trigger].contents = nil }
        placeDisplayDots(secondRow: true)
    }

    /// The F key used as the second-row trigger, if that's the trigger.
    private var triggerKey: Int? {
        let settings = AppSettings.shared
        return settings.edgeKeysLayerModifier == .functionKey ? settings.edgeKeysTriggerKey : nil
    }

    /// A key held down, as a modifier: lit and pressed in for as long as it's
    /// held, springing back on release.
    func setKeyHeld(_ key: Int, _ held: Bool) {
        guard caps.indices.contains(key) else { return }
        let cap = caps[key]
        let color = (held ? NSColor(white: 1, alpha: 0.32) : Self.capColor).cgColor
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = cap.presentation()?.backgroundColor ?? cap.backgroundColor
        fade.toValue = color
        fade.duration = held ? 0.08 : 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap.removeAnimation(forKey: "flash")
        cap.backgroundColor = color
        cap.add(fade, forKey: "held")

        let glyph = glyphs[key]
        let from = glyph.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        let press = CASpringAnimation(keyPath: "transform.scale")
        press.fromValue = from
        press.toValue = held ? 0.84 : 1
        press.damping = held ? 26 : 12
        press.stiffness = held ? 500 : 320
        press.duration = press.settlingDuration
        glyph.transform = held ? CATransform3DMakeScale(0.84, 0.84, 1) : CATransform3DIdentity
        glyph.add(press, forKey: "held")
    }

    private func setModifierGlyph(on layer: CALayer) {
        layer.contents = Self.symbolImage("command", size: glyphPointSize, color: Self.glyphColor)?
            .layerContents(forContentsScale: scale)
    }

    /// Flips every cap between its two rows: going to the second row the
    /// glyphs rise, coming back they sink, a beat apart from left to right.
    func showSecondRow(_ shown: Bool, modifier: EdgeKeysModifier) {
        guard shown != rowShown else { return }
        rowShown = shown
        syncBusy(animated: true)
        // A pinned player covers first-row keys: out of the way for the second
        // row — unless it's in the esc spot, where it stays, like the stats.
        if playerPinned, !playerInEsc {
            if shown { mediaCap?.hide() } else if mediaAvailable { revealMedia() }
        }
        if shown, !playerInEsc, (secondRow[0] ?? EdgeKeyAction.none) == EdgeKeyAction.none {
            let label = modifier == .functionKey ? "F\(AppSettings.shared.edgeKeysTriggerKey)" : modifier.rawValue
            let small = modifier == .fn || modifier == .functionKey
            rowGlyphs[0].contents = Self.textImage(label, size: glyphPointSize * (small ? 0.85 : 1.1))?
                .layerContents(forContentsScale: scale)
        }
        let now = CACurrentMediaTime()
        let lift: CGFloat = 5
        for key in 0...13 {
            // Touch ID keeps its lock unless it has a second-row action, and
            // a Touch ID prompt's fingerprint stays put either way.
            if key == 13, (secondRow[13] ?? EdgeKeyAction.none) == EdgeKeyAction.none || touchIDPrompt { continue }
            if key == triggerKey { continue }
            // The esc-spot player holds still.
            if key == 0, playerInEsc { continue }
            let leaving = shown ? glyphs[key] : rowGlyphs[key]
            let arriving = shown ? rowGlyphs[key] : glyphs[key]
            let delay = Double(key) * 0.008
            // Up into the second row, back down to the first — like the
            // second row sits above the first.
            let direction: CGFloat = shown ? 1 : -1
            animate(leaving, opacity: 0, fromY: 0, toY: lift * direction, begin: now + delay, duration: 0.14)
            animate(arriving, opacity: 1, fromY: -lift * direction, toY: 0, begin: now + delay + 0.04, duration: 0.22)

            // A key with nothing on the second row dims while it shows.
            let empty = key != 0 && key != triggerKey && (secondRow[key] ?? EdgeKeyAction.none) == EdgeKeyAction.none
            let color = (shown && empty ? NSColor(white: 1, alpha: 0.06) : Self.capColor).cgColor
            if caps[key].backgroundColor != color {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = caps[key].presentation()?.backgroundColor ?? caps[key].backgroundColor
                fade.toValue = color
                fade.duration = 0.2
                caps[key].backgroundColor = color
                caps[key].add(fade, forKey: "dim")
            }
        }
    }

    private func animate(_ layer: CALayer, opacity: Float, fromY: CGFloat, toY: CGFloat,
                         begin: CFTimeInterval, duration: CFTimeInterval) {
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "row")
        layer.opacity = opacity
        layer.transform = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = opacity
        let move = CASpringAnimation(keyPath: "transform.translation.y")
        move.fromValue = fromY
        move.toValue = toY
        move.damping = 22
        move.stiffness = 380
        let group = CAAnimationGroup()
        group.animations = [fade, move]
        group.beginTime = begin
        group.duration = duration
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "row")
    }

    private var firstRow: [Int: EdgeKeyAction] = [:]
    private var touchIDPrompt = false

    /// Lock ↔ fingerprint on the Touch ID key, with the same lift as a row
    /// flip; the fingerprint breathes while the prompt is up — red like the
    /// macOS Touch ID prompt's own, or white (a setting).
    // MARK: Busy keys

    private struct Busy {
        let secondRow: Bool
        /// In place of the glyph, while the action's row is up.
        let spinner: CALayer
        /// In the cap's corner, while the other row is up.
        let badge: CALayer
    }
    private var busy: [Int: Busy] = [:]

    /// Six dots round a circle, the brightest travelling clockwise.
    private static func dotSpinner(side: CGFloat, scale: CGFloat) -> CALayer {
        let count = 6
        let period: CFTimeInterval = 0.9
        let replicator = CAReplicatorLayer()
        replicator.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        replicator.instanceCount = count
        replicator.instanceTransform = CATransform3DMakeRotation(-2 * .pi / CGFloat(count), 0, 0, 1)
        replicator.instanceDelay = period / CFTimeInterval(count)
        let dotSide = (side * 0.3).rounded(.up)
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: dotSide, height: dotSide)
        dot.position = CGPoint(x: side / 2, y: side - dotSide / 2)
        dot.cornerRadius = dotSide / 2
        dot.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        dot.contentsScale = scale
        dot.opacity = 0.3
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = period
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        replicator.addSublayer(dot)
        return replicator
    }

    /// `secondRow` is the row the working action is on; nil when it's done.
    func setBusy(_ key: Int, secondRow: Bool?) {
        guard caps.indices.contains(key) else { return }
        let cap = caps[key]
        if let old = busy.removeValue(forKey: key) {
            old.spinner.removeFromSuperlayer()
            old.badge.removeFromSuperlayer()
            let glyph = old.secondRow ? rowGlyphs[key] : glyphs[key]
            glyph.isHidden = false
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.2
            glyph.add(fade, forKey: "back")
        }
        guard let secondRow else {
            syncBusy(animated: true)
            return
        }
        let side = (glyphPointSize * 1.1).rounded()
        let spinner = Self.dotSpinner(side: side, scale: scale)
        spinner.position = CGPoint(x: cap.bounds.midX, y: cap.bounds.midY)
        let badgeSide: CGFloat = 9
        let badge = Self.dotSpinner(side: badgeSide, scale: scale)
        badge.position = CGPoint(x: cap.bounds.maxX - badgeSide / 2 - 4, y: cap.bounds.maxY - badgeSide / 2 - 3)
        cap.addSublayer(spinner)
        cap.addSublayer(badge)
        // The action's own glyph gives way to the spinner for as long as it works.
        (secondRow ? rowGlyphs[key] : glyphs[key]).isHidden = true
        busy[key] = Busy(secondRow: secondRow, spinner: spinner, badge: badge)
        syncBusy(animated: false)
    }

    /// Spinner on the row that has the action, badge on the other.
    private func syncBusy(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.2 : 0)
        CATransaction.setDisableActions(!animated)
        for item in busy.values {
            let onItsRow = item.secondRow == rowShown
            item.spinner.opacity = onItsRow ? 1 : 0
            item.badge.opacity = onItsRow ? 0 : 1
        }
        // A status dot shows with its row, and gives way to a busy badge.
        for (row, dots) in displayDots {
            for (key, dot) in dots {
                dot.opacity = row == rowShown && busy[key] == nil ? 1 : 0
            }
        }
        CATransaction.commit()
    }

    private lazy var fingerprint: CALayer = {
        let layer = CALayer()
        layer.frame = caps[13].bounds
        layer.contentsGravity = .center
        layer.contentsScale = scale
        layer.opacity = 0
        caps[13].addSublayer(layer)
        return layer
    }()

    func setTouchIDPrompt(_ visible: Bool) {
        guard visible != touchIDPrompt else { return }
        touchIDPrompt = visible
        // Whatever the key shows now gives way: the lock, or its second-row glyph.
        let lock = rowShown && (secondRow[13] ?? .none) != .none ? rowGlyphs[13] : glyphs[13]
        let print = fingerprint
        if visible {
            let color = AppSettings.shared.edgeKeysRedFingerprint ? NSColor.systemRed : Self.glyphColor
            print.contents = Self.symbolImage("touchid", size: glyphPointSize * 1.1, color: color)?
                .layerContents(forContentsScale: scale)
        }
        swapTouchIDSpot(promptUp: visible)
        let now = CACurrentMediaTime()
        animate(visible ? lock : print, opacity: 0, fromY: 0, toY: 5, begin: now, duration: 0.14)
        animate(visible ? print : lock, opacity: 1, fromY: -5, toY: 0, begin: now + 0.04, duration: 0.22)
        if visible {
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = 1.12
            breathe.duration = 0.9
            breathe.beginTime = now + 0.3
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            print.add(breathe, forKey: "breathe")
        } else {
            print.removeAnimation(forKey: "breathe")
        }
    }

    /// The always-shown row: each key's own symbol, or what it was reassigned to.
    func setFirstRow(_ actions: [Int: EdgeKeyAction]) {
        firstRow = actions
        let height = (glyphPointSize * 1.05).rounded()
        for key in 1...12 {
            let action = actions[key] ?? .keyDefault
            if EdgeKeyActions.control(at: key, in: actions, firstRow: true) == .playPause {
                setSymbol(playing ? "pause.fill" : "play.fill", on: key)
            } else if action == .keyDefault, let name = Self.symbols[key] {
                setSymbol(name, on: key)
            } else {
                glyphs[key].contents = EdgeKeyActions.glyph(action, height: height, color: glyphColor(for: action))?
                    .layerContents(forContentsScale: scale)
            }
        }
        // The trigger F key is the modifier in both rows: ⌘, standing still
        // while the rest flip (see showSecondRow). A tap still does its action.
        if let trigger = triggerKey { setModifierGlyph(on: glyphs[trigger]) }
        placeDisplayDots(secondRow: false)
    }

    // MARK: Media

    private var mediaCap: MediaCap?
    private var mediaSpan: ClosedRange<Int>?
    private var mediaState: MusicEdgeHUD.State?

    /// The keys that play/pause and skip in the row on screen, side by side.
    private func mediaKeys() -> ClosedRange<Int>? {
        let row = rowShown ? secondRow : firstRow
        let found = (1...12).filter { key in
            guard let control = EdgeKeyActions.control(at: key, in: row, firstRow: !rowShown) else { return false }
            return [.previous, .playPause, .next].contains(control)
        }
        guard let first = found.first else { return nil }
        var runs: [ClosedRange<Int>] = []
        var start = first, end = first
        for key in found.dropFirst() {
            if key == end + 1 { end = key } else { runs.append(start...end); start = key; end = key }
        }
        runs.append(start...end)
        return runs.max { $0.count < $1.count }
    }

    func updateMedia(_ state: MusicEdgeHUD.State) {
        // A read without artwork keeps the cover of the same song.
        var state = state
        if state.art == nil, let shown = mediaState, shown.title == state.title, shown.artist == state.artist {
            state.art = shown.art
        }
        let startedOrStopped = mediaState?.playing != state.playing
        mediaState = state
        mediaCap?.update(state)
        // The play/pause keys follow what the player shows — the source the
        // keys work — not the system's own now-playing app, which can be a
        // different, paused one.
        setPlaying(state.playing)
        // Music starting brings the player back; stopping lets another widget take its place.
        if startedOrStopped, leftWidgetSwitching { updateLeftWidget() }
    }

    /// The player has something to show; its state leads the play/pause keys.
    var hasMediaState: Bool { mediaState != nil }

    private var pager = (index: 0, count: 0)

    func setMediaPager(index: Int, count: Int) {
        pager = (index, count)
        mediaCap?.setPager(index: index, count: count)
    }

    var mediaPagerIndex: Int { pager.index }

    /// Another player: its content comes in vertically, as the pager runs.
    func slideMediaSource(down: Bool) {
        revealMedia()
        mediaCap?.swipe(forward: down, vertical: true)
    }

    var isMediaShown: Bool { mediaCap?.isShown ?? false }
    /// Told each time the player shows, so the strip keeps it fresh.
    var onMediaShown: (() -> Void)?

    /// The player stays up (a setting), except under the second row.
    private var playerPinned = false

    /// Whether any app has a player; with none, a pinned player steps aside.
    private(set) var mediaAvailable = true

    func setMediaAvailable(_ available: Bool) {
        guard available != mediaAvailable else { return }
        mediaAvailable = available
        guard playerPinned, !rowShown || playerInEsc else { return }
        if available { revealPlayer() } else {
            mediaCap?.hide()
            updateLeftWidget()
        }
    }

    func setPinnedPlayer(_ pinned: Bool) {
        guard pinned != playerPinned else { return }
        playerPinned = pinned
        MusicEdgeHUD.shared.keepsFresh = pinned
        if pinned {
            MusicEdgeHUD.shared.refreshForStrip()
            if (!rowShown || playerInEsc) && mediaAvailable { revealPlayer() }
            else { updateLeftWidget() }
        } else {
            mediaCap?.hide()
            updateLeftWidget()
        }
    }

    /// Off (a setting), the media keys stay plain keys: no player at all.
    private var playerEnabled = true

    func setPlayerEnabled(_ enabled: Bool) {
        guard enabled != playerEnabled else { return }
        playerEnabled = enabled
        if !enabled {
            mediaCap?.setVideo(nil)
            mediaCap?.hide()
        }
    }

    // MARK: Stats

    /// The hardware stats, from the Touch ID key's spot out to the strip's
    /// right end — the player's mirror on the left.
    private var statsLayer: CALayer?

    func setStats(_ images: [NSImage]?) {
        guard let images, !images.isEmpty else {
            statsLayer?.removeFromSuperlayer()
            statsLayer = nil
            return
        }
        if statsLayer == nil {
            let layer = CALayer()
            layer.opacity = touchIDPrompt ? 0 : 1
            strip.addSublayer(layer)
            statsLayer = layer
        }
        guard let container = statsLayer else { return }
        // The left player mirrored: after one key gap from F12, out to the
        // display's right edge, the gauges 10 apart (closing in to 7 when
        // tight), and any room to spare split either side of the group.
        let spot = capFrame(13)
        let keyGap = capFrame(1).minX - capFrame(0).maxX
        let start = capFrame(12).maxX
        let region = bounds.width - start
        let widths = images.map(\.size.width)
        let room = region - keyGap
        let total = widths.reduce(0, +)
        let between = images.count > 1
            ? min(10, max(7, ((room - total) / CGFloat(images.count - 1)).rounded(.down))) : 0
        let spare = max(0, room - total - between * CGFloat(images.count - 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: start, y: spot.minY, width: region, height: spot.height)
        var parts = container.sublayers ?? []
        while parts.count < images.count {
            let part = CALayer()
            part.contentsGravity = .resize
            part.contentsScale = scale
            container.addSublayer(part)
            parts.append(part)
        }
        while parts.count > images.count { parts.removeLast().removeFromSuperlayer() }
        var x = keyGap + spare / 2
        for (part, image) in zip(parts, images) {
            part.frame = CGRect(x: x.rounded(), y: ((spot.height - image.size.height) / 2).rounded(),
                                width: image.size.width, height: image.size.height)
            part.contents = image.layerContents(forContentsScale: scale)
            x += image.size.width + between
        }
        CATransaction.commit()
    }

    /// During a Touch ID prompt, the key's spot either brings back a key with
    /// a fingerprint, or — the hint style — shows the lock screen's hint: a
    /// bar on the display's edge under "Touch ID", as wide as a key. Whatever
    /// sat there (the stats, the lock) gives way with the same motion.
    private func swapTouchIDSpot(promptUp: Bool) {
        let cap = caps[13]
        let hint = AppSettings.shared.edgeKeysTouchIDHint
        let keyShown = AppSettings.shared.edgeKeysShowTouchID
        guard hint || !keyShown else { return }
        let now = CACurrentMediaTime()
        if let statsLayer {
            animate(statsLayer, opacity: promptUp ? 0 : 1, fromY: promptUp ? 0 : 8, toY: promptUp ? 8 : 0,
                    begin: promptUp ? now : now + 0.1, duration: promptUp ? 0.2 : 0.3)
        }
        if hint {
            if keyShown {
                animate(cap, opacity: promptUp ? 0 : 1, fromY: promptUp ? 0 : 8, toY: promptUp ? 8 : 0,
                        begin: promptUp ? now : now + 0.1, duration: promptUp ? 0.2 : 0.3)
            }
            showTouchIDHint(promptUp, at: now)
            return
        }
        if promptUp {
            cap.isHidden = false
            animate(cap, opacity: 1, fromY: -8, toY: 0, begin: now + 0.06, duration: 0.3)
        } else {
            animate(cap, opacity: 0, fromY: 0, toY: -8, begin: now, duration: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.touchIDPrompt, !AppSettings.shared.edgeKeysShowTouchID else { return }
                cap.isHidden = true
                cap.opacity = 1
            }
        }
    }

    private var touchIDHintBar: CALayer?
    private var touchIDHintLabel: CALayer?

    /// The bar draws out from its centre along the edge, then the label
    /// rises in; leaving, the bar pinches back and the label fades.
    private func showTouchIDHint(_ shown: Bool, at now: CFTimeInterval) {
        let spot = capFrame(13)
        // The lock screen hint's own bar.
        let barWidth = TouchIDHintView.barSize.width
        let barHeight = TouchIDHintView.barSize.height
        if touchIDHintBar == nil {
            let bar = CALayer()
            bar.cornerRadius = barHeight
            bar.cornerCurve = .continuous
            bar.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            bar.opacity = 0
            strip.addSublayer(bar)
            touchIDHintBar = bar
            let label = CALayer()
            label.contentsGravity = .center
            label.contentsScale = scale
            label.opacity = 0
            strip.addSublayer(label)
            touchIDHintLabel = label
        }
        guard let bar = touchIDHintBar, let label = touchIDHintLabel else { return }
        // The lock screen hint's look: white, with its soft glow.
        let color = NSColor.white
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [bar, label] {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOffset = .zero
        }
        // LockScreenTouchID's dark style: glow 0.5, bar at 0.45 of it, label 0.5.
        bar.shadowOpacity = 0.5 * 0.45
        bar.shadowRadius = 6
        label.shadowOpacity = 0.5 * 0.5
        label.shadowRadius = 7
        // On the display's edge — the strip's bottom — over the key's spot.
        bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        bar.position = CGPoint(x: spot.midX, y: barHeight / 2)
        bar.backgroundColor = color.cgColor
        let text = NSAttributedString(string: "Touch ID", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        label.contents = NSImage(size: CGSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { _ in
            text.draw(at: .zero)
            return true
        }.layerContents(forContentsScale: scale)
        label.bounds = CGRect(x: 0, y: 0, width: ceil(size.width), height: ceil(size.height))
        // Where the lock screen puts it: 15 pt above the bar.
        label.position = CGPoint(x: spot.midX, y: barHeight + 15)
        CATransaction.commit()

        bar.removeAllAnimations()
        label.removeAllAnimations()
        let fromWidth = bar.presentation()?.bounds.width ?? (shown ? 4 : barWidth)
        if shown {
            bar.opacity = 1
            let grow = CASpringAnimation(keyPath: "bounds.size.width")
            grow.fromValue = 4
            grow.toValue = barWidth
            grow.damping = 16
            grow.stiffness = 220
            grow.duration = grow.settlingDuration
            bar.add(grow, forKey: "grow")
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.55
            breathe.duration = 1.4
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.beginTime = now + 0.6
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(breathe, forKey: "breathe")
            // The label rises in a beat after the bar.
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -6
            rise.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let appear = CAAnimationGroup()
            appear.animations = [rise, fade]
            appear.duration = 0.4
            appear.beginTime = now + 0.12
            appear.fillMode = .backwards
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.opacity = 1
            label.add(appear, forKey: "appear")
        } else {
            // The unlock: the bar pinches into its centre, the label shrinks away.
            let pinch = CABasicAnimation(keyPath: "bounds.size.width")
            pinch.fromValue = fromWidth
            pinch.toValue = barHeight
            let barFade = CABasicAnimation(keyPath: "opacity")
            barFade.fromValue = bar.presentation()?.opacity ?? 1
            barFade.toValue = 0
            let barGroup = CAAnimationGroup()
            barGroup.animations = [pinch, barFade]
            barGroup.duration = 0.16
            barGroup.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
            bar.opacity = 0
            bar.add(barGroup, forKey: "leave")
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.9
            let labelFade = CABasicAnimation(keyPath: "opacity")
            labelFade.fromValue = label.presentation()?.opacity ?? 1
            labelFade.toValue = 0
            let leave = CAAnimationGroup()
            leave.animations = [shrink, labelFade]
            leave.duration = 0.1
            leave.timingFunction = CAMediaTimingFunction(name: .easeIn)
            label.opacity = 0
            label.add(leave, forKey: "leave")
        }
    }

    /// The player sits in the esc key's spot (esc off, a setting) instead of
    /// over the media keys.
    private var playerInEsc = false

    func setPlayerInEsc(_ inEsc: Bool) {
        guard inEsc != playerInEsc else { return }
        playerInEsc = inEsc
        mediaCap?.hide()
        mediaCap?.removeFromSuperlayer()
        mediaCap = nil
        mediaSpan = nil
        if playerPinned, !rowShown || inEsc, mediaAvailable {
            revealPlayer()
        } else {
            updateLeftWidget()
        }
    }

    /// The media keys merge into a small player — for a moment, or for good
    /// when pinned.
    /// SP8CE's video, shown in the player in place of the cover (see `MediaCap.setVideo`).
    private var video: EdgeVideo?

    func setVideo(_ video: EdgeVideo?) {
        let wasHosting = self.video != nil
        self.video = video
        guard playerEnabled else { return }
        if let video {
            if !wasHosting || mediaCap == nil { revealMedia() }
            mediaCap?.setVideo(video)
            if !wasHosting { mediaCap?.show(stays: true) }
        } else if wasHosting {
            mediaCap?.setVideo(nil)
            // Back to what it was: a player that isn't pinned steps down after a moment.
            if !(playerPinned && (!rowShown || playerInEsc) && mediaAvailable) {
                mediaCap?.show(stays: false)
            }
        }
        // A video is the player's to show, whatever else the left widget was doing.
        if leftWidgetSwitching { updateLeftWidget() }
    }

    /// Where SP8CE draws its video, in window coordinates, and the slot's corner radius.
    func videoSlotRect() -> (CGRect, CGFloat)? {
        guard video != nil, playerEnabled, let cap = mediaCap, cap.isShown,
              let slot = cap.videoSlot, let root = layer else { return nil }
        return (convert(cap.convert(slot, to: root), to: nil), cap.videoRadius)
    }

    func revealMedia(hideWeather: Bool = true) {
        let inEsc = playerInEsc && AppSettings.shared.edgeKeysPlayerInEsc
        guard playerEnabled, let keys = inEsc ? 0...0 : (AppSettings.shared.edgeKeysMediaPlayer ? mediaKeys() : nil) else { return }
        if hideWeather {
            weatherCap?.hide()
            calendarCap?.hide()
            usageCap?.hide()
        }
        if mediaSpan != keys {
            mediaCap?.removeFromSuperlayer()
            var capF = capFrame(keys.lowerBound).union(capFrame(keys.upperBound))
            if inEsc {
                // From the display's left edge to one key gap before F1.
                capF = CGRect(x: 0, y: capF.minY, width: capF.maxX, height: capF.height)
            }
            let thirdKey = min(keys.upperBound, keys.lowerBound + 2)
            let thirdCenter: CGFloat? = keys.count < 3 ? nil : capFrame(thirdKey).midX - capF.minX
            let cap = MediaCap(frame: capF, radius: capRadius, scale: scale, thirdKeyCenter: thirdCenter,
                               plain: inEsc,
                               textGap: inEsc ? capFrame(1).minX - capFrame(0).maxX : 7)
            cap.onHidden = { [weak self] in self?.updateLeftWidget() }
            strip.addSublayer(cap)
            mediaCap = cap
            mediaSpan = keys
        }
        if let mediaState { mediaCap?.update(mediaState) }
        if let video { mediaCap?.setVideo(video) }
        mediaCap?.setPager(index: pager.index, count: pager.count)
        mediaCap?.show(stays: playerPinned && (!rowShown || inEsc) && mediaAvailable)
        onMediaShown?()
    }

    /// A quick shake: that player won't take commands from here (Dia, say,
    /// while another app is the system's now-playing one).
    func nudgeMedia() {
        guard let cap = mediaCap, cap.isShown else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -5, 5, -3, 3, 0]
        shake.duration = 0.32
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cap.add(shake, forKey: "nudge")
    }

    // MARK: - Weather, calendar and AI usage in Esc Spot

    private var weatherCap: GlanceCap?
    private var weatherData: WeatherData?
    private var calendarCap: GlanceCap?
    private var calendarEntry: CalendarFeed.Entry?
    private var usageCap: UsageCap?
    private var usageSnapshot: TokenBarSnapshot?
    private var updatingLeftWidget = false
    private var leftWidgetTimer: Timer?

    private var weatherAllowed: Bool { playerInEsc && AppSettings.shared.edgeKeysWeatherInEsc }
    private var calendarAllowed: Bool { playerInEsc && AppSettings.shared.edgeKeysCalendarInEsc }
    private var usageAllowed: Bool { playerInEsc && AppSettings.shared.edgeKeysUsageInEsc }
    private var mediaAllowed: Bool {
        if playerInEsc {
            return AppSettings.shared.edgeKeysPlayerInEsc
        }
        return AppSettings.shared.edgeKeysMediaPlayer
    }
    /// The esc spot has more than one widget to cycle through.
    private var leftWidgetSwitching: Bool { leftWidgetCycle().count > 1 }

    /// The widgets turned on, in order.
    private func leftWidgetCycle() -> [LeftWidgetMode] {
        (mediaAllowed ? [.media] : []) + (weatherAllowed ? [.weather] : [])
            + (calendarAllowed ? [.calendar] : []) + (usageAllowed ? [.usage] : [])
    }

    /// The player has something to show: with no app playing anything it's an empty black cap.
    private var mediaHasContent: Bool { mediaAvailable || video != nil }

    /// The widgets a sideways swipe goes through: those turned on, less an empty player.
    private func leftWidgetSwipeCycle() -> [LeftWidgetMode] {
        leftWidgetCycle().filter { $0 != .media || mediaHasContent }
    }

    /// More than one widget to swipe between; with only one, a swipe leaves it be.
    private var leftWidgetSwipeable: Bool { leftWidgetSwipeCycle().count > 1 }

    private func isLeftWidgetShown(_ mode: LeftWidgetMode) -> Bool {
        switch mode {
        case .media:   return mediaCap?.isShown == true
        case .weather: return weatherCap?.isShown == true
        case .calendar: return calendarCap?.isShown == true
        case .usage:   return usageCap?.isShown == true
        }
    }

    private var leftWidgetHeld: Bool {
        leftWidgetChosenAt.map { CACurrentMediaTime() - $0 < Self.leftWidgetHold } ?? false
    }

    /// What the esc spot shows when nobody has chosen: the player while music plays, else the AI
    /// usage while an AI is working, else an event under way or within the hour, else the weather,
    /// else the player with something in it, the calendar, the usage, the player.
    private func preferredLeftWidget() -> LeftWidgetMode {
        if leftWidgetHeld, leftWidgetCycle().contains(leftWidgetMode) { return leftWidgetMode }
        if mediaAllowed, video != nil || (mediaAvailable && mediaState?.playing == true) { return .media }
        if usageAllowed, AIUsageFeed.shared.anyRecentlyActive { return .usage }
        if calendarAllowed, let entry = calendarEntry, CalendarFeed.isSoon(entry) { return .calendar }
        if weatherAllowed { return .weather }
        if mediaAllowed, mediaHasContent { return .media }
        if calendarAllowed { return .calendar }
        return mediaAllowed ? .media : (usageAllowed ? .usage : .media)
    }

    /// Puts the right widget up: on the spot, or with the sideways slide when another one is
    /// showing. Called whenever anything it depends on changes.
    func updateLeftWidget() {
        guard !updatingLeftWidget else { return }
        updatingLeftWidget = true
        defer { updatingLeftWidget = false }
        if !weatherAllowed {
            weatherCap?.hide()
            weatherCap?.removeFromSuperlayer()
            weatherCap = nil
        }
        if !calendarAllowed {
            calendarCap?.hide()
            calendarCap?.removeFromSuperlayer()
            calendarCap = nil
        }
        if !usageAllowed {
            usageCap?.hide()
            usageCap?.removeFromSuperlayer()
            usageCap = nil
        }
        if !mediaAllowed && playerInEsc {
            mediaCap?.hide()
            mediaCap?.removeFromSuperlayer()
            mediaCap = nil
        }
        let cycle = leftWidgetCycle()
        guard !cycle.isEmpty else {
            leftWidgetMode = .media
            leftWidgetChosenAt = nil
            return
        }
        let target = preferredLeftWidget()
        // Chosen by activity: open on the page of the AI that worked last, unless the user has flipped it.
        var page: Int?
        if target == .usage, !leftWidgetHeld, let provider = AIUsageFeed.shared.mostRecentlyActiveProvider {
            page = UsageCap.page(for: provider)
        }
        if target != leftWidgetMode, isLeftWidgetShown(leftWidgetMode) {
            // The same slide as a swipe, the short way round.
            let forward: Bool
            if let from = cycle.firstIndex(of: leftWidgetMode), let to = cycle.firstIndex(of: target) {
                forward = (to - from + cycle.count) % cycle.count <= cycle.count / 2
            } else {
                forward = true
            }
            transitionLeftWidget(to: target, forward: forward, usagePage: page)
            return
        }
        leftWidgetMode = target
        switch target {
        case .media:
            weatherCap?.hide()
            calendarCap?.hide()
            usageCap?.hide()
            revealMedia(hideWeather: true)
        case .weather:
            calendarCap?.hide()
            usageCap?.hide()
            revealWeather(hideMedia: true)
        case .calendar:
            weatherCap?.hide()
            usageCap?.hide()
            revealCalendar(hideMedia: true)
        case .usage:
            weatherCap?.hide()
            calendarCap?.hide()
            revealUsage(hideMedia: true, page: page)
        }
    }

    /// The player where the mode logic puts it, or plainly where there is no mode logic.
    private func revealPlayer() {
        if playerInEsc { updateLeftWidget() } else { revealMedia() }
    }

    func revealWeather(hideMedia: Bool = true) {
        guard playerInEsc, AppSettings.shared.edgeKeysWeatherInEsc else { return }
        if hideMedia { mediaCap?.hide() }
        let keys = 0...0
        var capF = capFrame(keys.lowerBound).union(capFrame(keys.upperBound))
        capF = CGRect(x: 0, y: capF.minY, width: capF.maxX, height: capF.height)

        if weatherCap == nil || weatherCap?.frame != capF {
            weatherCap?.removeFromSuperlayer()
            let cap = GlanceCap(frame: capF, radius: capRadius, scale: scale)
            strip.addSublayer(cap)
            weatherCap = cap
        }
        weatherCap?.update(weatherData ?? WeatherMonitor.shared.currentWeather)
        weatherCap?.show()
    }

    func updateWeather(_ weather: WeatherData?) {
        weatherData = weather
        weatherCap?.update(weather)
        if playerInEsc, leftWidgetMode == .weather {
            revealWeather(hideMedia: true)
        }
    }

    func revealCalendar(hideMedia: Bool = true) {
        guard calendarAllowed else { return }
        if hideMedia { mediaCap?.hide() }
        var capF = capFrame(0)
        capF = CGRect(x: 0, y: capF.minY, width: capF.maxX, height: capF.height)

        if calendarCap == nil || calendarCap?.frame != capF {
            calendarCap?.removeFromSuperlayer()
            let cap = GlanceCap(frame: capF, radius: capRadius, scale: scale)
            strip.addSublayer(cap)
            calendarCap = cap
        }
        calendarCap?.update(calendar: calendarEntry)
        calendarCap?.show()
    }

    /// The next event or reminder changed, or a minute went by: the countdown moves on.
    func updateCalendar(reevaluate: Bool = true) {
        guard calendarAllowed else { return }
        CalendarFeed.shared.refresh()
        calendarEntry = CalendarFeed.shared.next()
        calendarCap?.update(calendar: calendarEntry)
        // An event coming up within the hour takes over from the weather.
        if reevaluate, leftWidgetSwitching { updateLeftWidget() }
    }

    /// `page`: the page to open on (flipping to it if the widget is up).
    func revealUsage(hideMedia: Bool = true, page: Int? = nil) {
        guard playerInEsc, AppSettings.shared.edgeKeysUsageInEsc else { return }
        if hideMedia { mediaCap?.hide() }
        var capF = capFrame(0)
        capF = CGRect(x: 0, y: capF.minY, width: capF.maxX, height: capF.height)

        if usageCap == nil || usageCap?.frame != capF || usageCap?.bars != UsageCap.barsStyle {
            usageCap?.removeFromSuperlayer()
            let cap = UsageCap(frame: capF, radius: capRadius, scale: scale, corners: Self.roundedCorners)
            strip.addSublayer(cap)
            usageCap = cap
        }
        usageCap?.update(usageSnapshot ?? AIUsageFeed.shared.snapshot, stale: AIUsageFeed.shared.isStale)
        usageCap?.setPulseAllowed(PresentationState.shared.canPresent)
        if let page { usageCap?.showPage(page, animated: usageCap?.isShown == true) }
        usageCap?.show()
    }

    func updateUsage(_ snapshot: TokenBarSnapshot?, reevaluate: Bool = true) {
        usageSnapshot = snapshot
        usageCap?.update(snapshot, stale: AIUsageFeed.shared.isStale)
        // Activity may have started or stopped, or moved to the other page.
        if reevaluate, leftWidgetSwitching { updateLeftWidget() }
    }

    /// Off while the screen is locked or asleep: the active dot's pulse repeats for as long as it shows.
    func setUsagePulse(_ allowed: Bool) {
        usageCap?.setPulseAllowed(allowed)
    }

    /// While the strip shows, the widget follows the activity: the three-minute "recently active"
    /// window and the minute a swipe holds both end without any event to say so.
    func setLeftWidgetTicking(_ on: Bool) {
        guard on else {
            leftWidgetTimer?.invalidate()
            leftWidgetTimer = nil
            return
        }
        guard leftWidgetTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
            // The strip was rebuilt: this view is gone.
            guard let self else { timer.invalidate(); return }
            self.updateCalendar(reevaluate: false)
            self.updateUsage(self.usageSnapshot)
        }
        timer.tolerance = 5
        leftWidgetTimer = timer
    }

    private func flipUsagePage(down: Bool) {
        leftWidgetChosenAt = CACurrentMediaTime()
        usageCap?.flipPage(down: down)
    }

    private func slideOutLeftWidget(_ mode: LeftWidgetMode, forward: Bool) {
        // Only if it hasn't been brought back meanwhile by another swipe.
        func done() -> () -> Void { { [weak self] in
            guard let self, self.leftWidgetMode != mode else { return }
            switch mode {
            case .media:   self.mediaCap?.hide(animated: false)
            case .weather: self.weatherCap?.hide(animated: false)
            case .calendar: self.calendarCap?.hide(animated: false)
            case .usage:   self.usageCap?.hide(animated: false)
            }
        } }
        switch mode {
        case .media:   mediaCap?.slideOut(forward: forward, completion: done())
        case .weather: weatherCap?.slideOut(forward: forward, completion: done())
        case .calendar: calendarCap?.slideOut(forward: forward, completion: done())
        case .usage:   usageCap?.slideOut(forward: forward, completion: done())
        }
    }

    private func slideInLeftWidget(_ mode: LeftWidgetMode, forward: Bool, usagePage: Int? = nil) {
        switch mode {
        case .media:
            revealMedia(hideWeather: false)
            mediaCap?.slideIn(forward: forward)
        case .weather:
            revealWeather(hideMedia: false)
            weatherCap?.slideIn(forward: forward)
        case .calendar:
            revealCalendar(hideMedia: false)
            calendarCap?.slideIn(forward: forward)
        case .usage:
            revealUsage(hideMedia: false, page: usagePage)
            usageCap?.slideIn(forward: forward)
        }
    }

    /// The old widget slides out and the new one in.
    private func transitionLeftWidget(to target: LeftWidgetMode, forward: Bool, usagePage: Int? = nil) {
        // The widgets' slides are explicit animations; anything implicit here crossfaded the whole
        // strip, leaving a still copy of the music widget fading in place under the one sliding out.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let old = leftWidgetMode
        leftWidgetMode = target
        slideOutLeftWidget(old, forward: forward)
        slideInLeftWidget(target, forward: forward, usagePage: usagePage)
    }

    /// A sideways swipe: to the next widget in the cycle (media, weather, calendar, usage), or the
    /// previous; never to an empty player.
    func switchLeftWidget(forward: Bool) {
        guard playerInEsc, leftWidgetSwipeable else { return }
        let cycle = leftWidgetSwipeCycle()
        let at = cycle.firstIndex(of: leftWidgetMode) ?? 0
        let next = cycle[(at + (forward ? 1 : cycle.count - 1)) % cycle.count]
        guard next != leftWidgetMode else { return }
        leftWidgetChosenAt = CACurrentMediaTime()
        transitionLeftWidget(to: next, forward: forward)
    }

    func swipeMedia(forward: Bool) {
        guard playerEnabled else { return }
        revealMedia()
        mediaCap?.swipe(forward: forward)
    }

    // MARK: Display state

    private var displayStates: [String: DisplayLinkState] = [:]
    private var amphetamineActive: Bool?
    private var warpState: CloudflareWARP.State = .unknown
    private var warpBusy = false
    private var microphoneState: (exists: Bool, muted: Bool, inUse: Bool) = (false, false, false)
    /// Status dots, keyed by row (false = first) and key.
    private var displayDots: [Bool: [Int: CALayer]] = [:]

    func setDisplayStates(_ states: [String: DisplayLinkState]) {
        guard states != displayStates else { return }
        displayStates = states
        setFirstRow(firstRow)
        setSecondRow(secondRow)
    }

    func setAmphetamineActive(_ active: Bool?) {
        guard active != amphetamineActive else { return }
        amphetamineActive = active
        setFirstRow(firstRow)
        setSecondRow(secondRow)
    }

    func setWARPState(_ state: CloudflareWARP.State, busy: Bool) {
        guard state != warpState || busy != warpBusy else { return }
        warpState = state
        warpBusy = busy
        setFirstRow(firstRow)
        setSecondRow(secondRow)
    }

    func setMicrophoneState(exists: Bool, muted: Bool, inUse: Bool) {
        let next = (exists, muted, inUse)
        guard next != microphoneState else { return }
        microphoneState = next
        setFirstRow(firstRow)
        setSecondRow(secondRow)
    }

    private func linkState(_ action: EdgeKeyAction) -> DisplayLinkState? {
        switch action {
        case .displayToggle(let uuid): return displayStates[uuid]
        case .amphetamineToggle: return amphetamineActive.map { $0 ? .connected : .disconnected }
        case .cloudflareWARPToggle:
            if warpBusy { return .connecting }
            switch warpState {
            case .connected: return .connected
            case .disconnected: return .disconnected
            case .connecting, .disconnecting: return .connecting
            case .failed: return .muted
            case .unknown, .unavailable: return .absent
            }
        case .microphoneToggle:
            guard microphoneState.exists else { return .absent }
            if microphoneState.muted {
                return .muted
            }
            if microphoneState.inUse {
                return .connected
            }
            return .disconnected
        default: return nil
        }
    }

    /// Dimmed when the display isn't plugged in at all.
    private func glyphColor(for action: EdgeKeyAction) -> NSColor {
        linkState(action) == .absent ? NSColor(white: 1, alpha: 0.3) : Self.glyphColor
    }

    private func placeDisplayDots(secondRow row: Bool) {
        displayDots[row]?.values.forEach { $0.removeFromSuperlayer() }
        displayDots[row] = [:]
        let actions = row ? secondRow : firstRow
        for (key, action) in actions where caps.indices.contains(key) && key != triggerKey {
            guard let state = linkState(action), state != .absent else { continue }
            let side: CGFloat = 6
            let cap = caps[key]
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.position = CGPoint(x: cap.bounds.maxX - side / 2 - 5, y: cap.bounds.maxY - side / 2 - 4)
            dot.cornerRadius = side / 2
            switch state {
            case .connected:
                dot.backgroundColor = NSColor.systemGreen.cgColor
                dot.shadowColor = NSColor.systemGreen.cgColor
                dot.shadowOpacity = 0.6
                dot.shadowRadius = 2.5
                dot.shadowOffset = .zero
            case .muted:
                dot.backgroundColor = NSColor.systemRed.cgColor
                dot.shadowColor = NSColor.systemRed.cgColor
                dot.shadowOpacity = 0.6
                dot.shadowRadius = 2.5
                dot.shadowOffset = .zero
            case .disconnected:
                dot.backgroundColor = NSColor(white: 1, alpha: 0.35).cgColor
            case .connecting:
                dot.backgroundColor = NSColor.systemYellow.cgColor
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.35
                pulse.duration = 0.6
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                dot.add(pulse, forKey: "connecting")
            case .absent:
                break
            }
            cap.addSublayer(dot)
            displayDots[row]?[key] = dot
        }
        syncBusy(animated: false)
    }

    func setPlaying(_ playing: Bool) {
        mediaCap?.setPlaying(playing)
        guard playing != self.playing else { return }
        self.playing = playing

        let name = playing ? "pause.fill" : "play.fill"

        for key in 1...12 {
            if EdgeKeyActions.control(at: key, in: firstRow, firstRow: true) == .playPause {
                let glyph = glyphs[key]
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.18
                glyph.add(transition, forKey: "swap")
                setSymbol(name, on: key)
            }
        }

        for key in 0...13 {
            if EdgeKeyActions.control(at: key, in: secondRow, firstRow: false) == .playPause {
                let glyph = rowGlyphs[key]
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.18
                glyph.add(transition, forKey: "swap")
                setRowSymbol(name, on: key, secondRow: true)
            }
        }
    }

    /// False when no key on screen controls it, so the caller shows a HUD elsewhere.
    func showLevel(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                   audioOutputKind: AudioOutputKind?) -> Bool {
        guard let keys = levelKeys(for: kind) else { return false }
        if levelSpans[kind] != keys {
            // The keys moved (reassigned, or the other row is up): a new cap there.
            levels[kind]?.removeFromSuperlayer()
            let level = LevelCap(caps: keys.map(capFrame), radius: capRadius, corners: Self.roundedCorners,
                                 glyphSize: glyphPointSize, scale: scale)
            strip.addSublayer(level)
            levels[kind] = level
            levelSpans[kind] = keys
        }
        levels[kind]?.show(kind: kind, value: value, muted: muted,
                           audioOutputKind: audioOutputKind)
        return true
    }
}

// MARK: - Level cap

/// The brightness or volume keys merged into one cap, with an icon and a level
/// bar — shown over them for a moment after they change the level.
///
/// It is the keys themselves that seem to stretch: the cap starts out shaped
/// exactly like the caps under it and melts into one bar, then splits back
/// into them before it fades, so neither end has a visible seam. The shape is
/// this layer's mask, one rounded rect per key throughout — as separate caps,
/// then stretched to overlap into a single bar — so every step in between is
/// a straight interpolation of the same path. The icon and bar ride in on
/// their own, a beat after the shape, so they're never squashed by it.
private final class LevelCap: CALayer {
    private static let linger: TimeInterval = 1.4

    private let shape = CAShapeLayer()
    private let content = CALayer()
    private let icon = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let glyphSize: CGFloat
    private let capsPath: CGPath
    private let barPath: CGPath
    private var hideWork: DispatchWorkItem?
    private var shown = false

    /// `caps` are the keys' frames in the strip.
    init(caps: [CGRect], radius: CGFloat, corners: CACornerMask, glyphSize: CGFloat, scale: CGFloat) {
        self.glyphSize = glyphSize
        let frame = caps.dropFirst().reduce(caps.first ?? .zero) { $0.union($1) }
        let local = caps.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        capsPath = Self.path(local, radius: radius, corners: corners)
        barPath = Self.path(Self.barSegments(local, width: frame.width, radius: radius),
                            radius: radius, corners: corners)
        super.init()
        self.frame = frame
        // The keys' own grey (white at 0.14 over the black strip), opaque so the
        // caps under it don't show through.
        backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        opacity = 0

        shape.frame = bounds
        shape.path = capsPath
        shape.fillColor = NSColor.black.cgColor
        mask = shape

        content.frame = bounds
        content.opacity = 0
        addSublayer(content)

        let iconSide = frame.height
        icon.frame = CGRect(x: 4, y: 0, width: iconSide, height: frame.height)
        icon.contentsGravity = .center
        icon.contentsScale = scale
        content.addSublayer(icon)

        let trackHeight: CGFloat = 4
        let trackX = icon.frame.maxX + 2
        track.frame = CGRect(x: trackX, y: ((frame.height - trackHeight) / 2).rounded(),
                             width: max(10, frame.width - trackX - 12), height: trackHeight)
        track.cornerRadius = trackHeight / 2
        track.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        track.masksToBounds = true
        content.addSublayer(track)

        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackHeight)
        fill.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        track.addSublayer(fill)
    }

    override init(layer: Any) {
        let other = layer as? LevelCap
        glyphSize = other?.glyphSize ?? 14
        capsPath = other?.capsPath ?? CGMutablePath()
        barPath = other?.barPath ?? CGMutablePath()
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(kind: SystemHUDKind, value: CGFloat, muted: Bool,
              audioOutputKind: AudioOutputKind?) {
        let level = muted ? 0 : max(0, min(1, value))
        let image = IndicatorRenderer.systemHUDIcon(
            kind: kind, value: level, muted: muted, audioOutputKind: audioOutputKind,
            deviceIcons: AppSettings.shared.systemHUDDeviceIcons,
            pointSize: glyphSize, color: NSColor(white: 1, alpha: 0.9))
        icon.contents = image?.layerContents(forContentsScale: icon.contentsScale)

        // The level: a quick glide between presses, a longer fill as it appears.
        CATransaction.begin()
        CATransaction.setAnimationDuration(shown ? 0.16 : 0.34)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1))
        fill.bounds.size.width = track.bounds.width * level
        CATransaction.commit()

        if !shown {
            shown = true
            let now = CACurrentMediaTime()
            for key in ["hideFade", "split"] { removeAnimation(forKey: key); shape.removeAnimation(forKey: key) }
            content.removeAnimation(forKey: "contentOut")

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let fromOpacity = presentation()?.opacity ?? 0
            let fromPath = shape.presentation()?.path ?? capsPath
            let fromContent = content.presentation()?.opacity ?? 0
            opacity = 1
            shape.path = barPath
            content.opacity = 1
            CATransaction.commit()

            // Shaped like the keys, so a short fade is all the entrance needs.
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            fade.toValue = 1
            fade.duration = 0.1
            add(fade, forKey: "appear")

            // The keys melt into one bar, easing to a stop without overshooting.
            let merge = CABasicAnimation(keyPath: "path")
            merge.fromValue = fromPath
            merge.toValue = barPath
            merge.duration = 0.32
            merge.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            shape.add(merge, forKey: "merge")

            // Then the icon and bar ride in.
            let contentIn = CABasicAnimation(keyPath: "opacity")
            contentIn.fromValue = fromContent
            contentIn.toValue = 1
            contentIn.beginTime = now + 0.06
            contentIn.duration = 0.22
            contentIn.fillMode = .backwards
            contentIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.add(contentIn, forKey: "contentIn")
            let lift = CABasicAnimation(keyPath: "transform.scale")
            lift.fromValue = 0.94
            lift.toValue = 1
            lift.beginTime = now + 0.06
            lift.duration = 0.3
            lift.fillMode = .backwards
            lift.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            content.add(lift, forKey: "lift")
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    private func hide() {
        guard shown else { return }
        shown = false
        let now = CACurrentMediaTime()
        for key in ["appear"] { removeAnimation(forKey: key) }
        shape.removeAnimation(forKey: "merge")
        content.removeAnimation(forKey: "contentIn")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fromPath = shape.presentation()?.path ?? barPath
        let fromContent = content.presentation()?.opacity ?? 1
        content.opacity = 0
        shape.path = capsPath
        opacity = 0
        CATransaction.commit()

        // The icon and bar go first…
        let contentOut = CABasicAnimation(keyPath: "opacity")
        contentOut.fromValue = fromContent
        contentOut.toValue = 0
        contentOut.duration = 0.14
        contentOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        content.add(contentOut, forKey: "contentOut")

        // …the bar splits back into the keys…
        let split = CABasicAnimation(keyPath: "path")
        split.fromValue = fromPath
        split.toValue = capsPath
        split.beginTime = now + 0.06
        split.duration = 0.3
        split.fillMode = .backwards
        split.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        shape.add(split, forKey: "split")

        // …and fades away over them as it settles into their shape, so their
        // glyphs are already coming back when the split lands.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = now + 0.2
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.fillMode = .backwards
        add(fade, forKey: "hideFade")
    }

    // MARK: Shape

    /// One segment per key covering the bar: each reaches from its key to the
    /// middle of the gaps beside it and past by more than the corner radius,
    /// so neighbours overlap and their inner corners are covered.
    private static func barSegments(_ caps: [CGRect], width: CGFloat, radius: CGFloat) -> [CGRect] {
        let overlap = radius + 1
        return caps.indices.map { i in
            let left = i == 0 ? 0 : (caps[i - 1].maxX + caps[i].minX) / 2 - overlap
            let right = i == caps.count - 1 ? width : (caps[i].maxX + caps[i + 1].minX) / 2 + overlap
            return CGRect(x: left, y: caps[i].minY, width: right - left, height: caps[i].height)
        }
    }

    /// Rounded rects with the same number and kind of elements whatever the
    /// radius or corners (an unrounded corner is a zero-length curve), so any
    /// two such paths interpolate. Corners follow CACornerMask's convention.
    private static func path(_ rects: [CGRect], radius: CGFloat, corners: CACornerMask) -> CGPath {
        let path = CGMutablePath()
        let k: CGFloat = 0.5523
        for r in rects {
            let bl = corners.contains(.layerMinXMinYCorner) ? radius : 0
            let br = corners.contains(.layerMaxXMinYCorner) ? radius : 0
            let tr = corners.contains(.layerMaxXMaxYCorner) ? radius : 0
            let tl = corners.contains(.layerMinXMaxYCorner) ? radius : 0
            path.move(to: CGPoint(x: r.minX + bl, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - br, y: r.minY))
            path.addCurve(to: CGPoint(x: r.maxX, y: r.minY + br),
                          control1: CGPoint(x: r.maxX - br + br * k, y: r.minY),
                          control2: CGPoint(x: r.maxX, y: r.minY + br - br * k))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tr))
            path.addCurve(to: CGPoint(x: r.maxX - tr, y: r.maxY),
                          control1: CGPoint(x: r.maxX, y: r.maxY - tr + tr * k),
                          control2: CGPoint(x: r.maxX - tr + tr * k, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX + tl, y: r.maxY))
            path.addCurve(to: CGPoint(x: r.minX, y: r.maxY - tl),
                          control1: CGPoint(x: r.minX + tl - tl * k, y: r.maxY),
                          control2: CGPoint(x: r.minX, y: r.maxY - tl + tl * k))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + bl))
            path.addCurve(to: CGPoint(x: r.minX + bl, y: r.minY),
                          control1: CGPoint(x: r.minX, y: r.minY + bl - bl * k),
                          control2: CGPoint(x: r.minX + bl - bl * k, y: r.minY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Media cap

/// Previous, play/pause and next merged into one key: artwork, the song,
/// whether it plays, and how far along — like the pop-up player, in a key.
/// What SP8CE plays while its window is out of sight, for the player to show
/// as a video (see `MediaCap.setVideo`). Sent as JSON; `position` was read at `at`.
struct EdgeVideo: Equatable {
    var aspect: CGFloat
    var title: String
    var position: Double
    var duration: Double
    var rate: Double
    var playing: Bool
    var at: Double

    init?(json text: String) {
        guard let data = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["active"] as? Bool == true,
              let aspect = (o["aspect"] as? NSNumber)?.doubleValue, aspect > 0 else { return nil }
        self.aspect = CGFloat(min(3, max(0.5, aspect)))
        title = o["title"] as? String ?? ""
        position = (o["position"] as? NSNumber)?.doubleValue ?? 0
        duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        rate = (o["rate"] as? NSNumber)?.doubleValue ?? 1
        playing = o["playing"] as? Bool ?? false
        at = (o["at"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
    }

    var progress: Double? {
        guard duration > 0 else { return nil }
        let now = playing ? position + max(0, Date().timeIntervalSince1970 - at) * rate : position
        return max(0, min(1, now / duration))
    }
}

private final class MediaCap: CALayer {
    private static let linger: TimeInterval = 2.5

    private let contentLayer = CALayer()
    private let infoLayer = CALayer()
    private let art = CALayer()
    /// Drawn text rather than a CATextLayer: its end truncation drew nothing
    /// at all for a title too long to fit.
    private let label = CALayer()
    /// The artist, on its own line under the title.
    private let subLabel = CALayer()
    /// The text column's width; the bar only runs under the text drawn in it.
    private var textWidth: CGFloat = 0
    private let stateGlyph = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private var currentSnapshot: CALayer?
    private var shown = false
    var onHidden: (() -> Void)?
    private var hideWork: DispatchWorkItem?
    private var ticker: Timer?
    private var state: MusicEdgeHUD.State?
    private var shownPlaying: Bool?
    private var scale: CGFloat = 2
    private var pagerDots: [CALayer] = []
    var isShown: Bool { shown }

    /// No cap behind it: the esc-spot player sits straight on the strip.
    private var baseColor = NSColor(white: 0.17, alpha: 1).cgColor
    private var plain = false
    /// Between the title and whatever sits at the right end.
    private var textGap: CGFloat = 7

    init(frame: CGRect, radius: CGFloat, scale: CGFloat, thirdKeyCenter: CGFloat? = nil, plain: Bool = false,
         textGap: CGFloat = 7) {
        self.textGap = textGap
        super.init()
        self.scale = scale
        // No implicit crossfade when layers come and go (the pager dots, a swipe's snapshot) or the
        // mask changes: Core Animation would fade a snapshot of the player out in place, a still
        // second copy under the one sliding away.
        for layer in [self, contentLayer, infoLayer, ringGroup] as [CALayer] { layer.actions = Self.quietActions }
        // No cap: the content runs right to the player's edges.
        if plain { baseColor = NSColor.clear.cgColor; self.plain = true; edge = 0 }
        self.frame = frame
        cornerRadius = radius
        cornerCurve = .continuous
        maskedCorners = EdgeKeyStripView.roundedCorners
        backgroundColor = baseColor
        opacity = 0
        let h = frame.height, w = frame.width

        // The play/pause glyph mirrors the artwork: the same square, the
        // same inset from the right edge as the cover has from the left.
        let glyphSide = max(10, h - 8)
        stateGlyph.frame = CGRect(x: w - edge - glyphSide, y: (h - glyphSide) / 2, width: glyphSide, height: glyphSide)
        stateGlyph.contentsGravity = .center
        stateGlyph.contentsScale = scale
        addSublayer(stateGlyph)
        if plain { buildVisualizer(in: stateGlyph.frame) }

        // The esc-spot player's cover is bigger: nearly the key's height (increased by 4px).
        let artSide = plain ? min(26, h) : max(10, h - 4)
        art.frame = CGRect(x: edge, y: ((h - artSide) / 2).rounded(), width: artSide, height: artSide)
        art.cornerRadius = min(6, artSide * 0.22)
        art.cornerCurve = .continuous
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.contentsScale = scale
        art.backgroundColor = nil

        let textX = art.frame.maxX + 7
        let rightLimit = stateGlyph.frame.minX - textGap
        let textWidth = max(0, rightLimit - textX)
        self.textWidth = textWidth
        // Title over artist, left-aligned beside the cover, as in Music (2px more gap between lines).
        let lift: CGFloat = plain ? -1.5 : 0   // no bar below: centre the two lines
        label.frame = CGRect(x: textX, y: (h / 2 + 1.5 + lift).rounded(), width: textWidth, height: 12)
        label.contentsScale = scale
        label.contentsGravity = .left
        subLabel.frame = CGRect(x: textX, y: (h / 2 - 10 + lift).rounded(), width: textWidth, height: 11)
        subLabel.contentsScale = scale
        subLabel.contentsGravity = .left
        // Too narrow for words when it's a lone key.
        label.isHidden = textWidth < 40
        subLabel.isHidden = label.isHidden

        let trackHeight: CGFloat = 1.5
        // Along the cover's bottom, under the text only.
        track.frame = CGRect(x: textX, y: art.frame.minY, width: textWidth, height: trackHeight)
        track.cornerRadius = trackHeight / 2
        track.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        track.masksToBounds = true

        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: trackHeight)
        fill.backgroundColor = NSColor(white: 1, alpha: 0.75).cgColor
        track.addSublayer(fill)

        contentLayer.frame = CGRect(x: 0, y: 0, width: max(0, stateGlyph.frame.minX - 4), height: h)
        contentLayer.masksToBounds = true
        addSublayer(contentLayer)

        infoLayer.frame = contentLayer.bounds
        contentLayer.addSublayer(infoLayer)

        infoLayer.addSublayer(art)
        infoLayer.addSublayer(label)
        infoLayer.addSublayer(subLabel)
        infoLayer.addSublayer(track)

        update(nil)
    }

    /// With several players the pager dots stand in front of the cover, which
    /// moves right to make room; the text follows it.
    private func layoutInfo(dotsShown: Bool) {
        let left: CGFloat = dotsShown ? pagerX + 1 + 3 + 7 : edge
        guard art.frame.minX != left else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame.origin.x = left
        let textX = art.frame.maxX + 7
        let width = max(0, stateGlyph.frame.minX - textGap - textX)
        textWidth = width
        label.frame = CGRect(x: textX, y: label.frame.minY, width: width, height: label.frame.height)
        subLabel.frame = CGRect(x: textX, y: subLabel.frame.minY, width: width, height: subLabel.frame.height)
        label.isHidden = width < 40
        subLabel.isHidden = label.isHidden
        track.frame = CGRect(x: textX, y: track.frame.minY, width: width, height: track.frame.height)
        CATransaction.commit()
        update(state)   // redraw the text for its new width
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: MusicEdgeHUD.State?) {
        let titleChanged = state?.title != self.state?.title || state?.artist != self.state?.artist
        self.state = state
        if video != nil {
            drawVideoText()
            setProgress(animated: false)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = state?.art ?? state?.appIcon {
            art.contents = image.layerContents(forContentsScale: scale)
        } else {
            art.contents = EdgeKeyStripView.symbolImage("music.note", size: 11, color: NSColor(white: 1, alpha: 0.6))?
                .layerContents(forContentsScale: scale)
        }
        art.contentsGravity = (state?.art ?? state?.appIcon) == nil ? .center : .resizeAspectFill

        // Some players (browsers) send an empty title: name the app instead.
        func nonEmpty(_ string: String?) -> String? {
            guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return string
        }
        let title = nonEmpty(state?.title)
        let heading = title ?? nonEmpty(state?.source) ?? (state == nil ? "Not Playing" : "Now Playing")
        let text = Self.line(heading, size: 10, bold: true, color: NSColor(white: 1, alpha: 0.92))
        // The artist alone: no album or "Single" after it.
        let artist = title != nil ? nonEmpty(state?.artist) : nil
        let sub = Self.line(artist ?? "", size: 9, bold: false, color: NSColor(white: 1, alpha: 0.55))
        // No artist: the title alone, centred in the height (2px more gap between lines).
        let lift: CGFloat = plain ? -1.5 : 0
        label.frame.origin.y = artist == nil
            ? (bounds.height - label.frame.height) / 2
            : (bounds.height / 2 + 1.5 + lift).rounded()
        subLabel.frame.origin.y = (bounds.height / 2 - 10 + lift).rounded()
        // The bar runs under the name only, as long as the longer line.
        let drawn = ceil(max(text.size().width, artist == nil ? 0 : sub.size().width))
        var free: CGFloat = 0
        if hasRing {
            // Cover, text and ring spaced evenly: 15 apart with room to
            // spare, closing in to 7 as a long title needs the width.
            let room = stateGlyph.frame.minX - art.frame.maxX
            let gap = min(15, max(7, ((room - drawn) / 2).rounded(.down)))
            // The cover sits 6 closer to its text than the text to the ring.
            let coverGap = max(3, gap - 6)
            let width = max(0, room - gap - coverGap)
            label.frame = CGRect(x: art.frame.maxX + coverGap, y: label.frame.minY, width: width, height: label.frame.height)
            subLabel.frame = CGRect(x: art.frame.maxX + coverGap, y: subLabel.frame.minY, width: width, height: subLabel.frame.height)
            label.isHidden = width < 40
            subLabel.isHidden = label.isHidden
            free = label.isHidden ? 0 : max(0, width - drawn)
            infoRight = label.frame.minX + min(width, drawn)
        }
        label.contents = Self.draw(text, in: label.bounds.size)?.layerContents(forContentsScale: scale)
        subLabel.contents = artist == nil ? nil : Self.draw(sub, in: subLabel.bounds.size)?.layerContents(forContentsScale: scale)
        track.frame.size.width = min(textWidth, max(30, drawn))
        if hasRing {
            // Short text: the group centred, the spare room split either side.
            centerShift = (free / 2).rounded()
            CATransaction.begin()
            CATransaction.setDisableActions(!(shown && titleChanged && pendingEntry == nil))
            CATransaction.setAnimationDuration(0.3)
            infoLayer.setAffineTransform(CGAffineTransform(translationX: centerShift, y: 0))
            for layer in [ringTrack, ringFill, visualizer].compactMap({ $0 }) {
                layer.setAffineTransform(CGAffineTransform(translationX: -centerShift, y: 0))
            }
            CATransaction.commit()
        }
        if titleChanged, pendingEntry != nil {
            // The song the swipe was waiting for.
            CATransaction.commit()
            setPlaying(state?.playing ?? false)
            setProgress(animated: false)
            slideIn()
            return
        }
        if titleChanged && shown && currentSnapshot == nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            art.add(fade, forKey: "crossfade")
            label.add(fade, forKey: "crossfade")
            subLabel.add(fade, forKey: "crossfade")
        }
        CATransaction.commit()

        setPlaying(state?.playing ?? false)
        setProgress(animated: false)
    }

    func setPlaying(_ playing: Bool) {
        guard playing != shownPlaying else { return }
        if visualizer != nil {
            shownPlaying = playing
            updateVisualizerRunning()
            return
        }
        if shownPlaying != nil {
            let swap = CATransition()
            swap.type = .fade
            swap.duration = 0.18
            stateGlyph.add(swap, forKey: "swap")
        }
        shownPlaying = playing
        stateGlyph.contents = EdgeKeyStripView.symbolImage(playing ? "pause.fill" : "play.fill",
                                                           size: stateGlyph.bounds.height * 0.72,
                                                           color: NSColor(white: 1, alpha: 0.9))?
            .layerContents(forContentsScale: scale)
    }

    // MARK: SP8CE's video

    /// While set, a slot for SP8CE's video takes the cover's place — as tall as
    /// the cover, as wide as the video's shape — with the title beside it and a
    /// straight bar under the title; no artist, ring, visualizer or glyph.
    /// SP8CE draws the live video over the slot from a window of its own.
    private(set) var video: EdgeVideo?
    private(set) var videoSlot: CGRect?
    var videoRadius: CGFloat { art.cornerRadius }
    /// The layout the video replaced, to go back to.
    private var coverLayout: (art: CGRect, track: CGRect, content: CGRect)?

    func setVideo(_ video: EdgeVideo?) {
        let old = self.video
        self.video = video
        guard let video else {
            if old != nil { leaveVideo() }
            return
        }
        if old == nil || old?.aspect != video.aspect { layoutVideo(animated: old == nil || shown) }
        drawVideoText()
        setProgress(animated: false)
    }

    private func layoutVideo(animated: Bool) {
        if coverLayout == nil { coverLayout = (art.frame, track.frame, contentLayer.frame) }
        hideWork?.cancel()
        let cover = coverLayout?.art ?? art.frame
        let height = cover.height
        let width = min((height * (video?.aspect ?? 16 / 9)).rounded(), (bounds.width * 0.42).rounded())
        let slot = CGRect(x: cover.minX, y: cover.minY, width: max(height, width), height: height)
        videoSlot = slot
        let textX = slot.maxX + 7
        let textWidth = max(0, bounds.width - max(edge, 6) - textX)
        self.textWidth = textWidth
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.34)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        contentLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        infoLayer.frame = contentLayer.bounds
        infoLayer.setAffineTransform(.identity)
        art.frame = slot
        art.contents = nil
        art.backgroundColor = NSColor.black.cgColor
        for layer in [ringGroup, stateGlyph, subLabel] { layer.opacity = 0 }
        // The title and the bar under it, centred as a pair beside the video.
        let titleY = (bounds.height / 2 - 3).rounded()
        label.frame = CGRect(x: textX, y: titleY, width: textWidth, height: 12)
        label.isHidden = textWidth < 30
        track.frame = CGRect(x: textX, y: titleY - 6, width: textWidth, height: 2)
        track.cornerRadius = 1
        fill.bounds.size.height = 2
        fill.position.y = 1
        CATransaction.commit()
        updateVisualizerRunning()
    }

    private func leaveVideo() {
        videoSlot = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        if let saved = coverLayout {
            contentLayer.frame = saved.content
            infoLayer.frame = contentLayer.bounds
            art.frame = saved.art
            track.frame = saved.track
            track.cornerRadius = saved.track.height / 2
            fill.bounds.size.height = saved.track.height
            fill.position.y = saved.track.height / 2
        }
        art.backgroundColor = nil
        for layer in [ringGroup, stateGlyph, subLabel] { layer.opacity = 1 }
        CATransaction.commit()
        coverLayout = nil
        // The regular layout, text and cover again.
        let state = self.state
        self.state = nil
        shownPlaying = nil
        update(state)
        updateVisualizerRunning()
    }

    private func drawVideoText() {
        guard let video else { return }
        let title = video.title.trimmingCharacters(in: .whitespaces).isEmpty ? (state?.title ?? "SP8CE") : video.title
        let text = Self.line(title, size: 10, bold: true, color: NSColor(white: 1, alpha: 0.92))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.contents = Self.draw(text, in: label.bounds.size)?.layerContents(forContentsScale: scale)
        subLabel.contents = nil
        CATransaction.commit()
    }

    // MARK: Visualizer

    /// The esc-spot player shows the music instead of a play/pause glyph:
    /// bars that move with the live audio (the system audio tap, as the menu
    /// bar's visualizer uses), resting as dots while paused.
    private var visualizer: CALayer?
    private var bars: [CALayer] = []
    private var barHeights: [CGFloat] = []
    private var barTargets: [CGFloat] = []
    private var vizTimer: Timer?
    private var tapHeld = false
    private static let barCount = 4

    deinit {
        vizTimer?.invalidate()
        if #available(macOS 14.2, *), tapHeld { AudioSpectrumTap.shared.release() }
    }

    /// The song's progress as a ring open at the bottom, like a gauge,
    /// with the visualizer inside it.
    private let ringTrack = CAShapeLayer()
    private let ringFill = CAShapeLayer()
    /// The ring and its visualizer, moving as one when the song or player changes.
    private let ringGroup = CALayer()
    private var hasRing = false
    /// How far the cover and text move right (and the ring left) to centre a short title.
    private var centerShift: CGFloat = 0
    /// Where the drawn text ends, for pressing the cover and text as one.
    private var infoRight: CGFloat = 0

    private func buildVisualizer(in frame: CGRect) {
        stateGlyph.isHidden = true
        // Progress ring & visualizer (reduced by 2px to 20 pt).
        let side = min(20, bounds.height)
        let ring = CGRect(x: bounds.width - edge - side, y: ((bounds.height - side) / 2).rounded(),
                          width: side, height: side)
        stateGlyph.frame = ring
        let lineWidth: CGFloat = 2
        // From lower left, clockwise over the top, to lower right: a 70° gap below.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: side / 2 - lineWidth / 2,
                    startAngle: 235 * .pi / 180, endAngle: -55 * .pi / 180, clockwise: true)
        ringGroup.frame = bounds
        addSublayer(ringGroup)
        for (shape, alpha) in [(ringTrack, 0.2), (ringFill, 0.9)] {
            shape.frame = ring
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = NSColor(white: 1, alpha: alpha).cgColor
            shape.lineWidth = lineWidth
            shape.lineCap = .butt
            shape.contentsScale = scale
            ringGroup.addSublayer(shape)
        }
        ringFill.strokeEnd = 0
        hasRing = true

        let width: CGFloat = 1.2
        let total = width * CGFloat(Self.barCount * 2 - 1)
        let inner = ring.insetBy(dx: side * 0.25, dy: side * 0.25)
        let layer = CALayer()
        layer.frame = inner
        ringGroup.addSublayer(layer)
        let frame = inner
        for i in 0..<Self.barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            bar.cornerRadius = width / 2
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: width)
            bar.position = CGPoint(x: (frame.width - total) / 2 + width / 2 + CGFloat(i) * width * 2,
                                   y: frame.height / 2)
            layer.addSublayer(bar)
            bars.append(bar)
        }
        barHeights = Array(repeating: 0, count: Self.barCount)
        barTargets = barHeights
        visualizer = layer
    }

    /// Moving while it's up and playing; resting otherwise.
    private func updateVisualizerRunning() {
        guard visualizer != nil else { return }
        let run = shown && shownPlaying == true && video == nil
        if run, vizTimer == nil {
            if #available(macOS 14.2, *), !tapHeld { AudioSpectrumTap.shared.acquire(); tapHeld = true }
            var last = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                let now = CACurrentMediaTime()
                self?.stepVisualizer(ticks: CGFloat(min(0.1, now - last) * 30))
                last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            vizTimer = timer
        } else if !run, vizTimer != nil {
            vizTimer?.invalidate()
            vizTimer = nil
            if #available(macOS 14.2, *), tapHeld { AudioSpectrumTap.shared.release(); tapHeld = false }
            // Settle to dots.
            barHeights = barHeights.map { _ in 0 }
            layoutBars(animated: true)
        }
    }

    private func stepVisualizer(ticks: CGFloat) {
        func blend(_ k: CGFloat) -> CGFloat { 1 - pow(1 - k, ticks) }
        var live: [CGFloat]?
        if #available(macOS 14.2, *) {
            let tap = AudioSpectrumTap.shared
            if tap.isDelivering && tap.hasSignal { live = tap.levels }
        }
        for i in 0..<Self.barCount {
            if let live, !live.isEmpty {
                // Four bars across the tap's bands, low to high.
                let band = min(live.count - 1, i * live.count / Self.barCount)
                barTargets[i] = live[band]
                barHeights[i] += (barTargets[i] - barHeights[i]) * blend(0.5)
            } else {
                if CGFloat.random(in: 0...1) < blend(0.2) { barTargets[i] = CGFloat.random(in: 0.3...1) }
                barHeights[i] += (barTargets[i] - barHeights[i]) * blend(0.4)
            }
        }
        layoutBars(animated: false)
    }

    private func layoutBars(animated: Bool) {
        guard let visualizer else { return }
        let maxHeight = visualizer.bounds.height * 0.6
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.25) }
        for (bar, level) in zip(bars, barHeights) {
            let width = bar.bounds.width
            bar.bounds.size.height = width + (maxHeight - width) * max(0, min(1, level))
        }
        CATransaction.commit()
    }

    /// `vertical`: another player rather than another track — up for the
    /// next one down the pager, down for going back up.
    func swipe(forward: Bool, vertical: Bool = false) {
        currentSnapshot?.removeAllAnimations()
        currentSnapshot?.removeFromSuperlayer()
        currentSnapshot = nil

        let width = contentLayer.bounds.width
        guard width > 20 else { return }

        // Up and down only a few points: the content has faded before it would reach the player's
        // edge, so nothing is cut off there and nothing shows outside it.
        let distance: CGFloat = vertical ? min(8, contentLayer.bounds.height * 0.3) : min(70, width * 0.6)
        // Horizontal: forward leaves to the left. Vertical: forward leaves
        // upward (layer y grows up), the next player rising from below.
        let outX: CGFloat = vertical ? (forward ? distance : -distance) : (forward ? -distance : distance)
        let inX: CGFloat = -outX
        let axis = vertical ? "transform.translation.y" : "transform.translation.x"
        softenEdges(vertical: vertical)
        // Already waiting on content (a quick second press): nothing on show
        // to slide out, so keep waiting — from the new direction.
        if pendingEntry != nil {
            pendingEntry = (axis, inX)
            entryTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.slideIn() }
            entryTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + (vertical ? 0.05 : 1.2), execute: timeout)
            return
        }

        swipeStartedAt = CACurrentMediaTime()
        let snapshot = CALayer()
        snapshot.frame = infoLayer.bounds
        snapshot.setAffineTransform(infoLayer.affineTransform())

        let snapArt = CALayer()
        snapArt.frame = art.frame
        snapArt.cornerRadius = art.cornerRadius
        snapArt.cornerCurve = art.cornerCurve
        snapArt.masksToBounds = true
        snapArt.contents = art.contents
        snapArt.contentsScale = scale
        snapArt.contentsGravity = art.contentsGravity
        snapshot.addSublayer(snapArt)

        let snapLabel = CALayer()
        snapLabel.frame = label.frame
        snapLabel.contents = label.contents
        snapLabel.contentsScale = scale
        snapLabel.contentsGravity = label.contentsGravity
        snapshot.addSublayer(snapLabel)

        let snapSub = CALayer()
        snapSub.frame = subLabel.frame
        snapSub.contents = subLabel.contents
        snapSub.contentsScale = scale
        snapSub.contentsGravity = subLabel.contentsGravity
        snapshot.addSublayer(snapSub)

        let snapTrack = CALayer()
        snapTrack.isHidden = track.isHidden
        snapTrack.frame = track.frame
        snapTrack.cornerRadius = track.cornerRadius
        snapTrack.backgroundColor = track.backgroundColor
        snapTrack.masksToBounds = true
        let snapFill = CALayer()
        snapFill.frame = fill.frame
        snapFill.backgroundColor = fill.backgroundColor
        snapTrack.addSublayer(snapFill)
        snapshot.addSublayer(snapTrack)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.insertSublayer(snapshot, below: infoLayer)
        CATransaction.commit()
        currentSnapshot = snapshot

        fill.bounds.size.width = 0

        let outSlide = CABasicAnimation(keyPath: axis)
        outSlide.isAdditive = true   // on top of the centring shift
        outSlide.fromValue = 0
        outSlide.toValue = outX
        outSlide.duration = 0.20
        outSlide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let outFade = CABasicAnimation(keyPath: "opacity")
        outFade.fromValue = 1
        outFade.toValue = 0
        outFade.duration = vertical ? 0.12 : 0.17
        outFade.timingFunction = CAMediaTimingFunction(name: vertical ? .easeOut : .easeIn)

        let outGroup = CAAnimationGroup()
        // Held at 0 until the group ends: the fade is shorter than the slide, and without this the
        // content flashed back at full strength for the last frames.
        outFade.fillMode = .forwards
        outGroup.animations = [outSlide, outFade]
        outGroup.duration = 0.20
        outGroup.fillMode = .forwards
        outGroup.isRemovedOnCompletion = false
        snapshot.add(outGroup, forKey: "swipeOut")
        if hasRing {
            // The ring leaves with the song, and waits unseen as the info
            // does: up or down with a new player, only fading for a new song.
            ringGroup.removeAllAnimations()
            if vertical {
                ringGroup.add(outGroup, forKey: "swipeOut")
            } else {
                let fadeOnly = outFade.copy() as! CABasicAnimation
                fadeOnly.fillMode = .forwards
                fadeOnly.isRemovedOnCompletion = false
                ringGroup.add(fadeOnly, forKey: "swipeOut")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) { [weak self, weak snapshot] in
            guard let self, let snapshot, self.currentSnapshot === snapshot else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            snapshot.removeFromSuperlayer()
            CATransaction.commit()
            self.currentSnapshot = nil
        }

        // The new content waits, unseen, until it's actually there: sliding
        // the old song back in and then swapping it read as two moves.
        infoLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoLayer.opacity = 0
        CATransaction.commit()
        pendingEntry = (axis, inX)
        entryTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.slideIn() }
        entryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (vertical ? 0.05 : 1.2), execute: timeout)
    }

    /// Where the next content comes from, while it's awaited.
    private var pendingEntry: (axis: String, from: CGFloat)?
    private var entryTimeout: DispatchWorkItem?

    /// The awaited content arrives: in from the side it was swiped toward,
    /// the cover settling from a touch smaller.
    private func slideIn() {
        guard let entry = pendingEntry else { return }
        pendingEntry = nil
        entryTimeout?.cancel()
        entryTimeout = nil
        // Not before the old content has mostly cleared.
        let delay = max(0, 0.12 - (CACurrentMediaTime() - swipeStartedAt))
        let begin = CACurrentMediaTime() + delay

        infoLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        infoLayer.opacity = 1
        CATransaction.commit()

        let slide = CASpringAnimation(keyPath: entry.axis)
        slide.isAdditive = true
        slide.fromValue = entry.from * 0.6
        slide.toValue = 0
        slide.damping = 20
        slide.stiffness = 300
        slide.duration = slide.settlingDuration
        slide.beginTime = begin
        slide.fillMode = .backwards

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        infoLayer.add(slide, forKey: "entrySlide")
        infoLayer.add(fade, forKey: "entryFade")
        if hasRing {
            ringGroup.removeAllAnimations()
            if entry.axis.hasSuffix(".y") { ringGroup.add(slide, forKey: "entrySlide") }
            ringGroup.add(fade, forKey: "entryFade")
        }
        restoreEdges(after: delay + max(0.5, slide.settlingDuration))

        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.82
        grow.toValue = 1
        grow.damping = 16
        grow.stiffness = 320
        grow.duration = grow.settlingDuration
        grow.beginTime = begin
        grow.fillMode = .backwards
        art.add(grow, forKey: "entryGrow")
    }

    func slideOut(forward: Bool, completion: (() -> Void)? = nil) {
        let width = contentLayer.bounds.width
        guard width > 20 else { completion?(); return }
        let distance: CGFloat = min(70, width * 0.6)
        let outX: CGFloat = forward ? -distance : distance
        let axis = "transform.translation.x"
        softenEdges(vertical: false)

        let outSlide = CABasicAnimation(keyPath: axis)
        outSlide.isAdditive = true
        outSlide.fromValue = 0
        outSlide.toValue = outX
        outSlide.duration = 0.20
        outSlide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let outFade = CABasicAnimation(keyPath: "opacity")
        outFade.fromValue = 1
        outFade.toValue = 0
        outFade.duration = 0.17
        outFade.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let outGroup = CAAnimationGroup()
        // Held at 0 until the group ends: the fade is shorter than the slide, and without this the
        // content flashed back at full strength for the last frames.
        outFade.fillMode = .forwards
        outGroup.animations = [outSlide, outFade]
        outGroup.duration = 0.20
        outGroup.fillMode = .forwards
        outGroup.isRemovedOnCompletion = false

        contentLayer.add(outGroup, forKey: "widgetSwipeOut")
        if hasRing {
            ringGroup.add(outGroup, forKey: "widgetSwipeOut")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            // Hidden first, then the content put back, in one transaction: it never shows in place.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            completion?()
            self?.contentLayer.removeAnimation(forKey: "widgetSwipeOut")
            self?.ringGroup.removeAnimation(forKey: "widgetSwipeOut")
            self?.contentLayer.transform = CATransform3DIdentity
            self?.ringGroup.transform = CATransform3DIdentity
            self?.clearEdges()
            CATransaction.commit()
        }
    }

    func slideIn(forward: Bool) {
        let width = contentLayer.bounds.width
        guard width > 20 else { return }
        let distance: CGFloat = min(70, width * 0.6)
        let inX: CGFloat = forward ? distance : -distance
        softenEdges(vertical: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 1
        shown = true
        CATransaction.commit()
        pendingEntry = ("transform.translation.x", inX)
        swipeStartedAt = CACurrentMediaTime() - 0.12
        slideIn()
    }
    private var swipeStartedAt: CFTimeInterval = 0

    // MARK: Soft edges

    /// While content slides out of the player and in, its edges fade and
    /// blur instead of cutting it off sharp: top and bottom for a new
    /// player, the sides for a new song.
    private var edgeBlurs: [CALayer] = []
    private var edgeRestore: DispatchWorkItem?

    private func softenEdges(vertical: Bool) {
        edgeRestore?.cancel()
        // Changing a mask or clipping implicitly crossfades the layer: Core Animation snapshots it
        // as it was and fades that out in place, which showed as a second copy of the player
        // standing still while the real one slid away.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        edgeBlurs.forEach { $0.removeFromSuperlayer() }
        edgeBlurs = []
        self.mask = nil
        contentLayer.mask = nil
        contentLayer.masksToBounds = true
        // Up and down the content fades within the player (see `swipe`); only the sides need softening.
        if vertical { return }
        // Sideways everything moves (text, cover, ring), so the whole player is masked, not just its
        // text. The fade lies in the gap to the next key, outside the player: nothing at rest dims,
        // and what slides out has faded before it reaches that key. The esc-spot player starts at
        // the display's edge, so on that side there's nothing to fade into.
        contentLayer.masksToBounds = false
        mask = Self.sideMask(size: bounds.size, room: sideRoom, openLeft: plain)
    }

    /// Keys whose implicit animation is a crossfade of a snapshot, turned off.
    static let quietActions: [String: CAAction] = [
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        "mask": NSNull(), "masksToBounds": NSNull(),
    ]

    /// Room between the player and the next key, where content sliding sideways fades out.
    private var sideRoom: CGFloat { max(4, min(10, textGap)) }

    /// Solid over the player, fading to clear across `room` beyond each side (none on the left when
    /// `openLeft`, the display's own edge). `inside`: the fade on the right starts that far in, for a
    /// widget with nothing at its right end.
    static func sideMask(size: CGSize, room: CGFloat, openLeft: Bool, inside: CGFloat = 0) -> CALayer {
        let left: CGFloat = openLeft ? 60 : room
        let width = size.width + left + room
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: -left, y: -4, width: width, height: size.height + 8)
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        mask.colors = [openLeft ? solid : clear, solid, solid, clear]
        mask.locations = [0, NSNumber(value: Double(left / width)),
                          NSNumber(value: Double((left + size.width - inside) / width)), 1]
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        return mask
    }

    /// Back to the player at rest: no mask, the text clipped to its column.
    private func clearEdges() {
        edgeRestore?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        edgeBlurs.forEach { $0.removeFromSuperlayer() }
        edgeBlurs = []
        mask = nil
        contentLayer.mask = nil
        contentLayer.masksToBounds = true
    }

    private func restoreEdges(after delay: TimeInterval) {
        edgeRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.clearEdges() }
        edgeRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Press

    /// Clicked for play/pause: the cover and text sink a little while held
    /// and spring back on release; the ring stays put.
    func setPressed(_ pressed: Bool) {
        let target = contentLayer
        let s: CGFloat = pressed ? 0.94 : 1
        // About the middle of the cover and text, wherever centring put them.
        let anchor = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
        let right = infoRight > 0 ? infoRight : label.frame.maxX
        let mid = CGPoint(x: (art.frame.minX + right) / 2 + centerShift, y: target.bounds.midY)
        var t = CATransform3DMakeTranslation(anchor.x - mid.x, anchor.y - mid.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(mid.x - anchor.x, mid.y - anchor.y, 0))
        let from = target.presentation()?.transform ?? target.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.transform = t
        CATransaction.commit()
        let anim: CABasicAnimation
        if pressed {
            anim = CABasicAnimation(keyPath: "transform")
            anim.duration = 0.09
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        } else {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping = 12
            spring.stiffness = 400
            spring.duration = spring.settlingDuration
            anim = spring
        }
        anim.fromValue = from
        anim.toValue = t
        target.add(anim, forKey: "press")
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = target.presentation()?.opacity ?? 1
        dim.toValue = pressed ? 0.7 : 1
        dim.duration = pressed ? 0.09 : 0.2
        // Held: stays dimmed. Released: back to full (the model value).
        dim.fillMode = .forwards
        dim.isRemovedOnCompletion = !pressed
        target.removeAnimation(forKey: "pressDim")
        target.add(dim, forKey: "pressDim")
    }

    /// Left edge of the pager dots' column: the cap's own inset.
    private var pagerX: CGFloat { edge }
    /// Inset of the content from the cap's sides; none without a cap drawn.
    private var edge: CGFloat = 4

    /// A dot per player, stacked in front of the cover, when there's more than one.
    func setPager(index: Int, count: Int) {
        // Same number of players: only the lit dot moves, gliding over.
        if count > 1, count == pagerDots.count, let highlight = pagerHighlight {
            guard index != pagerIndex, pagerDots.indices.contains(index) else { return }
            pagerIndex = index
            let target = pagerDots[index].position
            let glide = CASpringAnimation(keyPath: "position")
            glide.fromValue = highlight.presentation()?.position ?? highlight.position
            glide.toValue = target
            glide.damping = 18
            glide.stiffness = 300
            glide.duration = glide.settlingDuration
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.position = target
            CATransaction.commit()
            highlight.add(glide, forKey: "glide")
            let stretch = CAKeyframeAnimation(keyPath: "bounds.size.height")
            stretch.values = [3, 7, 3]
            stretch.keyTimes = [0, 0.4, 1]
            stretch.duration = 0.3
            highlight.add(stretch, forKey: "stretch")
            return
        }
        pagerDots.forEach { $0.removeFromSuperlayer() }
        pagerDots = []
        pagerHighlight?.removeFromSuperlayer()
        pagerHighlight = nil
        pagerIndex = index
        layoutInfo(dotsShown: count > 1)
        guard count > 1 else { return }
        let side: CGFloat = 3, gap: CGFloat = 2.5
        let total = CGFloat(count) * side + CGFloat(count - 1) * gap
        let x = pagerX + 1
        // Top to bottom: the first player highest.
        var y = (bounds.height + total) / 2 - side
        for _ in 0..<count {
            let dot = CALayer()
            dot.frame = CGRect(x: x, y: y, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.backgroundColor = NSColor(white: 1, alpha: 0.3).cgColor
            addSublayer(dot)
            pagerDots.append(dot)
            y -= side + gap
        }
        let highlight = CALayer()
        highlight.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        highlight.position = pagerDots[min(index, count - 1)].position
        highlight.cornerRadius = side / 2
        highlight.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
        addSublayer(highlight)
        pagerHighlight = highlight
    }
    private var pagerHighlight: CALayer?
    private var pagerIndex = 0

    /// SF Pro, with Thai drawn in Sukhumvit Set (the system otherwise falls
    /// back to Thonburi): Semi Bold for titles, Text for artists.
    private static func font(size: CGFloat, bold: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let thai = NSFontDescriptor(name: bold ? "SukhumvitSet-SemiBold" : "SukhumvitSet-Text", size: size)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [thai]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Thai set this small runs its letters together, so its runs get a little
    /// even kerning. Not tracking, and not per-letter kerning: both push the
    /// vowels and tone marks off their letters.
    private static func line(_ string: String, size: CGFloat, bold: Bool, color: NSColor) -> NSAttributedString {
        let line = NSMutableAttributedString(string: string, attributes: [
            .font: font(size: size, bold: bold),
            .foregroundColor: color,
        ])
        let thai = try? NSRegularExpression(pattern: "[\\x{0E00}-\\x{0E7F}]+")
        for match in thai?.matches(in: string, range: NSRange(string.startIndex..., in: string)) ?? [] {
            line.addAttribute(.kern, value: size * 0.06, range: match.range)
        }
        return line
    }

    /// One line, cut short with an ellipsis when it doesn't fit.
    private static func draw(_ text: NSAttributedString, in size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let line = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return NSImage(size: size, flipped: false) { rect in
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    private func setProgress(animated: Bool) {
        let progress = CGFloat(video.map { $0.progress ?? 0 } ?? state?.progress ?? 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.5 : 0)
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        fill.bounds.size.width = track.bounds.width * progress
        // The ring player shows progress on its ring instead; with a video, a straight bar.
        track.isHidden = video.map { $0.progress == nil } ?? (hasRing || state?.progress == nil)
        ringFill.strokeEnd = progress
        ringFill.isHidden = state?.progress == nil
        CATransaction.commit()
    }

    /// `stays`: pinned, no timer takes it down.
    func show(stays: Bool = false) {
        MusicEdgeHUD.shared.keepsFresh = true
        if !shown {
            shown = true
            defer { updateVisualizerRunning() }
            let from = presentation()?.opacity ?? 0
            removeAnimation(forKey: "hide")
            opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 1
            fade.duration = 0.16
            add(fade, forKey: "appear")
            let merge = CASpringAnimation(keyPath: "transform.scale.x")
            merge.fromValue = 0.92
            merge.toValue = 1
            merge.damping = 24
            merge.stiffness = 320
            merge.duration = merge.settlingDuration
            add(merge, forKey: "merge")
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, (self.video?.playing ?? self.state?.playing) == true else { return }
                self.setProgress(animated: true)
            }
        } else if !plain {
            // Another press while it's up: a quick glint (not on the esc-spot
            // player, which has no cap to light).
            let glint = CABasicAnimation(keyPath: "backgroundColor")
            glint.fromValue = NSColor(white: 0.3, alpha: 1).cgColor
            glint.toValue = baseColor
            glint.duration = 0.35
            add(glint, forKey: "glint")
        }
        hideWork?.cancel()
        // A video stays up for as long as SP8CE shows it.
        guard !stays, video == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger, execute: work)
    }

    /// `animated` false: at once, for a widget that has already slid out of sight.
    func hide(animated: Bool = true) {
        hideWork?.cancel()
        guard shown, video == nil else { return }
        shown = false
        defer { updateVisualizerRunning() }
        ticker?.invalidate()
        ticker = nil
        if !AppSettings.shared.edgeKeysPinnedPlayer { MusicEdgeHUD.shared.keepsFresh = false }
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.25
            add(fade, forKey: "hide")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0
        CATransaction.commit()
        onHidden?()
    }
}

// MARK: - Weather / Calendar Cap

/// An icon and two lines in the esc spot: the weather, or the next event or reminder.
private final class GlanceCap: CALayer {
    private let contentLayer = CALayer()
    private let iconLayer = CALayer()
    private let label = CALayer()
    private let subLabel = CALayer()

    private var shown = false
    private var scale: CGFloat = 2
    private var weather: WeatherData?
    var isShown: Bool { shown }

    init(frame: CGRect, radius: CGFloat, scale: CGFloat) {
        super.init()
        self.scale = scale
        // As the music widget's: no crossfaded snapshot left standing while it slides.
        for layer in [self, contentLayer] as [CALayer] { layer.actions = MediaCap.quietActions }
        self.frame = frame
        cornerRadius = radius
        cornerCurve = .continuous
        maskedCorners = EdgeKeyStripView.roundedCorners
        backgroundColor = NSColor.clear.cgColor
        opacity = 0

        contentLayer.frame = bounds
        addSublayer(contentLayer)

        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        contentLayer.addSublayer(iconLayer)

        label.contentsScale = scale
        label.contentsGravity = .left
        contentLayer.addSublayer(label)

        subLabel.contentsScale = scale
        subLabel.contentsGravity = .left
        contentLayer.addSublayer(subLabel)

        update(nil)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var iconSide: CGFloat { min(24, bounds.height - 4) }

    func update(_ weather: WeatherData?) {
        self.weather = weather
        let iconSide = self.iconSide

        let icon: NSImage
        let text: NSAttributedString
        let sub: NSAttributedString

        if let weather {
            icon = Self.weatherIcon(symbolName: weather.symbolName, size: iconSide)

            let isFahrenheit = (Locale.current.measurementSystem == .us)
            let tempVal = isFahrenheit ? (weather.temperature * 9 / 5 + 32) : weather.temperature
            let tempStr = "\(Int(tempVal.rounded()))°"
            let primary = "\(tempStr) · \(weather.conditionText)"
            text = NSAttributedString(string: primary, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.92),
            ])

            sub = NSAttributedString(string: weather.cityName, attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.55),
            ])
        } else {
            icon = Self.weatherIcon(symbolName: "cloud.sun.fill", size: iconSide)

            text = NSAttributedString(string: "Weather", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: 0.92),
            ])
            sub = NSAttributedString(string: "Updating…", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: 0.55),
            ])
        }
        layout(icon: icon, text: text, sub: sub)
    }

    /// The next event or reminder, as the menu bar shows it: its title, and the time until it
    /// starts (or is due), or what's left of it.
    func update(calendar entry: CalendarFeed.Entry?) {
        let symbol = entry?.isReminder == true ? "checklist" : "calendar"
        let icon = Self.weatherIcon(symbolName: symbol, size: iconSide, tint: entry?.calendarColor)
        let title = entry.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "Calendar"
        let time = entry.map(CalendarFeed.timeText(for:)) ?? "Nothing coming up"
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92),
        ])
        let sub = NSAttributedString(string: time, attributes: [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .medium),
            .foregroundColor: NSColor(white: 1, alpha: 0.55),
        ])
        layout(icon: icon, text: text, sub: sub)
    }

    private func layout(icon: NSImage, text: NSAttributedString, sub: NSAttributedString) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contents = icon.layerContents(forContentsScale: scale)
        let h = bounds.height, w = bounds.width
        let iconSide = self.iconSide
        let gap: CGFloat = 8

        // Center the icon and text group horizontally within the widget slot, like the media player
        let drawn = ceil(max(text.size().width, sub.size().width))
        let totalWidth = iconSide + gap + drawn
        let free = max(0, w - totalWidth)
        // A long title starts clear of the display's rounded corner and truncates at the end.
        let startX = max(8, (free / 2).rounded())

        iconLayer.frame = CGRect(x: startX, y: ((h - iconSide) / 2).rounded(), width: iconSide, height: iconSide)

        let textX = iconLayer.frame.maxX + gap
        let textWidth = max(0, w - textX - 4)
        let lift: CGFloat = -1.5
        label.frame = CGRect(x: textX, y: (h / 2 + 1.5 + lift).rounded(), width: textWidth, height: 12)
        subLabel.frame = CGRect(x: textX, y: (h / 2 - 10 + lift).rounded(), width: textWidth, height: 11)

        label.contents = Self.draw(text, in: label.bounds.size)?.layerContents(forContentsScale: scale)
        subLabel.contents = Self.draw(sub, in: subLabel.bounds.size)?.layerContents(forContentsScale: scale)

        CATransaction.commit()
    }

    /// `tint`: one colour (a calendar's); otherwise the symbol's own colours.
    private static func weatherIcon(symbolName: String, size: CGFloat, tint: NSColor? = nil) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.72, weight: .semibold)
            .applying(tint.map { .init(paletteColors: [$0]) } ?? .preferringMulticolor())
        let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: nil)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let sym else { return false }
            let symSize = sym.size
            guard symSize.width > 0, symSize.height > 0 else { return false }
            let scale = min(rect.width / symSize.width, rect.height / symSize.height)
            let w = symSize.width * scale
            let h = symSize.height * scale
            let drawRect = NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h)
            sym.draw(in: drawRect)
            return true
        }
    }

    private static func draw(_ text: NSAttributedString, in size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let line = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return NSImage(size: size, flipped: false) { rect in
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    func show() {
        guard !shown else { return }
        shown = true
        removeAnimation(forKey: "hide")
        let from = presentation()?.opacity ?? 0
        opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 1
        fade.duration = 0.2
        add(fade, forKey: "appear")
    }

    /// `animated` false: at once, for a widget that has already slid out of sight.
    func hide(animated: Bool = true) {
        guard shown else { return }
        shown = false
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.2
            add(fade, forKey: "hide")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0
        CATransaction.commit()
    }

    func setPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        contentLayer.opacity = pressed ? 0.7 : 1
        contentLayer.transform = pressed ? CATransform3DMakeScale(0.97, 0.97, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    func slideOut(forward: Bool, completion: (() -> Void)? = nil) {
        let width = contentLayer.bounds.width
        guard width > 20 else { completion?(); return }
        let distance: CGFloat = min(70, width * 0.6)
        let outX: CGFloat = forward ? -distance : distance
        let axis = "transform.translation.x"

        let outSlide = CABasicAnimation(keyPath: axis)
        outSlide.isAdditive = true
        outSlide.fromValue = 0
        outSlide.toValue = outX
        outSlide.duration = 0.20
        outSlide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let outFade = CABasicAnimation(keyPath: "opacity")
        outFade.fromValue = 1
        outFade.toValue = 0
        outFade.duration = 0.17
        outFade.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let outGroup = CAAnimationGroup()
        // Held at 0 until the group ends: the fade is shorter than the slide, and without this the
        // content flashed back at full strength for the last frames.
        outFade.fillMode = .forwards
        outGroup.animations = [outSlide, outFade]
        outGroup.duration = 0.20
        outGroup.fillMode = .forwards
        outGroup.isRemovedOnCompletion = false

        softenSides()
        contentLayer.add(outGroup, forKey: "widgetSwipeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            // Hidden first, then the content put back, in one transaction: it never shows in place.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            completion?()
            self?.contentLayer.removeAnimation(forKey: "widgetSwipeOut")
            self?.contentLayer.transform = CATransform3DIdentity
            self?.mask = nil
            CATransaction.commit()
        }
    }

    func slideIn(forward: Bool) {
        let width = contentLayer.bounds.width
        guard width > 20 else { return }
        let distance: CGFloat = min(70, width * 0.6)
        let inX: CGFloat = forward ? distance : -distance
        let delay: CFTimeInterval = 0.04
        let begin = CACurrentMediaTime() + delay

        contentLayer.removeAllAnimations()
        iconLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 1
        shown = true
        CATransaction.commit()

        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.isAdditive = true
        slide.fromValue = inX * 0.6
        slide.toValue = 0
        slide.damping = 20
        slide.stiffness = 300
        slide.duration = slide.settlingDuration
        slide.beginTime = begin
        slide.fillMode = .backwards

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        contentLayer.add(slide, forKey: "entrySlide")
        contentLayer.add(fade, forKey: "entryFade")

        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.82
        grow.toValue = 1
        grow.damping = 16
        grow.stiffness = 320
        grow.duration = grow.settlingDuration
        grow.beginTime = begin
        grow.fillMode = .backwards
        iconLayer.add(grow, forKey: "entryGrow")

        softenSides()
        let token = UUID()
        sideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + slide.settlingDuration) { [weak self] in
            guard let self, self.sideToken == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.mask = nil
            CATransaction.commit()
        }
    }

    /// While it slides: clipped to its own spot, fading out in the gap to F1 before reaching it
    /// (the same mask as the music widget's; its left side is the display's edge).
    private var sideToken: UUID?
    private func softenSides() {
        sideToken = nil
        // Without an implicit crossfade (see MediaCap.softenEdges).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The fade lies in the gap to F1, never over the widget itself, which
        // otherwise showed faded while the slide settled.
        mask = MediaCap.sideMask(size: bounds.size, room: 10, openLeft: true)
        CATransaction.commit()
    }
}

// MARK: - Settings pane

@available(macOS 14.0, *)
struct EdgeKeysPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selectedTab = 0
    @State private var editingSecondRow = false

    var body: some View {
        PaneContainer(section: .edgeKeys, tabs: ["General", "Widgets", "Key Mapping"],
                      tabSelection: $selectedTab) {
            Section {
                EdgeKeysPreview(mode: vm.edgeKeysMode, firstRow: vm.edgeKeysFirstRow,
                                modifier: vm.edgeKeysLayerModifier, triggerKey: vm.edgeKeysTriggerKey)
                    .frame(height: 96)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            switch selectedTab {
            case 0:
                generalSettings
            case 1:
                if vm.edgeKeysMode == .strip { widgetSettings }
                else { stripModeNotice("Widgets") }
            default:
                if vm.edgeKeysMode == .strip { keyMappingSettings }
                else { stripModeNotice("Key mapping") }
            }

        }
    }

    @ViewBuilder private var generalSettings: some View {
        Section {
            SettingsSegmentedPicker(title: "Mode", selection: $vm.edgeKeysMode,
                options: EdgeKeysMode.allCases.map { SettingsSegment($0.rawValue, $0) })
        } header: {
            Text("Display")
        } footer: {
            Text(modeFooter)
        }

        if vm.edgeKeysMode == .strip {
            Section {
                SettingsSegmentedPicker(title: "Key style", selection: $vm.edgeKeysKeyPlacement,
                    options: EdgeKeysKeyPlacement.allCases.map { SettingsSegment($0.rawValue, $0) })
                Toggle("Match menu bar height", isOn: $vm.edgeKeysStripMatchMenuBar)
                if !vm.edgeKeysStripMatchMenuBar {
                    LabeledContent("Height") {
                        HStack {
                            Slider(value: $vm.edgeKeysStripHeight, in: 24...48, step: 1)
                            Text("\(Int(vm.edgeKeysStripHeight)) pt")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                SettingsToggleRow("Hide in full screen", detail: "Use pop-ups in full-screen apps.",
                                  isOn: $vm.edgeKeysHideInFullscreen)
            } header: {
                Text("Appearance")
            } footer: {
                Text("The strip uses the bottom edge. Move the Dock to the side or hide it; tiled windows stay above the strip.")
            }

            Section("Touch ID prompts") {
                Picker("Fingerprint color", selection: $vm.edgeKeysRedFingerprint) {
                    Label("Red", systemImage: "touchid").tag(true)
                    Label("White", systemImage: "touchid").tag(false)
                }
                SettingsSegmentedPicker(title: "Prompt style", selection: $vm.edgeKeysTouchIDHint,
                    options: [SettingsSegment("Key", false), SettingsSegment("Pop-up", true)])
            }
        }

        if vm.edgeKeysMode != .off && !vm.systemHUDEnabled {
            Section {
                LabeledContent("Brightness & volume levels") {
                    Button("Enable System HUD") { vm.systemHUDEnabled = true }
                }
            } footer: {
                Text("System HUD is required to show brightness and volume levels.")
            }
        }

        Section {
            LabeledContent("Keyboard alignment") {
                Button("Align Keyboard…") { FunctionRowCalibration.shared.open() }
            }
        } footer: {
            Text("Line up the on-screen keys with your keyboard.")
        }
    }

    @ViewBuilder private var widgetSettings: some View {
        Section {
            SettingsToggleRow("Media player", detail: "Combine the media keys into playback controls.",
                              isOn: $vm.edgeKeysMediaPlayer)
            if vm.edgeKeysMediaPlayer {
                Toggle("Keep player visible", isOn: $vm.edgeKeysPinnedPlayer)
                    .help("Keep previous, play/pause and next merged into the player, instead of showing it briefly after a press.")
                SettingsToggleRow("SP8CE video", detail: "Requires Edge Keys Video in SP8CE.",
                                  isOn: $vm.edgeKeysSP8CEVideo)
                    .help("Show video when SP8CE’s window is out of sight. Turn on Edge Keys Video in SP8CE’s Settings › Modules first.")
            }
            LabeledContent("Double-press interval") {
                HStack {
                    Slider(value: $vm.edgeKeysDoublePressWindow, in: 0...0.5, step: 0.05)
                    Text(vm.edgeKeysDoublePressWindow == 0 ? "Off" : String(format: "%.2f s", vm.edgeKeysDoublePressWindow))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .help("Press play/pause twice to switch between apps playing media. A single press waits for this interval; Off makes it instant.")
        } header: {
            Text("Media")
        } footer: {
            Text("Double press play/pause to switch apps. Single presses wait for the interval; Off makes them instant.")
        }

        Section("Left edge · esc") {
            Toggle("Show esc key", isOn: $vm.edgeKeysShowEsc)
            if !vm.edgeKeysShowEsc {
                SettingsToggleRow("Player in the esc spot", detail: "Show the cover, title and source at the left edge.",
                                  isOn: $vm.edgeKeysPlayerInEsc)
                Toggle("Weather when idle", isOn: $vm.edgeKeysWeatherInEsc)
                    .help("Show the local weather forecast when no media is playing.")
                SettingsToggleRow("Calendar", detail: "Show the next event or reminder and its countdown, as in the menu bar.",
                                  isOn: $vm.edgeKeysCalendarInEsc)
                SettingsToggleRow("AI usage", detail: "Show TokenBar usage while an AI is working.",
                                  isOn: $vm.edgeKeysUsageInEsc)
                if vm.edgeKeysUsageInEsc {
                    SettingsSegmentedPicker(title: "Usage style", selection: $vm.edgeKeysUsageBars,
                        options: [SettingsSegment("Bars", true), SettingsSegment("Rings", false)])
                }
            }
        }

        Section("Right edge · Touch ID") {
            Toggle("Show Touch ID key", isOn: $vm.edgeKeysShowTouchID)
            if !vm.edgeKeysShowTouchID {
                SettingsToggleRow("Hardware stats", detail: "Show CPU, GPU and memory; Touch ID returns for prompts.",
                                  isOn: $vm.edgeKeysStatsInTouchID)
                    .help("Move the hardware gauges from the menu bar to the Touch ID spot.")
            }
        }

        Section("App shortcuts") {
            SettingsToggleRow("App shortcuts", detail: "Use F3–F9 for the active app’s shortcuts.",
                              isOn: $vm.edgeKeysAppKeys)
                .help("Show the most-used shortcuts on the left, such as back, reload and new tab in a browser.")
            if vm.edgeKeysAppKeys {
                Toggle("Follow the pointer", isOn: $vm.edgeKeysAppKeysFollowPointer)
                    .help("Use the app whose window is under the pointer. Pressing a shortcut brings that window forward first.")
                SettingsToggleRow("Learn frequent shortcuts", detail: "Counts stay on this Mac; typing is never recorded.",
                                  isOn: $vm.edgeKeysAppKeysLearn)
                    .help("Count the ⌘ and ⌃ shortcuts you use in each app and give the most-used ones a key.")
                LabeledContent("Learned shortcuts") {
                    Button("Reset") { EdgeKeyAppKeys.shared.resetLearned() }
                }
            }
        }
    }

    @ViewBuilder private var keyMappingSettings: some View {
        Section {
            SettingsSegmentedPicker(title: "Edit row", selection: $editingSecondRow,
                options: [SettingsSegment("First Row", false), SettingsSegment("Second Row", true)], navigation: true, showsLabel: false)
            .labelsHidden()
        }

        if editingSecondRow { secondRowActivation }

        Section {
            ForEach(editingSecondRow ? 0...13 : 1...12, id: \.self) { key in
                if vm.edgeKeysLayerModifier == .functionKey && vm.edgeKeysTriggerKey == key {
                    reservedModifierRow(key)
                } else {
                    EdgeKeyRow(key: key, action: Binding(
                        get: {
                            editingSecondRow ? (vm.edgeKeysSecondRow[key] ?? .none)
                                : (vm.edgeKeysFirstRow[key] ?? .keyDefault)
                        },
                        set: {
                            if editingSecondRow { vm.edgeKeysSecondRow[key] = $0 }
                            else { vm.edgeKeysFirstRow[key] = $0 }
                        }), allowsDefault: !editingSecondRow)
                }
            }
            Button("Restore This Row’s Defaults") {
                if editingSecondRow { vm.edgeKeysSecondRow = EdgeKeyAction.defaultSecondRow }
                else { vm.edgeKeysFirstRow = EdgeKeyAction.defaultFirstRow }
            }
        } header: {
            Text("Key actions")
        } footer: {
            Text(editingSecondRow
                 ? "Hold the modifier to show this row, then press a key to run its action."
                 : "Hold fn to use a key as a plain F key.")
        }
    }

    @ViewBuilder private var secondRowActivation: some View {
        Section {
            SettingsSegmentedPicker(title: "Hold", selection: $vm.edgeKeysLayerModifier,
                options: EdgeKeysModifier.allCases.map { modifier in SettingsSegment(modifier.label, modifier, enabled: !(modifier == .functionKey && !vm.edgeKeysCanReserve(vm.edgeKeysTriggerKey))) })
            if vm.edgeKeysLayerModifier != .functionKey && !vm.edgeKeysCanReserve(vm.edgeKeysTriggerKey) {
                Text("Clear F\(vm.edgeKeysTriggerKey) in both rows before using it as the modifier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.edgeKeysLayerModifier == .functionKey {
                Picker("Modifier key", selection: $vm.edgeKeysTriggerKey) {
                    ForEach(1...12, id: \.self) { key in
                        Text("F\(key)").tag(key).disabled(!vm.edgeKeysCanReserve(key))
                    }
                }
            }
            if vm.edgeKeysLayerModifier == .rightShift {
                SettingsToggleRow("Use Right ⇧ only for this row", detail: "Left Shift and external keyboards keep normal Shift behavior.",
                                  isOn: $vm.edgeKeysRightShiftExclusive)
                    .help("On the MacBook keyboard, Right Shift only opens the second row while MSG runs. It becomes Shift again when MSG quits.")
            }
            LabeledContent("Hold time") {
                HStack {
                    Slider(value: $vm.edgeKeysLayerHoldDelay, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f s", vm.edgeKeysLayerHoldDelay))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .help("Hold the modifier on its own for this long to show the second row. A short delay can flash the row while you use shortcuts.")
        } header: {
            Text("Second row activation")
        }
    }

    private func stripModeNotice(_ category: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(category) is available in Strip mode.")
                    .foregroundStyle(.secondary)
                Button("Use Strip Mode") { vm.edgeKeysMode = .strip }
            }
            .padding(.vertical, 8)
        }
    }

    private var modeFooter: String {
        switch vm.edgeKeysMode {
        case .off:   return "Use the usual macOS function-key pop-ups."
        case .popup: return "Show a pop-up above the key you press."
        case .strip: return "Keep the function keys along the built-in display’s bottom edge."
        }
    }

    private func reservedModifierRow(_ key: Int) -> some View {
        LabeledContent("F\(key)") {
            Label("Modifier · reserved", systemImage: "command")
                .foregroundStyle(.secondary)
        }
        .disabled(true)
    }
}

/// One F key's second-row action, picked from a menu.
@available(macOS 14.0, *)
private struct EdgeKeyRow: View {
    let key: Int
    @Binding var action: EdgeKeyAction
    /// First row: offer the key's own function.
    var allowsDefault = false

    /// What each key does on its own, as printed on the keycap.
    static let defaultNames = ["", "Brightness Down", "Brightness Up", "Mission Control", "Spotlight", "Dictation",
                               "Do Not Disturb", "Previous", "Play/Pause", "Next", "Mute", "Volume Down", "Volume Up"]
    static let defaultSymbols = ["", "sun.min.fill", "sun.max.fill", "rectangle.3.group", "magnifyingglass", "mic.fill",
                                 "moon.fill", "backward.fill", "play.fill", "forward.fill", "speaker.slash.fill",
                                 "speaker.wave.1.fill", "speaker.wave.3.fill"]
    static let settingsPanes: [SettingsSection] = [
        .general, .corner, .spacer, .menubar, .tiling, .dock, .hud, .edgeKeys, .music, .displaplacer, .hardware, .about
    ]

    var body: some View {
        LabeledContent {
            Menu {
                if allowsDefault {
                    Button(Self.defaultNames[key]) { action = .keyDefault }
                }
                Button("Nothing") { action = .none }
                Divider()
                Menu("Desktop") {
                    ForEach(1...10, id: \.self) { n in
                        Button("Desktop \(n)") { action = .desktop(n) }
                    }
                }
                Menu("Screenshot") {
                    ForEach(EdgeKeyAction.ScreenshotKind.allCases, id: \.self) { kind in
                        Button(EdgeKeyActions.title(.screenshot(kind))) { action = .screenshot(kind) }
                    }
                }
                Menu("System") {
                    Button("MSG Settings") { action = .settings(nil) }
                    Divider()
                    ForEach(EdgeKeyAction.SystemAction.allCases, id: \.self) { system in
                        Button(EdgeKeyActions.title(.system(system))) { action = .system(system) }
                    }
                }
                Button("Amphetamine: Keep Awake") { action = .amphetamineToggle }
                Button("Cloudflare WARP: VPN") { action = .cloudflareWARPToggle }
                Button("Mute/Unmute Microphone") { action = .microphoneToggle }
                Menu("Audio Device") {
                    Button { action = .cycleAudioInput } label: {
                        Label("Choose Audio Input", systemImage: "mic.fill")
                    }
                    Button { action = .cycleAudioOutput } label: {
                        Label("Choose Audio Output", systemImage: "speaker.wave.2.fill")
                    }
                }
                Menu("MSG Settings") {
                    Button("Open Settings") { action = .settings(nil) }
                    Divider()
                    ForEach(Self.settingsPanes, id: \.self) { section in
                        Button(section.title) { action = .settings(section.rawValue) }
                    }
                }
                Menu("External Display") {
                    Button("All External Displays") { action = .displayToggle("all") }
                    let externals = DisplaplacerEngine.externalDisplays()
                    if !externals.isEmpty { Divider() }
                    ForEach(externals, id: \.uuid) { display in
                        Button(display.name) { action = .displayToggle(display.uuid) }
                    }
                }
                Menu("Brightness") { controls([.brightnessDown, .brightnessUp]) }
                Menu("Volume") { controls([.volumeDown, .volumeUp, .mute]) }
                Menu("Media") {
                    controls([.previous, .playPause, .next])
                    Divider()
                    controls([.shuffle, .repeatMode, .favorite, .lyrics, .queue])
                }
                Divider()
                Button("Open App…") { chooseApp() }
            } label: {
                HStack(spacing: 6) {
                    if action == .keyDefault {
                        Image(systemName: Self.defaultSymbols[key])
                        Text(Self.defaultNames[key])
                    } else {
                        if let glyph = EdgeKeyActions.glyph(action, height: 13, color: .labelColor) {
                            Image(nsImage: glyph)
                        }
                        Text(EdgeKeyActions.title(action))
                    }
                }
            }
            .fixedSize()
        } label: {
            Text(key == 0 ? "esc" : key == 13 ? "Touch ID" : "F\(key)").monospacedDigit()
        }
    }

    private func controls(_ list: [EdgeKeyAction.Control]) -> some View {
        ForEach(list, id: \.self) { control in
            Button(EdgeKeyActions.title(.control(control))) { action = .control(control) }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        action = .app(bundleID)
    }
}

/// A small drawing of the built-in display's bottom edge in each mode.
@available(macOS 14.0, *)
private struct EdgeKeysPreview: View {
    let mode: EdgeKeysMode
    var firstRow: [Int: EdgeKeyAction] = [:]
    var modifier: EdgeKeysModifier = .command
    var triggerKey = 12

    private static let symbols: [String] = [
        "", "sun.min.fill", "sun.max.fill", "rectangle.3.group", "magnifyingglass", "mic.fill",
        "moon.fill", "backward.fill", "play.fill", "forward.fill", "speaker.slash.fill",
        "speaker.wave.1.fill", "speaker.wave.3.fill", "touchid",
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let stripHeight: CGFloat = 20
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hex: 0x2c2c3a), Color(hex: 0x14141c)],
                               startPoint: .top, endPoint: .bottom)
                switch mode {
                case .off:
                    Text("macOS default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity)
                case .popup:
                    popup(width: width)
                case .strip:
                    strip(width: width, height: stripHeight)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .animation(.smooth(duration: 0.3), value: mode)
        }
    }

    private func strip(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            ForEach(0..<14, id: \.self) { key in
                let gap = FunctionRow.unit - FunctionRow.face
                let capWidth = (key == 0 ? FunctionRow.escUnits * FunctionRow.unit - gap : FunctionRow.face) * width
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .overlay {
                        if key == 0 {
                            Text("esc").font(.system(size: 6, weight: .medium))
                        } else if modifier == .functionKey && key == triggerKey {
                            Image(systemName: "command").font(.system(size: 7, weight: .medium))
                        } else if key < 13, let action = firstRow[key], action != .keyDefault,
                                  let glyph = EdgeKeyActions.glyph(action, height: 16, color: .white) {
                            Image(nsImage: glyph).resizable().scaledToFit()
                                .frame(height: 8)
                        } else {
                            Image(systemName: Self.symbols[key]).font(.system(size: 7, weight: .medium))
                        }
                    }
                    .foregroundStyle(.white.opacity(key == 13 ? 0.45 : 0.85))
                    .frame(width: capWidth, height: height - 5)
                    .position(x: FunctionRow.center(of: key) * width, y: height / 2)
            }
        }
        .frame(height: height)
        .transition(.move(edge: .bottom))
    }

    private func popup(width: CGFloat) -> some View {
        let twoKeys = FunctionRow.twoKeys * width
        return ZStack(alignment: .topLeading) {
            Color.clear
            VStack(spacing: 5) {
                Image(systemName: "sun.max.fill").font(.system(size: 9, weight: .medium))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28))
                    Capsule().fill(Color.white).frame(width: twoKeys * 0.6)
                }
                .frame(width: twoKeys, height: 2.5)
            }
            .foregroundStyle(.white)
            .position(x: FunctionRow.brightness * width, y: 22)
        }
        .frame(height: 34)
        .transition(.opacity)
    }
}
