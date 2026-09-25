import AppKit

// MARK: - Shared Space-pill pipeline

/// The animation and drawing core used by both the native status item and the
/// tiling control bar. Keeping the timing, easing, geometry interpolation and
/// final AppKit drawing here prevents the two indicators from drifting apart.
struct SpacePillMetrics {
    let dotD: CGFloat
    let pillW: CGFloat
    let pillH: CGFloat
    let clampedIdx: CGFloat
    let countFloat: CGFloat
    let rowStretch: CGFloat
    let stretch: CGFloat

    private var pL: CGFloat { floor(clampedIdx) }
    private var pH: CGFloat { ceil(clampedIdx) }
    private var frac: CGFloat { clampedIdx - floor(clampedIdx) }

    private func dotAlpha(_ i: Int) -> CGFloat {
        CGFloat(i) > floor(countFloat) ? (countFloat - floor(countFloat)) : 1.0
    }

    func width(_ i: Int) -> CGFloat {
        let iF = CGFloat(i)
        if pL == pH { return iF == pL ? (pillW + rowStretch + stretch) : dotD * dotAlpha(i) }
        if iF == pL { return dotD + (pillW + rowStretch - dotD + stretch) * (1.0 - frac) }
        if iF == pH { return dotD + (pillW + rowStretch - dotD + stretch) * frac }
        return dotD * dotAlpha(i)
    }

    func height(_ i: Int) -> CGFloat {
        let iF = CGFloat(i)
        if pL == pH { return iF == pL ? pillH : dotD }
        if iF == pL { return dotD + (pillH - dotD) * (1.0 - frac) }
        if iF == pH { return dotD + (pillH - dotD) * frac }
        return dotD
    }

    func fill(_ i: Int, bright: NSColor, dim: NSColor, rowAlpha: CGFloat) -> NSColor {
        let iF = CGFloat(i)
        let alpha: CGFloat
        if pL == pH { alpha = iF == pL ? 1.0 : 0.0 }
        else if iF == pL { alpha = 1.0 - frac }
        else if iF == pH { alpha = frac }
        else { alpha = 0 }
        let color = dim.blended(withFraction: alpha, of: bright) ?? dim
        return color.withAlphaComponent(color.alphaComponent * rowAlpha * dotAlpha(i))
    }
}

enum SpacePillAnimationPipeline {
    static var frameInterval: TimeInterval { DisplayRate.interval }

    static func duration(style: AnimationStyle, from oldSpace: Int, to newSpace: Int) -> TimeInterval {
        let distance = max(1, abs(newSpace - oldSpace))
        let base: TimeInterval = style == .liquid ? 0.75 : 0.30
        return base * (1.0 + Double(distance - 1) * 0.5)
    }

    static func easedProgress(_ raw: CGFloat, style: AnimationStyle) -> CGFloat {
        style == .liquid ? Easing.spring(raw) : Easing.inOutQuart(raw)
    }

    static func stretch(progress: CGFloat, style: AnimationStyle) -> CGFloat {
        style == .liquid ? sin(progress * .pi) * 4.0 : 0.0
    }

    static func rowWidth(metrics: SpacePillMetrics, count: Int, spacing: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        for i in 1...max(1, count) {
            width += metrics.width(i)
            if i > 1 { width += spacing }
        }
        return width
    }

    /// Draws the interpolated pill/dot row and returns the trailing x position.
    /// Coordinates are supplied by the host, so this works in both flipped and
    /// non-flipped AppKit views.
    @discardableResult
    static func drawRow(
        metrics: SpacePillMetrics,
        count: Int,
        spacing: CGFloat,
        originX: CGFloat,
        originY: CGFloat,
        rowHeight: CGFloat,
        bright: NSColor,
        dim: NSColor,
        rowAlpha: CGFloat,
        direction: CGFloat
    ) -> CGFloat {
        let safeCount = max(1, count)
        var x = originX + metrics.stretch * direction * 0.35
        for i in 1...safeCount {
            let width = metrics.width(i)
            let height = metrics.height(i)
            let rect = NSRect(x: x, y: originY + (rowHeight - height) / 2,
                              width: width, height: height)
            metrics.fill(i, bright: bright, dim: dim, rowAlpha: rowAlpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            x += width
            if i < safeCount { x += spacing }
        }
        return x
    }
}

/// Pure drawing functions for the menu‑bar indicator. Reads animation
/// state from the `Indicator` reference it's handed each call.
final class IndicatorRenderer {

    private let settings: AppSettings
    private weak var statusItem: NSStatusItem?

    init(settings: AppSettings, statusItem: NSStatusItem) {
        self.settings = settings
        self.statusItem = statusItem
    }

    private var statusButtonHeight: CGFloat {
        statusItem?.button?.bounds.height ?? 22
    }

    // MARK: - Pill palette & geometry (shared by the inline + grid draw paths)

    /// Menu-bar pill colors for the four focus/brightness states, plus the
    /// per-display focus-transition blend. Used identically by both draw paths.
    private struct PillPalette {
        let brightFocus: NSColor
        let dimFocus: NSColor
        let brightNonFocus: NSColor
        let dimNonFocus: NSColor

