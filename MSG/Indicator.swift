import AppKit

// MARK: - Grid Layout

struct GridRow: Equatable {
    let displayIndices: [Int]
}

struct GridDims {
    let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat, gap: CGFloat
}

// MARK: - Indicator

/// Spaceman-style indicator: read CGS → draw static icon → set on button.
/// No diff-based animation, no previous-state tracking, no MC workarounds.
/// Each refresh simply renders whatever SpaceWatcher reports right now.
final class Indicator {

    let statusItem: NSStatusItem
    let spaceWatcher: SpaceWatcher
    private let settings: Settings
    private let renderer: IndicatorRenderer

    var onStatusBarClicked: (() -> Void)?

    // Layout state (no animation, just current configuration)
    var currentGridLayout: [GridRow] = []
    private var lastSetLength: CGFloat = 0

    // These exist only because IndicatorRenderer reads them. We keep them
    // at their neutral/default values — no animation ever runs.
    var animSpacePillProgress: CGFloat = 1.0
    var animSpacePillDisplay: Int = -1
    var animSpacePillOldActive: Int = 0
    var animSpacePillNewActive: Int = 0
    var animTextProgress: CGFloat = 1.0
    var animTextDisplay: Int = -1
    var animTextOldActive: Int = -1
    var animTextNewActive: Int = -1
    var animLayoutProgress: CGFloat = 1.0
    var animLayoutMorphOldW: CGFloat = 0
    var animLayoutMorphNewW: CGFloat = 0
    var animRowMorphProgress: CGFloat = 1.0
    var animRowMorphFromStacked: Bool = false
    var animRowMorphFromCount: Int = 1
    var animFocusProgress: CGFloat = 1.0
    var animFocusOldDisplay: Int = -1
    var animFocusNewDisplay: Int = -1
    var previousLayoutDisplays: [SpaceInfo.DisplayInfo] = []

    // MARK: Init

    init(settings: Settings) {
        self.settings = settings
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

        refresh()
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        onStatusBarClicked?()
    }

    // MARK: - Public hooks

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

    // MARK: - Refresh

    func refresh() {
        let info = spaceWatcher.currentInfo
        guard let button = statusItem.button else { return }

        // Keep previousLayoutDisplays in sync so renderer width calcs work
        if previousLayoutDisplays.isEmpty || previousLayoutDisplays.count != info.displays.count {
            previousLayoutDisplays = info.displays
        }

        // Grid layout
        if shouldUseGridLayout {
            currentGridLayout = computeGridLayout(for: info.displays)
        } else {
            currentGridLayout = []
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

        // Width
        applyStatusItemLength(info: info)

        // Draw
        switch settings.displayStyle {
        case .pill:
            button.image = renderer.makePillFrame(indicator: self, info: info, isDots: false)
        case .numbers:
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: false)
        case .boldNumber:
            button.attributedTitle = renderer.makeNumbersAttributedString(indicator: self, info: info, bold: true)
        case .dots:
            button.image = renderer.makePillFrame(indicator: self, info: info, isDots: true)
        }
    }

    // MARK: - Width

    private func applyStatusItemLength(info: SpaceInfo) {
        let isImageStyle = settings.displayStyle == .pill || settings.displayStyle == .dots
        let naturalW: CGFloat
        if shouldUseGridLayout {
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

        if isImageStyle {
            let pad: CGFloat = 4
            let lenToSet = max(24, naturalW) + pad * 2
            if abs(lenToSet - lastSetLength) > 0.1 {
                lastSetLength = lenToSet
                DispatchQueue.main.async { [weak self] in self?.statusItem.length = lenToSet }
            }
        } else if lastSetLength != -1 {
            lastSetLength = -1
            DispatchQueue.main.async { [weak self] in self?.statusItem.length = NSStatusItem.variableLength }
        }
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
