import AppKit

// ---------------------------------------------------------------------------
// HardwareStatusItem — dedicated menu bar item for hardware stats
// ---------------------------------------------------------------------------

final class HardwareStatusItem {

    private let item: NSStatusItem
    let barView: HardwareBarView
    private var popover: HardwarePopover?

    /// When the battery module is split into its own status item, its card
    /// should no longer appear in this popover.
    var hidesBatteryCard: Bool = false {
        didSet { popover?.hidesBatteryCard = hidesBatteryCard }
    }

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MSG.HardwareStats"

        barView = HardwareBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 22))

        if let btn = item.button {
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(togglePopover)
            btn.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        barView.onAnimationFrame = { [weak self] in
            guard let self else { return }
            self.item.button?.image = self.barView.renderedImage()
        }

        HardwareMonitor.shared.addObserver { [weak self] in
            DispatchQueue.main.async {
                self?.barView.stats = HardwareMonitor.shared.stats
                self?.refreshImage()
            }
        }

        refreshImage()
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
        } else {
            if popover == nil {
                popover = HardwarePopover()
                popover?.hidesBatteryCard = hidesBatteryCard
            }
            popover?.show(relativeTo: item.button!)
        }
    }

    func remove() {
        popover?.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    func refreshImage() {
        let size = barView.intrinsicContentSize
        barView.frame.size = size
        item.length = size.width
        item.button?.image = barView.renderedImage()
    }
}

// ---------------------------------------------------------------------------
// HardwareBarView — draws bars with labels
// ---------------------------------------------------------------------------

final class HardwareBarView: NSView {

    var stats = HardwareStats() {
        didSet {
            needsDisplay = true
            retargetAnimation()
        }
    }

    /// Fired on each animation tick so image-based hosts (the status item)
    /// can re-render; the live settings preview redraws via needsDisplay.
    var onAnimationFrame: (() -> Void)?

    var showCPU: Bool = true
    var showGPU: Bool = true
    var showMemory: Bool = true
    var showTemp: Bool = true
    var showFPS: Bool = false
    var showFan: Bool = false
    var showPower: Bool = false
    var showBattery: Bool = false

    /// Left→right module order. Ids not present fall back to the default order.
    var moduleOrder: [String] = AppSettings.hardwareModuleIDs

    /// When true, the corresponding module renders as a bare number + label
    /// (like FPS already does) instead of a bar/dot/circular gauge.
    var cpuRaw: Bool = false
    var gpuRaw: Bool = false
    var memoryRaw: Bool = false
    var tempRaw: Bool = false
    var fanRaw: Bool = false
    var powerRaw: Bool = false
    /// "bar" | "number" | "icon" (native-style battery glyph)
    var batteryStyle: String = "bar"

    /// Scales the battery glyph (outline, nub, level fill, charging bolt).
    /// 1.0 is the size used inside the combined multi-module bar; the
    /// dedicated battery-only status item uses a larger value.
    var batteryIconScale: CGFloat = 1.0

    /// "vertical" | "horizontal" | "circular" | "dot"
    var barStyle: String = "vertical"

    /// "vertical" (beside bar) | "horizontal" (below bar, like preview)
    var labelPosition: String = "vertical"

    /// "white" | "green"
    var colorScale: String = "white"

    // -----------------------------------------------------------------------
    // MARK: - Layout
    // -----------------------------------------------------------------------

    private let barW: CGFloat = 4
    private let gap: CGFloat = 3
    private let leftPadding: CGFloat = 4
    private let fontSize: CGFloat = 7.0
    private let horizontalLabelFontSize: CGFloat = 7.4
    private let circularHorizontalLabelFontSize: CGFloat = 6.2
    private let circularRadius: CGFloat = 6.75
    private let circularVerticalModuleW: CGFloat = 30

    // Number-style module fonts, shared by drawValue and the width sizing so
    // the two stay in sync.
    static let valueFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    static let valueUnitFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
    static let valueLabelFont = NSFont.systemFont(ofSize: 6, weight: .heavy)

    /// Bar height depends on label position: shorter when text is below.
    private var barH: CGFloat {
        labelPosition == "horizontal" ? 11 : 18
    }

