import AppKit
import ApplicationServices

// MARK: - DisplayStyle
enum DisplayStyle: String, CaseIterable {
    case pill        = "Pill"
    case numbers     = "Numbers"
    case boldNumber  = "Bold Number (current only)"
    case dots        = "Dots"

    var next: DisplayStyle {
        let all = DisplayStyle.allCases
        let idx = all.firstIndex(of: self)!
        return all[(idx + 1) % all.count]
    }
}

// MARK: - Persistent Settings Keys
private enum SettingsKey {
    static let cornerRadius         = "cornerRadius"
    static let topCornersEnabled    = "topCornersEnabled"
    static let bottomCornersEnabled = "bottomCornersEnabled"
    static let topCornersUnderMenuBar = "topCornersUnderMenuBar"
    static let darkMenuBarEnabled   = "darkMenuBarEnabled"
    static let fullscreenOnly       = "fullscreenOnly"
    static let hideInMissionControl = "hideInMissionControl"
    static let displayStyle         = "displayStyle"
    static let externalMonitorCorners = "externalMonitorCorners"
    static let prioritizeMainDisplay = "prioritizeMainDisplay"
    static let springAnimationEnabled = "springAnimationEnabled"
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // ── Cornermizer Settings ────────────────────────────────────
    var cornerRadius: CGFloat { didSet { save(); refreshOverlays() } }
    var topCornersEnabled: Bool { didSet { save(); refreshOverlays() } }
    var bottomCornersEnabled: Bool { didSet { save(); refreshOverlays() } }
    var topCornersUnderMenuBar: Bool { didSet { save(); refreshOverlays() } }
    var darkMenuBarEnabled: Bool { didSet { 
        save()
        updateWallpaperHack()
        refreshOverlays()
    }}
    var fullscreenOnly: Bool { didSet { 
        save()
        updateWallpaperHack()
        refreshOverlays()
    }}
    var hideInMissionControl: Bool { didSet { save(); refreshOverlays() } }
    var externalMonitorCorners: Bool { didSet { save(); rebuildCornerWindows() } }
    var prioritizeMainDisplay: Bool { didSet { save(); spaceWatcher?.prioritizeMain = prioritizeMainDisplay } }
    var springAnimationEnabled: Bool { didSet { save() } }

    private(set) var isFullscreen = false
    private(set) var isMissionControl = false

    // ── Spacer Settings ─────────────────────────────────────────
    var displayStyle: DisplayStyle { didSet { save(); refreshDisplay() } }

    // ── UI ───────────────────────────────────────────────────────
    private var statusItem: NSStatusItem!
    private var settingsMenu: SettingsMenu!
    private var cornerWindows: [CornerWindow] = []
    private var menuBarWindows: [MenuBarWindow] = []

    // ── Spacer state ─────────────────────────────────────────────
    private var spaceWatcher: SpaceWatcher!
    private var animationTimer: Timer?
    private var animationProgress: CGFloat = 1.0
    private var previousSpaces: [Int] = []
    private var fullPreviousDisplays: [SpaceInfo.DisplayInfo] = []
    private var previousLayoutDisplays: [SpaceInfo.DisplayInfo] = []
    private var layoutAnimationProgress: CGFloat = 1.0
    private var layoutAnimationTimer: Timer?
    private var morphOldW: CGFloat = 0
    private var morphNewW: CGFloat = 0
    private var lastSetLength: CGFloat = 0
    private var animatingDisplayIndex: Int = -1
    private var screenObserver: NSObjectProtocol?

