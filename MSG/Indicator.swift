import AppKit

// MARK: - Grid Layout

struct GridRow: Equatable {
    let displayIndices: [Int]
}

struct GridDims {
    let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat, gap: CGFloat
}

// MARK: - Indicator

/// Owns the menu‑bar status item, runs the render loop, and coordinates
/// animations. The key correctness invariant: snapshot state (previousSpaces,
/// previousActiveDisplayIndex, fullPreviousDisplays) is only updated when
/// SystemState.isStable. On stabilize, snapshot is atomically resynced to
/// current observations without triggering animations.
final class Indicator {

    // MARK: Public

    let statusItem: NSStatusItem
    let spaceWatcher: SpaceWatcher
    private let settings: Settings
    private let systemState: SystemState
    private let renderer: IndicatorRenderer

    var onStatusBarClicked: (() -> Void)?

    // MARK: Animation state (read by renderer via input snapshot)

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

    // Space-change debounce: prevents transient MC reads from triggering
    // false animations. When a space diff is first seen, we wait 400ms and
    // verify the new value is still current before animating.
    private var spaceDebounceTimer: Timer?
    private var spaceDebounceDisplay: Int = -1
    private var spaceDebounceOldValue: Int = 0
    private var spaceDebounceNewValue: Int = 0
    private var spaceDebounceIsDots: Bool = false
    private var isSpaceDebouncing: Bool { spaceDebounceTimer != nil }
    private var fullPreviousDisplays: [SpaceInfo.DisplayInfo] = []
    var previousLayoutDisplays: [SpaceInfo.DisplayInfo] = []
    private var previousEffectiveRowCount: Int = 1
    var currentGridLayout: [GridRow] = []
    private var lastSetLength: CGFloat = 0

    // MARK: Init

    init(settings: Settings, systemState: SystemState) {
        self.settings = settings
        self.systemState = systemState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.spaceWatcher = SpaceWatcher()
        self.renderer = IndicatorRenderer(settings: settings, statusItem: statusItem)
    }

    func start() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(buttonClicked(_:))
        statusItem.button?.imagePosition = .imageOnly

        spaceWatcher.customOrder = settings.displayOrderMode == .prioritizeMain ? [] : settings.displayOrder
        spaceWatcher.prioritizeMain = settings.displayOrderMode == .prioritizeMain
        spaceWatcher.focusDetection = settings.focusDetectionMode != .off
        spaceWatcher.onChange = { [weak self] in self?.refresh() }
        spaceWatcher.start()

        systemState.didStabilize = { [weak self] in self?.resyncSnapshotAfterStabilize() }
        systemState.didEnterUnstable = { [weak self] in self?.killAllAnimations() }