    private var barY: CGFloat {
        labelPosition == "horizontal" ? 10 : 2
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit { animTimer?.invalidate() }

    // -----------------------------------------------------------------------
    // MARK: - Value animation
    // -----------------------------------------------------------------------

    private var displayedRatios: [String: CGFloat] = [:]
    private var animStartRatios: [String: CGFloat] = [:]
    private var animTargetRatios: [String: CGFloat] = [:]
    private var animStartTime: CFTimeInterval = 0
    private var animTimer: Timer?
    private let animDuration: CFTimeInterval = 0.35

    /// Ease each bar's displayed ratio toward the new stats-derived target.
    private func retargetAnimation() {
        var targets: [String: CGFloat] = [:]
        for mod in activeModules() where !mod.isValue { targets[mod.label] = mod.ratio }

        // First stats arrival: snap without animating.
        if displayedRatios.isEmpty {
            displayedRatios = targets
            return
        }

        // Drop modules that are no longer shown.
        displayedRatios = displayedRatios.filter { targets[$0.key] != nil }

        animStartRatios = [:]
        animTargetRatios = [:]
        for (label, target) in targets {
            let current = displayedRatios[label] ?? target
            if abs(target - current) > 0.001 {
                animStartRatios[label] = current
                animTargetRatios[label] = target
            } else {
                displayedRatios[label] = target
            }
        }

        animTimer?.invalidate()
        guard !animTargetRatios.isEmpty else {
            animTimer = nil
            return
        }

        animStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.stepAnimation(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stepAnimation(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - animStartTime
        let progress = max(0, min(1, CGFloat(elapsed / animDuration)))
        let eased = Easing.outQuart(progress)
        for (label, target) in animTargetRatios {
            let start = animStartRatios[label] ?? target
            displayedRatios[label] = start + (target - start) * eased
        }
        if progress >= 1 {
            timer.invalidate()
            if animTimer === timer { animTimer = nil }
        }
        needsDisplay = true
        onAnimationFrame?()
    }

    // -----------------------------------------------------------------------
    // MARK: - Drawing
    // -----------------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        let modules = activeModules()
        guard !modules.isEmpty else { return }

        let drawWidth = bounds.width - leftPadding
        let moduleW = drawWidth / CGFloat(modules.count)

        for (i, mod) in modules.enumerated() {
            var mod = mod
            if !mod.isValue, let shown = displayedRatios[mod.label] { mod.ratio = shown }
            let x = leftPadding + CGFloat(i) * moduleW
            let rect = NSRect(x: x, y: 0, width: moduleW, height: bounds.height)
            if mod.isBatteryIcon {
                drawBatteryIcon(module: mod, in: rect)
            } else if mod.isValue {
                drawValue(module: mod, in: rect)
            } else if barStyle == "circular" {
                drawCircular(module: mod, in: rect)
            } else if barStyle == "horizontal" {
                drawHorizontalBar(module: mod, in: rect)
            } else if barStyle == "dot" {
                drawDot(module: mod, in: rect)
            } else {
                drawVertical(module: mod, in: rect)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Vertical bar
    // -----------------------------------------------------------------------

    private func drawVertical(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        let w: CGFloat = isHorizontal ? 5 : barW
        let barOriginX = rect.midX - w / 2

        // Background track
        let track = NSRect(x: barOriginX, y: barY, width: w, height: barH)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: w / 2, yRadius: w / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        // Filled portion
        if module.ratio > 0 {
            let fillH = max(2, barH * module.ratio)
            let fillRect = NSRect(x: barOriginX, y: barY, width: w, height: fillH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: w / 2, yRadius: w / 2)
            moduleColor(module).setFill()
            fillPath.fill()
        }

        if isHorizontal {
            drawHorizontalLabel(module.label, x: rect.midX, y: 1, in: rect)
        } else {
            // Label on the left side of the bar
            let labelX = barOriginX - gap - estimatedCharWidth()
            drawVerticalLabel(module.label, x: labelX, in: rect)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Horizontal bar
    // -----------------------------------------------------------------------

    private func drawHorizontalBar(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        let labelW = estimatedLabelWidth(module.label)
        let trackH: CGFloat = 5
        let trackW: CGFloat
        let trackX: CGFloat
        let trackY: CGFloat

        if isHorizontal {
            trackW = min(28, max(20, rect.width - 4))
            trackX = rect.midX - trackW / 2
            trackY = 13
        } else {
            trackW = max(18, rect.width - labelW - gap - 4)
            trackX = rect.minX + labelW + gap
            trackY = rect.midY - trackH / 2
        }

        let track = NSRect(x: trackX, y: trackY, width: trackW, height: trackH)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        if module.ratio > 0 {
            let fillW = max(trackH, trackW * module.ratio)
            let fillRect = NSRect(x: trackX, y: trackY, width: fillW, height: trackH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2, yRadius: trackH / 2)
            moduleColor(module).setFill()
            fillPath.fill()
        }

        if isHorizontal {
            drawHorizontalLabel(module.label, x: rect.midX, y: 1, in: rect)
        } else {
            drawHorizontalLabelCentered(module.label, x: rect.minX + labelW / 2, centerY: rect.midY, in: rect)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Dot
    // -----------------------------------------------------------------------

    private func drawDot(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        let dotD: CGFloat = isHorizontal ? 7 : 6
        let dotX: CGFloat
        let dotY: CGFloat

        if isHorizontal {
            dotX = rect.midX - dotD / 2
            dotY = 12
        } else {
            let labelW = estimatedCharWidth()
            let contentW = labelW + gap + dotD
            let startX = rect.minX + max(1, (rect.width - contentW) / 2)
            dotX = startX + labelW + gap
            dotY = rect.midY - dotD / 2
        }

        let dotRect = NSRect(x: dotX, y: dotY, width: dotD, height: dotD)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        moduleColor(module, preferredScale: "green").setFill()
        dotPath.fill()

        if isHorizontal {
            drawHorizontalLabel(module.label, x: rect.midX, y: 1, in: rect)
        } else {
            let labelX = dotX - gap - estimatedCharWidth()
            drawVerticalLabel(module.label, x: labelX, in: rect)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Circular bar
    // -----------------------------------------------------------------------

    private func drawCircular(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        // Smaller ring when the label sits below, so it fits between the
        // label and the top edge without clipping.
        let r: CGFloat = isHorizontal ? 5.25 : circularRadius
        let centerY: CGFloat = isHorizontal ? rect.midY + 4 : rect.midY
        let lineW: CGFloat = 2.5
        let strokeInset = lineW / 2
        let labelW = estimatedCharWidth()
        let ringX: CGFloat
        if isHorizontal {
            ringX = rect.midX
        } else {
            let contentW = labelW + gap + (r + strokeInset) * 2
            let startX = rect.minX + max(1, (rect.width - contentW) / 2)
            ringX = startX + labelW + gap + r + strokeInset
        }
        let center = NSPoint(x: ringX, y: centerY)

        // Background ring
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
        bgPath.lineWidth = lineW
        NSColor.white.withAlphaComponent(0.15).setStroke()
        bgPath.stroke()

        // Filled arc
        let startAngle: CGFloat = 90
        let endAngle: CGFloat = startAngle - 360 * module.ratio
        if module.ratio > 0.01 {
            let arcPath = NSBezierPath()
            arcPath.appendArc(withCenter: center, radius: r,
                              startAngle: startAngle, endAngle: endAngle, clockwise: true)
            arcPath.lineWidth = lineW
            arcPath.lineCapStyle = .round
            moduleColor(module).setStroke()
            arcPath.stroke()
        }

        // Label on the left side of the ring
        if isHorizontal {
            drawHorizontalLabel(module.label, x: center.x, y: 1, in: rect, fontSize: circularHorizontalLabelFontSize)
        } else {
            let labelX = center.x - r - strokeInset - gap - labelW
            drawVerticalLabel(module.label, x: labelX, in: rect)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Battery icon
    // -----------------------------------------------------------------------

    /// Native-style battery glyph: rounded body outline with a nub, the
    /// charge level filled inside, and a bolt overlay while charging.
    /// Proportions measured from the native macOS battery icon
    /// (in units of body height): outline 0.11 thick with 0.32 corner
    /// radius, fill corner 0.22, nub 0.49 tall.
    private func drawBatteryIcon(module: Module, in rect: NSRect) {
        let s = batteryIconScale
        let nubW: CGFloat = 2.0 * s
        let nubGap: CGFloat = 1.0 * s
        let bodyW: CGFloat = min(22.5 * s, max(12 * s, rect.width - 6 - nubGap - nubW))
        let bodyH: CGFloat = 10.5 * s
        let totalW = bodyW + nubGap + nubW
        let body = NSRect(x: rect.midX - totalW / 2,
                          y: rect.midY - bodyH / 2,
                          width: bodyW, height: bodyH)

        let outlineColor = NSColor.white.withAlphaComponent(0.55)
        let outline = NSBezierPath(roundedRect: body, xRadius: 3.4 * s, yRadius: 3.4 * s)
        outline.lineWidth = 1.15 * s
        outlineColor.setStroke()
        outline.stroke()

        let nubH: CGFloat = 5.0 * s
        let nub = NSRect(x: body.maxX + nubGap, y: rect.midY - nubH / 2,
                         width: nubW, height: nubH)
        outlineColor.setFill()
        NSBezierPath(roundedRect: nub, xRadius: nubW / 2, yRadius: nubW / 2).fill()

        // Level fill
        let inset: CGFloat = 1.6 * s
        let ratio = max(0, min(1, module.ratio))
        let fillW = (body.width - inset * 2) * ratio
        if fillW > 0.5 {
            let fillRect = NSRect(x: body.minX + inset, y: body.minY + inset,
                                  width: fillW, height: body.height - inset * 2)
            batteryColor(ratio: ratio).setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 2.2 * s, yRadius: 2.2 * s).fill()
        }

        // Bolt while actively charging; plug while connected to power but not
        // charging (full, or paused by Optimized Battery Charging).
        if module.showChargeIcon {
            drawBatteryOverlayIcon("bolt.fill", in: body, scale: s, glyphBox: 14, gap: 1.1)
        } else if module.showPlugIcon {
            // Prongs-up plug like the native icon; the portrait variant needs
            // a newer SF Symbols set, so fall back to the horizontal one.
            let plug = NSImage(systemSymbolName: "powerplug.portrait.fill", accessibilityDescription: nil) != nil
                ? "powerplug.portrait.fill" : "powerplug.fill"
            drawBatteryOverlayIcon(plug, in: body, scale: s, glyphBox: 10, gap: 1.1)
        }
    }

    /// Native-style overlay: the glyph's silhouette, dilated by `gap`, is
    /// punched out of the battery artwork (transparent, so the menu bar
    /// shows through like the system icon), then the glyph is drawn in
    /// white on top.
    private func drawBatteryOverlayIcon(_ symbolName: String, in body: NSRect, scale s: CGFloat,
                                        glyphBox: CGFloat, gap: CGFloat) {
        guard let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 10 * s, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let img = icon.withSymbolConfiguration(cfg) ?? icon

        // Aspect-fit the glyph into the box: draw(in:) would otherwise
        // stretch the taller-than-wide glyphs into fat blobs.
        let natural = img.size
        guard natural.width > 0, natural.height > 0 else { return }
        let k = (glyphBox * s) / max(natural.width, natural.height)
        let glyphRect = NSRect(x: body.midX - natural.width * k / 2,
                               y: body.midY - natural.height * k / 2,
                               width: natural.width * k,
                               height: natural.height * k)

        // Erase the dilated silhouette from the outline/fill underneath
        // (only the image's alpha matters for destinationOut).
        let r = gap * s
        for dx: CGFloat in [-r, 0, r] {
            for dy: CGFloat in [-r, 0, r] {
                img.draw(in: glyphRect.offsetBy(dx: dx, dy: dy),
                         from: .zero, operation: .destinationOut, fraction: 1)
            }
        }
        img.draw(in: glyphRect)
    }

    // -----------------------------------------------------------------------
    // MARK: - Helpers
    // -----------------------------------------------------------------------

    /// Rough width of one character in the vertical label font.
    private func estimatedCharWidth() -> CGFloat {
        let s = "X" as NSString
        return s.size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
        ]).width
    }

    private func estimatedLabelWidth(_ text: String) -> CGFloat {
        let s = text as NSString
        return s.size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: horizontalLabelFontSize, weight: .bold),
        ]).width
    }

    // -----------------------------------------------------------------------
    // MARK: - Labels
    // -----------------------------------------------------------------------

    private func drawVerticalLabel(_ text: String, x: CGFloat, in rect: NSRect) {
        let chars = Array(text)
        let charH = min(fontSize + 1, (rect.height - 2) / CGFloat(max(1, chars.count)))
        let totalH = charH * CGFloat(chars.count)
        let startY = rect.midY + totalH / 2 - charH / 2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
        ]
        for (i, ch) in chars.enumerated() {
            let s = String(ch) as NSString
            let sz = s.size(withAttributes: attrs)
            let cy = startY - CGFloat(i) * charH
            s.draw(at: NSPoint(x: x, y: cy - sz.height / 2), withAttributes: attrs)
        }
    }

    private func drawHorizontalLabel(_ text: String, x: CGFloat, y: CGFloat, in rect: NSRect, fontSize: CGFloat? = nil) {
        let s = text as NSString
        let labelFontSize = fontSize ?? horizontalLabelFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let sz = s.size(withAttributes: attrs)
        let drawY = max(rect.minY + 1, min(y, rect.maxY - sz.height - 1))
        s.draw(at: NSPoint(x: x - sz.width / 2, y: drawY),
               withAttributes: attrs)
    }

    private func drawHorizontalLabelCentered(_ text: String, x: CGFloat, centerY: CGFloat, in rect: NSRect) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: horizontalLabelFontSize, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let sz = s.size(withAttributes: attrs)
        let drawY = max(rect.minY + 1, min(centerY - sz.height / 2, rect.maxY - sz.height - 1))
        s.draw(at: NSPoint(x: x - sz.width / 2, y: drawY),
               withAttributes: attrs)
    }

    // -----------------------------------------------------------------------
    // MARK: - Value drawing (FPS)
    // -----------------------------------------------------------------------

    private func drawValue(module: Module, in rect: NSRect) {
        let valStr = module.valueText as NSString
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueFont,
            .foregroundColor: NSColor.white,
        ]
        let lblStr = module.label as NSString
        let lblAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueLabelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .kern: -0.4,
        ]
        // Unit drawn one size down and aligned to the number's baseline, so it
        // reads as a suffix ("49°", "12%") rather than a second full-size glyph.
        let unitStr = module.unit as NSString
        let hasUnit = !module.unit.isEmpty
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueUnitFont,
            .foregroundColor: NSColor.white,   // match the value's color
        ]

        let valSize = valStr.size(withAttributes: valAttrs)
        let unitSize = hasUnit ? unitStr.size(withAttributes: unitAttrs) : .zero
        let unitGap: CGFloat = hasUnit ? 1.5 : 0
        let numberUnitW = valSize.width + unitGap + unitSize.width

        if module.showChargeIcon {
            let iconSize: CGFloat = 8
            let iconGap: CGFloat = 2
            let totalWidth = numberUnitW + iconGap + iconSize
            let startX = rect.midX - totalWidth / 2
            let valY = rect.midY - valSize.height / 2
            valStr.draw(at: NSPoint(x: startX, y: valY), withAttributes: valAttrs)
            if hasUnit {
                let baseline = valY - Self.valueFont.descender
                unitStr.draw(at: NSPoint(x: startX + valSize.width + unitGap,
                                         y: baseline + Self.valueUnitFont.descender),
                             withAttributes: unitAttrs)
            }

            if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
                let tinted = bolt.withSymbolConfiguration(config) ?? bolt
                let iconRect = NSRect(x: startX + numberUnitW + iconGap,
                                      y: rect.midY - iconSize / 2,
                                      width: iconSize, height: iconSize)
                tinted.draw(in: iconRect)
            }
            return
        }

        let lblSize = lblStr.size(withAttributes: lblAttrs)

        // Lay the number (+ unit) and label out as one block. Center it on the
        // cell using the fonts' cap heights (not their padded glyph boxes, which
        // sink the pair and leave loose leading) and lift it slightly, so the
        // module reads centered against the neighboring gauges.
        let numberFont = Self.valueFont
        let labelFont = Self.valueLabelFont
        let unitFont = Self.valueUnitFont
        let gap: CGFloat = 3.5    // spacing from the number's baseline to the label's cap
        let lift: CGFloat = -1.0  // nudge the whole block (positive = up, negative = down)
        let numberCap = numberFont.capHeight
        let labelCap = labelFont.capHeight

        // Baseline that vertically centers [number cap | gap | label cap], + lift.
        let baseline = rect.midY + lift + (gap + labelCap - numberCap) / 2

        // Center the number + unit together, then hang the label under the pair.
        let startX = rect.midX - numberUnitW / 2
        valStr.draw(at: NSPoint(x: startX, y: baseline + numberFont.descender), withAttributes: valAttrs)
        if hasUnit {
            unitStr.draw(at: NSPoint(x: startX + valSize.width + unitGap,
                                     y: baseline + unitFont.descender),
                         withAttributes: unitAttrs)
        }

        let lblX = rect.midX - lblSize.width / 2
        let lblY = baseline - gap + labelFont.descender - labelCap
        lblStr.draw(at: NSPoint(x: lblX, y: lblY), withAttributes: lblAttrs)
    }

    // -----------------------------------------------------------------------
    // MARK: - Color
    // -----------------------------------------------------------------------

    /// Neutral below 80%, then a smooth yellow→orange→red ramp toward 100%.
    private func barColor(ratio: CGFloat, forceWhite: Bool = false, preferredScale: String? = nil) -> NSColor {
        if forceWhite { return NSColor.white }
        if let warn = loadWarningColor(ratio) { return warn }
        let scale = preferredScale ?? colorScale
        if scale == "green" { return NSColor(hue: 0.34, saturation: 0.62, brightness: 1.0, alpha: 1.0) }
        return NSColor.white
    }

    /// Battery scale is inverted: low charge is the bad end.
    private func batteryColor(ratio: CGFloat) -> NSColor {
        if stats.isLowPowerMode { return NSColor.systemYellow }
        let r = max(0, min(1, ratio))
        if r <= 0.10 { return NSColor(hue: 0.0,  saturation: 0.9, brightness: 0.95, alpha: 1.0) }
        if r <= 0.25 { return NSColor(hue: 0.10, saturation: 0.9, brightness: 0.95, alpha: 1.0) }
        if colorScale == "green" { return NSColor(hue: 0.34, saturation: 0.62, brightness: 1.0, alpha: 1.0) }
        return NSColor.white
    }

    // -----------------------------------------------------------------------
    // MARK: - Modules
    // -----------------------------------------------------------------------

    private struct Module {
        let label: String
        var ratio: CGFloat
        var isValue: Bool = false
        var valueText: String = ""
        /// Unit suffix drawn smaller after the number (e.g. "%", "°", "GB").
        var unit: String = ""
        var forceWhite: Bool = false
        /// Draw a small lightning-bolt icon beside the value instead of the
        /// text label below it — used for the Power module while charging.
        var showChargeIcon: Bool = false
        /// Battery icon style only: plug overlay for "connected, not
        /// charging" (full, or paused by Optimized Battery Charging).
        var showPlugIcon: Bool = false
        /// Overrides the threshold color entirely — used by the battery
        /// module, whose scale is inverted (low charge is the bad end).
        var customColor: NSColor? = nil
        /// Render as a native-style battery glyph (outline + level fill).
        var isBatteryIcon: Bool = false
    }

    private func moduleColor(_ module: Module, preferredScale: String? = nil) -> NSColor {
        if let c = module.customColor { return c }
        return barColor(ratio: module.ratio, forceWhite: module.forceWhite,
                        preferredScale: preferredScale)
    }

    private func activeModules() -> [Module] {
        var mods: [Module] = []
        // Any id missing from moduleOrder falls back to the end in default order.
        let order = moduleOrder + AppSettings.hardwareModuleIDs.filter { !moduleOrder.contains($0) }
        for id in order { appendModule(id, to: &mods) }
        return mods
    }

    /// Appends the module for `id` in render order, if its show-flag is on.
    private func appendModule(_ id: String, to mods: inout [Module]) {
        switch id {
        case "cpu":
            guard showCPU else { return }
            if cpuRaw {
                mods.append(Module(label: "CPU", ratio: 0, isValue: true,
                                   valueText: "\(Int(stats.cpuPercent.rounded()))",
                                   unit: "%", forceWhite: true))
            } else {
                mods.append(Module(label: "CPU",
                                   ratio: CGFloat(min(stats.cpuPercent / 100.0, 1.0))))
            }
        case "gpu":
            guard showGPU else { return }
            if gpuRaw {
                mods.append(Module(label: "GPU", ratio: 0, isValue: true,
                                   valueText: "\(Int(stats.gpuPercent.rounded()))",
                                   unit: "%", forceWhite: true))
            } else {
                mods.append(Module(label: "GPU",
                                   ratio: CGFloat(min(stats.gpuPercent / 100.0, 1.0))))
            }
        case "memory":
            guard showMemory else { return }
            let memMode = AppSettings.shared.hardwareStatsMemMode
            if memoryRaw {
                let valueText = memMode == "usage"
                    ? String(format: "%.1f", stats.memoryUsedGB)
                    : stats.memoryPressure.rawValue
                mods.append(Module(label: "MEM", ratio: 0, isValue: true,
                                   valueText: valueText,
                                   unit: memMode == "usage" ? "GB" : "",
                                   forceWhite: true))
            } else {
                let memRatio: CGFloat
                if memMode == "usage" {
                    memRatio = stats.memoryTotalGB > 0
                        ? CGFloat(min(1.0, stats.memoryUsedGB / stats.memoryTotalGB))
                        : 0
                } else {
                    memRatio = {
                        switch stats.memoryPressure {
                        case .normal:  return 0.25
                        case .warning: return 0.60
                        case .critical: return 0.90
                        }
                    }()
                }
                mods.append(Module(label: "MEM", ratio: memRatio))
            }
        case "temp":
            guard showTemp else { return }
            let sensor = AppSettings.shared.hardwareStatsTempSensor
            let t: Double
            switch sensor {
            case "cpu":  t = stats.cpuTemp ?? 30
            case "gpu":  t = stats.gpuTemp ?? 30
            default:     t = stats.cpuTemp ?? stats.gpuTemp ?? 30
            }
            if tempRaw {
                mods.append(Module(label: "TMP", ratio: 0, isValue: true,
                                   valueText: "\(Int(t.rounded()))", unit: "°C", forceWhite: true))
            } else {
                let minT = AppSettings.shared.hardwareStatsTempMin
                let maxT = AppSettings.shared.hardwareStatsTempMax
                let range = max(1.0, maxT - minT)
                let tempRatio = CGFloat(max(0, min(1, (t - minT) / range)))
                mods.append(Module(label: "TMP", ratio: tempRatio))
            }
        case "fan":
            guard showFan else { return }
            if fanRaw {
                let valueText = stats.fans.first.map { "\($0.current)" } ?? "—"
                mods.append(Module(label: "FAN", ratio: 0, isValue: true,
                                   valueText: valueText, unit: "rpm", forceWhite: true))
            } else if let fan = stats.fans.first {
                let fanRatio = CGFloat(fan.current) / CGFloat(max(1, fan.max))
                mods.append(Module(label: "FAN", ratio: fanRatio))
            } else {
                mods.append(Module(label: "FAN", ratio: 0, forceWhite: true))
            }
        case "power":
            guard showPower else { return }
            if powerRaw {
                let valueText = stats.powerWatts.map { "\(Int($0.rounded()))" } ?? "—"
                mods.append(Module(label: "PWR", ratio: 0, isValue: true,
                                   valueText: valueText, unit: "W", forceWhite: true,
                                   showChargeIcon: stats.isCharging == true))
            } else if let watts = stats.powerWatts {
                let powerRatio = CGFloat(max(0, min(1, watts / HardwareMonitor.modelMaxChargeWatts)))
                mods.append(Module(label: "PWR", ratio: powerRatio))
            } else {
                mods.append(Module(label: "PWR", ratio: 0, forceWhite: true))
            }
        case "battery":
            guard showBattery else { return }
            if batteryStyle == "number" {
                let valueText = stats.batteryPercentText(includeSymbol: false) ?? "—"
                mods.append(Module(label: "BAT", ratio: 0, isValue: true,
                                   valueText: valueText, unit: "%", forceWhite: true))
            } else if batteryStyle == "icon" {
                let ratio = CGFloat(stats.batteryPercent ?? 0) / 100.0
                mods.append(Module(label: "BAT", ratio: ratio,
                                   showChargeIcon: stats.isCharging == true,
                                   showPlugIcon: stats.isCharging == false && stats.adapterWatts != nil,
                                   isBatteryIcon: true))
            } else if let pct = stats.batteryPercent {
                let ratio = CGFloat(pct) / 100.0
                mods.append(Module(label: "BAT", ratio: ratio,
                                   customColor: batteryColor(ratio: ratio)))
            } else {
                mods.append(Module(label: "BAT", ratio: 0, forceWhite: true))
            }
        case "fps":
            guard showFPS else { return }
            mods.append(Module(label: "FPS", ratio: 0,
                               isValue: true, valueText: "\(stats.fps)",
                               forceWhite: true))
        default:
            break
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Size
    // -----------------------------------------------------------------------

    override var intrinsicContentSize: NSSize {
        let modules = activeModules()
        let count = max(1, modules.count)

        // Solo battery-icon module needs extra width to fit the scaled glyph
        // beyond what the generic per-module formula below would allot.
        if count == 1, let m = modules.first, m.isBatteryIcon, batteryIconScale > 1.0 {
            let s = batteryIconScale
            let bodyCap = 22.5 * s
            let nubW = 2.0 * s
            let nubGap = 1.0 * s
            let width = bodyCap + nubGap + nubW + 6 + 4 + leftPadding
            return NSSize(width: width, height: 22)
        }

        var perModule: CGFloat
        switch barStyle {
        case "circular":
            perModule = labelPosition == "horizontal" ? 24 : circularVerticalModuleW
        case "horizontal":
            perModule = labelPosition == "horizontal" ? 36 : 46
        case "dot":
            perModule = labelPosition == "horizontal" ? 18 : 24
        default:
            perModule = labelPosition == "horizontal" ? 16 : 20
        }
        // A number-style module with a unit suffix (e.g. "2000rpm") can exceed
        // the fixed slot. draw(_:) splits the width into equal slices, so widen
        // every column to the widest value module to guarantee nothing clips.
        for m in modules where m.isValue {
            perModule = max(perModule, valueModuleWidth(m))
        }
        return NSSize(width: perModule * CGFloat(count) + 4 + leftPadding, height: 22)
    }

    /// Rendered width of a number-style module (number + unit suffix + any
    /// charge icon), plus a little side padding.
    private func valueModuleWidth(_ m: Module) -> CGFloat {
        var w = (m.valueText as NSString).size(withAttributes: [.font: Self.valueFont]).width
        if !m.unit.isEmpty {
            w += 1.5 + (m.unit as NSString).size(withAttributes: [.font: Self.valueUnitFont]).width
        }
        if m.showChargeIcon { w += 2 + 8 }   // icon gap + icon
        return w + 6
    }

    func updateSize() {
        frame.size = intrinsicContentSize
        if let btn = superview as? NSStatusBarButton {
            btn.frame = frame
        }
    }

    func renderedImage() -> NSImage {
        let size = intrinsicContentSize
        frame.size = size
        return NSImage(size: size, flipped: false) { _ in
            self.draw(self.bounds)
            return true
        }
    }
}

// ---------------------------------------------------------------------------
// PopoverShellView — the popover's entire visual shell as one continuous
// piece: rounded body + arrow (HIG: "popover arrow"; AppKit internally calls
// it the anchor — see NSPopover's shouldHideAnchor) traced as a single
// outline, with one vibrancy layer and one hairline stroke. A real NSPopover
// draws this as one shape via its private _NSPopoverFrame; drawing the body
// and arrow as two separate pieces leaves the body's own top edge/stroke
// showing as a flat seam across the arrow's base, so both live on one path.
// ---------------------------------------------------------------------------

private final class PopoverShellView: NSView {
    private let effect = NSVisualEffectView()
    /// Solid stand-in for `effect`/`glassEffect` when the user has Reduce
    /// Transparency on — System Settings ▸ Accessibility ▸ Display.
    private let opaqueBacking = NSView()
    /// Liquid Glass surface (macOS 26+), swapped in for `effect` so the
    /// popover matches the system's own Clear/Tinted glass style instead of
    /// looking frozen in the pre-26 vibrancy look.
    private var glassEffect: NSView?
    private let maskLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private let cornerRadius: CGFloat
    private let arrowWidth: CGFloat
    private let arrowHeight: CGFloat

    /// Horizontal center of the arrow, in this view's own bounds.
    var arrowCenterX: CGFloat {
        didSet { needsLayout = true }
    }

    init(cornerRadius: CGFloat, arrowWidth: CGFloat, arrowHeight: CGFloat) {
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.arrowCenterX = 0
        super.init(frame: .zero)
        wantsLayer = true

        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        opaqueBacking.wantsLayer = true
        opaqueBacking.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        opaqueBacking.autoresizingMask = [.width, .height]
        opaqueBacking.isHidden = true
        addSubview(opaqueBacking)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.wantsLayer = true
            glass.autoresizingMask = [.width, .height]
            glass.isHidden = true
            addSubview(glass)
            glassEffect = glass
        }

        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        strokeLayer.lineWidth = 0.5
        layer?.addSublayer(strokeLayer)

        refreshAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance),
                                                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                object: NSWorkspace.shared)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Re-reads Reduce Transparency and the system's Liquid Glass tint style
    /// (Clear/Tinted) and picks the matching surface. Reduce Transparency is
    /// pushed live via notification; the tint style has no public change
    /// notification, so callers also invoke this each time the popover opens.
    @objc func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        opaqueBacking.isHidden = !reduceTransparency
        if #available(macOS 26.0, *), let glass = glassEffect as? NSGlassEffectView {
            glass.isHidden = reduceTransparency
            effect.isHidden = true
            glass.style = UserDefaults.standard.bool(forKey: "AppleReduceDesktopTinting") ? .clear : .regular
        } else {
            effect.isHidden = reduceTransparency
        }
        needsLayout = true
    }

    /// Whichever surface is currently visible — the one that owns the mask.
    private var activeSurfaceLayer: CALayer? {
        if !opaqueBacking.isHidden { return opaqueBacking.layer }
        if let glass = glassEffect, !glass.isHidden { return glass.layer }
        return effect.layer
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        opaqueBacking.frame = bounds
        glassEffect?.frame = bounds
        let path = Self.shellPath(size: bounds.size, radius: cornerRadius,
                                   arrowWidth: arrowWidth, arrowHeight: arrowHeight,
                                   arrowCenterX: arrowCenterX)
        // The window frame animation (popover resize) already interpolates
        // bounds smoothly; letting these layers pick up their own implicit
        // path animation on top of that makes the mask chase a moving
        // target and lag/wobble behind it. Snap them to the current bounds
        // every frame instead.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        maskLayer.frame = bounds
        activeSurfaceLayer?.mask = maskLayer
        strokeLayer.path = path
        strokeLayer.frame = bounds
        CATransaction.commit()
    }

    /// Rounded-rect body with the arrow notch cut directly into its top
    /// edge, built from true circular corner arcs (never Apple's
    /// "continuous" squircle curve, which would leave an uneven gap against
    /// the real menu-bar/status-item chrome this popover sits under).
    private static func shellPath(size: CGSize, radius r: CGFloat,
                                   arrowWidth: CGFloat, arrowHeight: CGFloat,
                                   arrowCenterX: CGFloat) -> CGPath {
        let minX: CGFloat = 0, minY: CGFloat = 0, maxX = size.width
        let bodyTop = size.height - arrowHeight
        let arrowLeftX = arrowCenterX - arrowWidth / 2
        let arrowRightX = arrowCenterX + arrowWidth / 2
        // Soft anchor like the native popover: rounded apex, and concave
        // fillets where the arrow's slopes flare into the body's top edge.
        let tipRadius: CGFloat = 3.5
        let baseRadius: CGFloat = 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + r, y: bodyTop))
        path.addArc(tangent1End: CGPoint(x: arrowLeftX, y: bodyTop),
                    tangent2End: CGPoint(x: arrowCenterX, y: size.height), radius: baseRadius)
        path.addArc(tangent1End: CGPoint(x: arrowCenterX, y: size.height),
                    tangent2End: CGPoint(x: arrowRightX, y: bodyTop), radius: tipRadius)
        path.addArc(tangent1End: CGPoint(x: arrowRightX, y: bodyTop),
                    tangent2End: CGPoint(x: maxX - r, y: bodyTop), radius: baseRadius)
        path.addLine(to: CGPoint(x: maxX - r, y: bodyTop))
        path.addArc(tangent1End: CGPoint(x: maxX, y: bodyTop),
                    tangent2End: CGPoint(x: maxX, y: bodyTop - r), radius: r)
        path.addLine(to: CGPoint(x: maxX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                    tangent2End: CGPoint(x: maxX - r, y: minY), radius: r)
        path.addLine(to: CGPoint(x: minX + r, y: minY))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY),
                    tangent2End: CGPoint(x: minX, y: minY + r), radius: r)
        path.addLine(to: CGPoint(x: minX, y: bodyTop - r))
        path.addArc(tangent1End: CGPoint(x: minX, y: bodyTop),
                    tangent2End: CGPoint(x: minX + r, y: bodyTop), radius: r)
        path.closeSubpath()
        return path
    }
}