        func resolve(display dIdx: Int, focusOld: Int, focusNew: Int, focusProgress: CGFloat,
                     activeDisplayIndex: Int, focusOff: Bool) -> (bright: NSColor, dim: NSColor, active: Bool) {
            if dIdx == focusOld && focusProgress < 1.0 {
                let ft = Easing.outQuart(focusProgress)
                return (brightFocus.blended(withFraction: ft, of: brightNonFocus) ?? brightFocus,
                        dimFocus.blended(withFraction: ft, of: dimNonFocus) ?? dimFocus, true)
            } else if dIdx == focusNew && focusProgress < 1.0 {
                let ft = Easing.outQuart(focusProgress)
                return (brightNonFocus.blended(withFraction: ft, of: brightFocus) ?? brightNonFocus,
                        dimNonFocus.blended(withFraction: ft, of: dimFocus) ?? dimNonFocus, true)
            } else {
                let active = focusOff || dIdx == activeDisplayIndex
                return (active ? brightFocus : brightNonFocus, active ? dimFocus : dimNonFocus, active)
            }
        }
    }

    private func makePalette() -> PillPalette {
        let base = menuBarTextColor
        return PillPalette(
            brightFocus:    base.withAlphaComponent(settings.brightFocusAlpha),
            dimFocus:       base.withAlphaComponent(settings.dimFocusAlpha),
            brightNonFocus: base.withAlphaComponent(settings.brightNonFocusAlpha),
            dimNonFocus:    base.withAlphaComponent(settings.dimNonFocusAlpha)
        )
    }

    // MARK: - Width helpers

    func targetWidth(for displays: [SpaceInfo.DisplayInfo], stackIndicators: Bool, gridRows: [GridRow] = []) -> CGFloat {
        guard !displays.isEmpty else { return 26 }
        return gnomePillFixedWidth(for: displays, stackIndicators: stackIndicators, gridRows: gridRows)
    }

    func gnomePillFixedWidth(
        for displays: [SpaceInfo.DisplayInfo],
        stackIndicators: Bool,
        gridRows: [GridRow] = [],
        gridDotD: CGFloat = 5.25, gridPillW: CGFloat = 26, gridSp: CGFloat = 6
    ) -> CGFloat {
        guard !displays.isEmpty else { return 26 }

        if !gridRows.isEmpty {
            var maxW: CGFloat = 0
            for row in gridRows {
                var rowW: CGFloat = 0
                for (idx, dIdx) in row.displayIndices.enumerated() {
                    guard dIdx < displays.count else { continue }
                    if idx > 0 { rowW += 16 }
                    let c = max(1, displays[dIdx].total)
                    rowW += gridPillW + CGFloat(c - 1) * (gridDotD + gridSp)
                }
                maxW = max(maxW, rowW)
            }
            return max(26, maxW)
        }

        let useCompact = stackIndicators && displays.count > 1
        let dotD: CGFloat = useCompact ? 3.5 : 5.25
        let pillW: CGFloat = useCompact ? 18 : 26
        let sp: CGFloat = useCompact ? 3.5 : 5.25
        if stackIndicators || displays.count <= 1 {
            var maxW: CGFloat = 0
            for d in displays {
                let c = max(1, d.total)
                maxW = max(maxW, pillW + CGFloat(c - 1) * (dotD + sp))
            }
            return maxW
        } else {
            var totalW: CGFloat = 0
            for (idx, d) in displays.enumerated() {
                if idx > 0 { totalW += 16 }
                let c = max(1, d.total)
                totalW += pillW + CGFloat(c - 1) * (dotD + sp)
            }
            return totalW
        }
    }

    // MARK: - Pill / Dots Frame