        refresh()
    }

    /// Kill every in-flight animation timer so transient reads don't feed into
    /// render callbacks while the system is unstable.
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

        spaceDebounceTimer?.invalidate(); spaceDebounceTimer = nil
        spaceDebounceDisplay = -1
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        onStatusBarClicked?()
    }

    // MARK: - Stability resync

    /// Called when SystemState transitions back to stable. Atomically resync
    /// snapshot state to current observations so the next refreshDisplay
    /// doesn't see a fake diff (which would trigger a spurious animation).
    private func resyncSnapshotAfterStabilize() {
        let info = spaceWatcher.currentInfo
        previousSpaces = info.displays.map { $0.current }
        previousActiveDisplayIndex = info.activeDisplayIndex
        fullPreviousDisplays = info.displays
        previousLayoutDisplays = info.displays
        previousEffectiveRowCount = effectiveRowCount(for: info.displays)
        refresh()
    }

    // MARK: - Public hooks for AppDelegate

    func applySettings() {
        spaceWatcher.customOrder = settings.displayOrderMode == .prioritizeMain ? [] : settings.displayOrder
        spaceWatcher.prioritizeMain = settings.displayOrderMode == .prioritizeMain
        spaceWatcher.focusDetection = settings.focusDetectionMode != .off
        refresh()
    }

    func setFocusedUUID(_ uuid: String?) {
        spaceWatcher.currentFocusedUUID = uuid
    }

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

    // MARK: - Refresh loop

    func refresh() {
        let info = spaceWatcher.currentInfo
        guard let button = statusItem.button else { return }

        // The single gate: stable means we can mutate snapshot state and
        // trigger animations safely. When unstable, we still render the
        // current frame but freeze all snapshot updates.
        let stable = systemState.isStable && !systemState.isFullscreen

        // Layout morph (display count change)
        let countChanged = fullPreviousDisplays.count != info.displays.count
        let totalsChanged = fullPreviousDisplays.map { $0.total } != info.displays.map { $0.total }

        if !fullPreviousDisplays.isEmpty && countChanged && stable {
            startLayoutMorph(from: fullPreviousDisplays, to: info.displays)
            fullPreviousDisplays = info.displays
        } else if !fullPreviousDisplays.isEmpty && (totalsChanged || (countChanged && !stable)) {
            // Silently update — no morph animation while unstable
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

        // Grid layout
        if shouldUseGridLayout && animLayoutProgress >= 1.0 {
            currentGridLayout = computeGridLayout(for: info.displays)
        } else if !shouldUseGridLayout {
            currentGridLayout = []
        }

        // Row morph (inline ↔ stacked)
        if stable && !shouldUseGridLayout && (settings.displayStyle == .pill || settings.displayStyle == .dots)
            && animLayoutProgress >= 1.0 {
            let cur = effectiveRowCount(for: info.displays)
            if animRowMorphProgress >= 1.0 && cur != previousEffectiveRowCount {
                startRowMorph(fromCount: previousEffectiveRowCount, fromStacked: previousEffectiveRowCount > 1)
                previousEffectiveRowCount = cur
            }
        }

        // Clear old button state when switching style families
        let isImageStyle = settings.displayStyle == .pill || settings.displayStyle == .dots
        if isImageStyle {
            if button.image == nil || !button.title.isEmpty {
                button.title = ""
                button.attributedTitle = NSAttributedString()
            }
        } else if button.image != nil {
            button.image = nil
        }

        // Width management
        applyStatusItemLength(info: info)

        // Style-specific rendering + animation triggers
        switch settings.displayStyle {
        case .pill:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable { tryStartFocusChange(info: info) }
            if stable && !isSpaceDebouncing { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.image = renderer.makePillFrame(
                indicator: self, info: info, isDots: false
            )

        case .numbers:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable && !isSpaceDebouncing { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: false)

        case .boldNumber:
            if stable { tryStartSpaceChange(info: info, isDots: false) }
            if stable && !isSpaceDebouncing { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: true)

        case .dots:
            if stable { tryStartSpaceChange(info: info, isDots: true) }
            if stable { tryStartFocusChange(info: info) }
            if stable && !isSpaceDebouncing { previousSpaces = info.displays.map { $0.current } }
            if stable { previousActiveDisplayIndex = info.activeDisplayIndex }
            button.image = renderer.makePillFrame(
                indicator: self, info: info, isDots: true
            )
        }
    }

    // MARK: - Animation triggers

    private func tryStartSpaceChange(info: SpaceInfo, isDots: Bool) {
        guard previousSpaces.count == info.displays.count else { return }

        // If a debounce timer is already running, check whether the diff
        // it was tracking is still valid — if the target space changed again,
        // cancel and re-arm on the latest diff.
        if let timer = spaceDebounceTimer {
            guard spaceDebounceDisplay < info.displays.count else {
                timer.invalidate(); spaceDebounceTimer = nil; spaceDebounceDisplay = -1
                return
            }
            let currentVal = info.displays[spaceDebounceDisplay].current
            if currentVal == spaceDebounceNewValue {
                return // same diff — let the timer run
            }
            // The space changed again before the verification window expired.
            // Cancel the old timer and treat this as a new diff below.
            timer.invalidate(); spaceDebounceTimer = nil; spaceDebounceDisplay = -1
        }

        for i in 0..<info.displays.count {
            let prev = previousSpaces[i]
            let cur = info.displays[i].current
            if prev != cur && prev >= 1 && prev <= info.displays[i].total {
                let displayIdx = i
                spaceDebounceOldValue = prev
                spaceDebounceNewValue = cur
                spaceDebounceDisplay = displayIdx
                spaceDebounceIsDots = isDots

                spaceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.spaceDebounceTimer = nil
                    let settledInfo = self.spaceWatcher.currentInfo
                    guard displayIdx < settledInfo.displays.count else {
                        self.spaceDebounceDisplay = -1
                        return
                    }
                    let settled = settledInfo.displays[displayIdx].current
                    let old = self.spaceDebounceOldValue
                    self.spaceDebounceDisplay = -1

                    // The space is still at the new value — this is a real change.
                    if settled == self.spaceDebounceNewValue && settled != old {
                        self.previousSpaces = settledInfo.displays.map { $0.current }
                        switch self.settings.displayStyle {
                        case .pill:
                            self.startPillAnimation(info: settledInfo, displayIndex: displayIdx, from: old, to: settled, isDots: false)
                        case .dots:
                            if self.settings.animationStyle == .solid {
                                self.startTextAnimation(displayIndex: displayIdx, oldActive: old, newActive: settled)
                            } else {
                                self.startPillAnimation(info: settledInfo, displayIndex: displayIdx, from: old, to: settled, isDots: true)
                            }
                        case .numbers, .boldNumber:
                            self.startTextAnimation(displayIndex: displayIdx, oldActive: old, newActive: settled)
                        }
                    } else {
                        // Transient — value changed again during the window.
                        // Silently sync to current without animation.
                        self.previousSpaces = settledInfo.displays.map { $0.current }
                    }
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

    // MARK: - Width management

    private func applyStatusItemLength(info: SpaceInfo) {
        let isImageStyle = settings.displayStyle == .pill || settings.displayStyle == .dots
        var naturalW: CGFloat
        if animLayoutProgress < 1.0 {
            let t = Easing.outQuart(animLayoutProgress)
            naturalW = animLayoutMorphOldW + (animLayoutMorphNewW - animLayoutMorphOldW) * t
        } else if shouldUseGridLayout {
            let dims = gridDimensions(for: currentGridLayout, isDots: settings.displayStyle == .dots)
            naturalW = renderer.gnomePillFixedWidth(
                for: info.displays,
                isDots: settings.displayStyle == .dots,
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
        } else {
            if animLayoutProgress < 1.0 {
                if abs(finalLen - lastSetLength) > 0.5 {
                    lastSetLength = finalLen
                    DispatchQueue.main.async { [weak self] in self?.statusItem.length = finalLen }
                }
            } else if lastSetLength != -1 {
                lastSetLength = -1
                DispatchQueue.main.async { [weak self] in self?.statusItem.length = NSStatusItem.variableLength }
            }
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
        let interval: TimeInterval = 1.0 / 60.0
        let useSpring = style == .jelly

        animSpacePillTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animSpacePillProgress += CGFloat(interval / duration)
            if self.animSpacePillProgress >= 1.0 {
                t.invalidate()
                self.animSpacePillTimer = nil
                self.animSpacePillDisplay = -1
                self.refresh()
                return
            }
            let p: CGFloat = useSpring ? Easing.spring(self.animSpacePillProgress) : Easing.outQuart(self.animSpacePillProgress)
            // Direct render to button image during the slide
            if let captured = self.animSpacePillCaptured {
                self.statusItem.button?.image = self.renderer.makePillFrame(
                    indicator: self,
                    info: captured,
                    isDots: isDots,
                    animatingDisplay: displayIndex,
                    spacePillOldActive: oldSpace,
                    spacePillNewActive: newSpace,
                    spacePillProgress: p,
                    overrideGridRows: self.animSpacePillCapturedGrid
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
        let base: TimeInterval = settings.animationStyle == .solid
            ? (settings.displayStyle == .dots ? 0.075 : 0.18)
            : (settings.displayStyle == .dots ? 0.4 : 0.16)
        let duration: TimeInterval = (settings.displayStyle == .dots && settings.animationStyle == .solid)
            ? (0.075 + Double(distance) * 0.025)
            : (base + Double(distance) * base)
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

        let duration: TimeInterval = 0.4
        let interval: TimeInterval = 1.0 / 60.0
        animLayoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.animLayoutProgress += CGFloat(interval / duration)
            if self.animLayoutProgress >= 1.0 {
                self.animLayoutProgress = 1.0
                t.invalidate(); self.animLayoutTimer = nil
            }
            self.refresh()
        }
    }

    private func startRowMorph(fromCount: Int, fromStacked: Bool) {
        let capturedFromCount = fromCount
        let capturedFromStacked = fromStacked
        animRowMorphPending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animRowMorphTimer?.invalidate()
            self.animRowMorphFromCount = capturedFromCount
            self.animRowMorphFromStacked = capturedFromStacked
            self.animRowMorphProgress = 0.0
            self.animRowMorphTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
                guard let self else { return }
                self.animRowMorphProgress += 0.05
                if self.animRowMorphProgress >= 1.0 { self.animRowMorphProgress = 1.0; t.invalidate() }
                self.refresh()
                self.statusItem.button?.display()
            }
            if let t = self.animRowMorphTimer { RunLoop.current.add(t, forMode: .common) }
        }
        animRowMorphPending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func startFocusAnimation(from: Int, to: Int) {
        animFocusTimer?.invalidate()
        animFocusOldDisplay = from
        animFocusNewDisplay = to
        animFocusProgress = 0.0
        animFocusTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self else { return }
            self.animFocusProgress += 0.06
            if self.animFocusProgress >= 1.0 {
                self.animFocusProgress = 1.0; t.invalidate()
                self.animFocusOldDisplay = -1; self.animFocusNewDisplay = -1
            }
            self.refresh()
        }
        if let t = animFocusTimer { RunLoop.current.add(t, forMode: .common) }
    }

    // MARK: - Grid Layout

    func computeGridLayout(for displays: [SpaceInfo.DisplayInfo]) -> [GridRow] {
        let screens = NSScreen.screens
        guard screens.count >= 2 else { return [GridRow(displayIndices: Array(0..<displays.count))] }

        var uuidToDisplayIndex: [String: Int] = [:]
        for (i, d) in displays.enumerated() { uuidToDisplayIndex[d.uuid] = i }

        let builtIn = screens[0]
        var mainIdx = -1
        var above: [(Int, CGFloat)] = []
        var below: [(Int, CGFloat)] = []
        var left:  [(Int, CGFloat)] = []
        var right: [(Int, CGFloat)] = []

        for (screenIdx, screen) in screens.enumerated() {
            guard let uuid = Self.screenUUID(screen),
                  let displayIdx = uuidToDisplayIndex[uuid] else { continue }
            if screenIdx == 0 { mainIdx = displayIdx; continue }
            let f = screen.frame, b = builtIn.frame
            if f.minY >= b.maxY { above.append((displayIdx, f.minX)) }
            else if f.maxY <= b.minY { below.append((displayIdx, f.minX)) }
            else if f.maxX <= b.minX { left.append((displayIdx, f.minX)) }
            else { right.append((displayIdx, f.minX)) }
        }

        above.sort { $0.1 < $1.1 }
        below.sort { $0.1 < $1.1 }
        left.sort  { $0.1 < $1.1 }
        right.sort { $0.1 < $1.1 }

        var rows: [GridRow] = []
        if !above.isEmpty { rows.append(GridRow(displayIndices: above.map { $0.0 })) }
        var mainRow: [Int] = left.map { $0.0 }
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
        let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat
        let gap: CGFloat = 1
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
              let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(dID),
              let uuidString = CFUUIDCreateString(nil, uuidUnmanaged.takeRetainedValue()) as String? else {
            return nil
        }
        return uuidString
    }
}

// MARK: - Easing

enum Easing {
    static func outQuart(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 4) }
    static func inOutQuart(_ t: CGFloat) -> CGFloat {
        return t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2
    }
    static func outExpo(_ t: CGFloat) -> CGFloat { t == 1 ? 1 : 1 - pow(2, -10 * t) }
    static func spring(_ t: CGFloat) -> CGFloat {
        if t == 0 { return 0 }
        if t == 1 { return 1 }
        return pow(2, -2.5 * t) * 0.35 * sin((t - 0.03) * (2 * .pi) / 0.22) + 1
    }
}