// ---------------------------------------------------------------------------
// HardwarePopover — detailed stats shown on click
// ---------------------------------------------------------------------------

final class HardwarePopover: NSObject {
    private let window: NSWindow
    private let root: NSView
    private let stack: NSStackView
    private var pollTimer: Timer?
    private var resizeTimer: Timer?
    private var closeMonitor: Any?
    private weak var sourceButton: NSStatusBarButton?
    private var menuTrackingCount = 0
    private var menuTrackingObservers: [NSObjectProtocol] = []

    private let energySampler = EnergyAppSampler()
    private var energyApps: [EnergyAppSampler.SignificantApp] = []
    private lazy var energyList = EnergyAppsListView(rowWidth: contentWidth - 20)
    private var energyModes = HardwareMonitor.EnergyModes()

    /// Last ratio drawn for each stat card, keyed by card id. Cards are
    /// recreated from scratch every rebuild, so this is what lets a fresh
    /// MiniBarView ease from the old value instead of snapping to the new one.
    private var lastBarRatios: [String: CGFloat] = [:]
    /// Last watt figure shown in the battery card, so a fresh AnimatedValueField
    /// can ease from it instead of snapping (same reasoning as lastBarRatios).
    private var lastPowerWatts: Double?

    private let popWidth: CGFloat = 248
    /// Width available to content between the stack's edge insets.
    private var contentWidth: CGFloat { popWidth - gutter * 2 }