    func makePillFrame(
        indicator: Indicator,
        info: SpaceInfo,
        animatingDisplay: Int = -1,
        spacePillOldActive: Int = 0,
        spacePillNewActive: Int = 0,
        spacePillProgress: CGFloat = 1.0,
        overrideGridRows: [GridRow]? = nil,
        activeDisplayOverride: Int? = nil,
        renderFocusOnly: Bool = false,
        animationStyle: AnimationStyle = .liquid
    ) -> NSImage {

        let displays = info.displays
        let activeDisplayIndex = activeDisplayOverride ?? info.activeDisplayIndex
        let imgH = statusButtonHeight
        let palette = makePalette()

        let stackIndicators = indicator.stackIndicators

        let gridRows = overrideGridRows ?? indicator.currentGridLayout
        let isMorphing = indicator.animLayoutProgress < 1.0
        let useGrid = !gridRows.isEmpty && !isMorphing
        let t = Easing.outQuart(indicator.animLayoutProgress)
        let isRowMorphing = indicator.animRowMorphProgress < 1.0
        // Ease the row morph so 1↔2 row transitions glide instead of moving linearly,
        // matching the layout/focus morphs which also use outQuart.
        let rmT = isRowMorphing ? Easing.outQuart(indicator.animRowMorphProgress) : 1.0

        let oldDisplays = indicator.previousLayoutDisplays

        // Animation state pulled from indicator
        let _spacePillActive = animatingDisplay >= 0 ? animatingDisplay : indicator.animSpacePillDisplay
        let _spacePillOld    = animatingDisplay >= 0 ? spacePillOldActive : indicator.animSpacePillOldActive
        let _spacePillNew    = animatingDisplay >= 0 ? spacePillNewActive : indicator.animSpacePillNewActive
        let _spacePillProg   = animatingDisplay >= 0 ? spacePillProgress  : indicator.animSpacePillProgress

        // Liquid stretch: active pill widens during slide, peaking at midpoint
        let pillHasAnim = _spacePillActive >= 0
        let pillStretchBase: CGFloat = pillHasAnim
            ? SpacePillAnimationPipeline.stretch(progress: _spacePillProg, style: animationStyle)
            : 0
        let pillDir: CGFloat = _spacePillNew > _spacePillOld ? 1 : -1

        let textProgress: CGFloat = 1.0
        let textDisplay: Int = -1
        let textOld: Int = -1
        let textNew: Int = -1

        let focusOld = indicator.animFocusOldDisplay
        let focusNew = indicator.animFocusNewDisplay
        let focusProgress = indicator.animFocusProgress

        let rowMorphFromStacked = indicator.animRowMorphFromStacked
        let rowMorphFromCount   = indicator.animRowMorphFromCount

        // Grid dims
        let gd = useGrid ? indicator.gridDimensions(for: gridRows)
                         : GridDims(dotD: 5.25, pillW: 26, pillH: 8, sp: 6, rowH: 20, gap: 1)
        let gridDotD = gd.dotD, gridPillW = gd.pillW, gridPillH = gd.pillH
        let gridSp = gd.sp, gridRowH = gd.rowH, gridGap = gd.gap

        // Target/old sizing
        let useCompact = stackIndicators && displays.count > 1
        let dotD_t: CGFloat = useCompact ? 3.5 : 5.25
        let pillW_t: CGFloat = useCompact ? 18 : 26
        let pillH_t: CGFloat = useCompact ? 4 : 8
        let sp_t: CGFloat = useCompact ? 3.5 : 5.25
        let rowH_t: CGFloat = useCompact ? 8 : 20
        let gap_t: CGFloat = 1

        let oldUseCompact = stackIndicators && oldDisplays.count > 1
        let dotD_o: CGFloat = oldUseCompact ? 3.5 : 5.25
        let pillW_o: CGFloat = oldUseCompact ? 18 : 26
        let pillH_o: CGFloat = oldUseCompact ? 4 : 8
        let sp_o: CGFloat = oldUseCompact ? 3.5 : 5.25
        let rowH_o: CGFloat = oldUseCompact ? 8 : 20
        let gap_o: CGFloat = 1

        var dotD  = dotD_o  + (dotD_t  - dotD_o)  * t
        var pillW = pillW_o + (pillW_t - pillW_o) * t
        var pillH = pillH_o + (pillH_t - pillH_o) * t
        var sp    = sp_o    + (sp_t    - sp_o)    * t
        var rowH  = rowH_o  + (rowH_t  - rowH_o)  * t
        var gap   = gap_o   + (gap_t   - gap_o)   * t

        if isRowMorphing && !isMorphing {
            let fromCompact = rowMorphFromStacked && rowMorphFromCount > 1
            let toCompact = stackIndicators && displays.count > 1
            let f_dotD: CGFloat = fromCompact ? 3.5 : 5.25
            let f_pillW: CGFloat = fromCompact ? 18 : 26
            let f_pillH: CGFloat = fromCompact ? 4 : 8
            let f_sp: CGFloat = fromCompact ? 3.5 : 5.25
            let f_rowH: CGFloat = fromCompact ? 8 : 20
            let f_gap: CGFloat = 1
            let g_dotD: CGFloat = toCompact ? 3.5 : 5.25
            let g_pillW: CGFloat = toCompact ? 18 : 26
            let g_pillH: CGFloat = toCompact ? 4 : 8
            let g_sp: CGFloat = toCompact ? 3.5 : 5.25
            let g_rowH: CGFloat = toCompact ? 8 : 20
            let g_gap: CGFloat = 1
            dotD  = f_dotD  + (g_dotD  - f_dotD)  * rmT
            pillW = f_pillW + (g_pillW - f_pillW) * rmT
            pillH = f_pillH + (g_pillH - f_pillH) * rmT
            sp    = f_sp    + (g_sp    - f_sp)    * rmT
            rowH  = f_rowH  + (g_rowH  - f_rowH)  * rmT
            gap   = f_gap   + (g_gap   - f_gap)   * rmT
        }

        var naturalW: CGFloat
        if useGrid {
            naturalW = gnomePillFixedWidth(for: displays, stackIndicators: stackIndicators, gridRows: gridRows, gridDotD: gridDotD, gridPillW: gridPillW, gridSp: gridSp)
        } else if isMorphing {
            naturalW = indicator.animLayoutMorphOldW + (indicator.animLayoutMorphNewW - indicator.animLayoutMorphOldW) * t
        } else {
            naturalW = targetWidth(for: displays, stackIndicators: stackIndicators)
        }
        if isRowMorphing && !isMorphing {
            let fromDisplays = rowMorphFromCount > displays.count ? oldDisplays : displays
            let fromW = gnomePillFixedWidth(for: fromDisplays, stackIndicators: rowMorphFromStacked)
            let toW = targetWidth(for: displays, stackIndicators: stackIndicators)
            naturalW = fromW + (toW - fromW) * rmT
        }

        let pad: CGFloat = 4
        let fixedW = naturalW + pad * 2

        return NSImage(size: NSSize(width: fixedW, height: imgH), flipped: false) { _ in
            let rmDisplaysToDraw = isRowMorphing && !isMorphing && rowMorphFromCount > displays.count ? oldDisplays : displays
            let displaysToDraw = (isMorphing && oldDisplays.count > displays.count) ? oldDisplays : rmDisplaysToDraw
            let alpha_row2: CGFloat = isRowMorphing && !isMorphing
                ? (rowMorphFromCount < displays.count ? rmT : (1.0 - rmT))
                : ((displays.count > oldDisplays.count) ? t : (1.0 - t))
            let inlineStartX: CGFloat = pad
            var inlineXPos: CGFloat = 0

            if useGrid {
                self.drawGrid(
                    displays: displaysToDraw, activeDisplayIndex: activeDisplayIndex, palette: palette,
                    gridRows: gridRows, naturalW: naturalW, fixedW: fixedW, imgH: imgH, pad: pad,
                    gridDotD: gridDotD, gridPillW: gridPillW, gridPillH: gridPillH,
                    gridSp: gridSp, gridRowH: gridRowH, gridGap: gridGap,
                    spacePillActive: _spacePillActive, spacePillOld: _spacePillOld,
                    spacePillNew: _spacePillNew, spacePillProgress: _spacePillProg,
                    focusOld: focusOld, focusNew: focusNew, focusProgress: focusProgress,
                    textProgress: textProgress, textDisplay: textDisplay,
                    textOld: textOld, textNew: textNew,
                    renderFocusOnly: renderFocusOnly,
                    animationStyle: animationStyle
                )
            } else {
                for (dIdx, display) in displaysToDraw.enumerated() {
                    let isFadingRow = dIdx >= min(oldDisplays.count, displays.count)
                    var rowAlpha = isFadingRow ? alpha_row2 : 1.0

                    // A row-layout change keeps every display visible: the same
                    // display groups are only moving between inline and stacked
                    // positions. Fade only when the display set itself changed.
                    if isRowMorphing && !isMorphing && oldDisplays.count != displays.count {
                        if dIdx >= displays.count { rowAlpha = 1.0 - rmT }
                        else if dIdx >= rowMorphFromCount { rowAlpha = rmT }
                    }
                    if rowAlpha <= 0 { continue }

                    let toStacked = stackIndicators && displaysToDraw.count > 1
                    let fromStacked = isRowMorphing ? (rowMorphFromStacked && rowMorphFromCount > 1) : toStacked
                    let stackProgress: CGFloat
                    if isRowMorphing && fromStacked != toStacked {
                        stackProgress = fromStacked ? (1.0 - rmT) : rmT
                    } else {
                        stackProgress = toStacked ? 1.0 : 0.0
                    }

                    let rowY: CGFloat
                    if !toStacked && !fromStacked {
                        rowY = (imgH - rowH) / 2
                    } else if isRowMorphing && fromStacked != toStacked {
                        let inlineY = (imgH - rowH) / 2
                        let totalH = CGFloat(max(rowMorphFromCount, displays.count)) * rowH + CGFloat(max(0, max(rowMorphFromCount, displays.count) - 1)) * gap
                        let stackedY0 = (imgH - totalH) / 2 + CGFloat(max(rowMorphFromCount, displays.count) - 1 - dIdx) * (rowH + gap)
                        rowY = toStacked ? inlineY + (stackedY0 - inlineY) * rmT : stackedY0 + (inlineY - stackedY0) * rmT
                    } else if isMorphing && displaysToDraw.count > 1 {
                        let isConnecting = displays.count > oldDisplays.count
                        let yMain_2: CGFloat = 11.5; let yMain_1: CGFloat = 1.0
                        let yExt_2: CGFloat = 2.5; let yExt_1: CGFloat = -5.0
                        if dIdx == 0 {
                            let s = isConnecting ? yMain_1 : yMain_2
                            let e = isConnecting ? yMain_2 : yMain_1
                            rowY = s + (e - s) * t
                        } else {
                            let s = isConnecting ? yExt_1 : yExt_2
                            let e = isConnecting ? yExt_2 : yExt_1
                            rowY = s + (e - s) * t
                        }
                    } else {
                        let totalH_static = CGFloat(displays.count) * rowH + CGFloat(max(0, displays.count - 1)) * gap
                        rowY = (imgH - totalH_static) / 2 + CGFloat(displays.count - 1 - dIdx) * (rowH + gap)
                    }

                    let (bright, dim, isActive) = palette.resolve(
                        display: dIdx, focusOld: focusOld, focusNew: focusNew,
                        focusProgress: focusProgress, activeDisplayIndex: activeDisplayIndex,
                        focusOff: self.settings.focusDetectionMode == .off
                    )
                    if renderFocusOnly && !isActive { continue }
                    let isAnim = dIdx == _spacePillActive

                    let oldDisplay = (dIdx < oldDisplays.count) ? oldDisplays[dIdx] : display
                    let countFloat = CGFloat(oldDisplay.total) + (CGFloat(display.total) - CGFloat(oldDisplay.total)) * t
                    let count = Int(ceil(countFloat))
                    let morphActiveIdx = CGFloat(oldDisplay.current) + (CGFloat(display.current) - CGFloat(oldDisplay.current)) * t

                    let isTextAnim = textProgress < 1.0 && dIdx == textDisplay
                    let currentPillIdx: CGFloat
                    if isTextAnim {
                        let p = Easing.outQuart(textProgress)
                        currentPillIdx = CGFloat(textOld) + CGFloat(textNew - textOld) * p
                    } else if isAnim {
                        currentPillIdx = CGFloat(_spacePillOld) + CGFloat(_spacePillNew - _spacePillOld) * _spacePillProg
                    } else {
                        currentPillIdx = isMorphing ? morphActiveIdx : CGFloat(display.current)
                    }
                    let clampedPillIdx = max(1.0, min(countFloat, currentPillIdx))

                    let rowNaturalW = countFloat * dotD + max(0, countFloat - 1) * sp + (pillW - dotD)
                    let rowStretch = max(0, naturalW - rowNaturalW) * stackProgress

                    let metrics = SpacePillMetrics(
                        dotD: dotD, pillW: pillW, pillH: pillH,
                        clampedIdx: clampedPillIdx, countFloat: countFloat,
                        rowStretch: rowStretch, stretch: isAnim ? pillStretchBase : 0
                    )

                    let totalRowW = SpacePillAnimationPipeline.rowWidth(
                        metrics: metrics, count: count, spacing: sp
                    )

                    let inlineX = inlineStartX + inlineXPos
                    let stackedX = (fixedW - totalRowW) / 2
                    var x = inlineX + (stackedX - inlineX) * stackProgress
                    if dIdx > 0 && stackProgress < 1.0 {
                        let sepX = x - 10
                        let sepRect = NSRect(x: sepX, y: (imgH - 8) / 2, width: 1.5, height: 8)
                        palette.dimFocus.withAlphaComponent(rowAlpha * (1.0 - stackProgress)).set()
                        NSBezierPath(roundedRect: sepRect, xRadius: 0.75, yRadius: 0.75).fill()
                    }
                    x = SpacePillAnimationPipeline.drawRow(
                        metrics: metrics, count: count, spacing: sp,
                        originX: x, originY: rowY, rowHeight: rowH,
                        bright: bright, dim: dim, rowAlpha: rowAlpha,
                        direction: isAnim ? pillDir : 0
                    )
                    inlineXPos += rowNaturalW + (isAnim ? pillStretchBase : 0) + 16
                }
            }
            return true
        }
    }

