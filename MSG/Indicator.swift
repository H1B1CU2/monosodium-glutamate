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

    /// When > now, music display suppressed (space change cooldown)
    private var musicSuppressUntil: TimeInterval = 0
    /// Whether music info was shown in last refresh (for morph detection)
    private var musicDisplayShown = false

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
    private var animSpacePillTimer: Timer?
    private var animSpacePillCaptured: SpaceInfo?
    private var animSpacePillCapturedGrid: [GridRow] = []
    private var animSpacePillIsDots: Bool = false

    var animTextProgress: CGFloat = 1.0
    var animTextDisplay: Int = -1
    var animTextOldActive: Int = -1
    var animTextNewActive: Int = -1
    private var animTextTimer: Timer?

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
        self.musicMonitor = MusicMonitor()
        self.renderer = IndicatorRenderer(settings: settings, statusItem: statusItem)
        self.musicPopover = MusicPopover(monitor: musicMonitor)
    }

    func start() {
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
                self.musicSuppressUntil = ProcessInfo.processInfo.systemUptime + 3.0
            }
            guard self.systemState.isStable else { return }
            self.refresh()
        }
        spaceWatcher.start()

        musicMonitor.onChange = { [weak self] in
            guard let self else { return }
            self.refresh()
        }
        musicMonitor.start()

        systemState.didStabilize = { [weak self] in self?.resyncSnapshotAfterStabilize() }
        systemState.didEnterUnstable = { [weak self] in self?.killAllAnimations() }
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
            // Advance marquee
            self.marqueeOffset += 0.4
            // Redraw button
            if let button = self.statusItem.button {
                let frame = self.renderer.makeMusicFrame(
                    title: self.musicMonitor.currentTitle,
                    artist: self.musicMonitor.currentArtist,
                    barHeights: self.visualizerHeights,
                    marqueeOffset: self.marqueeOffset
                )
                button.image = frame
                self.musicFrameWidth = frame.size.width
            }
        }
        if let t = visualizerTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func stopVisualizer() {
        visualizerTimer?.invalidate(); visualizerTimer = nil
    }

    // MARK: - Stability

    private func killAllAnimations() {
        animSpacePillTimer?.invalidate(); animSpacePillTimer = nil
        animSpacePillProgress = 1.0; animSpacePillDisplay = -1
        animSpacePillOldActive = 0; animSpacePillNewActive = 0
        animSpacePillCaptured = nil

        animTextTimer?.invalidate(); animTextTimer = nil
        animTextProgress = 1.0; animTextDisplay = -1
        animTextOldActive = -1; animTextNewActive = -1

        animLayoutTimer?.invalidate(); animLayoutTimer = nil
        animLayoutProgress = 1.0

        animRowMorphTimer?.invalidate(); animRowMorphTimer = nil
        animRowMorphPending?.cancel(); animRowMorphPending = nil
        animRowMorphProgress = 1.0

        animFocusTimer?.invalidate(); animFocusTimer = nil
        animFocusProgress = 1.0; animFocusOldDisplay = -1; animFocusNewDisplay = -1

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
        stopVisualizer()
        refresh()
    }

    func setFocusedUUID(_ uuid: String?) { spaceWatcher.currentFocusedUUID = uuid }

    // MARK: - Computed

    var stackIndicators: Bool {
        if settings.displayStyle == .dots { return false }
        switch settings.stackMode {
        case .inline: return false
        case .stack:  return true
        case .dynamic:
            let screens = NSScreen.screens
            guard screens.count >= 2 else { return false }
            let f1 = screens[0].frame, f2 = screens[1].frame
            let xOv = max(0, min(f1.maxX, f2.maxX) - max(f1.minX, f2.minX))
            let yOv = max(0, min(f1.maxY, f2.maxY) - max(f1.minY, f2.minY))
            return xOv > yOv
        }
    }

    var shouldUseGridLayout: Bool {
        return (settings.displayStyle == .pill || settings.displayStyle == .dots)
            && settings.stackMode == .dynamic
            && settings.displayOrderMode == .physicalDetection
            && NSScreen.screens.count >= 3
    }

    private func effectiveRowCount(for displays: [SpaceInfo.DisplayInfo]) -> Int {
        return stackIndicators ? displays.count : 1
    }

    // MARK: - Refresh

    func refresh() {
        let info = spaceWatcher.currentInfo
        guard let button = statusItem.button else { return }

        let showMusic = settings.musicDisplayMode == .dynamic && musicMonitor.isPlaying
            && ProcessInfo.processInfo.systemUptime >= musicSuppressUntil

        // Swap between music and space indicator
        if showMusic != musicDisplayShown {
            musicDisplayShown = showMusic
            if !showMusic { stopVisualizer() }
        }

        // Music mode
        if musicDisplayShown {
            startVisualizer()
            button.attributedTitle = NSAttributedString()
            let frame = renderer.makeMusicFrame(
                title: musicMonitor.currentTitle,
                artist: musicMonitor.currentArtist,
                barHeights: visualizerHeights,
                marqueeOffset: marqueeOffset
            )
            button.image = frame
            musicFrameWidth = frame.size.width
            statusItem.length = NSStatusItem.variableLength
            return
        }

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
            animLayoutMorphOldW = renderer.targetWidth(for: info.displays, style: settings.displayStyle, stackIndicators: stackIndicators)
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
        if stable && !shouldUseGridLayout && (settings.displayStyle == .pill || settings.displayStyle == .dots)
            && animLayoutProgress >= 1.0 {
            let cur = effectiveRowCount(for: info.displays)
            if animRowMorphProgress >= 1.0 && cur != previousEffectiveRowCount {
                startRowMorph(fromCount: previousEffectiveRowCount, fromStacked: previousEffectiveRowCount > 1)
                previousEffectiveRowCount = cur
            }
        }

        // Clear old state
        let isImageStyle = settings.displayStyle == .pill || settings.displayStyle == .dots
        if isImageStyle {
            if button.image == nil || !button.title.isEmpty {
                button.title = ""
                button.attributedTitle = NSAttributedString()
            }
        } else if button.image != nil {
            button.image = nil
        }

        applyStatusItemLength(info: info)

        // Render + animation triggers
        switch settings.displayStyle {
        case .pill:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable { tryStartFocusChange(info: info) }
            if stable { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.image = renderer.makePillFrame(indicator: self, info: info, isDots: false)

        case .numbers:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: false)

        case .boldNumber:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: true)

        case .dots:
            if stable { tryStartSpaceChange(info: info, isDots: true) }
            if stable { tryStartFocusChange(info: info) }
            if stable { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.image = renderer.makePillFrame(indicator: self, info: info, isDots: true)
        }

    }

    // MARK: - Animation triggers

    private func tryStartSpaceChange(info: SpaceInfo, isDots: Bool) {
        guard previousSpaces.count == info.displays.count else { return }
        for i in 0..<info.displays.count {
            let prev = previousSpaces[i]
            let cur = info.displays[i].current
            if prev != cur && prev >= 1 && prev <= info.displays[i].total {
                previousSpaces = info.displays.map { $0.current }
                switch settings.displayStyle {
                case .pill:
                    startPillAnimation(info: info, displayIndex: i, from: prev, to: cur, isDots: false)
                case .dots:
                    startTextAnimation(displayIndex: i, oldActive: prev, newActive: cur)
                case .numbers, .boldNumber:
                    startTextAnimation(displayIndex: i, oldActive: prev, newActive: cur)
                }
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
        let isImageStyle = settings.displayStyle == .pill || settings.displayStyle == .dots
        var naturalW: CGFloat
        if animLayoutProgress < 1.0 {
            naturalW = animLayoutMorphOldW + (animLayoutMorphNewW - animLayoutMorphOldW) * Easing.outQuart(animLayoutProgress)
        } else if shouldUseGridLayout {
            let dims = gridDimensions(for: currentGridLayout, isDots: settings.displayStyle == .dots)
            naturalW = renderer.gnomePillFixedWidth(
                for: info.displays, isDots: settings.displayStyle == .dots,
                stackIndicators: stackIndicators,
                gridRows: currentGridLayout,
                gridDotD: dims.dotD, gridPillW: dims.pillW, gridSp: dims.sp
            )
        } else {
            naturalW = renderer.targetWidth(for: info.displays, style: settings.displayStyle, stackIndicators: stackIndicators)
        }

        let finalLen = isImageStyle ? max(24, naturalW) : naturalW

        if isImageStyle {
            let pad: CGFloat = 4
            let lenToSet = finalLen + pad * 2
            if abs(lenToSet - lastSetLength) > 0.1 {
                lastSetLength = lenToSet
                DispatchQueue.main.async { [weak self] in self?.statusItem.length = lenToSet }
            }
        } else if animLayoutProgress < 1.0 {
            if abs(finalLen - lastSetLength) > 0.5 {
                lastSetLength = finalLen
                DispatchQueue.main.async { [weak self] in self?.statusItem.length = finalLen }
            }
        } else if lastSetLength != -1 {
            lastSetLength = -1
            DispatchQueue.main.async { [weak self] in self?.statusItem.length = NSStatusItem.variableLength }
        }
    }

    // MARK: - Animations

    private func startPillAnimation(info: SpaceInfo, displayIndex: Int, from oldSpace: Int, to newSpace: Int, isDots: Bool) {
        guard settings.animationStyle != .none else { refresh(); return }
        animSpacePillTimer?.invalidate()
        animSpacePillProgress = 0
        animSpacePillDisplay = displayIndex
        animSpacePillOldActive = oldSpace
        animSpacePillNewActive = newSpace
        animSpacePillCaptured = info
        animSpacePillCapturedGrid = currentGridLayout
        animSpacePillIsDots = isDots

        let style = settings.animationStyle
        let distance = abs(newSpace - oldSpace)
        let duration: TimeInterval = style == .solid ? 0.18 : (style == .jelly ? (0.6 + Double(distance) * 0.2) : 0.5)
        let useSpring = style == .jelly

        animSpacePillTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animSpacePillProgress += CGFloat((1.0 / 60.0) / duration)
            if self.animSpacePillProgress >= 1.0 {
                t.invalidate(); self.animSpacePillTimer = nil; self.animSpacePillDisplay = -1
                self.refresh(); return
            }
            let p = useSpring ? Easing.spring(self.animSpacePillProgress) : Easing.outQuart(self.animSpacePillProgress)
            if let cap = self.animSpacePillCaptured {
                self.statusItem.button?.image = self.renderer.makePillFrame(
                    indicator: self, info: cap, isDots: isDots,
                    animatingDisplay: displayIndex,
                    spacePillOldActive: oldSpace, spacePillNewActive: newSpace,
                    spacePillProgress: p, overrideGridRows: self.animSpacePillCapturedGrid
                )
            }
        }
    }

    private func startTextAnimation(displayIndex: Int, oldActive: Int, newActive: Int) {
        animTextTimer?.invalidate()
        guard settings.animationStyle != .none else {
            animTextOldActive = -1; animTextNewActive = -1; animTextProgress = 1.0; animTextDisplay = -1
            refresh(); return
        }
        animTextDisplay = displayIndex
        animTextOldActive = oldActive
        animTextNewActive = newActive
        animTextProgress = 0
        let distance = abs(newActive - oldActive)
        let base = settings.animationStyle == .solid
            ? (settings.displayStyle == .dots ? 0.075 : 0.18)
            : (settings.displayStyle == .dots ? 0.4 : 0.16)
        let duration = (settings.displayStyle == .dots && settings.animationStyle == .solid)
            ? (0.075 + Double(distance) * 0.025) : (base + Double(distance) * base)
        animTextTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animTextProgress += CGFloat(0.016 / duration)
            if self.animTextProgress >= 1.0 {
                self.animTextProgress = 1.0; t.invalidate()
                self.animTextOldActive = -1; self.animTextNewActive = -1; self.animTextDisplay = -1
            }
            self.refresh()
        }
    }

    private func startLayoutMorph(from old: [SpaceInfo.DisplayInfo], to new: [SpaceInfo.DisplayInfo]) {
        animLayoutTimer?.invalidate()
        if animLayoutProgress < 1.0 {
            animLayoutMorphOldW = animLayoutMorphOldW + (animLayoutMorphNewW - animLayoutMorphOldW) * Easing.outQuart(animLayoutProgress)
        } else {
            animLayoutMorphOldW = renderer.targetWidth(for: old, style: settings.displayStyle, stackIndicators: stackIndicators)
        }
        animLayoutMorphNewW = renderer.targetWidth(for: new, style: settings.displayStyle, stackIndicators: stackIndicators)
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
            if let t = self.animRowMorphTimer { RunLoop.current.add(t, forMode: .common) }
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
        if let t = animFocusTimer { RunLoop.current.add(t, forMode: .common) }
    }

    // MARK: - Grid

    func computeGridLayout(for displays: [SpaceInfo.DisplayInfo]) -> [GridRow] {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { return [GridRow(displayIndices: Array(0..<displays.count))] }
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

    func gridDimensions(for rows: [GridRow], isDots: Bool) -> GridDims {
        let imgH = statusItem.button?.bounds.height ?? 22
        let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat, gap: CGFloat = 1
        if isDots { dotD = 6; pillW = 6; pillH = 6; sp = 6; rowH = 8 }
        else      { dotD = 4; pillW = 18; pillH = 4; sp = 4; rowH = 8 }
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
}

// MARK: - Easing

enum Easing {
    static func outQuart(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 4) }
    static func inOutQuart(_ t: CGFloat) -> CGFloat { t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2 }
    static func inOutCubic(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func outExpo(_ t: CGFloat) -> CGFloat { t == 1 ? 1 : 1 - pow(2, -10 * t) }
    static func spring(_ t: CGFloat) -> CGFloat {
        if t == 0 { return 0 }; if t == 1 { return 1 }
        return pow(2, -2.5 * t) * 0.35 * sin((t - 0.03) * (2 * .pi) / 0.22) + 1
    }
}