    /// Corner radius of the shell; the gutter below is subtracted from this
    /// to get each card's own radius, so every card corner is concentric
    /// with the shell corner around it (inner = outer − gutter).
    private let shellRadius: CGFloat = 20
    private let gutter: CGFloat = 8
    private var cardCornerRadius: CGFloat { max(0, shellRadius - gutter) }
    private let arrowWidth: CGFloat = 16
    private let arrowHeight: CGFloat = 8
    private let shell: PopoverShellView

    /// When the battery module has its own dedicated status item, its card
    /// is dropped from this popover to avoid showing it twice.
    var hidesBatteryCard: Bool = false

    var isShown: Bool { window.isVisible }

    override init() {
        root = NSView(frame: NSRect(x: 0, y: 0, width: popWidth, height: 200))

        // Shell matching MusicPopover's card language: body, arrow, and
        // vibrancy are one continuous piece (see PopoverShellView), same as
        // a real NSPopover's own frame chrome.
        shell = PopoverShellView(cornerRadius: shellRadius, arrowWidth: arrowWidth, arrowHeight: arrowHeight)
        shell.frame = root.bounds
        shell.autoresizingMask = [.width, .height]
        root.addSubview(shell)

        stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: gutter, bottom: 8, right: gutter)
        root.addSubview(stack)

        // Pin the stack below the arrow strip so content never clips and the
        // view's fittingSize reflects the stack's intrinsic height.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: arrowHeight),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window = NSWindow(contentRect: root.frame,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        window.contentView = root

        super.init()