    // MARK: - Grid drawing (separate to keep makePillFrame readable)

    private func drawGrid(
        displays: [SpaceInfo.DisplayInfo], activeDisplayIndex: Int, palette: PillPalette,
        gridRows: [GridRow], naturalW: CGFloat, fixedW: CGFloat, imgH: CGFloat, pad: CGFloat,
        gridDotD: CGFloat, gridPillW: CGFloat, gridPillH: CGFloat,
        gridSp: CGFloat, gridRowH: CGFloat, gridGap: CGFloat,
        spacePillActive: Int, spacePillOld: Int, spacePillNew: Int, spacePillProgress: CGFloat,
        focusOld: Int, focusNew: Int, focusProgress: CGFloat,
        textProgress: CGFloat, textDisplay: Int, textOld: Int, textNew: Int,
        renderFocusOnly: Bool = false,
        animationStyle: AnimationStyle = .liquid
    ) {
        let pillHasAnim = spacePillActive >= 0
        let pillStretchBase: CGFloat = pillHasAnim
            ? SpacePillAnimationPipeline.stretch(progress: spacePillProgress, style: animationStyle)
            : 0
        let pillDir: CGFloat = spacePillNew > spacePillOld ? 1 : -1
        let totalRows = gridRows.count
        let totalGridH = CGFloat(totalRows) * gridRowH + CGFloat(max(0, totalRows - 1)) * gridGap
        let gridBaseY = (imgH - totalGridH) / 2

        for (rowIdx, row) in gridRows.enumerated() {
            let rowY = gridBaseY + CGFloat(totalRows - 1 - rowIdx) * (gridRowH + gridGap)

            var rowContentW: CGFloat = 0
            for (relIdx, dIdx) in row.displayIndices.enumerated() {
                guard dIdx < displays.count else { continue }
                let d = displays[dIdx]
                if relIdx > 0 { rowContentW += 16 }
                let c = max(1, d.total)
                rowContentW += gridPillW + CGFloat(c - 1) * (gridDotD + gridSp)
            }
            let gridRowStretch = max(0, naturalW - rowContentW)
            let perDisplayStretch = row.displayIndices.isEmpty ? 0 : gridRowStretch / CGFloat(row.displayIndices.count)

            var x: CGFloat = pad

            for (relIdx, dIdx) in row.displayIndices.enumerated() {
                guard dIdx < displays.count else { continue }
                let display = displays[dIdx]

                if relIdx > 0 {
                    let sepRect = NSRect(x: x - 10, y: rowY + (gridRowH - 8) / 2, width: 1.5, height: 8)
                    let sp = NSBezierPath(roundedRect: sepRect, xRadius: 0.75, yRadius: 0.75)
                    palette.dimFocus.setFill()
                    sp.fill()
                }

                let (bright, dim, isActiveDisplay) = palette.resolve(
                    display: dIdx, focusOld: focusOld, focusNew: focusNew,
                    focusProgress: focusProgress, activeDisplayIndex: activeDisplayIndex,
                    focusOff: settings.focusDetectionMode == .off
                )
                if renderFocusOnly && !isActiveDisplay { continue }
                let isAnimDisplay = dIdx == spacePillActive

                let count = display.total
                let countFloat = CGFloat(count)
                let clampedPillIdx: CGFloat
                if textProgress < 1.0 && dIdx == textDisplay {
                    let p = Easing.outQuart(textProgress)
                    clampedPillIdx = CGFloat(textOld) + CGFloat(textNew - textOld) * p
                } else if isAnimDisplay {
                    clampedPillIdx = CGFloat(spacePillOld) + CGFloat(spacePillNew - spacePillOld) * spacePillProgress
                } else {
                    clampedPillIdx = CGFloat(display.current)
                }
                let clamped = max(1.0, min(countFloat, clampedPillIdx))
                let metrics = SpacePillMetrics(
                    dotD: gridDotD, pillW: gridPillW, pillH: gridPillH,
                    clampedIdx: clamped, countFloat: countFloat,
                    rowStretch: perDisplayStretch, stretch: isAnimDisplay ? pillStretchBase : 0
                )

                let px = SpacePillAnimationPipeline.drawRow(
                    metrics: metrics, count: count, spacing: gridSp,
                    originX: x, originY: rowY, rowHeight: gridRowH,
                    bright: bright, dim: dim, rowAlpha: 1.0,
                    direction: isAnimDisplay ? pillDir : 0
                )
                x = px + (relIdx < row.displayIndices.count - 1 ? 16 : 0)
            }
        }
    }