    // ── Init ─────────────────────────────────────────────────────
    override init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            SettingsKey.cornerRadius:           CGFloat(10),
            SettingsKey.topCornersEnabled:      true,
            SettingsKey.bottomCornersEnabled:   true,
            SettingsKey.topCornersUnderMenuBar: false,
            SettingsKey.darkMenuBarEnabled:     false,
            SettingsKey.fullscreenOnly:         false,
            SettingsKey.hideInMissionControl:   true,
            SettingsKey.displayStyle:           DisplayStyle.pill.rawValue,
            SettingsKey.externalMonitorCorners: false,
            SettingsKey.prioritizeMainDisplay:  true,
            SettingsKey.springAnimationEnabled: false,
        ])
        cornerRadius           = CGFloat(d.float(forKey: SettingsKey.cornerRadius))
        topCornersEnabled      = d.bool(forKey: SettingsKey.topCornersEnabled)
        bottomCornersEnabled   = d.bool(forKey: SettingsKey.bottomCornersEnabled)
        topCornersUnderMenuBar = d.bool(forKey: SettingsKey.topCornersUnderMenuBar)
        darkMenuBarEnabled     = d.bool(forKey: SettingsKey.darkMenuBarEnabled)
        fullscreenOnly         = d.bool(forKey: SettingsKey.fullscreenOnly)
        hideInMissionControl   = d.bool(forKey: SettingsKey.hideInMissionControl)
        externalMonitorCorners = d.bool(forKey: SettingsKey.externalMonitorCorners)
        prioritizeMainDisplay  = d.bool(forKey: SettingsKey.prioritizeMainDisplay)
        springAnimationEnabled = d.bool(forKey: SettingsKey.springAnimationEnabled)
        let styleRaw = d.string(forKey: SettingsKey.displayStyle) ?? DisplayStyle.pill.rawValue
        displayStyle = DisplayStyle(rawValue: styleRaw) ?? .pill
        super.init()
    }

    // ── Launch ───────────────────────────────────────────────────
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()

        setupMenuBar()
        setupSettingsMenu()
        
        if darkMenuBarEnabled && !fullscreenOnly {
            WallpaperManager.shared.applyDarkMenuBar(to: NSScreen.screens)
        }
        
        rebuildMenuBarWindows()
        rebuildCornerWindows()
        refreshOverlays()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildCornerWindows()
            self?.spaceWatcher?.updateInfo()
            self?.refreshDisplay()
            if self?.darkMenuBarEnabled == true {
                WallpaperManager.shared.applyDarkMenuBar(to: NSScreen.screens)
            }
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(wallpaperChanged(_:)),
            name: NSNotification.Name("NSWorkspaceDidChangeDesktopImageNotification"),
            object: nil
        )

        spaceWatcher = SpaceWatcher { [weak self] in self?.refreshDisplay() }
        spaceWatcher.prioritizeMain = prioritizeMainDisplay
        spaceWatcher.start()
        refreshDisplay()
        perform(#selector(pollWindowState), with: nil, afterDelay: 0.5)
    }

    @objc private func wallpaperChanged(_ notification: Notification) {
        updateWallpaperHack()
    }

    private func updateWallpaperHack() {
        if darkMenuBarEnabled && !fullscreenOnly {
            // Delay slightly to let the system finish setting the wallpaper
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WallpaperManager.shared.applyDarkMenuBar(to: NSScreen.screens)
            }
        } else {
            WallpaperManager.shared.restoreOriginalWallpapers(to: NSScreen.screens)
        }
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // ── Polling ──────────────────────────────────────────────────
    @objc private func pollWindowState() {
        perform(#selector(pollWindowState), with: nil, afterDelay: 0.5)
        let fs = detectFullscreen(), mc = detectMissionControl()
        var changed = false
        if fs != isFullscreen { isFullscreen = fs; changed = true }
        if mc != isMissionControl { isMissionControl = mc; changed = true }
        if changed { refreshOverlays() }
    }

    private func detectFullscreen() -> Bool {
        // Method 1: Check if Menu Bar is visible (most reliable for Fullscreen)
        if !NSMenu.menuBarVisible() { return true }
        
        // Method 2: Accessibility check for focused window
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &winRef) == .success else { return false }
        var fsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(winRef as! AXUIElement, "AXFullScreen" as CFString, &fsRef) == .success else { return false }
        return (fsRef as? NSNumber)?.boolValue == true
    }

    private func detectMissionControl() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock"
    }

    // ── Setup ────────────────────────────────────────────────────
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
        }
    }

    private func setupSettingsMenu() { settingsMenu = SettingsMenu(delegate: self) }

    private func rebuildCornerWindows() {
        for win in cornerWindows { win.orderOut(nil) }
        cornerWindows.removeAll()
        let screens = externalMonitorCorners ? NSScreen.screens : [NSScreen.main ?? NSScreen.screens[0]]
        for screen in screens {
            let win = CornerWindow(appDelegate: self, screen: screen)
            win.orderFront(nil)
            cornerWindows.append(win)
        }
        refreshOverlays()
    }

    private func rebuildMenuBarWindows() {
        for win in menuBarWindows { win.orderOut(nil) }
        menuBarWindows.removeAll()
        for screen in NSScreen.screens {
            let win = MenuBarWindow(screen: screen)
            menuBarWindows.append(win)
        }
    }

    // ── Overlays ─────────────────────────────────────────────────
    func refreshOverlays() {
        let hideCornersMC = hideInMissionControl && isMissionControl
        let hideCornersFS = fullscreenOnly && !isFullscreen
        
        if hideCornersMC || hideCornersFS {
            for win in cornerWindows { win.orderOut(nil) }
        } else {
            for win in cornerWindows {
                win.orderFront(nil)
                win.updateFrame()
                win.cornerView?.needsDisplay = true
            }
        }
        
        updateMenuBarWindow()
    }

    func updateMenuBarWindow() {
        if !darkMenuBarEnabled {
            for win in menuBarWindows { win.orderOut(nil) }
            return
        }
        
        // If fullscreenOnly is ON, we only show the overlay in fullscreen.
        // If fullscreenOnly is OFF, the wallpaper hack handles the desktop, 
        // but we still use the overlay for fullscreen as the wallpaper is hidden.
        if isFullscreen {
            for win in menuBarWindows {
                win.updateFrame()
                win.orderFront(nil)
            }
        } else {
            // Desktop mode: 
            // If fullscreenOnly is ON, hide the bar.
            // If fullscreenOnly is OFF, the wallpaper hack is active, so we hide the overlay window to avoid redundancy.
            for win in menuBarWindows { win.orderOut(nil) }
        }
    }

    // ── Persistence ──────────────────────────────────────────────
    private func save() {
        let d = UserDefaults.standard
        d.set(Float(cornerRadius),       forKey: SettingsKey.cornerRadius)
        d.set(topCornersEnabled,         forKey: SettingsKey.topCornersEnabled)
        d.set(bottomCornersEnabled,      forKey: SettingsKey.bottomCornersEnabled)
        d.set(topCornersUnderMenuBar,    forKey: SettingsKey.topCornersUnderMenuBar)
        d.set(darkMenuBarEnabled,        forKey: SettingsKey.darkMenuBarEnabled)
        d.set(fullscreenOnly,            forKey: SettingsKey.fullscreenOnly)
        d.set(hideInMissionControl,      forKey: SettingsKey.hideInMissionControl)
        d.set(displayStyle.rawValue,     forKey: SettingsKey.displayStyle)
        d.set(externalMonitorCorners,    forKey: SettingsKey.externalMonitorCorners)
        d.set(prioritizeMainDisplay,     forKey: SettingsKey.prioritizeMainDisplay)
        d.set(springAnimationEnabled,    forKey: SettingsKey.springAnimationEnabled)
    }

    // MARK: - Spacer Display Logic

    func refreshDisplay() {
        let info = spaceWatcher.currentInfo
        guard let button = statusItem.button else { return }

        // Detect display count change for morph animation
        // Detect display or space count change for morph animation
        let currentTotals = info.displays.map { $0.total }
        let previousTotals = fullPreviousDisplays.map { $0.total }
        
        if !fullPreviousDisplays.isEmpty && (fullPreviousDisplays.count != info.displays.count || currentTotals != previousTotals) {
            startLayoutMorphAnimation(from: fullPreviousDisplays, to: info.displays)
            fullPreviousDisplays = info.displays
        } else if fullPreviousDisplays.isEmpty {
            fullPreviousDisplays = info.displays
            previousLayoutDisplays = info.displays
            morphOldW = calculateTargetWidth(for: info.displays, style: displayStyle)
            morphNewW = calculateTargetWidth(for: info.displays, style: displayStyle)
        }

        // Only clear if needed to prevent redundant layout passes
        if displayStyle == .pill {
            if button.image == nil || !button.title.isEmpty {
                button.title = ""
                button.attributedTitle = NSAttributedString()
            }
        } else {
            if button.image != nil { button.image = nil }
        }

        // Unified width management: update once per frame
        var naturalW: CGFloat
        if layoutAnimationProgress < 1.0 {
            let t = easeOutQuart(layoutAnimationProgress)
            naturalW = morphOldW + (morphNewW - morphOldW) * t
        } else {
            naturalW = calculateTargetWidth(for: info.displays, style: displayStyle)
        }

        let padding: CGFloat = (displayStyle == .pill) ? 12 : 0
        let targetW = naturalW + padding

        // Apply width: use a 'Stable Width' strategy to prevent layout recursion crashes and clipping.
        let finalLen = (displayStyle == .pill) ? max(36, targetW) : targetW
        
        if displayStyle == .pill {
            let lenToSet = finalLen
            
            if abs(lenToSet - lastSetLength) > 0.1 {
                lastSetLength = lenToSet
                DispatchQueue.main.async { [weak self] in
                    self?.statusItem.length = lenToSet
                }
            }
        } else {
            if layoutAnimationProgress < 1.0 {
                if abs(finalLen - lastSetLength) > 0.5 {
                    lastSetLength = finalLen
                    DispatchQueue.main.async { [weak self] in
                        self?.statusItem.length = finalLen
                    }
                }
            } else if lastSetLength != -1 {
                lastSetLength = -1
                DispatchQueue.main.async { [weak self] in
                    self?.statusItem.length = NSStatusItem.variableLength
                }
            }
        }

        switch displayStyle {
        case .pill:
            // Detect which display changed space
            if previousSpaces.count == info.displays.count {
                for i in 0..<info.displays.count {
                    let prev = previousSpaces[i]
                    let cur = info.displays[i].current
                    if prev != cur && prev >= 1 && prev <= info.displays[i].total {
                        previousSpaces = info.displays.map { $0.current }
                        startPillAnimation(info: info, displayIndex: i, from: prev, to: cur)
                        return
                    }
                }
            }
            previousSpaces = info.displays.map { $0.current }
            button.image = makeGnomePillFrame(
                displays: info.displays, activeDisplayIndex: info.activeDisplayIndex
            )

        case .numbers:
            previousSpaces = info.displays.map { $0.current }
            button.attributedTitle = makeMultiDisplayString(info: info) { display, isActive in
                self.makeNumbersString(display, isActive: isActive)
            }
        case .boldNumber:
            previousSpaces = info.displays.map { $0.current }
            button.attributedTitle = makeMultiDisplayString(info: info) { display, isActive in
                self.makeBoldNumberString(display, isActive: isActive)
            }
        case .dots:
            previousSpaces = info.displays.map { $0.current }
            button.attributedTitle = makeMultiDisplayString(info: info) { display, isActive in
                self.makeDotsString(display, isActive: isActive)
            }
        }
    }

    private func makeMultiDisplayString(info: SpaceInfo, formatter: (SpaceInfo.DisplayInfo, Bool) -> NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let separator = NSAttributedString(string: " | ", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.2),
            .font: NSFont.systemFont(ofSize: 13, weight: .light)
        ])

        for (idx, display) in info.displays.enumerated() {
            if idx > 0 { result.append(separator) }
            result.append(formatter(display, idx == info.activeDisplayIndex))
        }
        return result
    }

    /// Fixed width = widest row across all displays.
    private func gnomePillFixedWidth(for displays: [SpaceInfo.DisplayInfo]) -> CGFloat {
        guard !displays.isEmpty else { return 26 }
        let isMulti = displays.count > 1
        let dotD: CGFloat = isMulti ? 4 : 6
        let pillW: CGFloat = isMulti ? 18 : 26
        let sp: CGFloat = isMulti ? 4 : 6
        var maxW: CGFloat = 0
        for d in displays {
            let c = max(1, d.total)
            maxW = max(maxW, pillW + CGFloat(c - 1) * (dotD + sp))
        }
        return maxW
    }

    // MARK: - Pill Animation

    private func startPillAnimation(info: SpaceInfo, displayIndex: Int, from oldSpace: Int, to newSpace: Int) {
        animationTimer?.invalidate()
        animationProgress = 0
        animatingDisplayIndex = displayIndex

        let captured = info
        let duration: TimeInterval = 0.4
        let interval: TimeInterval = 1.0 / 60.0

        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.animationProgress += CGFloat(interval / duration)
            if self.animationProgress >= 1.0 {
                timer.invalidate()
                self.animationTimer = nil
                self.animatingDisplayIndex = -1
                self.refreshDisplay()
                return
            }
            let t = self.springAnimationEnabled ? self.spring(self.animationProgress) : self.easeInOutQuart(self.animationProgress)
            self.statusItem.button?.image = self.makeGnomePillFrame(
                displays: captured.displays,
                activeDisplayIndex: captured.activeDisplayIndex,
                animatingDisplay: displayIndex,
                oldActive: oldSpace, newActive: newSpace, progress: t
            )
        }
    }

    // MARK: - Layout Morph Animation

    private func startLayoutMorphAnimation(from old: [SpaceInfo.DisplayInfo], to new: [SpaceInfo.DisplayInfo]) {
        layoutAnimationTimer?.invalidate()
        
        // Start from current visual state
        if layoutAnimationProgress < 1.0 {
            morphOldW = morphOldW + (morphNewW - morphOldW) * easeOutQuart(layoutAnimationProgress)
        } else {
            morphOldW = calculateTargetWidth(for: old, style: displayStyle)
        }
        
        morphNewW = calculateTargetWidth(for: new, style: displayStyle)
        previousLayoutDisplays = old
        layoutAnimationProgress = 0
        
        let duration: TimeInterval = 0.4
        let interval: TimeInterval = 1.0 / 60.0

        layoutAnimationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.layoutAnimationProgress += CGFloat(interval / duration)
            if self.layoutAnimationProgress >= 1.0 {
                self.layoutAnimationProgress = 1.0
                timer.invalidate()
                self.layoutAnimationTimer = nil
            }
            self.refreshDisplay()
        }
    }

    private func easeOutBack(_ t: CGFloat) -> CGFloat {
        let s: CGFloat = 1.70158
        let t2 = t - 1
        return t2 * t2 * ((s + 1) * t2 + s) + 1
    }

    private func easeOutQuart(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 4) }

    private func easeInOutQuart(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2
    }

    private func easeOutExpo(_ t: CGFloat) -> CGFloat {
        return t == 1 ? 1 : 1 - pow(2, -10 * t)
    }

    private func spring(_ t: CGFloat) -> CGFloat {
        if t == 0 { return 0 }
        if t == 1 { return 1 }
        return pow(2, -10 * t) * sin((t - 0.1) * (2 * .pi) / 0.4) + 1
    }

    // MARK: - GNOME Pill Style (multi-row)
    // CUSTOMIZE - GNOME Pill Style

    private func makeGnomePillFrame(
        displays: [SpaceInfo.DisplayInfo],
        activeDisplayIndex: Int,
        animatingDisplay: Int = -1,
        oldActive: Int = 0,
        newActive: Int = 0,
        progress: CGFloat = 1.0
    ) -> NSImage {
        let isMorphing = layoutAnimationProgress < 1.0
        let t = easeOutQuart(layoutAnimationProgress)
        
        let oldDisplays = previousLayoutDisplays
        let newDisplays = displays
        
        // Target values
        let numDisplays = displays.count
        let isMulti = numDisplays > 1
        let dotD_tgt: CGFloat  = isMulti ? 4  : 6
        let pillW_tgt: CGFloat = isMulti ? 18 : 26
        let pillH_tgt: CGFloat = isMulti ? 4  : 8
        let sp_tgt: CGFloat    = isMulti ? 4  : 6
        let rowH_tgt: CGFloat  = isMulti ? 8  : 20
        let gap_tgt: CGFloat   = 1

        // Initial values (from old state)
        let oldIsMulti = oldDisplays.count > 1
        let dotD_old: CGFloat  = oldIsMulti ? 4  : 6
        let pillW_old: CGFloat = oldIsMulti ? 18 : 26
        let pillH_old: CGFloat = oldIsMulti ? 4  : 8
        let sp_old: CGFloat    = oldIsMulti ? 4  : 6
        let rowH_old: CGFloat  = oldIsMulti ? 8  : 20
        let gap_old: CGFloat   = 1

        // Interpolated values
        let dotD  = dotD_old  + (dotD_tgt  - dotD_old)  * t
        let pillW = pillW_old + (pillW_tgt - pillW_old) * t
        let pillH = pillH_old + (pillH_tgt - pillH_old) * t
        let sp    = sp_old    + (sp_tgt    - sp_old)    * t
        let rowH  = rowH_old  + (rowH_tgt  - rowH_old)  * t
        let gap   = gap_old   + (gap_tgt   - gap_old)   * t

        let naturalW = morphOldW + (morphNewW - morphOldW) * t
        let padding: CGFloat = 12
        let fixedW = max(36, naturalW + padding)
        
        let image = NSImage(size: NSSize(width: fixedW, height: 22), flipped: false) { _ in
            // When morphing, we draw the larger set of displays to handle fading
            let displaysToDraw = (isMorphing && oldDisplays.count > displays.count) ? oldDisplays : displays
            let alpha_row2: CGFloat = (displays.count > oldDisplays.count) ? t : (1.0 - t)
            
            for (dIdx, display) in displaysToDraw.enumerated() {
                // Determine if this row should fade (it's the one being added/removed)
                let isFadingRow = dIdx >= min(oldDisplays.count, displays.count)
                let rowAlpha = isFadingRow ? alpha_row2 : 1.0
                if rowAlpha <= 0 { continue }
                
                // Directly interpolate Y for each row to ensure fluidity
                let rowY: CGFloat
                if isMorphing && displaysToDraw.count > 1 {
                    let isConnecting = displays.count > oldDisplays.count
                    
                    let yMain_2: CGFloat = 11.5 // Top row in 2-row
                    let yMain_1: CGFloat = 1.0  // Only row in 1-row
                    let yExt_2: CGFloat = 2.5   // Bottom row in 2-row
                    let yExt_1: CGFloat = -5.0  // Offscreen
                    
                    if dIdx == 0 {
                        let start = isConnecting ? yMain_1 : yMain_2
                        let end = isConnecting ? yMain_2 : yMain_1
                        rowY = start + (end - start) * t
                    } else {
                        let start = isConnecting ? yExt_1 : yExt_2
                        let end = isConnecting ? yExt_2 : yExt_1
                        rowY = start + (end - start) * t
                    }
                } else {
                    // Standard stacking when not morphing
                    let totalH_static = CGFloat(displays.count) * rowH + CGFloat(max(0, displays.count - 1)) * gap
                    rowY = (22 - totalH_static) / 2 + CGFloat(displays.count - 1 - dIdx) * (rowH + gap)
                }
                
                let isActive = dIdx == activeDisplayIndex
                let isAnim = dIdx == animatingDisplay
                
                // Interpolate display state for fluid morphing
                let oldDisplay = (dIdx < oldDisplays.count) ? oldDisplays[dIdx] : display
                let countFloat = CGFloat(oldDisplay.total) + (CGFloat(display.total) - CGFloat(oldDisplay.total)) * t
                let count = Int(ceil(countFloat))
                let morphActiveIdx = CGFloat(oldDisplay.current) + (CGFloat(display.current) - CGFloat(oldDisplay.current)) * t
                
                // Colors: use system label colors for perfect adaptive contrast
                let bright: NSColor = isActive ? .labelColor : NSColor.labelColor.withAlphaComponent(0.45)
                let dim: NSColor = isActive ? .secondaryLabelColor : NSColor.secondaryLabelColor.withAlphaComponent(0.35)
                
                // Animation state
                let currentPillIdx: CGFloat
                if isAnim {
                    currentPillIdx = CGFloat(oldActive) + CGFloat(newActive - oldActive) * progress
                } else {
                    currentPillIdx = isMorphing ? morphActiveIdx : CGFloat(display.current)
                }
                let clampedPillIdx = max(1.0, min(countFloat, currentPillIdx))

                // NEW STRETCH LOGIC:
                // Use naturalW (the widest row's natural length) to calculate stretch for shorter rows
                let rowNaturalW = countFloat * dotD + max(0, countFloat - 1) * sp + (pillW - dotD)
                let rowStretch = max(0, naturalW - rowNaturalW)

                // 2. Add a little "organic" stretch when moving
                let stretchBase: CGFloat = isAnim ? abs(CGFloat(newActive - oldActive)) : 0
                let stretch = stretchBase * sin(max(0, min(1, progress)) * .pi) * 3.0
                
                func widthForSpace(_ i: Int) -> CGFloat {
                    let iFloat = CGFloat(i)
                    let pLow = floor(clampedPillIdx)
                    let pHigh = ceil(clampedPillIdx)
                    let frac = clampedPillIdx - pLow
                    
                    // Alpha for the last (fading) dot
                    let dotAlpha: CGFloat = (iFloat > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                    
                    func adjustW(_ w: CGFloat) -> CGFloat {
                        // If it's the fading dot, it shouldn't just shrink, it should fade.
                        // But for width calculation, it needs to shrink to avoid jumping.
                        return w * dotAlpha
                    }
                    
                    if pLow == pHigh {
                        return iFloat == pLow ? (pillW + rowStretch) : adjustW(dotD)
                    }
                    
                    if iFloat == pLow {
                        return dotD + (pillW + rowStretch - dotD) * (1.0 - frac) + stretch * 0.5
                    } else if iFloat == pHigh {
                        return dotD + (pillW + rowStretch - dotD) * frac + stretch * 0.5
                    }
                    return adjustW(dotD)
                }

                func heightForSpace(_ i: Int) -> CGFloat {
                    let iFloat = CGFloat(i)
                    let pLow = floor(clampedPillIdx)
                    let pHigh = ceil(clampedPillIdx)
                    let frac = clampedPillIdx - pLow
                    
                    if pLow == pHigh {
                        return iFloat == pLow ? pillH : dotD
                    }
                    
                    if iFloat == pLow {
                        return dotD + (pillH - dotD) * (1.0 - frac)
                    } else if iFloat == pHigh {
                        return dotD + (pillH - dotD) * frac
                    }
                    return dotD
                }
                
                func colorForSpace(_ i: Int) -> NSColor {
                    let iFloat = CGFloat(i)
                    let pLow = floor(clampedPillIdx)
                    let pHigh = ceil(clampedPillIdx)
                    let frac = clampedPillIdx - pLow
                    
                    let dotAlpha: CGFloat = (iFloat > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                    
                    let alpha: CGFloat
                    if pLow == pHigh {
                        alpha = iFloat == pLow ? 1.0 : 0.0
                    } else if iFloat == pLow {
                        alpha = 1.0 - frac
                    } else if iFloat == pHigh {
                        alpha = frac
                    } else {
                        alpha = 0
                    }
                    
                    let color = dim.blended(withFraction: alpha, of: bright) ?? dim
                    return color.withAlphaComponent(color.alphaComponent * rowAlpha * dotAlpha)
                }

                // Calculate total row width to center it
                var totalRowW: CGFloat = 0
                for i in 1...count {
                    totalRowW += widthForSpace(i)
                    if i > 1 { totalRowW += sp }
                }
                
                var x: CGFloat = (fixedW - totalRowW) / 2
                for i in 1...count {
                    let w = widthForSpace(i)
                    let h = heightForSpace(i)
                    let rect = NSRect(x: x, y: rowY + (rowH - h) / 2, width: w, height: h)
                    NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill(with: colorForSpace(i))
                    x += w + sp
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Numbers Style

    private func makeNumbersString(_ d: SpaceInfo.DisplayInfo, isActive: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let nf = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bf = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        
        let alpha: CGFloat = isActive ? 1.0 : 0.4
        let nc = NSColor.secondaryLabelColor.withAlphaComponent(alpha * 0.5)
        let ac = NSColor.labelColor.withAlphaComponent(alpha)
        
        for i in 1...max(1, d.total) {
            if i > 1 { result.append(NSAttributedString(string: " ", attributes: [.font: nf, .foregroundColor: nc])) }
            let on = i == d.current
            result.append(NSAttributedString(string: "\(i)", attributes: [.font: on ? bf : nf, .foregroundColor: on ? ac : nc]))
        }
        return result
    }

    // MARK: - Bold Number

    private func makeBoldNumberString(_ d: SpaceInfo.DisplayInfo, isActive: Bool) -> NSAttributedString {
        let alpha: CGFloat = isActive ? 1.0 : 0.4
        return NSAttributedString(string: "\(d.current)",
                           attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                                        .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)])
    }

    // MARK: - Dots Style

    private func makeDotsString(_ d: SpaceInfo.DisplayInfo, isActive: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let f = NSFont.systemFont(ofSize: 10)
        let alpha: CGFloat = isActive ? 1.0 : 0.4
        let ac = NSColor.labelColor.withAlphaComponent(alpha), ic = NSColor.tertiaryLabelColor.withAlphaComponent(alpha * 0.5)
        for i in 1...max(1, d.total) {
            if i > 1 { result.append(NSAttributedString(string: " ", attributes: [.font: f, .foregroundColor: ic])) }
            result.append(NSAttributedString(string: "●", attributes: [.font: f, .foregroundColor: i == d.current ? ac : ic]))
        }
        return result
    }

    // MARK: - Clicks

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let menu = settingsMenu.menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func calculateTargetWidth(for displays: [SpaceInfo.DisplayInfo], style: DisplayStyle) -> CGFloat {
        guard !displays.isEmpty else { return 26 }
        switch style {
        case .pill:
            return gnomePillFixedWidth(for: displays)
        case .numbers:
            var w: CGFloat = 0
            for (idx, d) in displays.enumerated() {
                if idx > 0 { w += 16 }
                w += CGFloat(max(1, d.total)) * 14
            }
            return max(26, w)
        case .boldNumber:
            return max(26, CGFloat(displays.count) * 14 + CGFloat(max(0, displays.count - 1)) * 16)
        case .dots:
            var w: CGFloat = 0
            for (idx, d) in displays.enumerated() {
                if idx > 0 { w += 16 }
                w += CGFloat(max(1, d.total)) * 10
            }
            return max(26, w)
        }
    }
}

// Helper to fill a bezier path with a given color
private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