        // Track open menus (the fan preset picker) so the 1s refresh doesn't
        // rebuild the row views and yank the control out from under the user.
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.menuTrackingCount += 1 })
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.menuTrackingCount = max(0, self.menuTrackingCount - 1)
        })
    }

    deinit {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        sourceButton = button
        // The tint style (Clear/Tinted) has no public change notification,
        // so pick it up fresh on every open rather than only at popover
        // creation time.
        shell.refreshAppearance()
        // Keep showing whatever energyApps last held (from the previous time
        // this popover was open) instead of blanking to empty — resetting
        // the sampler still means the *next* reading is measured fresh from
        // now, but the list doesn't need to sit empty for a second while
        // waiting for it.
        energySampler.reset()
        _ = energySampler.sample()   // baseline; real values from the next tick
        refreshEnergyModes()
        rebuild()

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        // The button's own bounds can be taller than the menu bar's visual
        // content (macOS pads status items to clear notch camera housing),
        // so anchor from the top edge minus the standard thickness instead
        // of the bottom edge — otherwise the popover floats well below the icon.
        let menuBarBottom = screenRect.maxY - NSStatusBar.system.thickness
        var origin = NSPoint(x: screenRect.midX - window.frame.width / 2,
                             y: menuBarBottom - window.frame.height - 4)
        if let screen = button.window?.screen {
            let vf = screen.visibleFrame
            if origin.x + window.frame.width > vf.maxX { origin.x = vf.maxX - window.frame.width - 4 }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
        }

        // Point the arrow at the button's horizontal center, clamped clear
        // of the rounded corners.
        let minCenter = 16 + arrowWidth / 2
        let maxCenter = popWidth - 16 - arrowWidth / 2
        let wanted = screenRect.midX - origin.x
        shell.arrowCenterX = max(minCenter, min(maxCenter, wanted))
        shell.layoutSubtreeIfNeeded()

        window.setFrameOrigin(origin)
        window.orderFront(nil)

        if closeMonitor == nil {
            closeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, self.window.isVisible else { return }
                let loc = NSEvent.mouseLocation
                if self.window.frame.contains(loc) { return }
                if let btn = self.sourceButton {
                    let btnScreen = btn.window?.convertToScreen(btn.convert(btn.bounds, to: nil)) ?? .zero
                    if btnScreen.contains(loc) { return }
                }
                self.close()
            }
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshValues()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }

        // The sampler needs some elapsed wall time to compute a fresh delta;
        // 150ms clears its internal 100ms floor, so a currently-heavy app
        // shows up almost immediately instead of after the first full
        // 1-second poll tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.refreshValues()
        }
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        resizeTimer?.invalidate(); resizeTimer = nil
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        window.orderOut(nil)
    }

    // Rebuild the whole layout (structure may change: fans appear/disappear).
    private func rebuild() {
        let s = HardwareMonitor.shared.stats
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Popover cards can be hidden per module (Settings ▸ Hardware ▸ Order).
        let hidden = Set(AppSettings.shared.hardwareStatsHiddenCards)

        let showsBatteryCard = s.batteryPercent != nil && !hidesBatteryCard && !hidden.contains("battery")
        if showsBatteryCard {
            let batteryCard = makeBatteryCard(s)
            stack.addArrangedSubview(batteryCard)
            batteryCard.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }

        // Collect the half-width cards that are enabled, then flow them into
        // rows of two. Power is a standalone card only when there's no battery
        // card (otherwise its wattage lives inside the battery card).
        var halfCards: [NSView] = []

        if !hidden.contains("cpu") {
            let ratio = CGFloat(min(s.cpuPercent / 100.0, 1.0))
            halfCards.append(StatCard(caption: "CPU",
                                      value: String(format: "%.1f%%", s.cpuPercent),
                                      barRatio: ratio,
                                      previousBarRatio: lastBarRatios["cpu"],
                                      cornerRadius: cardCornerRadius))
            lastBarRatios["cpu"] = ratio
        }
        if !hidden.contains("gpu") {
            let ratio = CGFloat(min(s.gpuPercent / 100.0, 1.0))
            halfCards.append(StatCard(caption: "GPU",
                                      value: String(format: "%.1f%%", s.gpuPercent),
                                      barRatio: ratio,
                                      previousBarRatio: lastBarRatios["gpu"],
                                      cornerRadius: cardCornerRadius))
            lastBarRatios["gpu"] = ratio
        }
        if !hidden.contains("memory") {
            let pressure: (pct: Int, ratio: CGFloat) = {
                switch s.memoryPressure {
                case .normal:   return (25, 0.25)
                case .warning:  return (60, 0.60)
                case .critical: return (90, 0.90)
                }
            }()
            halfCards.append(StatCard(caption: "MEM",
                                      captionDetail: String(format: "%.1f GB", s.memoryUsedGB),
                                      value: "\(pressure.pct)%",
                                      barRatio: pressure.ratio,
                                      previousBarRatio: lastBarRatios["memory"],
                                      cornerRadius: cardCornerRadius))
            lastBarRatios["memory"] = pressure.ratio
        }
        if !hidden.contains("temp") {
            let t = s.cpuTemp ?? s.gpuTemp
            let minT = AppSettings.shared.hardwareStatsTempMin
            let maxT = AppSettings.shared.hardwareStatsTempMax
            let tempRatio = t.map { CGFloat(max(0, min(1, ($0 - minT) / max(1.0, maxT - minT)))) }
            halfCards.append(StatCard(caption: "TEMP",
                                      value: t.map { String(format: "%.0f°C", $0) } ?? "—",
                                      barRatio: tempRatio,
                                      previousBarRatio: tempRatio != nil ? lastBarRatios["temp"] : nil,
                                      cornerRadius: cardCornerRadius))
            if let tempRatio {
                lastBarRatios["temp"] = tempRatio
            } else {
                lastBarRatios.removeValue(forKey: "temp")
            }
        }
        if !showsBatteryCard && !hidden.contains("power") {
            let powerCaption: String
            switch s.isCharging {
            case .some(true):  powerCaption = "CHARGING"
            case .some(false): powerCaption = "DISCHARGING"
            case .none:        powerCaption = "POWER"
            }
            halfCards.append(StatCard(caption: powerCaption,
                                      value: s.powerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                                      detail: s.adapterWatts.map { "\($0)W adapter" },
                                      showsBolt: s.isCharging == true,
                                      cornerRadius: cardCornerRadius))
        }
        if !hidden.contains("fps") {
            halfCards.append(StatCard(caption: "FPS", value: "\(s.fps)", detail: "frames per second",
                                      cornerRadius: cardCornerRadius))
        }

        var idx = 0
        while idx < halfCards.count {
            let end = min(idx + 2, halfCards.count)
            addCardRow(Array(halfCards[idx..<end]))
            idx = end
        }

        if !s.fans.isEmpty && !hidden.contains("fan") {
            let fansCard = makeFansCard(s.fans)
            stack.addArrangedSubview(fansCard)
            fansCard.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }

        let settingsRow = PopoverActionRow(title: "Settings") { [weak self] in
            self?.openSettings()
        }
        stack.addArrangedSubview(settingsRow)
        settingsRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        resizeWindow()
    }

    /// Adds one row of equal-width stat cards to the vertical stack.
    private func addCardRow(_ cards: [NSView]) {
        let row = NSStackView(views: cards)
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    }

    /// Full-width card holding per-fan readings and the preset picker.
    private func makeFansCard(_ fans: [FanInfo]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.cornerRadius = cardCornerRadius
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        card.layer?.borderWidth = 1

        let inner = NSStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 5
        inner.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let rowWidth = contentWidth - 20

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = StatCard.captionString("FANS")
        inner.addArrangedSubview(caption)
        inner.setCustomSpacing(7, after: caption)

        for f in fans {
            let ratio = f.max > 0 ? CGFloat(f.current) / CGFloat(f.max) : 0

            let name = NSTextField(labelWithString: f.name)
            name.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            name.textColor = .labelColor
            name.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let value = NSTextField(labelWithString: "\(f.current) RPM · \(Int(ratio * 100))%")
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            // Flexible spacer pins the value flush to the row's right edge,
            // same trick used in the battery card.
            let valueSpacer = NSView()
            valueSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            let row = NSStackView(views: [name, valueSpacer, value])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .firstBaseline
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

            let bar = MiniBarView()
            bar.ratio = ratio
            bar.fillColor = statThresholdColor(ratio)
            bar.translatesAutoresizingMaskIntoConstraints = false
            inner.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
            inner.setCustomSpacing(8, after: bar)
        }

        let presetLabel = NSTextField(labelWithString: "Preset")
        presetLabel.font = NSFont.systemFont(ofSize: 10)
        presetLabel.textColor = .secondaryLabelColor
        presetLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Flexible spacer pins the picker flush to the row's right edge.
        let presetSpacer = NSView()
        presetSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let presetBtn = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 20), pullsDown: false)
        let presetTitles = ["silent": "Silent", "default": "Default", "performance": "Performance"]
        presetBtn.addItems(withTitles: ["Silent", "Default", "Performance"])
        if let title = presetTitles[AppSettings.shared.hardwareStatsFanPreset] {
            presetBtn.selectItem(withTitle: title)
        }
        presetBtn.target = self
        presetBtn.action = #selector(presetChanged(_:))
        presetBtn.controlSize = .small
        presetBtn.font = NSFont.systemFont(ofSize: 10)

        let presetRow = NSStackView(views: [presetLabel, presetSpacer, presetBtn])
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.alignment = .centerY
        inner.addArrangedSubview(presetRow)
        presetRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        return card
    }

    /// Full-width battery card: charge level, energy-mode picker, and the
    /// approximated "apps using significant energy" list.
    private func makeBatteryCard(_ s: HardwareStats) -> NSView {
        let card = makeBatteryDetailCard(stats: s, contentWidth: contentWidth,
                              cornerRadius: cardCornerRadius,
                              energyModes: energyModes, energyAppsView: energyList,
                              previousPowerWatts: lastPowerWatts) { [weak self] mode in
            self?.selectEnergyMode(mode)
        }
        lastPowerWatts = s.powerWatts
        return card
    }

    private func openSettings() {
        close()
        if #available(macOS 14.0, *) {
            SettingsWindowController.shared.show(pane: .hardware)
        }
    }

    private func refreshValues() {
        guard menuTrackingCount == 0 else { return }
        let sampledApps = energySampler.sample()
        let energyNamesChanged = sampledApps.map(\.name) != energyApps.map(\.name)
        energyApps = sampledApps

        if energyNamesChanged {
            energyList.setApps(sampledApps, animated: true) { [weak self] in
                self?.resizeWindow(animated: true)
            }
            return
        }

        rebuild()
        energyList.setApps(sampledApps, animated: false) { [weak self] in
            self?.resizeWindow(animated: true)
        }
    }

    /// Re-reads pmset's powermode values off-main and repaints when they land.
    private func refreshEnergyModes() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let modes = HardwareMonitor.readEnergyModes()
            DispatchQueue.main.async {
                guard let self else { return }
                self.energyModes = modes
                if self.window.isVisible, self.menuTrackingCount == 0 { self.rebuild() }
            }
        }
    }

    private func selectEnergyMode(_ mode: Int) {
        // Optimistic repaint; the pmset re-read after the helper call is the
        // source of truth (and reverts the chips if the write failed).
        energyModes.battery = mode
        energyModes.ac = mode
        rebuild()
        HardwareMonitor.shared.setEnergyMode(mode) { [weak self] _ in
            self?.refreshEnergyModes()
        }
    }

    private func resizeWindow(animated: Bool = false) {
        stack.layoutSubtreeIfNeeded()
        let h = max(60, stack.fittingSize.height) + arrowHeight
        let lockedTopY = window.frame.maxY
        let newFrame = NSRect(x: window.frame.minX,
                              y: lockedTopY - h,   // keep arrow/top fixed; extend from the bottom
                              width: popWidth, height: h)
        if animated {
            animateWindowHeight(to: h, lockedTopY: lockedTopY)
        } else {
            resizeTimer?.invalidate(); resizeTimer = nil
            window.setFrame(newFrame, display: true, animate: false)
        }
    }

    private func animateWindowHeight(to targetHeight: CGFloat, lockedTopY: CGFloat) {
        resizeTimer?.invalidate()

        let startHeight = window.frame.height
        let delta = targetHeight - startHeight
        guard abs(delta) > 0.5 else {
            window.setFrame(NSRect(x: window.frame.minX, y: lockedTopY - targetHeight,
                                   width: popWidth, height: targetHeight),
                            display: true, animate: false)
            return
        }

        let start = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.18
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - start
            let p = max(0, min(1, CGFloat(elapsed / duration)))
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            let height = startHeight + delta * eased
            self.window.setFrame(NSRect(x: self.window.frame.minX,
                                        y: lockedTopY - height,
                                        width: self.popWidth,
                                        height: height),
                                 display: true, animate: false)
            if p >= 1 {
                timer.invalidate()
                if self.resizeTimer === timer { self.resizeTimer = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let map = ["Default": "default", "Silent": "silent", "Performance": "performance"]
        guard let title = sender.selectedItem?.title,
              let preset = map[title] else { return }
        AppSettings.shared.hardwareStatsFanPreset = preset
        HardwareMonitor.shared.applySelectedFanPresetFromUser()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuild()
        }
    }

}

