import AppKit

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

    // MARK: - Width helpers

    func targetWidth(for displays: [SpaceInfo.DisplayInfo], stackIndicators: Bool, gridRows: [GridRow] = []) -> CGFloat {
        guard !displays.isEmpty else { return 26 }
        return gnomePillFixedWidth(for: displays, stackIndicators: stackIndicators, gridRows: gridRows)
    }

    func gnomePillFixedWidth(
        for displays: [SpaceInfo.DisplayInfo],
        stackIndicators: Bool,
        gridRows: [GridRow] = [],
        gridDotD: CGFloat = 6, gridPillW: CGFloat = 26, gridSp: CGFloat = 6
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
        let dotD: CGFloat = useCompact ? 4 : 6
        let pillW: CGFloat = useCompact ? 18 : 26
        let sp: CGFloat = useCompact ? 4 : 6
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
        let baseColor = menuBarTextColor
        let bf = settings.brightFocusAlpha
        let df = settings.dimFocusAlpha
        let bn = settings.brightNonFocusAlpha
        let dn = settings.dimNonFocusAlpha
        let brightFocusColor = baseColor.withAlphaComponent(bf)
        let dimFocusColor = baseColor.withAlphaComponent(df)
        let brightNonFocusColor = baseColor.withAlphaComponent(bn)
        let dimNonFocusColor = baseColor.withAlphaComponent(dn)

        let stackIndicators = indicator.stackIndicators

        let gridRows = overrideGridRows ?? indicator.currentGridLayout
        let isMorphing = indicator.animLayoutProgress < 1.0
        let useGrid = !gridRows.isEmpty && !isMorphing
        let t = Easing.outQuart(indicator.animLayoutProgress)
        let isRowMorphing = indicator.animRowMorphProgress < 1.0
        let rmT = isRowMorphing ? indicator.animRowMorphProgress : 1.0

        let oldDisplays = indicator.previousLayoutDisplays

        // Animation state pulled from indicator
        let _spacePillActive = animatingDisplay >= 0 ? animatingDisplay : indicator.animSpacePillDisplay
        let _spacePillOld    = animatingDisplay >= 0 ? spacePillOldActive : indicator.animSpacePillOldActive
        let _spacePillNew    = animatingDisplay >= 0 ? spacePillNewActive : indicator.animSpacePillNewActive
        let _spacePillProg   = animatingDisplay >= 0 ? spacePillProgress  : indicator.animSpacePillProgress

        // Liquid stretch: active pill widens during slide, peaking at midpoint
        let isLiquid = animationStyle == .liquid
        let pillHasAnim = _spacePillActive >= 0
        let pillStretchBase: CGFloat = (pillHasAnim && isLiquid) ? sin(_spacePillProg * .pi) * 4 : 0
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
                         : GridDims(dotD: 6, pillW: 26, pillH: 8, sp: 6, rowH: 20, gap: 1)
        let gridDotD = gd.dotD, gridPillW = gd.pillW, gridPillH = gd.pillH
        let gridSp = gd.sp, gridRowH = gd.rowH, gridGap = gd.gap

        // Target/old sizing
        let useCompact = stackIndicators && displays.count > 1
        let dotD_t: CGFloat = useCompact ? 4 : 6
        let pillW_t: CGFloat = useCompact ? 18 : 26
        let pillH_t: CGFloat = useCompact ? 4 : 8
        let sp_t: CGFloat = useCompact ? 4 : 6
        let rowH_t: CGFloat = useCompact ? 8 : 20
        let gap_t: CGFloat = 1

        let oldUseCompact = stackIndicators && oldDisplays.count > 1
        let dotD_o: CGFloat = oldUseCompact ? 4 : 6
        let pillW_o: CGFloat = oldUseCompact ? 18 : 26
        let pillH_o: CGFloat = oldUseCompact ? 4 : 8
        let sp_o: CGFloat = oldUseCompact ? 4 : 6
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
            let f_dotD: CGFloat = fromCompact ? 4 : 6
            let f_pillW: CGFloat = fromCompact ? 18 : 26
            let f_pillH: CGFloat = fromCompact ? 4 : 8
            let f_sp: CGFloat = fromCompact ? 4 : 6
            let f_rowH: CGFloat = fromCompact ? 8 : 20
            let f_gap: CGFloat = 1
            let g_dotD: CGFloat = toCompact ? 4 : 6
            let g_pillW: CGFloat = toCompact ? 18 : 26
            let g_pillH: CGFloat = toCompact ? 4 : 8
            let g_sp: CGFloat = toCompact ? 4 : 6
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
            let fromW = gnomePillFixedWidth(for: fromDisplays, stackIndicators: stackIndicators)
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
                    displays: displaysToDraw, activeDisplayIndex: activeDisplayIndex,
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

                    if isRowMorphing && !isMorphing {
                        if dIdx >= displays.count { rowAlpha = 1.0 - rmT }
                        else if dIdx >= rowMorphFromCount { rowAlpha = rmT }
                    }
                    if rowAlpha <= 0 { continue }

                    let toStacked = stackIndicators && displaysToDraw.count > 1
                    let fromStacked = isRowMorphing ? (rowMorphFromStacked && rowMorphFromCount > 1) : toStacked
                    let isStacked = toStacked

                    let rowY: CGFloat
                    if !isStacked && !fromStacked {
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

                    let isActive: Bool
                    let bright: NSColor
                    let dim: NSColor

                    if dIdx == focusOld && focusProgress < 1.0 {
                        let ft = Easing.outQuart(focusProgress)
                        bright = brightFocusColor.blended(withFraction: ft, of: brightNonFocusColor) ?? brightFocusColor
                        dim = dimFocusColor.blended(withFraction: ft, of: dimNonFocusColor) ?? dimFocusColor
                        isActive = true
                    } else if dIdx == focusNew && focusProgress < 1.0 {
                        let ft = Easing.outQuart(focusProgress)
                        bright = brightNonFocusColor.blended(withFraction: ft, of: brightFocusColor) ?? brightNonFocusColor
                        dim = dimNonFocusColor.blended(withFraction: ft, of: dimFocusColor) ?? dimNonFocusColor
                        isActive = true
                    } else {
                        isActive = self.settings.focusDetectionMode == .off || dIdx == activeDisplayIndex
                        bright = isActive ? brightFocusColor : brightNonFocusColor
                        dim = isActive ? dimFocusColor : dimNonFocusColor
                    }
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
                    let rowStretch = isStacked ? max(0, naturalW - rowNaturalW) : 0

                    func widthForSpace(_ i: Int) -> CGFloat {
                        let iF = CGFloat(i)
                        let pL = floor(clampedPillIdx), pH = ceil(clampedPillIdx)
                        let frac = clampedPillIdx - pL
                        let dotAlpha: CGFloat = (iF > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                        func adj(_ w: CGFloat) -> CGFloat { w * dotAlpha }
                        let stretch = isAnim ? pillStretchBase : 0
                        if pL == pH { return iF == pL ? (pillW + rowStretch + stretch) : adj(dotD) }
                        if iF == pL { return dotD + (pillW + rowStretch - dotD + stretch) * (1.0 - frac) }
                        if iF == pH { return dotD + (pillW + rowStretch - dotD + stretch) * frac }
                        return adj(dotD)
                    }

                    func heightForSpace(_ i: Int) -> CGFloat {
                        let iF = CGFloat(i), pL = floor(clampedPillIdx), pH = ceil(clampedPillIdx), frac = clampedPillIdx - pL
                        if pL == pH { return iF == pL ? pillH : dotD }
                        if iF == pL { return dotD + (pillH - dotD) * (1.0 - frac) }
                        if iF == pH { return dotD + (pillH - dotD) * frac }
                        return dotD
                    }

                    func colorForSpace(_ i: Int) -> NSColor {
                        let iF = CGFloat(i)
                        let dotAlpha: CGFloat = (iF > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                        let pL = floor(clampedPillIdx), pH = ceil(clampedPillIdx), frac = clampedPillIdx - pL
                        let alpha: CGFloat
                        if pL == pH { alpha = iF == pL ? 1.0 : 0.0 }
                        else if iF == pL { alpha = 1.0 - frac }
                        else if iF == pH { alpha = frac }
                        else { alpha = 0 }
                        let c = dim.blended(withFraction: alpha, of: bright) ?? dim
                        return c.withAlphaComponent(c.alphaComponent * rowAlpha * dotAlpha)
                    }

                    var totalRowW: CGFloat = 0
                    for i in 1...count {
                        totalRowW += widthForSpace(i)
                        if i > 1 { totalRowW += sp }
                    }

                    var x: CGFloat
                    if isStacked {
                        x = (fixedW - totalRowW) / 2
                    } else {
                        x = inlineStartX + inlineXPos
                        if dIdx > 0 {
                            let sepX = x - 10
                            let sepRect = NSRect(x: sepX, y: (imgH - 8) / 2, width: 1.5, height: 8)
                            dimFocusColor.withAlphaComponent(rowAlpha).set()
                            NSBezierPath(roundedRect: sepRect, xRadius: 0.75, yRadius: 0.75).fill()
                        }
                    }
                    // Directional stretch offset: smear toward destination
                    let stretchShift = isAnim ? pillStretchBase * pillDir * 0.35 : 0
                    x += stretchShift

                    for i in 1...count {
                        let w = widthForSpace(i)
                        let h = heightForSpace(i)
                        let rect = NSRect(x: x, y: rowY + (rowH - h) / 2, width: w, height: h)
                        let path = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
                        colorForSpace(i).setFill()
                        path.fill()
                        x += w
                        if i < count { x += sp }
                    }
                    if !isStacked {
                        inlineXPos += totalRowW + 16
                    }
                }
            }
            return true
        }
    }

    // MARK: - Grid drawing (separate to keep makePillFrame readable)

    private func drawGrid(
        displays: [SpaceInfo.DisplayInfo], activeDisplayIndex: Int,
        gridRows: [GridRow], naturalW: CGFloat, fixedW: CGFloat, imgH: CGFloat, pad: CGFloat,
        gridDotD: CGFloat, gridPillW: CGFloat, gridPillH: CGFloat,
        gridSp: CGFloat, gridRowH: CGFloat, gridGap: CGFloat,
        spacePillActive: Int, spacePillOld: Int, spacePillNew: Int, spacePillProgress: CGFloat,
        focusOld: Int, focusNew: Int, focusProgress: CGFloat,
        textProgress: CGFloat, textDisplay: Int, textOld: Int, textNew: Int,
        renderFocusOnly: Bool = false,
        animationStyle: AnimationStyle = .liquid
    ) {
        let baseColor = menuBarTextColor
        let bf = settings.brightFocusAlpha
        let df = settings.dimFocusAlpha
        let bn = settings.brightNonFocusAlpha
        let dn = settings.dimNonFocusAlpha
        let brightFocusColor = baseColor.withAlphaComponent(bf)
        let dimFocusColor = baseColor.withAlphaComponent(df)
        let brightNonFocusColor = baseColor.withAlphaComponent(bn)
        let dimNonFocusColor = baseColor.withAlphaComponent(dn)
        let isLiquid = animationStyle == .liquid
        let pillHasAnim = spacePillActive >= 0
        let pillStretchBase: CGFloat = (pillHasAnim && isLiquid) ? sin(spacePillProgress * .pi) * 4 : 0
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
                    dimFocusColor.setFill()
                    sp.fill()
                }

                let isActiveDisplay: Bool
                let bright: NSColor
                let dim: NSColor
                if dIdx == focusOld && focusProgress < 1.0 {
                    let ft = Easing.outQuart(focusProgress)
                    bright = brightFocusColor.blended(withFraction: ft, of: brightNonFocusColor) ?? brightFocusColor
                    dim = dimFocusColor.blended(withFraction: ft, of: dimNonFocusColor) ?? dimFocusColor
                    isActiveDisplay = true
                } else if dIdx == focusNew && focusProgress < 1.0 {
                    let ft = Easing.outQuart(focusProgress)
                    bright = brightNonFocusColor.blended(withFraction: ft, of: brightFocusColor) ?? brightNonFocusColor
                    dim = dimNonFocusColor.blended(withFraction: ft, of: dimFocusColor) ?? dimNonFocusColor
                    isActiveDisplay = true
                } else {
                    isActiveDisplay = settings.focusDetectionMode == .off || dIdx == activeDisplayIndex
                    bright = isActiveDisplay ? brightFocusColor : brightNonFocusColor
                    dim = isActiveDisplay ? dimFocusColor : dimNonFocusColor
                }
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
                let rowStretchLocal = perDisplayStretch

                func gw(_ i: Int) -> CGFloat {
                    let iF = CGFloat(i)
                    let pL = floor(clamped), pH = ceil(clamped)
                    let frac = clamped - pL
                    let dotAlpha: CGFloat = (iF > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                    func adj(_ w: CGFloat) -> CGFloat { w * dotAlpha }
                    let stretch = isAnimDisplay ? pillStretchBase : 0
                    if pL == pH { return iF == pL ? (gridPillW + rowStretchLocal + stretch) : adj(gridDotD) }
                    if iF == pL { return gridDotD + (gridPillW + rowStretchLocal - gridDotD + stretch) * (1.0 - frac) }
                    if iF == pH { return gridDotD + (gridPillW + rowStretchLocal - gridDotD + stretch) * frac }
                    return adj(gridDotD)
                }
                func gh(_ i: Int) -> CGFloat {
                    let iF = CGFloat(i), pL = floor(clamped), pH = ceil(clamped), frac = clamped - pL
                    if pL == pH { return iF == pL ? gridPillH : gridDotD }
                    if iF == pL { return gridDotD + (gridPillH - gridDotD) * (1.0 - frac) }
                    if iF == pH { return gridDotD + (gridPillH - gridDotD) * frac }
                    return gridDotD
                }
                func gc(_ i: Int) -> NSColor {
                    let iF = CGFloat(i)
                    let dotAlpha: CGFloat = (iF > floor(countFloat)) ? (countFloat - floor(countFloat)) : 1.0
                    let pL = floor(clamped), pH = ceil(clamped), frac = clamped - pL
                    let alpha: CGFloat
                    if pL == pH { alpha = iF == pL ? 1.0 : 0.0 }
                    else if iF == pL { alpha = 1.0 - frac }
                    else if iF == pH { alpha = frac }
                    else { alpha = 0 }
                    let color = dim.blended(withFraction: alpha, of: bright) ?? dim
                    return color.withAlphaComponent(color.alphaComponent * dotAlpha)
                }

                let stretchShift = isAnimDisplay ? pillStretchBase * pillDir * 0.35 : 0
                var px = x + stretchShift
                for i in 1...count {
                    let w = gw(i)
                    let h = gh(i)
                    let rect = NSRect(x: px, y: rowY + (gridRowH - h) / 2, width: w, height: h)
                    gc(i).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
                    px += w
                    if i < count { px += gridSp }
                }
                x = px + (relIdx < row.displayIndices.count - 1 ? 16 : 0)
            }
        }
    }

    // MARK: - Music display

    func makeMusicAttributedString(title: String?, artist: String?) -> NSAttributedString {
        let t = title ?? "—"
        let a = artist ?? "—"
        let textColor = menuBarTextColor
        let dimColor = menuBarDimColor
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dimFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: textColor]))
        result.append(NSAttributedString(string: " — ", attributes: [.font: dimFont, .foregroundColor: dimColor]))
        result.append(NSAttributedString(string: a, attributes: [.font: dimFont, .foregroundColor: dimColor]))
        return result
    }

    func makeMusicFrame(title: String?, artist: String?, barHeights: [CGFloat], marqueeOffset: CGFloat = 0, barToDots: CGFloat = 0) -> NSImage {
        let t = title ?? "—"
        let a = artist ?? "—"
        let imgH: CGFloat = 22

        let textColor = menuBarTextColor
        let dimColor = menuBarDimColor
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let dimFont = NSFont.systemFont(ofSize: 12, weight: .regular)

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: textColor]))
        attr.append(NSAttributedString(string: " — ", attributes: [.font: dimFont, .foregroundColor: dimColor]))
        attr.append(NSAttributedString(string: a, attributes: [.font: dimFont, .foregroundColor: dimColor]))

        let fullTextW = attr.size().width
        let maxTextW: CGFloat = 200
        let needsMarquee = fullTextW > maxTextW
        let textW = needsMarquee ? maxTextW : fullTextW

        // If marquee needed, scroll loops every fullTextW + 20px gap
        let overflow = fullTextW + 20
        let scrollOffset: CGFloat = needsMarquee ? marqueeOffset.truncatingRemainder(dividingBy: overflow) : 0

        // Visualizer bars
        let barCount = 4
        let barW: CGFloat = 2.5
        let barGap: CGFloat = 3
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
                let textY = (imgH - attr.size().height) / 2
                let drawX = pad - scrollOffset
                attr.draw(in: NSRect(x: drawX, y: textY, width: fullTextW, height: attr.size().height))

                // If marquee, draw second copy at the end for seamless loop
                if needsMarquee {
                    attr.draw(in: NSRect(x: drawX + overflow, y: textY, width: fullTextW, height: attr.size().height))
                }

                ctx.restoreGraphicsState()
            }

            // Draw bars interpolating into dots (barToDots: 0 = bars, 1 = dots)
            let t = barToDots
            let dotDiam: CGFloat = 4
            let barBaseY: CGFloat = (imgH - barMaxH) / 2
            let barCenterY = barBaseY + barMaxH / 2
            let barOriginX = pad + textW + barGapToText
            let morphColor = textColor
            morphColor.setFill()
            for i in 0..<barCount {
                let barH = i < barHeights.count ? barMinH + (barMaxH - barMinH) * barHeights[i] : 0
                let h = barH + (dotDiam - barH) * t
                let w = barW + (dotDiam - barW) * t
                let cx = barOriginX + CGFloat(i) * (barW + barGap) + barW / 2
                let x = cx - w / 2
                let y = barCenterY - h / 2
                let radius = w / 2
                let rect = NSRect(x: x, y: y, width: w, height: h)
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                path.fill()
            }
            return true
        }
    }

    // MARK: - Colors

    /// Adapts text/pill color to the menu bar's actual translucency
    /// background. labelColor stays white on a light translucent menu bar
    /// → invisible. Reading effectiveAppearance gives the real answer.
    var menuBarTextColor: NSColor {
        guard let button = statusItem?.button else { return .labelColor }
        let name = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
        switch name {
        case .darkAqua, .vibrantDark:  return NSColor(white: 0.90, alpha: 1)
        default:                        return NSColor(white: 0.15, alpha: 1)
        }
    }
    var menuBarDimColor: NSColor {
        let bright = menuBarTextColor
        guard let button = statusItem?.button else { return .secondaryLabelColor }
        let name = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
        switch name {
        case .darkAqua, .vibrantDark:  return bright.withAlphaComponent(0.55)
        default:                        return bright.withAlphaComponent(0.60)
        }
    }

}
