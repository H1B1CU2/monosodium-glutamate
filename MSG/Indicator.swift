import AppKit

// MARK: - Grid Layout

struct GridRow: Equatable {
    let displayIndices: [Int]
}

struct GridDims {
    let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat, gap: CGFloat
}

// MARK: - Indicator

final class Indicator {

    let statusItem: NSStatusItem
    let spaceWatcher: SpaceWatcher
    let musicMonitor: MusicMonitor
    private let settings: AppSettings
    let systemState: SystemState
    private let renderer: IndicatorRenderer

    var onStatusBarClicked: (() -> Void)?
    var onMCStateChanged: (() -> Void)?

    /// When > now, music display suppressed (space change cooldown)
    private var musicSuppressUntil: TimeInterval = 0
    private var musicUnsuppressTimer: Timer?
    /// Whether music info was shown in last refresh (for morph detection)
    private var musicDisplayShown = false
    /// Whether currently in linger mode (stored for timer access)
    private var musicLingerActive = false
    /// When music was last playing (for linger-after-pause)
    private var musicLastPlayedAt: TimeInterval = 0
    /// Previous title/artist for track-change cross-fade
    private var lastMusicTitle: String?
    private var lastMusicArtist: String?
    /// Guard against overlapping swap fades
    private var musicSwapFadeActive = false
    /// Bars→pause-glyph morph progress (0 = bars, 1 = paused)
    private var musicLingerMorphProgress: CGFloat = 0
    private var musicLingerMorphTimer: Timer?
    /// Text alpha during the pause morph's marquee reset (dips out, then back)
    private var musicPauseTextAlpha: CGFloat = 1
    /// One-shot timer that fires when linger should expire
    private var musicLingerExpireTimer: Timer?