// ---------------------------------------------------------------------------
// StatCard — rounded metric card used by HardwarePopover
// ---------------------------------------------------------------------------

/// One metric as a card: dim uppercase caption, large value, and either a
/// thin threshold-tinted bar or a footnote line at the bottom.
private final class StatCard: NSView {

    init(caption: String,
         captionDetail: String? = nil,
         captionDetailColor: NSColor? = nil,
         value: String,
         detail: String? = nil,
         barRatio: CGFloat? = nil,
         previousBarRatio: CGFloat? = nil,
         showsBolt: Bool = false,
         cornerRadius: CGFloat = 8) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        layer?.borderWidth = 1

        let captionLabel = NSTextField(labelWithString: "")
        captionLabel.attributedStringValue = Self.captionString(caption)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 62),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            valueLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        if let captionDetail {
            let cd = NSTextField(labelWithString: captionDetail)
            cd.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            cd.textColor = captionDetailColor ?? .tertiaryLabelColor
            cd.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cd)
            NSLayoutConstraint.activate([
                cd.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),
                cd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: cd.leadingAnchor, constant: -6),
            ])
        } else {
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10).isActive = true
        }

        if showsBolt, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Charging") {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            let iv = NSImageView(image: bolt.withSymbolConfiguration(config) ?? bolt)
            iv.contentTintColor = .systemGreen
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 3),
                iv.centerYAnchor.constraint(equalTo: valueLabel.centerYAnchor),
            ])
        }

        if let barRatio {
            let bar = MiniBarView()
            bar.ratio = barRatio
            bar.fillColor = statThresholdColor(barRatio)
            if let previousBarRatio {
                bar.animateRatio(from: previousBarRatio)
            }
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                bar.heightAnchor.constraint(equalToConstant: 3),
            ])
        } else if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = NSFont.systemFont(ofSize: 9)
            d.textColor = .tertiaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            d.translatesAutoresizingMaskIntoConstraints = false
            addSubview(d)
            NSLayoutConstraint.activate([
                d.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                d.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                d.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Shared caption styling so the fans card header matches the stat cards.
    static func captionString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.5,
        ])
    }
}

// ---------------------------------------------------------------------------
// MiniBarView — thin rounded progress bar inside a card
// ---------------------------------------------------------------------------

private final class MiniBarView: NSView {
    var ratio: CGFloat = 0 {
        didSet {
            displayedRatio = ratio
            needsDisplay = true
        }
    }
    var fillColor: NSColor = .white
    /// Position (0…1) of a vertical marker tick drawn across the full view
    /// height — used by the battery bar to show the charge limit. nil = none.
    var limitRatio: CGFloat? = nil
    /// Track/fill thickness. nil fills the whole view height (the stat cards).
    /// The battery bar makes the view taller than the track so the limit tick
    /// can protrude above and below it.
    var trackThickness: CGFloat? = nil

    /// Value actually painted; eased toward `ratio` by `animateRatio(from:)`.
    /// Stat cards are torn down and rebuilt every poll, so without this the
    /// fill would jump straight to each new reading instead of easing.
    private var displayedRatio: CGFloat = 0
    private var animStartRatio: CGFloat = 0
    private var animTargetRatio: CGFloat = 0
    private var animStartTime: CFTimeInterval = 0
    private var animTimer: Timer?
    private let animDuration: CFTimeInterval = 0.35

    deinit { animTimer?.invalidate() }

    /// Eases the fill from `start` to the already-assigned `ratio`. Callers
    /// track the previous card's ratio across rebuilds and pass it in here.
    func animateRatio(from start: CGFloat) {
        animTimer?.invalidate()
        guard abs(start - ratio) > 0.001 else {
            displayedRatio = ratio
            needsDisplay = true
            return
        }
        displayedRatio = start
        animStartRatio = start
        animTargetRatio = ratio
        animStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.stepAnimation(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stepAnimation(_ timer: Timer) {
        let elapsed = CACurrentMediaTime() - animStartTime
        let progress = max(0, min(1, CGFloat(elapsed / animDuration)))
        displayedRatio = animStartRatio + (animTargetRatio - animStartRatio) * Easing.outQuart(progress)
        needsDisplay = true
        if progress >= 1 {
            timer.invalidate()
            if animTimer === timer { animTimer = nil }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let th = trackThickness ?? bounds.height
        let trackY = (bounds.height - th) / 2
        let r = th / 2
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: trackY, width: bounds.width, height: th),
                     xRadius: r, yRadius: r).fill()

        let clamped = max(0, min(1, displayedRatio))
        if clamped > 0.001 {
            let w = max(th, bounds.width * clamped)
            fillColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: trackY, width: w, height: th),
                         xRadius: r, yRadius: r).fill()
        }

        // Charge-limit tick: a full-height marker with a soft dark halo so it
        // stays legible over both the (possibly white) fill and the faint
        // track behind it.
        if let lr = limitRatio, lr > 0.001, lr < 0.999 {
            let tickW: CGFloat = 1.6
            let x = min(bounds.maxX - tickW, max(0, bounds.width * lr - tickW / 2))
            let tick = NSRect(x: x, y: 0, width: tickW, height: bounds.height)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: tick.insetBy(dx: -0.6, dy: 0), xRadius: 1.1, yRadius: 1.1).fill()
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: tick, xRadius: tickW / 2, yRadius: tickW / 2).fill()
        }
    }
}

// ---------------------------------------------------------------------------
// AnimatedValueField — text field that ticks straight to each new reading
// ---------------------------------------------------------------------------

/// A label that changes in one discrete tick per reading — old value out, new
/// value in, no counting through intermediate numbers and no slide. The
/// `previous` parameter is kept so callers keep tracking the last reading
/// (see lastPowerWatts) and other transition styles stay easy to try here.
private final class AnimatedValueField: NSTextField {
    func configure(value: Double, previous: Double?, format: (Double) -> String) {
        stringValue = format(value)
    }
}

/// Load-warning ramp shared by the menu-bar gauges and the popover mini bars.
/// Neutral below 80%, then hue is interpolated continuously so the color eases
/// through the range instead of snapping: yellow at 0.80, orange at 0.90, red at
/// 1.00. Returns nil below the threshold so the caller supplies its own base.
private func loadWarningColor(_ ratio: CGFloat) -> NSColor? {
    let r = max(0, min(1, ratio))
    guard r >= 0.8 else { return nil }
    let yellow: CGFloat = 0.15, orange: CGFloat = 0.083, red: CGFloat = 0.0
    let hue: CGFloat = r < 0.9
        ? yellow + (orange - yellow) * (r - 0.8) / 0.1
        : orange + (red - orange) * (r - 0.9) / 0.1
    return NSColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1.0)
}

/// Same ramp as the gauges, but resting on a translucent-white base.
private func statThresholdColor(_ ratio: CGFloat) -> NSColor {
    loadWarningColor(ratio) ?? NSColor.white.withAlphaComponent(0.85)
}

/// Battery scale is inverted: low charge is the bad end.
private func batteryLevelColor(_ ratio: CGFloat) -> NSColor {
    let r = max(0, min(1, ratio))
    if r <= 0.10 { return NSColor(hue: 0.0,  saturation: 0.9, brightness: 0.95, alpha: 1.0) }
    if r <= 0.25 { return NSColor(hue: 0.10, saturation: 0.9, brightness: 0.95, alpha: 1.0) }
    return NSColor.white.withAlphaComponent(0.85)
}

// ---------------------------------------------------------------------------
// EnergyModeChip — selectable Automatic / Low Power / High Power pill
// ---------------------------------------------------------------------------

private final class EnergyModeChip: NSView {
    private let onSelect: () -> Void
    private let isSelected: Bool
    private let background = CALayer()
    private var trackingArea: NSTrackingArea?

    private var restColor: CGColor {
        isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
            : NSColor.white.withAlphaComponent(0.05).cgColor
    }

    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        background.backgroundColor = restColor
        background.cornerRadius = 7
        layer?.addSublayer(background)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10, weight: isSelected ? .semibold : .medium)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if !isSelected { background.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        background.backgroundColor = restColor
    }

    override func mouseDown(with event: NSEvent) {
        if !isSelected { onSelect() }
    }
}