    // MARK: - Music display

    /// Shared text line for the music display; also used to measure marquee need.
    private func musicAttributedString(title: String?, artist: String?, titleColor: NSColor, subColor: NSColor) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dimFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: title ?? "—", attributes: [.font: font, .foregroundColor: titleColor]))
        attr.append(NSAttributedString(string: " — ", attributes: [.font: dimFont, .foregroundColor: subColor]))
        attr.append(NSAttributedString(string: artist ?? "—", attributes: [.font: dimFont, .foregroundColor: subColor]))
        return attr
    }

    private static let musicMaxTextWidth: CGFloat = 200

    private struct MusicTextKey: Equatable {
        let title: String?
        let artist: String?
        let titleAlphaKey: Int
        let fadeKey: Int
        let appearanceIsDark: Bool
    }
    private var musicTextKey: MusicTextKey?
    private var musicTextAttr: NSAttributedString?
    private var musicTextSize: NSSize = .zero

    /// True when the title/artist line overflows and marquee-scrolls.
    func musicMarqueeActive(title: String?, artist: String?) -> Bool {
        let isDark = statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = MusicTextKey(
            title: title,
            artist: artist,
            titleAlphaKey: 255,
            fadeKey: 255,
            appearanceIsDark: isDark
        )
        if musicTextKey == key {
            return musicTextSize.width > IndicatorRenderer.musicMaxTextWidth
        }
        let attr = musicAttributedString(title: title, artist: artist, titleColor: .labelColor, subColor: .labelColor)
        return attr.size().width > IndicatorRenderer.musicMaxTextWidth
    }

    func makeMusicFrame(title: String?, artist: String?, barHeights: [CGFloat], marqueeOffset: CGFloat = 0, pauseMorph: CGFloat = 0, textAlpha: CGFloat = 1) -> NSImage {
        let imgH: CGFloat = 22

        let textColor = menuBarTextColor
        let dimColor = menuBarDimColor
        // Paused: the title settles to the dim (artist) color as the bars morph
        // into the pause glyph; textAlpha dips the line during the marquee reset.
        let t01 = max(0, min(1, pauseMorph))
        let fade = max(0, min(1, textAlpha))
        let titleAlpha = (1 + (dimColor.alphaComponent - 1) * t01) * fade
        let isDark = statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let key = MusicTextKey(
            title: title,
            artist: artist,
            titleAlphaKey: Int((titleAlpha * 255.0).rounded()),
            fadeKey: Int((fade * 255.0).rounded()),
            appearanceIsDark: isDark
        )

        let attr: NSAttributedString
        let textSize: NSSize

        if musicTextKey == key, let cachedAttr = musicTextAttr {
            attr = cachedAttr
            textSize = musicTextSize
        } else {
            let newAttr = musicAttributedString(
                title: title, artist: artist,
                titleColor: textColor.withAlphaComponent(titleAlpha),
                subColor: dimColor.withAlphaComponent(dimColor.alphaComponent * fade))
            let newSize = newAttr.size()
            musicTextKey = key
            musicTextAttr = newAttr
            musicTextSize = newSize
            attr = newAttr
            textSize = newSize
        }

        let fullTextW = textSize.width
        let textH = textSize.height
        let maxTextW = IndicatorRenderer.musicMaxTextWidth
        let needsMarquee = fullTextW > maxTextW
        let textW = needsMarquee ? maxTextW : fullTextW

        // If marquee needed, scroll loops every fullTextW + 20px gap
        let overflow = fullTextW + 20
        let scrollOffset: CGFloat = needsMarquee ? marqueeOffset.truncatingRemainder(dividingBy: overflow) : 0

        // Visualizer bars
        let barCount = audioVisualizerBandCount
        let barW: CGFloat = 2
        let barGap: CGFloat = 2
        let barAreaW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap
        let barMaxH: CGFloat = 12
        let barMinH: CGFloat = 3
        let barGapToText: CGFloat = 8

        let totalW = textW + barGapToText + barAreaW + 4
        let pad: CGFloat = 4
        let finalW = totalW + pad * 2

        return NSImage(size: NSSize(width: finalW, height: imgH), flipped: false) { _ in
            // Clip text region
            let textRect = NSRect(x: pad, y: 0, width: textW, height: imgH)
            if let ctx = NSGraphicsContext.current {
                ctx.saveGraphicsState()
                textRect.clip()

                // Draw text with scroll offset
                let textY = (imgH - textH) / 2
                let drawX = pad - scrollOffset
                attr.draw(in: NSRect(x: drawX, y: textY, width: fullTextW, height: textH))

                // If marquee, draw second copy at the end for seamless loop
                if needsMarquee {
                    attr.draw(in: NSRect(x: drawX + overflow, y: textY, width: fullTextW, height: textH))
                }

                ctx.restoreGraphicsState()
            }

            // Bars converge pairwise into a ⏸ glyph (pauseMorph: 0 = bars, 1 = paused)
            let pillarW: CGFloat = 2.5
            let pillarH: CGFloat = 10
            let pillarGap: CGFloat = 4
            let barBaseY: CGFloat = (imgH - barMaxH) / 2
            let barCenterY = barBaseY + barMaxH / 2
            let barOriginX = pad + textW + barGapToText
            let areaCenterX = barOriginX + barAreaW / 2
            // One path + nonzero winding fills the union, so converging pairs
            // don't double-darken where they overlap mid-morph.
            let glyph = NSBezierPath()
            for i in 0..<barCount {
                let barH = i < barHeights.count ? barMinH + (barMaxH - barMinH) * barHeights[i] : 0
                let side: CGFloat = i < barCount / 2 ? -1 : 1
                let pillarCx = areaCenterX + side * (pillarW + pillarGap) / 2
                let barCx = barOriginX + CGFloat(i) * (barW + barGap) + barW / 2
                let cx = barCx + (pillarCx - barCx) * t01
                let h = barH + (pillarH - barH) * t01
                let w = barW + (pillarW - barW) * t01
                let rect = NSRect(x: cx - w / 2, y: barCenterY - h / 2, width: w, height: h)
                glyph.append(NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2))
            }
            textColor.setFill()
            glyph.fill()
            return true
        }
    }

    // MARK: - System HUD (volume / brightness) Frame

    /// Icon + rounded level bar that replaces the native macOS volume/brightness
    /// OSD. `value` is 0…1; `muted` dims the fill and forces the slash icon.
    /// The volume/brightness glyph for a HUD state — shared by this renderer
    /// and the tiling bar's Space Indicator, so both HUDs always agree.
    static func systemHUDIcon(kind: SystemHUDKind, value v: CGFloat, muted: Bool,
                              audioOutputKind: AudioOutputKind?, deviceIcons: Bool,
                              pointSize: CGFloat, color: NSColor) -> NSImage? {
        let symbolName: String
        switch kind {
        case .brightness:
            symbolName = v < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if deviceIcons, let audioOutputKind {
                switch audioOutputKind {
                case .airPodsPro: symbolName = "airpodspro"
                case .airPods:    symbolName = "airpods"
                case .headphones: symbolName = "headphones"
                case .speaker:
                    if muted          { symbolName = "speaker.slash.fill" }
                    else if v <= 0.001 { symbolName = "speaker.fill" }
                    else if v < 0.33   { symbolName = "speaker.wave.1.fill" }
                    else if v < 0.66   { symbolName = "speaker.wave.2.fill" }
                    else               { symbolName = "speaker.wave.3.fill" }
                }
            } else if muted          { symbolName = "speaker.slash.fill" }
            else if v <= 0.001 { symbolName = "speaker.fill" }
            else if v < 0.33   { symbolName = "speaker.wave.1.fill" }
            else if v < 0.66   { symbolName = "speaker.wave.2.fill" }
            else               { symbolName = "speaker.wave.3.fill" }
        }

        func symbol(_ name: String) -> NSImage? {
            let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            img?.isTemplate = false
            return img
        }
        // Older systems lack the AirPods glyphs; fall back to the nearest one.
        switch symbolName {
        case "airpodspro": return symbol(symbolName) ?? symbol("airpods") ?? symbol("headphones")
        case "airpods":    return symbol(symbolName) ?? symbol("headphones")
        default:           return symbol(symbolName)
        }
    }

    /// Whether a HUD glyph is centered in its slot rather than bottom-anchored.
    /// The sun symbols radiate from their middle and differ in size (min 14pt,
    /// max 16pt), so the shared bottom anchor that keeps the speaker family
    /// steady left them a point high and, for sun.min, a point left.
    static func centersSystemHUDIcon(kind: SystemHUDKind) -> Bool {
        kind == .brightness
    }

    func makeSystemHUDFrame(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind? = nil) -> NSImage {
        let imgH: CGFloat = 22
        let v = max(0, min(1, value))
        let color = menuBarTextColor

        let icon = Self.systemHUDIcon(kind: kind, value: v, muted: muted, audioOutputKind: audioOutputKind,
                                      deviceIcons: settings.systemHUDDeviceIcons, pointSize: 12, color: color)

        // Reserve a fixed-width slot for the icon so the HUD's overall width never
        // changes as the symbol swaps (speaker.wave.1 → .3, slash, etc.), which
        // would otherwise resize the status item and shift the whole menu bar.
        let iconSlotW: CGFloat = 18

        let gap: CGFloat = 6
        let trackW: CGFloat = 70
        let trackH: CGFloat = 4
        let pad: CGFloat = 4
        let finalW = pad + iconSlotW + gap + trackW + pad

        let dimmed = muted && kind == .volume
        let trackColor = color.withAlphaComponent(0.22)
        let fillColor = dimmed ? color.withAlphaComponent(0.4) : color

        return NSImage(size: NSSize(width: finalW, height: imgH), flipped: false) { _ in
            if let icon {
                // Fixed anchor rather than centering on this icon's own reported
                // width/height. SF Symbol variants within a family (speaker.fill →
                // wave.1/2/3, sun.min → sun.max) share consistent leading/bottom
                // bearings by design — centering per-icon instead made the
                // recognizable glyph shape visibly drift as the symbol swapped,
                // since narrower variants report extra invisible padding reserved
                // for the wider ones (e.g. speaker.fill leaves room for the waves).
                let referenceIconHeight: CGFloat = 14
                var ix = pad + 1
                var iy = (imgH - referenceIconHeight) / 2
                if Self.centersSystemHUDIcon(kind: kind) {
                    ix = pad + (iconSlotW - icon.size.width) / 2
                    iy = (imgH - icon.size.height) / 2
                }
                icon.draw(in: NSRect(x: ix, y: iy, width: icon.size.width, height: icon.size.height))
            }
            let tx = pad + iconSlotW + gap
            let ty = (imgH - trackH) / 2
            let track = NSBezierPath(roundedRect: NSRect(x: tx, y: ty, width: trackW, height: trackH),
                                     xRadius: trackH / 2, yRadius: trackH / 2)
            trackColor.setFill(); track.fill()

            let effectiveV = (muted && kind == .volume) ? 0 : v
            if effectiveV > 0 {
                let fillW = max(trackH, trackW * effectiveV)
                let fill = NSBezierPath(roundedRect: NSRect(x: tx, y: ty, width: fillW, height: trackH),
                                        xRadius: trackH / 2, yRadius: trackH / 2)
                fillColor.setFill(); fill.fill()
            }
            return true
        }
    }

    // MARK: - Input Source (keyboard language) Frame

    /// SF Symbol globe image tinted to `color` for the input source HUD.
    static func inputSourceHUDIcon(pointSize: CGFloat = 12, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.isTemplate = false
        return img
    }

    /// Globe icon + input source name, shown when the keyboard layout changes.
    /// Same visual language as the system HUD frame: fixed icon slot on the
    /// left, content to the right, 22pt tall.
    func makeInputSourceHUDFrame(name: String) -> NSImage {
        let imgH: CGFloat = 22
        let color = menuBarTextColor
        let icon = Self.inputSourceHUDIcon(pointSize: 12, color: color)

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attr = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color])
        let maxTextW: CGFloat = 160
        let textW = min(attr.size().width, maxTextW)

        let iconSlotW: CGFloat = 18
        let gap: CGFloat = 4
        let pad: CGFloat = 4
        let finalW = pad + iconSlotW + gap + textW + pad

        return NSImage(size: NSSize(width: finalW, height: imgH), flipped: false) { _ in
            if let icon {
                let referenceIconHeight: CGFloat = 14
                let ix = pad + 1
                let iy = (imgH - referenceIconHeight) / 2
                icon.draw(in: NSRect(x: ix, y: iy, width: icon.size.width, height: icon.size.height))
            }
            if let ctx = NSGraphicsContext.current {
                ctx.saveGraphicsState()
                let textX = pad + iconSlotW + gap
                NSRect(x: textX, y: 0, width: textW, height: imgH).clip()
                let textY = (imgH - attr.size().height) / 2
                attr.draw(at: NSPoint(x: textX, y: textY))
                ctx.restoreGraphicsState()
            }
            return true
        }
    }

    /// SF Symbol image tinted to `color` (palette config — the symbol is colored,
    /// not a template, since `color` already adapts to the menu bar appearance).
    private func systemSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        img?.isTemplate = false
        return img
    }

    // MARK: - Colors

    private struct ColorCacheKey: Equatable {
        let appearanceName: NSAppearance.Name?
    }
    private var colorCacheKey: ColorCacheKey?
    private var cachedTextColor: NSColor?
    private var cachedDimColor: NSColor?

    /// Adapts text/pill color to the menu bar's actual translucency
    /// background. labelColor stays white on a light translucent menu bar
    /// → invisible. Reading effectiveAppearance gives the real answer.
    var menuBarTextColor: NSColor {
        let currentMatch = statusItem?.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
        let key = ColorCacheKey(appearanceName: currentMatch)
        if colorCacheKey == key, let c = cachedTextColor { return c }

        let color: NSColor
        switch currentMatch {
        case .darkAqua, .vibrantDark:  color = NSColor(white: 0.90, alpha: 1)
        default:                        color = NSColor(white: 0.15, alpha: 1)
        }
        colorCacheKey = key
        cachedTextColor = color
        cachedDimColor = (currentMatch == .darkAqua || currentMatch == .vibrantDark)
            ? color.withAlphaComponent(0.55)
            : color.withAlphaComponent(0.60)
        return color
    }

    var menuBarDimColor: NSColor {
        _ = menuBarTextColor // populates cache for current appearance
        return cachedDimColor ?? NSColor(white: 0.5, alpha: 1)
    }

}