    // Audio visualizer
    var visualizerHeights: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8]
    private var visualizerTargets: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8]
    private var visualizerTimer: Timer?
    private var marqueeOffset: CGFloat = 0
    private var musicFrameWidth: CGFloat = 0

    // Music popover
    private var musicPopover: MusicPopover?
    private var previousDisplaysForSuppression: [SpaceInfo.DisplayInfo]?
    private var rightClickTracker: RightClickTracker?

    // MARK: System HUD (volume / brightness overlay)

    /// When active, the status item is taken over by the volume/brightness bar
    /// and `refresh()` returns early so observers can't clobber it.
    private var systemHUDActive = false
    private var systemHUDKind: SystemHUDKind = .volume
    private var systemHUDMuted = false
    private var systemHUDAudioOutputKind: AudioOutputKind?
    private var systemHUDValue: CGFloat = 0     // animated, currently drawn
    private var systemHUDTarget: CGFloat = 0
    private var systemHUDFillTimer: Timer?
    private var systemHUDExpireTimer: Timer?

    // MARK: Input source HUD (keyboard language overlay)

    /// When active, the status item shows the keyboard language name and
    /// `refresh()` returns early. Between this and the volume/brightness HUD,
    /// whichever event happened last owns the item.
    private var inputSourceHUDActive = false
    private var inputSourceHUDName = ""
    private var inputSourceHUDExpireTimer: Timer?

    // MARK: Animation state

    var animSpacePillProgress: CGFloat = 1.0
    var animSpacePillDisplay: Int = -1
    var animSpacePillOldActive: Int = 0
    var animSpacePillNewActive: Int = 0
    private var animSpacePillCaptured: SpaceInfo?
    private var animSpacePillCapturedGrid: [GridRow] = []
    private var animSpacePillTimer: Timer?
    private var preRenderedPillFrames: [NSImage]?
    /// Seconds to hold on the old space before the next space-change animation
    /// advances, so its start isn't hidden behind the music→indicator fade-in.
    private var pillStartHoldDelay: TimeInterval = 0
    private let musicIndicatorSwapFadeDuration: TimeInterval = 0.25
    private let pillStartHoldAfterMusicFadeIn: TimeInterval = 0.42

    var animLayoutProgress: CGFloat = 1.0
    var animLayoutMorphOldW: CGFloat = 0
    var animLayoutMorphNewW: CGFloat = 0
    private var animLayoutTimer: Timer?

    var animRowMorphProgress: CGFloat = 1.0
    var animRowMorphFromStacked: Bool = false
    var animRowMorphFromCount: Int = 1
    private var animRowMorphTimer: Timer?

    var animFocusProgress: CGFloat = 1.0
    var animFocusOldDisplay: Int = -1
    var animFocusNewDisplay: Int = -1
    private var animFocusTimer: Timer?

    // MARK: Snapshot state (only mutated when systemState.isStable)

    private var previousSpaces: [Int] = []
    private var previousActiveDisplayIndex: Int = -1
    private var fullPreviousDisplays: [SpaceInfo.DisplayInfo] = []
    var previousLayoutDisplays: [SpaceInfo.DisplayInfo] = []
    private var previousEffectiveRowCount: Int = 1
    var currentGridLayout: [GridRow] = []
    private var lastSetLength: CGFloat = 0

    // MARK: Init

    init(settings: AppSettings, musicMonitor: MusicMonitor) {
        self.settings = settings
        self.systemState = SystemState()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.spaceWatcher = SpaceWatcher()
        self.musicMonitor = musicMonitor
        self.renderer = IndicatorRenderer(settings: settings, statusItem: statusItem)
        self.musicPopover = MusicPopover(monitor: musicMonitor)
    }

    /// Pull the status item out of the menu bar. Must happen before the app
    /// terminates: on macOS 26 the item is a MenuBarAgent-owned scene, and if
    /// the process exits while the scene is still registered, MenuBarAgent
    /// relaunches the app to restore it.
    func removeFromMenuBar() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func start() {
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly

        if let button = statusItem.button {
            let tracker = RightClickTracker(frame: button.bounds)
            tracker.autoresizingMask = [.width, .height]
            tracker.onRightClick = { [weak self] in
                guard let self else { return }
                self.musicPopover?.close()
                self.onStatusBarClicked?()
            }
            button.addSubview(tracker)
            self.rightClickTracker = tracker
        }

        spaceWatcher.customOrder = settings.displayOrderMode == .prioritizeMain ? [] : settings.displayOrder
        spaceWatcher.prioritizeMain = settings.displayOrderMode == .prioritizeMain
        spaceWatcher.focusDetection = settings.focusDetectionMode != .off
        spaceWatcher.onChange = { [weak self] in
            guard let self else { return }
            // Only suppress music display when spaces actually changed, not on focus-only shifts
            let newDisplays = self.spaceWatcher.currentInfo.displays
            let spacesChanged: Bool
            if let prev = self.previousDisplaysForSuppression {
                spacesChanged = prev.map(\.current) != newDisplays.map(\.current)
                    || prev.map(\.total) != newDisplays.map(\.total)
                    || prev.map(\.uuid) != newDisplays.map(\.uuid)
            } else {
                spacesChanged = false
            }
            self.previousDisplaysForSuppression = newDisplays
            if spacesChanged && self.settings.musicDisplayMode != .off && self.musicMonitor.isPlaying {
                let alreadySuppressed = ProcessInfo.processInfo.systemUptime < self.musicSuppressUntil
                self.musicSuppressUntil = ProcessInfo.processInfo.systemUptime + (alreadySuppressed ? 3.0 : 1.5)
                self.scheduleMusicUnsuppressRefresh()
            }
            guard self.systemState.isStable else { return }
            guard self.animSpacePillDisplay < 0 else { return }
            self.refresh()
        }
        spaceWatcher.start()

        // MusicMonitor is owned and started by AppDelegate; just observe it.
        musicMonitor.addObserver { [weak self] in
            self?.refresh()
        }

        systemState.didStabilize = { [weak self] in
            self?.spaceWatcher.isInMissionControl = false
            WallpaperEngine.shared.isMissionControlActive = false
            self?.spaceWatcher.updateInfo()
            self?.resyncSnapshotAfterStabilize()
        }
        systemState.didEnterUnstable = { [weak self] in
            self?.spaceWatcher.isInMissionControl = true
            WallpaperEngine.shared.isMissionControlActive = true
            self?.spaceWatcher.cancelChaseReads()
            self?.killAllAnimations()
        }
        systemState.onChange = { [weak self] in self?.onMCStateChanged?() }
        systemState.start()

        refresh()
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.buttonNumber == 1
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        if isRightClick {
            musicPopover?.close()
            onStatusBarClicked?()
            return
        }

        // Left click: if music showing, toggle popover; otherwise show menu
        if musicDisplayShown {
            if let popover = musicPopover, popover.isShown {
                popover.close()
            } else if let button = statusItem.button {
                musicPopover?.show(relativeTo: button)
            }
        } else {
            musicPopover?.close()
            onStatusBarClicked?()
        }
    }

    private func startVisualizer() {
        guard visualizerTimer == nil else { return }
        if #available(macOS 14.2, *) { AudioSpectrumTap.shared.acquire() }
        visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.musicLingerActive {
                var live: [CGFloat]?
                if #available(macOS 14.2, *) {
                    let tap = AudioSpectrumTap.shared
                    if tap.isDelivering && tap.hasSignal { live = tap.levels }
                }
                if let live {
                    // Real audio: chase the tap's band levels
                    for i in 0..<audioVisualizerBandCount {
                        self.visualizerTargets[i] = i < live.count ? live[i] : 0
                        self.visualizerHeights[i] += (self.visualizerTargets[i] - self.visualizerHeights[i]) * 0.5
                    }
                } else {
                    // Fallback (no tap permission / pre-14.2): random targets
                    for i in 0..<audioVisualizerBandCount {
                        if Float.random(in: 0...1) < 0.2 {
                            self.visualizerTargets[i] = CGFloat.random(in: 0.3...1.0)
                        }
                    }
                    // Smooth toward targets
                    for i in 0..<audioVisualizerBandCount {
                        self.visualizerHeights[i] += (self.visualizerTargets[i] - self.visualizerHeights[i]) * 0.4
                    }
                }
            }
            // Always advance marquee
            self.marqueeOffset += 0.4
            // Delegate to refresh for single render path (handles barToDots morph)
            self.refresh()
        }
        if let t = visualizerTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func stopVisualizer() {
        guard visualizerTimer != nil else { return }
        visualizerTimer?.invalidate(); visualizerTimer = nil
        if #available(macOS 14.2, *) { AudioSpectrumTap.shared.release() }
    }

    private func startLingerMorph() {
        guard musicLingerMorphTimer == nil else { return }
        musicLingerMorphProgress = 0
        // A long title frozen mid-scroll reads badly while paused: dip the text
        // out over the first half of the morph and bring it back at its start.
        let resetMarquee = marqueeOffset != 0
            && renderer.musicMarqueeActive(title: musicMonitor.currentTitle, artist: musicMonitor.currentArtist)
        musicLingerMorphTimer = runProgressTimer(interval: 0.016, duration: 0.267, commonModes: true, onTick: { me, p in
            me.musicLingerMorphProgress = p
            if resetMarquee {
                if p >= 0.5 { me.marqueeOffset = 0 }
                me.musicPauseTextAlpha = p < 0.5 ? 1 - p * 2 : (p - 0.5) * 2
            }
            me.refresh()
        }, onDone: { me in
            me.musicPauseTextAlpha = 1
            me.musicLingerMorphTimer = nil
        })
    }

    private func startReverseMorph() {
        musicLingerMorphTimer?.invalidate()
        musicPauseTextAlpha = 1
        let reverseStart = musicLingerMorphProgress
        let reverseDuration = max(0.001, Double(reverseStart) * 0.133)
        let morphReverseStartTime = CACurrentMediaTime()
        musicLingerMorphTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - morphReverseStartTime
            self.musicLingerMorphProgress = reverseStart * CGFloat(1.0 - min(1.0, elapsed / reverseDuration))
            if elapsed >= reverseDuration {
                self.musicLingerMorphProgress = 0
                t.invalidate(); self.musicLingerMorphTimer = nil
                self.startVisualizer()
            }
            self.refresh()
        }
        if let t = musicLingerMorphTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func startSwapFade(toMusic: Bool) {
        guard let button = statusItem.button else { return }
        musicSwapFadeActive = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = musicIndicatorSwapFadeDuration
            button.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + musicIndicatorSwapFadeDuration) {
            self.musicDisplayShown = toMusic
            if !toMusic {
                self.musicLingerExpireTimer?.invalidate(); self.musicLingerExpireTimer = nil
                self.musicLingerMorphTimer?.invalidate(); self.musicLingerMorphTimer = nil
                self.musicLingerMorphProgress = 0
                self.musicPauseTextAlpha = 1
                self.stopVisualizer()
            }
            self.lastMusicTitle = nil
            self.lastMusicArtist = nil
            // Returning to the space indicator: a space change may have happened
            // while music was showing. Hold slightly beyond the fade-in so the
            // first visible motion starts after the indicator has fully returned.
            if !toMusic { self.pillStartHoldDelay = self.pillStartHoldAfterMusicFadeIn }
            self.refresh()
            self.pillStartHoldDelay = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = self.musicIndicatorSwapFadeDuration
                self.statusItem.button?.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.musicIndicatorSwapFadeDuration) {
                self.musicSwapFadeActive = false
            }
        }
    }

    private func startTrackFade(title: String?, artist: String?) {
        guard let button = statusItem.button else { return }
        musicSwapFadeActive = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.lastMusicTitle = title
            self.lastMusicArtist = artist
            self.refresh()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                self.statusItem.button?.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.musicSwapFadeActive = false
            }
        }
    }

    // MARK: - Stability

    private func killAllAnimations() {
        animSpacePillTimer?.invalidate(); animSpacePillTimer = nil
        animSpacePillProgress = 1.0; animSpacePillDisplay = -1
        animSpacePillOldActive = 0; animSpacePillNewActive = 0
        animSpacePillCaptured = nil
        preRenderedPillFrames = nil
        pillStartHoldDelay = 0

        animLayoutTimer?.invalidate(); animLayoutTimer = nil
        animLayoutProgress = 1.0

        animRowMorphTimer?.invalidate(); animRowMorphTimer = nil
        animRowMorphProgress = 1.0

        animFocusTimer?.invalidate(); animFocusTimer = nil
        animFocusProgress = 1.0; animFocusOldDisplay = -1; animFocusNewDisplay = -1

        musicLingerMorphTimer?.invalidate(); musicLingerMorphTimer = nil
        musicLingerMorphProgress = 0
        musicLingerExpireTimer?.invalidate(); musicLingerExpireTimer = nil
        musicUnsuppressTimer?.invalidate(); musicUnsuppressTimer = nil
        musicSwapFadeActive = false
        musicLingerActive = false
        stopVisualizer()
    }

    private func resyncSnapshotAfterStabilize() {
        let info = spaceWatcher.currentInfo
        previousSpaces = info.displays.map { $0.current }
        previousActiveDisplayIndex = info.activeDisplayIndex
        fullPreviousDisplays = info.displays
        previousLayoutDisplays = info.displays
        previousEffectiveRowCount = effectiveRowCount(for: info.displays)
        refresh()
    }

    // MARK: - Public hooks

    var isMissionControl: Bool { systemState.isMissionControl }
    var isFullscreen: Bool { systemState.isFullscreen }

    func applySettings() {
        spaceWatcher.customOrder = settings.displayOrderMode == .prioritizeMain ? [] : settings.displayOrder
        spaceWatcher.prioritizeMain = settings.displayOrderMode == .prioritizeMain
        spaceWatcher.focusDetection = settings.focusDetectionMode != .off
        musicSuppressUntil = 0
        musicDisplayShown = false
        musicLastPlayedAt = 0
        musicLingerActive = false
        musicLingerMorphTimer?.invalidate(); musicLingerMorphTimer = nil
        musicLingerMorphProgress = 0
        musicLingerExpireTimer?.invalidate(); musicLingerExpireTimer = nil
        musicUnsuppressTimer?.invalidate(); musicUnsuppressTimer = nil
        musicSwapFadeActive = false
        lastMusicTitle = nil
        lastMusicArtist = nil
        stopVisualizer()
        refresh()
    }

    private func scheduleMusicUnsuppressRefresh() {
        musicUnsuppressTimer?.invalidate()
        let delay = max(0.05, musicSuppressUntil - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.musicUnsuppressTimer = nil
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .common)
        musicUnsuppressTimer = timer
    }

    // MARK: - Computed

    var stackIndicators: Bool {
        switch settings.stackMode {
        case .inline: return false
        case .stack:  return true
        case .dynamic:
            let screens = NSScreen.screens
            guard AppSettings.shared.effectiveDisplayCount >= 2 else { return false }
            guard screens.count >= 2 else { return true }
            let f1 = screens[0].frame, f2 = screens[1].frame
            let xOv = max(0, min(f1.maxX, f2.maxX) - max(f1.minX, f2.minX))
            let yOv = max(0, min(f1.maxY, f2.maxY) - max(f1.minY, f2.minY))
            return xOv > yOv
        }
    }

    var shouldUseGridLayout: Bool {
        return settings.stackMode == .dynamic
            && settings.displayOrderMode == .physicalDetection
            && AppSettings.shared.effectiveDisplayCount >= 3
    }

    private func effectiveRowCount(for displays: [SpaceInfo.DisplayInfo]) -> Int {
        return stackIndicators ? displays.count : 1
    }

    // MARK: - Refresh

    func refresh() {
        // The volume/brightness or keyboard-language HUD owns the status item while it's up.
        if systemHUDActive || inputSourceHUDActive { return }

        let spacerOn = settings.spacerEnabled
        let musicOn = settings.musicEnabled

        guard spacerOn || musicOn else {
            statusItem.isVisible = false
            return
        }
        statusItem.isVisible = true

        let info = spaceWatcher.currentInfo
        guard let button = statusItem.button else { return }

        if musicMonitor.isPlaying {
            musicLastPlayedAt = ProcessInfo.processInfo.systemUptime
            musicLingerActive = false
        } else if !musicLingerActive && musicDisplayShown && musicLastPlayedAt > 0 {
            musicLingerActive = true
            stopVisualizer()
        }

        let musicModeAllowsDisplay: Bool
        switch settings.musicDisplayMode {
        case .dynamic:
            musicModeAllowsDisplay = musicMonitor.isPlaying || musicLingerActive
        case .static:
            musicModeAllowsDisplay = true
        case .off:
            musicModeAllowsDisplay = false
        }

        let showMusic = musicOn
            && musicModeAllowsDisplay
            && ProcessInfo.processInfo.systemUptime >= musicSuppressUntil

        // Swap between music and space indicator
        if showMusic != musicDisplayShown && !musicSwapFadeActive {
            startSwapFade(toMusic: showMusic)
            return
        }

        // Music mode
        if musicDisplayShown {
            if musicLingerActive && musicLingerMorphProgress < 1.0 {
                startLingerMorph()
            } else if !musicLingerActive {
                musicLingerExpireTimer?.invalidate(); musicLingerExpireTimer = nil
                if musicLingerMorphProgress > 0 {
                    startReverseMorph()
                } else {
                    startVisualizer()
                }
            }
            // Schedule linger expiry if not already set. Only Dynamic mode hides
            // the display after the linger window; in Static mode the paused
            // state (pause glyph + dimmed title) persists until playback resumes.
            if musicLingerActive && musicLingerExpireTimer == nil && settings.musicDisplayMode == .dynamic {
                let remaining = settings.musicLingerDuration - (ProcessInfo.processInfo.systemUptime - musicLastPlayedAt)
                if remaining > 0 {
                    musicLingerExpireTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
                        self?.musicLingerExpireTimer = nil
                        self?.musicLingerActive = false
                        self?.musicLastPlayedAt = 0
                        self?.refresh()
                    }
                    if let t = musicLingerExpireTimer { RunLoop.current.add(t, forMode: .common) }
                } else {
                    musicLingerActive = false
                    musicLastPlayedAt = 0
                }
            }

            let currentTitle = musicMonitor.currentTitle
            let currentArtist = musicMonitor.currentArtist
            let trackChanged = !musicLingerActive && (currentTitle != lastMusicTitle || currentArtist != lastMusicArtist)

            if trackChanged && !musicSwapFadeActive {
                startTrackFade(title: currentTitle, artist: currentArtist)
                return
            }

            lastMusicTitle = currentTitle
            lastMusicArtist = currentArtist

            button.attributedTitle = NSAttributedString()
            let frame = renderer.makeMusicFrame(
                title: currentTitle,
                artist: currentArtist,
                barHeights: visualizerHeights,
                marqueeOffset: marqueeOffset,
                pauseMorph: musicLingerMorphProgress,
                textAlpha: musicPauseTextAlpha
            )
            button.image = frame
            musicFrameWidth = frame.size.width
            statusItem.length = NSStatusItem.variableLength
            return
        }

        guard spacerOn else { return }

        let stable = systemState.isStable

        // Layout morph
        let countChanged = fullPreviousDisplays.count != info.displays.count
        let totalsChanged = fullPreviousDisplays.map { $0.total } != info.displays.map { $0.total }

        if !fullPreviousDisplays.isEmpty && countChanged && stable {
            startLayoutMorph(from: fullPreviousDisplays, to: info.displays)
            fullPreviousDisplays = info.displays
        } else if !fullPreviousDisplays.isEmpty && (totalsChanged || (countChanged && !stable)) {
            if stable {
                fullPreviousDisplays = info.displays
                previousLayoutDisplays = info.displays
            }
        } else if fullPreviousDisplays.isEmpty {
            fullPreviousDisplays = info.displays
            previousLayoutDisplays = info.displays
            animLayoutMorphOldW = renderer.targetWidth(for: info.displays, stackIndicators: stackIndicators)
            animLayoutMorphNewW = animLayoutMorphOldW
            if !shouldUseGridLayout { previousEffectiveRowCount = effectiveRowCount(for: info.displays) }
        }

        // Grid
        if shouldUseGridLayout && animLayoutProgress >= 1.0 {
            currentGridLayout = computeGridLayout(for: info.displays)
        } else if !shouldUseGridLayout {
            currentGridLayout = []
        }

        // Row morph
        if stable && !shouldUseGridLayout && animLayoutProgress >= 1.0 {
            let cur = effectiveRowCount(for: info.displays)
            if animRowMorphProgress >= 1.0 && cur != previousEffectiveRowCount {
                startRowMorph(fromCount: previousEffectiveRowCount, fromStacked: previousEffectiveRowCount > 1)
                previousEffectiveRowCount = cur
            }
        }

        // Clear old state
        if button.image == nil || !button.title.isEmpty {
            button.title = ""
            button.attributedTitle = NSAttributedString()
        }

        applyStatusItemLength(info: info)

        // Render + animation triggers
        if stable { tryStartSpaceChange(info: info) }
        if stable { tryStartFocusChange(info: info) }
        if stable { previousSpaces = info.displays.map { $0.current } }
        if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
        // The space animation timer writes button.image directly using captured info.
        // A competing write from refresh() using current info causes per-frame conflicts
        // (active display index differs between captured vs current). Let the animation
        // timer own rendering; it already reads animFocus* from self for the focus overlay.
        if animSpacePillDisplay < 0 {
            button.image = renderer.makePillFrame(indicator: self, info: info)
        }

    }

    // MARK: - Animation triggers

    private func tryStartSpaceChange(info: SpaceInfo) {
        guard previousSpaces.count == info.displays.count else { return }
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

    private func tryStartFocusChange(info: SpaceInfo) {
        guard animFocusProgress >= 1.0,
              previousActiveDisplayIndex >= 0,
              info.activeDisplayIndex != previousActiveDisplayIndex else { return }
        startFocusAnimation(from: previousActiveDisplayIndex, to: info.activeDisplayIndex)
    }

    // MARK: - Width

    private func applyStatusItemLength(info: SpaceInfo) {
        // Don't resize during an active pill animation — the timer writes
        // button.image directly and an async length change would race.
        guard animSpacePillDisplay < 0 else { return }
        var naturalW: CGFloat
        if animLayoutProgress < 1.0 {
            naturalW = animLayoutMorphOldW + (animLayoutMorphNewW - animLayoutMorphOldW) * Easing.outQuart(animLayoutProgress)
        } else if animRowMorphProgress < 1.0 && !shouldUseGridLayout {
            let fromDisplays = animRowMorphFromCount > info.displays.count
                ? previousLayoutDisplays
                : info.displays
            let fromW = renderer.gnomePillFixedWidth(
                for: fromDisplays,
                stackIndicators: animRowMorphFromStacked
            )
            let toW = renderer.targetWidth(
                for: info.displays,
                stackIndicators: stackIndicators
            )
            naturalW = fromW + (toW - fromW) * Easing.outQuart(animRowMorphProgress)
        } else if shouldUseGridLayout {
            let dims = gridDimensions(for: currentGridLayout)
            naturalW = renderer.gnomePillFixedWidth(
                for: info.displays,
                stackIndicators: stackIndicators,
                gridRows: currentGridLayout,
                gridDotD: dims.dotD, gridPillW: dims.pillW, gridSp: dims.sp
            )
        } else {
            naturalW = renderer.targetWidth(for: info.displays, stackIndicators: stackIndicators)
        }

        let finalLen = max(24, naturalW)
        let pad: CGFloat = 2
        let lenToSet = finalLen + pad * 2
        if abs(lenToSet - lastSetLength) > 0.1 {
            lastSetLength = lenToSet
            DispatchQueue.main.async { [weak self] in self?.statusItem.length = lenToSet }
        }
    }

    // MARK: - Animations

    /// Drives a forward 0→1 progress animation on a main-thread Timer (the
    /// established design — see CLAUDE.md, deliberately not CVDisplayLink).
    /// `onTick` receives clamped progress every frame; `onDone` runs once at 1.
    private func runProgressTimer(
        interval: TimeInterval = 1.0 / 60.0,
        duration: TimeInterval,
        commonModes: Bool = false,
        onTick: @escaping (Indicator, CGFloat) -> Void,
        onDone: @escaping (Indicator) -> Void = { _ in }
    ) -> Timer {
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1.0, CGFloat((CACurrentMediaTime() - start) / duration))
            onTick(self, p)
            if p >= 1.0 { t.invalidate(); onDone(self) }
        }
        RunLoop.current.add(timer, forMode: commonModes ? .common : .default)
        return timer
    }

    private func startPillAnimation(info: SpaceInfo, displayIndex: Int, from oldSpace: Int, to newSpace: Int) {
        animSpacePillTimer?.invalidate()
        spaceWatcher.cancelChaseReads()

        animSpacePillProgress = 0
        animSpacePillDisplay = displayIndex
        animSpacePillOldActive = oldSpace
        animSpacePillNewActive = newSpace
        animSpacePillCaptured = info
        animSpacePillCapturedGrid = currentGridLayout

        let style = settings.animationStyle
        let distance = abs(newSpace - oldSpace)
        let base: TimeInterval = style == .liquid ? 0.75 : 0.30
        let k = 0.5
        let duration: TimeInterval = base * (1.0 + Double(distance - 1) * k)
        let interval: TimeInterval = 1.0 / 60.0
        let useSpring = style == .liquid
        let startTime = CACurrentMediaTime() + pillStartHoldDelay

        // Single-pass frame renderer: bakes focus into the frame at call time.
        let renderFrame: (CGFloat, Int) -> NSImage? = { [weak self] raw, focusIdx in
            guard let self, let cap = self.animSpacePillCaptured else { return nil }
            let p = useSpring ? Easing.spring(raw) : Easing.inOutQuart(raw)
            let idx = max(0, min(focusIdx, cap.displays.count - 1))
            let effectiveInfo = idx == cap.activeDisplayIndex ? cap : SpaceInfo(
                displays: cap.displays, activeDisplayIndex: idx, mainDisplayIndex: cap.mainDisplayIndex
            )
            return self.renderer.makePillFrame(
                indicator: self, info: effectiveInfo,
                animatingDisplay: displayIndex,
                spacePillOldActive: oldSpace, spacePillNewActive: newSpace,
                spacePillProgress: p, overrideGridRows: self.animSpacePillCapturedGrid,
                animationStyle: style
            )
        }

        // Pre-rasterize frames with snapshot focus baked in.
        let frameCount = max(1, Int(ceil(duration / interval)))
        let snapshotFocus = previousActiveDisplayIndex
        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let raw = CGFloat(i + 1) / CGFloat(frameCount)
            if let img = renderFrame(min(1.0, raw), snapshotFocus) {
                frames.append(rasterize(img))
            }
        }
        preRenderedPillFrames = frames.isEmpty ? nil : frames

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - startTime
            // Hold on the old space (progress 0, full opacity) until the swap
            // fade-in completes, so the animation's start is actually visible.
            if elapsed < 0 {
                self.animSpacePillProgress = 0
                if let img = renderFrame(0, self.spaceWatcher.currentInfo.activeDisplayIndex) {
                    self.statusItem.button?.image = img
                }
                return
            }
            let raw = min(1.0, CGFloat(elapsed / duration))
            self.animSpacePillProgress = raw

            if raw >= 1.0 {
                t.invalidate()
                self.animSpacePillTimer = nil
                self.animSpacePillDisplay = -1
                self.preRenderedPillFrames = nil
                self.refresh()
                return
            }

            let liveFocus = self.spaceWatcher.currentInfo.activeDisplayIndex

            // Pre-rendered fast path: focus hasn't changed since start.
            if let cache = self.preRenderedPillFrames, liveFocus == snapshotFocus {
                let raw_idx = Int(raw * CGFloat(cache.count)) - 1
                let idx = min(cache.count - 1, max(0, raw_idx))
                self.statusItem.button?.image = cache[idx]
                return
            }

            // Focus changed mid-animation: keep snapshot in sync and render live.
            if liveFocus != self.previousActiveDisplayIndex {
                self.previousActiveDisplayIndex = liveFocus
            }
            if let img = renderFrame(raw, liveFocus) {
                self.statusItem.button?.image = img
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        animSpacePillTimer = timer
    }

    /// Force `image`'s deferred drawing closure to run *now* into a bitmap
    /// representation, then return an NSImage that wraps that bitmap. AppKit
    /// can then blit it directly without re-invoking any draw closure.
    private func rasterize(_ image: NSImage) -> NSImage {
        let size = image.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixW = max(1, Int(ceil(size.width * scale)))
        let pixH = max(1, Int(ceil(size.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixW, pixelsHigh: pixH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }

    private func startLayoutMorph(from old: [SpaceInfo.DisplayInfo], to new: [SpaceInfo.DisplayInfo]) {
        animLayoutTimer?.invalidate()
        if animLayoutProgress < 1.0 {
            animLayoutMorphOldW = animLayoutMorphOldW + (animLayoutMorphNewW - animLayoutMorphOldW) * Easing.outQuart(animLayoutProgress)
        } else {
            animLayoutMorphOldW = renderer.targetWidth(for: old, stackIndicators: stackIndicators)
        }
        animLayoutMorphNewW = renderer.targetWidth(for: new, stackIndicators: stackIndicators)
        previousLayoutDisplays = old
        animLayoutProgress = 0
        animLayoutTimer = runProgressTimer(duration: 0.4, onTick: { me, p in
            me.animLayoutProgress = p
            me.refresh()
        }, onDone: { me in me.animLayoutTimer = nil })
    }

    private func startRowMorph(fromCount: Int, fromStacked: Bool) {
        // Start immediately and synchronously (like startLayoutMorph): the trigger in
        // refresh() guards on animRowMorphProgress, so setting it to 0 here makes the
        // very next render in this same refresh pass draw the *old* layout, and the
        // morph plays forward from it. The previous 0.3s debounce delay caused the
        // frame to snap to the new layout, hold, then jump back to morph from the start.
        animRowMorphTimer?.invalidate()
        animRowMorphFromCount = fromCount
        animRowMorphFromStacked = fromStacked
        animRowMorphProgress = 0.0
        animRowMorphTimer = runProgressTimer(interval: 0.016, duration: 0.4, onTick: { me, p in
            me.animRowMorphProgress = p
            me.refresh(); me.statusItem.button?.display()
        })
    }

    private func startFocusAnimation(from: Int, to: Int) {
        animFocusTimer?.invalidate()
        animFocusOldDisplay = from; animFocusNewDisplay = to; animFocusProgress = 0.0
        animFocusTimer = runProgressTimer(interval: 0.016, duration: 0.25, onTick: { me, p in
            me.animFocusProgress = p
            me.refresh()
        }, onDone: { me in
            me.animFocusOldDisplay = -1; me.animFocusNewDisplay = -1
        })
    }

    // MARK: - System HUD

    /// Show (or update) the volume/brightness bar. On first entry it crossfades
    /// in over whatever was showing; subsequent calls animate the fill to the new
    /// value. Auto-dismisses ~1.5s after the last change, like the native OSD.
    func showSystemHUD(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind? = nil) {
        let v = max(0, min(1, value))
        let wasActive = systemHUDActive
        systemHUDKind = kind
        systemHUDMuted = muted
        systemHUDAudioOutputKind = audioOutputKind
        systemHUDTarget = v
        statusItem.isVisible = true

        // Latest event wins: a volume/brightness change takes over from the
        // keyboard-language display.
        if inputSourceHUDActive {
            inputSourceHUDExpireTimer?.invalidate(); inputSourceHUDExpireTimer = nil
            inputSourceHUDActive = false
        }

        if !wasActive {
            systemHUDActive = true
            systemHUDValue = v
            // Stop anything else that writes button.image.
            animSpacePillTimer?.invalidate(); animSpacePillTimer = nil
            animSpacePillDisplay = -1
            preRenderedPillFrames = nil
            musicLingerMorphTimer?.invalidate(); musicLingerMorphTimer = nil
            stopVisualizer()
            renderSystemHUD()
            if let button = statusItem.button {
                button.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    button.animator().alphaValue = 1
                }
            }
        } else {
            animateSystemHUDFill()
        }
        resetSystemHUDExpire()
    }

    private func animateSystemHUDFill() {
        systemHUDFillTimer?.invalidate()
        let start = systemHUDValue
        let delta = systemHUDTarget - start
        guard abs(delta) > 0.0001 else {
            systemHUDValue = systemHUDTarget
            renderSystemHUD()
            return
        }
        systemHUDFillTimer = runProgressTimer(interval: 1.0 / 60.0, duration: 0.18, commonModes: true, onTick: { me, p in
            me.systemHUDValue = start + delta * Easing.outQuart(p)
            me.renderSystemHUD()
        }, onDone: { me in
            me.systemHUDFillTimer = nil
            me.systemHUDValue = me.systemHUDTarget
            me.renderSystemHUD()
        })
    }

    private func renderSystemHUD() {
        guard systemHUDActive, let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString()
        let frame = renderer.makeSystemHUDFrame(kind: systemHUDKind, value: systemHUDValue, muted: systemHUDMuted, audioOutputKind: systemHUDAudioOutputKind)
        button.image = frame
        let len = frame.size.width + 4
        if abs(len - lastSetLength) > 0.1 {
            lastSetLength = len
            statusItem.length = len
        }
    }

    private func resetSystemHUDExpire() {
        systemHUDExpireTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.dismissSystemHUD()
        }
        RunLoop.current.add(timer, forMode: .common)
        systemHUDExpireTimer = timer
    }

    private func dismissSystemHUD() {
        systemHUDExpireTimer?.invalidate(); systemHUDExpireTimer = nil
        systemHUDFillTimer?.invalidate(); systemHUDFillTimer = nil
        guard let button = statusItem.button else {
            systemHUDActive = false
            refresh()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.systemHUDActive = false
            // If the keyboard-language HUD grabbed the item mid-fade, it owns
            // the button (and its alpha) now — don't fight its fade-in.
            guard !self.inputSourceHUDActive else { return }
            self.lastSetLength = 0          // force length recompute on restore
            self.refresh()
            if let b = self.statusItem.button {
                b.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    b.animator().alphaValue = 1
                }
            }
        })
    }

    // MARK: - Input Source HUD (keyboard language)

    /// Morph the space indicator into the keyboard language name. First entry
    /// crossfades in over whatever was showing; switching again while it's up
    /// just swaps the text. Auto-dismisses ~1.5s after the last switch, then
    /// morphs back.
    func showInputSourceHUD(name: String) {
        inputSourceHUDName = name
        statusItem.isVisible = true

        // Latest event wins: a language switch takes over from the
        // volume/brightness bar.
        if systemHUDActive {
            systemHUDExpireTimer?.invalidate(); systemHUDExpireTimer = nil
            systemHUDFillTimer?.invalidate(); systemHUDFillTimer = nil
            systemHUDActive = false
        }

        if !inputSourceHUDActive {
            inputSourceHUDActive = true
            // Stop anything else that writes button.image.
            animSpacePillTimer?.invalidate(); animSpacePillTimer = nil
            animSpacePillDisplay = -1
            preRenderedPillFrames = nil
            musicLingerMorphTimer?.invalidate(); musicLingerMorphTimer = nil
            stopVisualizer()
            renderInputSourceHUD()
            if let button = statusItem.button {
                button.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    button.animator().alphaValue = 1
                }
            }
        } else {
            renderInputSourceHUD()
        }
        resetInputSourceHUDExpire()
    }

    private func renderInputSourceHUD() {
        guard inputSourceHUDActive, let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString()
        let frame = renderer.makeInputSourceHUDFrame(name: inputSourceHUDName)
        button.image = frame
        let len = frame.size.width + 4
        if abs(len - lastSetLength) > 0.1 {
            lastSetLength = len
            statusItem.length = len
        }
    }

    private func resetInputSourceHUDExpire() {
        inputSourceHUDExpireTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.dismissInputSourceHUD()
        }
        RunLoop.current.add(timer, forMode: .common)
        inputSourceHUDExpireTimer = timer
    }

    private func dismissInputSourceHUD() {
        inputSourceHUDExpireTimer?.invalidate(); inputSourceHUDExpireTimer = nil
        guard inputSourceHUDActive else { return }
        guard let button = statusItem.button else {
            inputSourceHUDActive = false
            refresh()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            button.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.inputSourceHUDActive = false
            // If the volume/brightness HUD grabbed the item mid-fade, it owns
            // the button (and its alpha) now — don't fight its fade-in.
            guard !self.systemHUDActive else { return }
            self.lastSetLength = 0          // force length recompute on restore
            self.refresh()
            if let b = self.statusItem.button {
                b.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    b.animator().alphaValue = 1
                }
            }
        })
    }

    // MARK: - Grid

    func computeGridLayout(for displays: [SpaceInfo.DisplayInfo]) -> [GridRow] {
        let screens = NSScreen.screens
        guard AppSettings.shared.effectiveDisplayCount >= 2 else { return [GridRow(displayIndices: Array(0..<displays.count))] }
        var uuidToDisplayIndex: [String: Int] = [:]
        for (i, d) in displays.enumerated() { uuidToDisplayIndex[d.uuid] = i }
        let builtIn = screens[0]
        var mainIdx = -1
        var above: [(Int, CGFloat)] = []; var below: [(Int, CGFloat)] = []
        var left:  [(Int, CGFloat)] = []; var right: [(Int, CGFloat)] = []
        for (screenIdx, screen) in screens.enumerated() {
            guard let uuid = screen.uuid, let di = uuidToDisplayIndex[uuid] else { continue }
            if screenIdx == 0 { mainIdx = di; continue }
            let f = screen.frame, b = builtIn.frame
            if f.minY >= b.maxY       { above.append((di, f.minX)) }
            else if f.maxY <= b.minY  { below.append((di, f.minX)) }
            else if f.maxX <= b.minX  { left.append((di, f.minX)) }
            else                       { right.append((di, f.minX)) }
        }
        above.sort { $0.1 < $1.1 }; below.sort { $0.1 < $1.1 }
        left.sort  { $0.1 < $1.1 }; right.sort { $0.1 < $1.1 }
        var rows: [GridRow] = []
        if !above.isEmpty { rows.append(GridRow(displayIndices: above.map { $0.0 })) }
        var mainRow = left.map { $0.0 }
        if mainIdx >= 0 { mainRow.append(mainIdx) }
        mainRow.append(contentsOf: right.map { $0.0 })
        if !mainRow.isEmpty { rows.append(GridRow(displayIndices: mainRow)) }
        if !below.isEmpty { rows.append(GridRow(displayIndices: below.map { $0.0 })) }
        let covered = rows.reduce(0) { $0 + $1.displayIndices.count }
        if covered < displays.count { return [GridRow(displayIndices: Array(0..<displays.count))] }
        return rows
    }

    func gridDimensions(for rows: [GridRow]) -> GridDims {
        let imgH = statusItem.button?.bounds.height ?? 22
        let dotD: CGFloat = 3.5, pillW: CGFloat = 18, pillH: CGFloat = 4, sp: CGFloat = 4, rowH: CGFloat = 8, gap: CGFloat = 1
        let neededH = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * gap
        if neededH > imgH {
            let scale = (imgH - CGFloat(rows.count - 1) * gap) / (CGFloat(rows.count) * rowH)
            return GridDims(dotD: max(2, round(dotD * scale)), pillW: max(6, round(pillW * scale)),
                            pillH: max(2, round(pillH * scale)), sp: max(2, round(sp * scale)),
                            rowH: max(4, round(rowH * scale)), gap: gap)
        }
        return GridDims(dotD: dotD, pillW: pillW, pillH: pillH, sp: sp, rowH: rowH, gap: gap)
    }

}

// MARK: - Easing

enum Easing {
    static func outQuart(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 4) }
    static func inOutQuart(_ t: CGFloat) -> CGFloat { t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2 }
    static func spring(_ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return 1.0 - exp(-6.0 * t) * cos(8.0 * t)
    }
}

// MARK: - RightClickTracker

final class RightClickTracker: NSView {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