// ---------------------------------------------------------------------------
// PopoverActionRow — flat, icon-led action row with a hover highlight
// ---------------------------------------------------------------------------

/// A borderless "navigate elsewhere" row (centered label) used in place of a
/// stock NSButton bezel, which reads as an OS dialog control rather than
/// part of the popover's own flat surface.
final class PopoverActionRow: NSView {
    private let onActivate: () -> Void
    private let background = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    private static let restColor = NSColor.clear.cgColor
    private static let hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor

    init(title: String, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)

        wantsLayer = true
        background.backgroundColor = Self.restColor
        background.cornerRadius = 6
        layer?.addSublayer(background)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),

            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func layout() {
        super.layout()
        background.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        background.backgroundColor = Self.hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        background.backgroundColor = Self.restColor
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }
}

// ---------------------------------------------------------------------------
// EnergyAppsListView — persistent "apps using significant energy" section.
// The popovers tear down and rebuild every card each poll tick, so this view
// is owned by the popover and re-parented into each fresh battery card; it
// diffs the sampled app list itself. The section owns a height constraint so
// the battery card extends from its bottom edge when the significant-energy
// rows appear, instead of making the whole popover feel like it jumped.
// ---------------------------------------------------------------------------

final class EnergyAppsListView: NSView {

    private let rowWidth: CGFloat
    private let stack = NSStackView()
    private let placeholder: NSTextField
    private let header: NSTextField
    private var heightConstraint: NSLayoutConstraint?
    private var rows: [(name: String, view: NSView)] = []
    private var names: [String] = []

