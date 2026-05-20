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
    private let systemState: SystemState
    private let renderer: IndicatorRenderer

    var onStatusBarClicked: (() -> Void)?
    var onMCStateChanged: (() -> Void)?
    var onMCEnter: (() -> Void)?

    /// When > now, music display suppressed (space change cooldown)
    private var musicSuppressUntil: TimeInterval = 0
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
    /// Bars→dots morph progress (0 = bars, 1 = dots)
    private var musicLingerMorphProgress: CGFloat = 0
    private var musicLingerMorphTimer: Timer?
    /// One-shot timer that fires when linger should expire
    private var musicLingerExpireTimer: Timer?

    // Audio visualizer
    var visualizerHeights: [CGFloat] = [0.4, 0.7, 0.5, 0.9]
    private var visualizerTargets: [CGFloat] = [0.4, 0.7, 0.5, 0.9]
    private var visualizerTimer: Timer?
    private var marqueeOffset: CGFloat = 0
    private var musicFrameWidth: CGFloat = 0

    // Music popover
    private var musicPopover: MusicPopover?
    private var previousDisplaysForSuppression: [SpaceInfo.DisplayInfo]?

    // MARK: Animation state

    var animSpacePillProgress: CGFloat = 1.0
    var animSpacePillDisplay: Int = -1
    var animSpacePillOldActive: Int = 0
    var animSpacePillNewActive: Int = 0
    private var animSpacePillCaptured: SpaceInfo?
    private var animSpacePillCapturedGrid: [GridRow] = []
    private var animSpacePillTimer: Timer?
    /// Frames pre-rasterized at animation start. Nil once focus changes
    /// mid-animation (the timer falls back to live rendering for the rest).
    private var preRenderedPillFrames: [NSImage]?
    /// `previousActiveDisplayIndex` captured at pre-render time. If this
    /// diverges from the live value, the pre-rendered cache is stale.
    private var preRenderedPillFocusIdx: Int = -1

    var animLayoutProgress: CGFloat = 1.0
    var animLayoutMorphOldW: CGFloat = 0
    var animLayoutMorphNewW: CGFloat = 0
    private var animLayoutTimer: Timer?

    var animRowMorphProgress: CGFloat = 1.0
    var animRowMorphFromStacked: Bool = false
    var animRowMorphFromCount: Int = 1
    private var animRowMorphTimer: Timer?
    private var animRowMorphPending: DispatchWorkItem?

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

    init(settings: AppSettings) {
        self.settings = settings
        self.systemState = SystemState()
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.spaceWatcher = SpaceWatcher()
        self.musicMonitor = MusicMonitor(settings: settings)
        self.renderer = IndicatorRenderer(settings: settings, statusItem: statusItem)
        self.musicPopover = MusicPopover(monitor: musicMonitor)
    }

    func start() {
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.imagePosition = .imageOnly

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
            }
            guard self.systemState.isStable else { return }
            guard self.animSpacePillDisplay < 0 else { return }
            self.refresh()
        }
        spaceWatcher.start()

        musicMonitor.onChange = { [weak self] in
            guard let self else { return }
            self.refresh()
        }
        musicMonitor.start()

        systemState.didStabilize = { [weak self] in self?.resyncSnapshotAfterStabilize() }
        systemState.didEnterUnstable = { [weak self] in
            self?.killAllAnimations()
            self?.onMCEnter?()
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
        visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.musicLingerActive {
                // Pick new random targets
                for i in 0..<4 {
                    if Float.random(in: 0...1) < 0.2 {
                        self.visualizerTargets[i] = CGFloat.random(in: 0.3...1.0)
                    }
                }
                // Smooth toward targets
                for i in 0..<4 {
                    self.visualizerHeights[i] += (self.visualizerTargets[i] - self.visualizerHeights[i]) * 0.4
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
        visualizerTimer?.invalidate(); visualizerTimer = nil
    }

    private func startLingerMorph() {
        guard musicLingerMorphTimer == nil else { return }
        musicLingerMorphProgress = 0
        let morphStartTime = CACurrentMediaTime()
        musicLingerMorphTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.musicLingerMorphProgress = min(1.0, CGFloat((CACurrentMediaTime() - morphStartTime) / 0.267))
            if self.musicLingerMorphProgress >= 1.0 {
                self.musicLingerMorphProgress = 1.0
                t.invalidate(); self.musicLingerMorphTimer = nil
            }
            self.refresh()
        }
        if let t = musicLingerMorphTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func startReverseMorph() {
        musicLingerMorphTimer?.invalidate()
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
            ctx.duration = 0.25
            button.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.musicDisplayShown = toMusic
            if !toMusic {
                self.musicLingerExpireTimer?.invalidate(); self.musicLingerExpireTimer = nil
                self.musicLingerMorphTimer?.invalidate(); self.musicLingerMorphTimer = nil
                self.musicLingerMorphProgress = 0
                self.stopVisualizer()
            }
            self.lastMusicTitle = nil
            self.lastMusicArtist = nil
            self.refresh()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.statusItem.button?.animator().alphaValue = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
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
        preRenderedPillFocusIdx = -1

        animLayoutTimer?.invalidate(); animLayoutTimer = nil
        animLayoutProgress = 1.0

        animRowMorphTimer?.invalidate(); animRowMorphTimer = nil
        animRowMorphPending?.cancel(); animRowMorphPending = nil
        animRowMorphProgress = 1.0

        animFocusTimer?.invalidate(); animFocusTimer = nil
        animFocusProgress = 1.0; animFocusOldDisplay = -1; animFocusNewDisplay = -1

        musicLingerMorphTimer?.invalidate(); musicLingerMorphTimer = nil
        musicLingerMorphProgress = 0
        musicLingerExpireTimer?.invalidate(); musicLingerExpireTimer = nil
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
        musicSwapFadeActive = false
        lastMusicTitle = nil
        lastMusicArtist = nil
        stopVisualizer()
        refresh()
    }

    func setFocusedUUID(_ uuid: String?) { spaceWatcher.currentFocusedUUID = uuid }

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
        }

        let showMusic = musicOn && settings.musicDisplayMode == .dynamic
            && (musicMonitor.isPlaying || musicLingerActive)
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
            // Schedule linger expiry if not already set
            if musicLingerActive && musicLingerExpireTimer == nil {
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
                barToDots: musicLingerMorphProgress
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
        let pad: CGFloat = 4
        let lenToSet = finalLen + pad * 2
        if abs(lenToSet - lastSetLength) > 0.1 {
            lastSetLength = lenToSet
            DispatchQueue.main.async { [weak self] in self?.statusItem.length = lenToSet }
        }
    }

    // MARK: - Animations

    private func startPillAnimation(info: SpaceInfo, displayIndex: Int, from oldSpace: Int, to newSpace: Int) {
        animSpacePillTimer?.invalidate()
        spaceWatcher.cancelChaseReads()

        animSpacePillProgress = 0
        animSpacePillDisplay = displayIndex
        animSpacePillOldActive = oldSpace
        animSpacePillNewActive = newSpace
        animSpacePillCaptured = info
        animSpacePillCapturedGrid = currentGridLayout

        let distance = abs(newSpace - oldSpace)
        let duration: TimeInterval = 0.4
        let interval: TimeInterval = 1.0 / 60.0

        // Closure that maps a raw 0...1 progress to a fully rendered, live
        // frame. Used both for pre-render (with the focus snapshot baked in)
        // and for the live fallback path when focus changes mid-animation.
        let renderFrame: (CGFloat, Int) -> NSImage? = { [weak self] raw, focusIdx in
            guard let self, let cap = self.animSpacePillCaptured else { return nil }
            let p = Easing.inOutQuart(raw)
            let liveIdx = max(0, min(focusIdx, cap.displays.count - 1))
            let effectiveInfo = liveIdx == cap.activeDisplayIndex ? cap : SpaceInfo(
                displays: cap.displays, activeDisplayIndex: liveIdx, mainDisplayIndex: cap.mainDisplayIndex
            )
            return self.renderer.makePillFrame(
                indicator: self, info: effectiveInfo,
                animatingDisplay: displayIndex,
                spacePillOldActive: oldSpace, spacePillNewActive: newSpace,
                spacePillProgress: p, overrideGridRows: self.animSpacePillCapturedGrid
            )
        }

        // Pre-rasterize all frames using the focus state at start.
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
        preRenderedPillFocusIdx = snapshotFocus

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animSpacePillProgress += CGFloat(interval / duration)

            if self.animSpacePillProgress >= 1.0 {
                t.invalidate()
                self.animSpacePillTimer = nil
                self.animSpacePillDisplay = -1
                self.preRenderedPillFrames = nil
                self.preRenderedPillFocusIdx = -1
                self.refresh()
                return
            }

            let raw = self.animSpacePillProgress

            // Live focus — SpaceWatcher keeps currentInfo fresh even while
            // the animation guard suppresses refresh() in its onChange path.
            let liveFocus = self.spaceWatcher.currentInfo.activeDisplayIndex

            // Pre-rendered fast path: focus hasn't changed since start.
            //
            // Index math: pre-render produced frames at raw = 1/N, 2/N, …, N/N
            // (stored at array[0…N-1]). At tick i, progress ≈ i/N, so the
            // frame to show sits at array[i-1] = array[Int(progress*N)-1].
            // The earlier formulation (Int(progress*N)) silently skipped
            // frame 0 — fatal for `solid` (frame 0 = 31% motion) and
            // noticeable on `jelly` (frame 0 = 16% motion).
            if let cache = self.preRenderedPillFrames,
               self.preRenderedPillFocusIdx == liveFocus {
                let raw_idx = Int(raw * CGFloat(cache.count)) - 1
                let idx = min(cache.count - 1, max(0, raw_idx))
                self.statusItem.button?.image = cache[idx]
                return
            }

            // Focus changed: drop the cache and render live for the remainder.
            self.preRenderedPillFrames = nil
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
        animLayoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animLayoutProgress += CGFloat((1.0 / 60.0) / 0.4)
            if self.animLayoutProgress >= 1.0 { self.animLayoutProgress = 1.0; t.invalidate(); self.animLayoutTimer = nil }
            self.refresh()
        }
    }

    private func startRowMorph(fromCount: Int, fromStacked: Bool) {
        let capFromCount = fromCount; let capFromStacked = fromStacked
        animRowMorphPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animRowMorphTimer?.invalidate()
            self.animRowMorphFromCount = capFromCount
            self.animRowMorphFromStacked = capFromStacked
            self.animRowMorphProgress = 0.0
            self.animRowMorphTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
                guard let self else { return }
                self.animRowMorphProgress += 0.05
                if self.animRowMorphProgress >= 1.0 { self.animRowMorphProgress = 1.0; t.invalidate() }
                self.refresh(); self.statusItem.button?.display()
            }
        }
        animRowMorphPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startFocusAnimation(from: Int, to: Int) {
        animFocusTimer?.invalidate()
        animFocusOldDisplay = from; animFocusNewDisplay = to; animFocusProgress = 0.0
        animFocusTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { return }
            self.animFocusProgress += 0.06
            if self.animFocusProgress >= 1.0 { self.animFocusProgress = 1.0; t.invalidate()
                self.animFocusOldDisplay = -1; self.animFocusNewDisplay = -1 }
            self.refresh()
        }
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
            guard let uuid = Self.screenUUID(screen), let di = uuidToDisplayIndex[uuid] else { continue }
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
        let dotD: CGFloat = 4, pillW: CGFloat = 18, pillH: CGFloat = 4, sp: CGFloat = 4, rowH: CGFloat = 8, gap: CGFloat = 1
        let neededH = CGFloat(rows.count) * rowH + CGFloat(rows.count - 1) * gap
        if neededH > imgH {
            let scale = (imgH - CGFloat(rows.count - 1) * gap) / (CGFloat(rows.count) * rowH)
            return GridDims(dotD: max(3, round(dotD * scale)), pillW: max(6, round(pillW * scale)),
                            pillH: max(2, round(pillH * scale)), sp: max(2, round(sp * scale)),
                            rowH: max(4, round(rowH * scale)), gap: gap)
        }
        return GridDims(dotD: dotD, pillW: pillW, pillH: pillH, sp: sp, rowH: rowH, gap: gap)
    }

    static func screenUUID(_ screen: NSScreen) -> String? {
        guard let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let u = CGDisplayCreateUUIDFromDisplayID(dID),
              let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String? else { return nil }
        return s
    }

    private func currentScreenRefreshRate() -> Double {
        guard let screen = NSScreen.main else { return 60.0 }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        if displayID != 0, let mode = CGDisplayCopyDisplayMode(displayID) {
            let rate = mode.refreshRate
            return rate > 0 ? rate : 120.0
        }
        return 60.0
    }
}

// MARK: - Easing

enum Easing {
    static func outCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
    static func outQuart(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 4) }
    static func inOutQuart(_ t: CGFloat) -> CGFloat { t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2 }
    static func inOutCubic(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func outExpo(_ t: CGFloat) -> CGFloat { t == 1 ? 1 : 1 - pow(2, -10 * t) }
    static func spring(_ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return 1.0 - exp(-6.0 * t) * cos(8.0 * t)
    }
}