    init(rowWidth: CGFloat) {
        self.rowWidth = rowWidth

        let line = NSTextField(labelWithString: "No apps using significant energy")
        line.font = NSFont.systemFont(ofSize: 10)
        line.textColor = .tertiaryLabelColor
        placeholder = line

        let cap = NSTextField(labelWithString: "")
        cap.attributedStringValue = StatCard.captionString("USING SIGNIFICANT ENERGY")
        header = cap
        header.isHidden = true

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        stack.addArrangedSubview(placeholder)
        stack.addArrangedSubview(header)
        [placeholder, header].forEach { $0.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Diffs against the currently shown apps and animates the difference.
    /// `layoutChange` is called during the section-height animation so the
    /// popover bottom can move with the battery card's bottom edge.
    func setApps(_ apps: [EnergyAppSampler.SignificantApp], animated: Bool,
                 layoutChange: (() -> Void)? = nil) {
        let newNames = apps.map(\.name)
        guard newNames != names else {
            if heightConstraint == nil {
                ensuredHeightConstraint().constant = max(1, stack.fittingSize.height)
            }
            return
        }
        names = newNames

        var surviving: [String: NSView] = [:]
        var dying: [NSView] = []
        for (name, view) in rows {
            if newNames.contains(name) { surviving[name] = view } else { dying.append(view) }
        }
        rows = apps.map { app in
            (name: app.name, view: surviving[app.name] ?? makeAppRow(app))
        }
        let height = ensuredHeightConstraint()
        let oldHeight = max(1, bounds.height > 0 ? bounds.height : stack.fittingSize.height)
        height.constant = oldHeight
        layoutSubtreeIfNeeded()

        var appearing: [NSView] = []
        // Brand-new rows go in now at their final size, transparent. Keeping
        // arranged subviews visible avoids NSStackView's layout animation
        // fighting the popover's own frame animation.
        for entry in rows where surviving[entry.name] == nil {
            appearing.append(entry.view)
            entry.view.alphaValue = animated ? 0 : 1
            entry.view.wantsLayer = true
            stack.addArrangedSubview(entry.view)
            entry.view.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        let headerWasHidden = header.isHidden
        let applyTargets = {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.placeholder.isHidden = !newNames.isEmpty
                self.header.isHidden = newNames.isEmpty
                if headerWasHidden && !newNames.isEmpty {
                    self.header.alphaValue = animated ? 0 : 1
                    appearing.append(self.header)
                }
                // Order: placeholder, header, live rows. insertArrangedSubview
                // moves already-arranged views into their final positions before
                // the popover resize starts.
                for (i, entry) in self.rows.enumerated() {
                    self.stack.insertArrangedSubview(entry.view, at: 2 + i)
                    entry.view.isHidden = false
                    entry.view.alphaValue = appearing.contains(where: { $0 === entry.view }) ? entry.view.alphaValue : 1
                    entry.view.layer?.transform = CATransform3DIdentity
                }
                for view in dying {
                    self.stack.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                CATransaction.commit()
            }
        }

        guard animated, window != nil else {
            applyTargets()
            height.constant = max(1, stack.fittingSize.height)
            layoutChange?()
            return
        }

        applyTargets()
        let newHeight = max(1, stack.fittingSize.height)
        height.constant = oldHeight
        layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            height.animator().constant = newHeight
            appearing.forEach { $0.animator().alphaValue = 1 }
            layoutChange?()
        }
    }

    private func ensuredHeightConstraint() -> NSLayoutConstraint {
        if let heightConstraint { return heightConstraint }
        let constraint = heightAnchor.constraint(equalToConstant: max(1, stack.fittingSize.height))
        constraint.priority = .required
        constraint.isActive = true
        heightConstraint = constraint
        return constraint
    }

    private func makeAppRow(_ app: EnergyAppSampler.SignificantApp) -> NSView {
        let iconView = NSImageView()
        iconView.image = app.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let name = NSTextField(labelWithString: app.name)
        name.font = NSFont.systemFont(ofSize: 11)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [iconView, name])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        return row
    }
}

/// Full-width battery card: charge level, energy-mode picker, and the
/// approximated "apps using significant energy" list.
func makeBatteryDetailCard(stats s: HardwareStats,
                            contentWidth: CGFloat,
                            cornerRadius: CGFloat = 8,
                            energyModes: HardwareMonitor.EnergyModes,
                            energyAppsView: NSView,
                            previousPowerWatts: Double? = nil,
                            onSelectEnergyMode: @escaping (Int) -> Void) -> NSView {
    let card = NSView()
    card.wantsLayer = true
    card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    card.layer?.cornerRadius = cornerRadius
    card.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
    card.layer?.borderWidth = 1

    let inner = NSStackView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    inner.orientation = .vertical
    inner.alignment = .leading
    inner.spacing = 5
    inner.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
    card.addSubview(inner)
    NSLayoutConstraint.activate([
        inner.topAnchor.constraint(equalTo: card.topAnchor),
        inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
        inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    let rowWidth = contentWidth - 20
    let pct = s.batteryPercent ?? 0

    // Caption row: BATTERY … charge/adapter status
    let caption = NSTextField(labelWithString: "")
    caption.attributedStringValue = StatCard.captionString("BATTERY")
    caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    let statusText: String = {
        if s.isCharging == true {
            if let aw = s.adapterWatts { return "Charging · \(aw)W adapter" }
            return "Charging"
        }
        if let aw = s.adapterWatts { return "Plugged in · \(aw)W adapter" }
        return "Discharging"
    }()
    let status = NSTextField(labelWithString: statusText)
    status.font = NSFont.systemFont(ofSize: 9)
    status.textColor = .tertiaryLabelColor
    status.alignment = .right
    status.lineBreakMode = .byTruncatingTail
    status.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    // Flexible spacer pins status flush to the row's right edge, same trick
    // used to separate the percent and watt figures below.
    let headSpacer = NSView()
    headSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

    let headRow = NSStackView(views: [caption, headSpacer, status])
    headRow.orientation = .horizontal
    headRow.spacing = 6
    headRow.alignment = .firstBaseline
    inner.addArrangedSubview(headRow)
    headRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

    // Charge percentage (+ bolt while charging)
    let value = NSTextField(labelWithString: s.batteryPercentText() ?? "—")
    value.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
    value.textColor = .labelColor
    var valueViews: [NSView] = [value]
    if s.isCharging == true,
       let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Charging") {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let iv = NSImageView(image: bolt.withSymbolConfiguration(config) ?? bolt)
        iv.contentTintColor = .systemGreen
        iv.symbolConfiguration = config
        iv.imageScaling = .scaleProportionallyDown
        iv.widthAnchor.constraint(equalToConstant: 10).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
        valueViews.append(iv)
    }
    // System power draw, right-aligned (merged from the old watt card). The
    // charge/discharge state already reads in the header above, so the watt
    // figure needs no caption of its own here.
    let hasWatts = s.powerWatts != nil
    if let w = s.powerWatts {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.heightAnchor.constraint(equalToConstant: 1).isActive = true
        valueViews.append(spacer)

        let watt = AnimatedValueField(labelWithString: "")
        watt.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        watt.textColor = .secondaryLabelColor
        watt.configure(value: w, previous: previousPowerWatts) { String(format: "%.1f W", $0) }
        valueViews.append(watt)
    }
    let valueRow = NSStackView(views: valueViews)
    valueRow.orientation = .horizontal
    valueRow.spacing = 3
    valueRow.alignment = .centerY
    inner.addArrangedSubview(valueRow)
    if hasWatts { valueRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true }
    inner.setCustomSpacing(6, after: valueRow)

    // Charge level bar
    let bar = MiniBarView()
    bar.ratio = CGFloat(pct) / 100.0
    bar.fillColor = batteryLevelColor(CGFloat(pct) / 100.0)
    bar.translatesAutoresizingMaskIntoConstraints = false
    // While on power, mark where a charge limit stops charging. Kept visible
    // once it's holding at the limit (not just while actively charging), since
    // that's when the tick best explains why it stopped short of 100%.
    let onPower = s.isCharging == true || s.adapterWatts != nil
    let showsLimit = onPower && (s.chargeLimitPercent.map { $0 < 100 } ?? false)
    if showsLimit, let limit = s.chargeLimitPercent {
        bar.trackThickness = 3
        bar.limitRatio = CGFloat(limit) / 100.0
    }
    inner.addArrangedSubview(bar)
    bar.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
    bar.heightAnchor.constraint(equalToConstant: showsLimit ? 7 : 3).isActive = true
    inner.setCustomSpacing(10, after: bar)

    // Energy mode picker (hidden when pmset has no powermode key)
    if energyModes.supported {
        let emCaption = NSTextField(labelWithString: "")
        emCaption.attributedStringValue = StatCard.captionString("ENERGY MODE")
        inner.addArrangedSubview(emCaption)
        inner.setCustomSpacing(5, after: emCaption)

        let current = s.adapterWatts != nil ? energyModes.ac : energyModes.battery
        let titles = ["Automatic", "Low Power", "High Power"]
        let chips = titles.enumerated().map { index, title in
            EnergyModeChip(title: title, isSelected: current == index) {
                onSelectEnergyMode(index)
            }
        }
        let chipRow = NSStackView(views: chips)
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.distribution = .fillEqually
        inner.addArrangedSubview(chipRow)
        chipRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        inner.setCustomSpacing(10, after: chipRow)
    }

    // Significant energy apps — persistent view owned by the popover, so its
    // appear/disappear animations survive the per-tick card rebuild.
    inner.addArrangedSubview(energyAppsView)

    return card
}

// ---------------------------------------------------------------------------
// BatteryStatusItem — dedicated menu bar item for the battery module,
// shown when the "separate menu bar item" option is enabled
// ---------------------------------------------------------------------------

final class BatteryStatusItem {

    private let item: NSStatusItem
    let barView: HardwareBarView
    private var popover: BatteryPopover?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MSG.BatteryStats"

        barView = HardwareBarView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        // Only battery — HardwareBarView's other show* flags default to true.
        barView.showCPU = false
        barView.showGPU = false
        barView.showMemory = false
        barView.showTemp = false
        barView.showFPS = false
        barView.showFan = false
        barView.showPower = false
        barView.showBattery = true
        barView.batteryIconScale = 1.15

        if let btn = item.button {
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(togglePopover)
            btn.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        barView.onAnimationFrame = { [weak self] in
            guard let self else { return }
            self.item.button?.image = self.barView.renderedImage()
        }

        HardwareMonitor.shared.addObserver { [weak self] in
            DispatchQueue.main.async {
                self?.barView.stats = HardwareMonitor.shared.stats
                self?.refreshImage()
            }
        }

        refreshImage()
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
        } else {
            if popover == nil { popover = BatteryPopover() }
            popover?.show(relativeTo: item.button!)
        }
    }

    func remove() {
        popover?.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    func refreshImage() {
        let size = barView.intrinsicContentSize
        barView.frame.size = size
        item.length = size.width
        item.button?.image = barView.renderedImage()
    }
}

// ---------------------------------------------------------------------------
// BatteryPopover — compact popover for the dedicated battery status item
// ---------------------------------------------------------------------------

final class BatteryPopover: NSObject {
    private let window: NSWindow
    private let root: NSView
    private let stack: NSStackView
    private var pollTimer: Timer?
    private var resizeTimer: Timer?
    private var closeMonitor: Any?
    private weak var sourceButton: NSStatusBarButton?
    private var menuTrackingCount = 0
    private var menuTrackingObservers: [NSObjectProtocol] = []

    private let energySampler = EnergyAppSampler()
    private var energyApps: [EnergyAppSampler.SignificantApp] = []
    private lazy var energyList = EnergyAppsListView(rowWidth: contentWidth - 20)
    private var energyModes = HardwareMonitor.EnergyModes()
    /// Last watt figure shown, so a fresh AnimatedValueField can ease from it
    /// instead of snapping (cards are rebuilt from scratch every poll).
    private var lastPowerWatts: Double?

    private let popWidth: CGFloat = 248
    private var contentWidth: CGFloat { popWidth - 24 }

    /// Corner radius of the shell; the gutter below is subtracted from this
    /// to get each card's own radius, so every card corner is concentric
    /// with the shell corner around it (inner = outer − gutter).
    private let shellRadius: CGFloat = 20
    private let gutter: CGFloat = 12
    private var cardCornerRadius: CGFloat { max(0, shellRadius - gutter) }
    private let arrowWidth: CGFloat = 16
    private let arrowHeight: CGFloat = 8
    private let shell: PopoverShellView

    var isShown: Bool { window.isVisible }

    override init() {
        root = NSView(frame: NSRect(x: 0, y: 0, width: popWidth, height: 140))

        // Shell matching HardwarePopover's card language: body, arrow, and
        // vibrancy are one continuous piece (see PopoverShellView).
        shell = PopoverShellView(cornerRadius: shellRadius, arrowWidth: arrowWidth, arrowHeight: arrowHeight)
        shell.frame = root.bounds
        shell.autoresizingMask = [.width, .height]
        root.addSubview(shell)

        stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: gutter, bottom: 10, right: gutter)
        root.addSubview(stack)

        // Pin the stack below the arrow strip so content never clips and the
        // view's fittingSize reflects the stack's intrinsic height.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: arrowHeight),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window = NSWindow(contentRect: root.frame,
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        window.contentView = root

        super.init()

        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.menuTrackingCount += 1 })
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.menuTrackingCount = max(0, self.menuTrackingCount - 1)
        })
    }

    deinit {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        sourceButton = button
        // The tint style (Clear/Tinted) has no public change notification,
        // so pick it up fresh on every open rather than only at popover
        // creation time.
        shell.refreshAppearance()
        // Keep showing whatever energyApps last held (from the previous time
        // this popover was open) instead of blanking to empty — resetting
        // the sampler still means the *next* reading is measured fresh from
        // now, but the list doesn't need to sit empty for a second while
        // waiting for it.
        energySampler.reset()
        _ = energySampler.sample()   // baseline; real values from the next tick
        refreshEnergyModes()
        rebuild()

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        // The button's own bounds can be taller than the menu bar's visual
        // content (macOS pads status items to clear notch camera housing),
        // so anchor from the top edge minus the standard thickness instead
        // of the bottom edge — otherwise the popover floats well below the icon.
        let menuBarBottom = screenRect.maxY - NSStatusBar.system.thickness
        var origin = NSPoint(x: screenRect.midX - window.frame.width / 2,
                             y: menuBarBottom - window.frame.height - 4)
        if let screen = button.window?.screen {
            let vf = screen.visibleFrame
            if origin.x + window.frame.width > vf.maxX { origin.x = vf.maxX - window.frame.width - 4 }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
        }

        // Point the arrow at the button's horizontal center, clamped clear
        // of the rounded corners.
        let minCenter = 16 + arrowWidth / 2
        let maxCenter = popWidth - 16 - arrowWidth / 2
        let wanted = screenRect.midX - origin.x
        shell.arrowCenterX = max(minCenter, min(maxCenter, wanted))
        shell.layoutSubtreeIfNeeded()

        window.setFrameOrigin(origin)
        window.orderFront(nil)

        if closeMonitor == nil {
            closeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, self.window.isVisible else { return }
                let loc = NSEvent.mouseLocation
                if self.window.frame.contains(loc) { return }
                if let btn = self.sourceButton {
                    let btnScreen = btn.window?.convertToScreen(btn.convert(btn.bounds, to: nil)) ?? .zero
                    if btnScreen.contains(loc) { return }
                }
                self.close()
            }
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshValues()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }

        // The sampler needs some elapsed wall time to compute a fresh delta;
        // 150ms clears its internal 100ms floor, so a currently-heavy app
        // shows up almost immediately instead of after the first full
        // 1-second poll tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.refreshValues()
        }
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        resizeTimer?.invalidate(); resizeTimer = nil
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        window.orderOut(nil)
    }

    private func rebuild() {
        let s = HardwareMonitor.shared.stats
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let batteryCard = makeBatteryDetailCard(stats: s, contentWidth: contentWidth,
                                                cornerRadius: cardCornerRadius,
                                                energyModes: energyModes, energyAppsView: energyList,
                                                previousPowerWatts: lastPowerWatts) { [weak self] mode in
            self?.selectEnergyMode(mode)
        }
        lastPowerWatts = s.powerWatts
        stack.addArrangedSubview(batteryCard)
        batteryCard.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        resizeWindow()
    }

    private func refreshValues() {
        guard menuTrackingCount == 0 else { return }
        let sampledApps = energySampler.sample()
        let energyNamesChanged = sampledApps.map(\.name) != energyApps.map(\.name)
        energyApps = sampledApps

        if energyNamesChanged {
            energyList.setApps(sampledApps, animated: true) { [weak self] in
                self?.resizeWindow(animated: true)
            }
            return
        }

        rebuild()
        energyList.setApps(sampledApps, animated: false) { [weak self] in
            self?.resizeWindow(animated: true)
        }
    }

    /// Re-reads pmset's powermode values off-main and repaints when they land.
    private func refreshEnergyModes() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let modes = HardwareMonitor.readEnergyModes()
            DispatchQueue.main.async {
                guard let self else { return }
                self.energyModes = modes
                if self.window.isVisible, self.menuTrackingCount == 0 { self.rebuild() }
            }
        }
    }

    private func selectEnergyMode(_ mode: Int) {
        energyModes.battery = mode
        energyModes.ac = mode
        rebuild()
        HardwareMonitor.shared.setEnergyMode(mode) { [weak self] _ in
            self?.refreshEnergyModes()
        }
    }

    private func resizeWindow(animated: Bool = false) {
        stack.layoutSubtreeIfNeeded()
        let h = max(60, stack.fittingSize.height) + arrowHeight
        let lockedTopY = window.frame.maxY
        let newFrame = NSRect(x: window.frame.minX,
                              y: lockedTopY - h,   // keep arrow/top fixed; extend from the bottom
                              width: popWidth, height: h)
        if animated {
            animateWindowHeight(to: h, lockedTopY: lockedTopY)
        } else {
            resizeTimer?.invalidate(); resizeTimer = nil
            window.setFrame(newFrame, display: true, animate: false)
        }
    }

    private func animateWindowHeight(to targetHeight: CGFloat, lockedTopY: CGFloat) {
        resizeTimer?.invalidate()

        let startHeight = window.frame.height
        let delta = targetHeight - startHeight
        guard abs(delta) > 0.5 else {
            window.setFrame(NSRect(x: window.frame.minX, y: lockedTopY - targetHeight,
                                   width: popWidth, height: targetHeight),
                            display: true, animate: false)
            return
        }

        let start = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.18
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - start
            let p = max(0, min(1, CGFloat(elapsed / duration)))
            let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            let height = startHeight + delta * eased
            self.window.setFrame(NSRect(x: self.window.frame.minX,
                                        y: lockedTopY - height,
                                        width: self.popWidth,
                                        height: height),
                                 display: true, animate: false)
            if p >= 1 {
                timer.invalidate()
                if self.resizeTimer === timer { self.resizeTimer = nil }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }
}
