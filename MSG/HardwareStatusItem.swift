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
            let image = self.barView.renderedImage()
            if abs(self.item.length - image.size.width) > 0.5 { self.item.length = image.size.width }
            self.setImageIfChanged(image)
            if EdgeKeyStrip.statsInTouchID { EdgeKeyStrip.shared.showStats(self.moduleImages()) }
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
            makePopoverIfNeeded()
            popover?.show(relativeTo: item.button!)
        }
    }

    /// From the stats on the Edge Keys strip: the same window, opened above them.
    func toggleStripPopover(above rect: NSRect) {
        if let popover, popover.isShown {
            popover.close()
        } else {
            makePopoverIfNeeded()
            popover?.show(above: rect)
        }
    }

    private func makePopoverIfNeeded() {
        guard popover == nil else { return }
        popover = HardwarePopover()
        popover?.hidesBatteryCard = hidesBatteryCard
    }

    func remove() {
        popover?.close()
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: Edge Keys

    /// One view per module, drawn exactly as the bar draws it.
    private var moduleViews: [String: HardwareBarView] = [:]

    /// Each shown module on its own, trimmed to its ink — so the strip can
    /// space them evenly itself.
    func moduleImages() -> [NSImage] {
        let bar = barView
        let order = bar.moduleOrder + AppSettings.hardwareModuleIDs.filter { !bar.moduleOrder.contains($0) }
        let shown: [String: Bool] = [
            "cpu": bar.showCPU, "gpu": bar.showGPU, "memory": bar.showMemory, "temp": bar.showTemp,
            "fps": bar.showFPS, "fan": bar.showFan, "power": bar.showPower, "battery": bar.showBattery,
        ]
        return order.compactMap { id -> NSImage? in
            guard shown[id] == true else { return nil }
            let view = moduleViews[id] ?? HardwareBarView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
            moduleViews[id] = view
            view.showCPU = id == "cpu"; view.showGPU = id == "gpu"; view.showMemory = id == "memory"
            view.showTemp = id == "temp"; view.showFPS = id == "fps"; view.showFan = id == "fan"
            view.showPower = id == "power"; view.showBattery = id == "battery"
            view.moduleOrder = [id]
            view.cpuRaw = bar.cpuRaw; view.gpuRaw = bar.gpuRaw; view.memoryRaw = bar.memoryRaw
            view.tempRaw = bar.tempRaw; view.fanRaw = bar.fanRaw; view.powerRaw = bar.powerRaw
            view.batteryStyle = bar.batteryStyle; view.batteryIconScale = bar.batteryIconScale
            view.barStyle = bar.barStyle; view.labelPosition = bar.labelPosition
            view.colorScale = bar.colorScale; view.menuBarIsDark = true
            view.animatesPowerGlyph = false
            view.animatesBatteryRing = false
            view.usesBatteryPowerReadout = id == "battery"
            view.stats = bar.stats
            if id == "battery" { view.copyPowerGlyphAnimation(from: bar) }
            return Self.trimmed(view.renderedImage())
        }
    }

    /// The image cut down to the columns that have any ink.
    private static func trimmed(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, maxX = -1
        for x in 0..<w {
            for y in 0..<h where pixels[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                break
            }
        }
        guard maxX >= minX, let cut = cg.cropping(to: CGRect(x: minX, y: 0, width: maxX - minX + 1, height: h))
        else { return image }
        let scale = CGFloat(w) / max(1, image.size.width)
        return NSImage(cgImage: cut, size: CGSize(width: CGFloat(cut.width) / scale, height: image.size.height))
    }

    /// Off the menu bar while the stats sit on the Edge Keys strip.
    func setShownInMenuBar(_ shown: Bool) {
        if item.isVisible != shown { item.isVisible = shown }
    }

    func refreshImage() {
        defer {
            if EdgeKeyStrip.statsInTouchID { EdgeKeyStrip.shared.showStats(moduleImages()) }
        }
        let size = barView.intrinsicContentSize
        barView.frame.size = size
        if abs(item.length - size.width) > 0.5 { item.length = size.width }
        // The button lives in the menu bar, so its appearance is the real one:
        // vibrantLight over a light wallpaper even while the system is in Dark
        // mode. The offscreen bar view can't see that on its own.
        barView.menuBarIsDark = item.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
            .map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
        setImageIfChanged(barView.renderedImage())
    }

    /// Every image or length set on a status item makes AppKit re-publish it
    /// to each display's menu bar (`_updateReplicants…`) — the single largest
    /// idle cost in a profile. The render cache hands back the same image
    /// when nothing visible changed; don't pass that on as a change.
    ///
    /// Hosting the bar view live in the button was measured and is worse: a
    /// content redraw re-publishes the item just the same, and the snapshot
    /// then re-runs `draw(_:)` (text labels included) instead of copying a
    /// finished bitmap.
    private func setImageIfChanged(_ image: NSImage) {
        guard let button = item.button, button.image !== image else { return }
        button.image = image
    }
}

// ---------------------------------------------------------------------------
// HardwareBarView — draws bars with labels
// ---------------------------------------------------------------------------

final class HardwareBarView: NSView {

    var stats = HardwareStats() {
        didSet {
            needsDisplay = true
            retargetPowerGlyph()
            retargetBatteryRing()
            retargetAnimation()
        }
    }

    /// Offscreen module snapshots should use the final icon immediately.
    var animatesPowerGlyph = true
    var animatesBatteryRing = true

    /// The right-side hardware widget keeps watts readable in both power states.
    var usesBatteryPowerReadout = false

    /// Fired on each animation tick so image-based hosts can re-render; live
    /// hosts (the status items, the settings preview) redraw via needsDisplay.
    var onAnimationFrame: (() -> Void)?

    /// Set when hosted inside a status button: clicks belong to the button.
    var passesClicksThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    /// The signature of what's on screen, so animation ticks that wouldn't
    /// change a pixel (sub-pixel steps near the end of an ease) skip the draw.
    private var drawnSignature: String?

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

    /// Whether the menu bar's own background is dark.
    ///
    /// Pushed in by the status item rather than read here: this view renders
    /// offscreen into an NSImage, so its `effectiveAppearance` follows the app,
    /// not the menu bar. Those disagree — a translucent menu bar over a light
    /// wallpaper is `vibrantLight` while the system is still in Dark mode, and
    /// white-on-light is invisible. `IndicatorRenderer.menuBarTextColor` solves
    /// the same problem the same way, which is why the space indicator stays
    /// readable when these bars did not.
    var menuBarIsDark = true

    /// The ink every element is drawn in, matching `menuBarTextColor`'s values.
    private var ink: NSColor { menuBarIsDark ? .white : NSColor(white: 0.15, alpha: 1) }

    /// Darkens a hued status colour so it stays legible on a light menu bar.
    /// Bright yellow at 98% brightness is as invisible on a pale bar as white is.
    private func adapt(_ c: NSColor) -> NSColor {
        guard !menuBarIsDark, let hsb = c.usingColorSpace(.deviceRGB) else { return c }
        return NSColor(hue: hsb.hueComponent,
                       saturation: min(1, hsb.saturationComponent * 1.15),
                       brightness: hsb.brightnessComponent * 0.70,
                       alpha: hsb.alphaComponent)
    }

    // -----------------------------------------------------------------------
    // MARK: - Layout
    // -----------------------------------------------------------------------

    private let barW: CGFloat = 4
    private let gap: CGFloat = 3
    private let leftPadding: CGFloat = 4
    // Static so the measurement caches below can derive from the same constant
    // instead of restating the literal.
    fileprivate static let verticalLabelFontSize: CGFloat = 7.0
    private var fontSize: CGFloat { Self.verticalLabelFontSize }
    private let horizontalLabelFontSize: CGFloat = 7.4
    private let circularHorizontalLabelFontSize: CGFloat = 6.2
    private let circularRadius: CGFloat = 6.75
    private let circularVerticalModuleW: CGFloat = 30

    // Number-style module fonts, shared by drawValue and the width sizing so
    // the two stay in sync.
    static let valueFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    static let valueUnitFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
    static let valueLabelFont = NSFont.systemFont(ofSize: 6, weight: .heavy)
    private static let circularStrokeWidth: CGFloat = 2.5
    private static let batteryPowerFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    private static let batteryPowerUnitFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
    private static let batteryPowerGlyphSize: CGFloat = 8.5
    private static let batteryPowerGlyphGap: CGFloat = 3.5

    private var batteryPowerReadoutWidth: CGFloat {
        let watts = batteryPowerText
        let numberWidth = max(("100" as NSString).size(withAttributes: [.font: Self.batteryPowerFont]).width,
                              (watts as NSString).size(withAttributes: [.font: Self.batteryPowerFont]).width)
        // Symmetric side room keeps the readout centred while the icon fades
        // beside it. Strip snapshots trim this room when no icon is visible.
        return 2 * (Self.batteryPowerGlyphSize + Self.batteryPowerGlyphGap) + numberWidth + 1 + ("W" as NSString).size(withAttributes: [.font: Self.batteryPowerUnitFont]).width + 6
    }

    private var batteryPowerText: String {
        guard let watts = stats.powerWatts, watts.isFinite, watts >= 0 else { return "—" }
        return String(format: "%.0f", watts)
    }

    /// Bar height depends on label position: shorter when text is below.
    private var barH: CGFloat {
        labelPosition == "horizontal" ? 11 : 18
    }

    private var barY: CGFloat {
        labelPosition == "horizontal" ? 10 : 2
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        animTimer?.invalidate()
        powerGlyphTimer?.invalidate()
        batteryRingTimer?.invalidate()
    }

    // -----------------------------------------------------------------------
    // MARK: - Value animation
    // -----------------------------------------------------------------------

    private var displayedRatios: [String: CGFloat] = [:]
    private var animStartRatios: [String: CGFloat] = [:]
    private var animTargetRatios: [String: CGFloat] = [:]
    private var animStartTime: CFTimeInterval = 0
    private var animTimer: Timer?
    private let animDuration: CFTimeInterval = 0.35

    private enum PowerGlyph: String {
        case none, bolt, plug
    }
    private var hasPowerGlyphState = false
    private var powerGlyphCurrent: PowerGlyph = .none
    private var powerGlyphPrevious: PowerGlyph = .none
    private var powerGlyphProgress: CGFloat = 1
    private var powerGlyphStartTime: CFTimeInterval = 0
    private var powerGlyphTimer: Timer?

    /// Strip snapshots follow the live view's animation instead of snapping
    /// to the newest power state on every freshly rendered image.
    func copyPowerGlyphAnimation(from source: HardwareBarView) {
        powerGlyphCurrent = source.powerGlyphCurrent
        powerGlyphPrevious = source.powerGlyphPrevious
        powerGlyphProgress = source.powerGlyphProgress
    }
    private var hasBatteryRingState = false
    private var batteryRingBlend: CGFloat = 0
    private var batteryRingTarget: CGFloat = 0
    private var batteryRingTimer: Timer?

    private func retargetBatteryRing() {
        let target: CGFloat = stats.isExternalPowerConnected && stats.batteryPercent != nil ? 1 : 0
        guard hasBatteryRingState else {
            hasBatteryRingState = true
            batteryRingBlend = target
            batteryRingTarget = target
            return
        }
        if !animatesBatteryRing {
            batteryRingTimer?.invalidate()
            batteryRingTimer = nil
            batteryRingBlend = target
            batteryRingTarget = target
            return
        }
        guard target != batteryRingTarget else { return }
        batteryRingTarget = target
        batteryRingTimer?.invalidate()
        let start = batteryRingBlend
        let startedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = max(0, min(1, CGFloat((CACurrentMediaTime() - startedAt) / 0.32)))
            self.batteryRingBlend = start + (target - start) * Easing.outQuart(progress)
            if progress >= 1 {
                timer.invalidate()
                self.batteryRingTimer = nil
            }
            self.needsDisplay = true
            self.onAnimationFrame?()
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryRingTimer = timer
    }

    private func retargetPowerGlyph() {
        let target: PowerGlyph
        if stats.isCharging == true {
            target = .bolt
        } else if stats.isExternalPowerConnected {
            target = .plug
        } else {
            target = .none
        }
        guard hasPowerGlyphState else {
            hasPowerGlyphState = true
            powerGlyphCurrent = target
            return
        }
        guard target != powerGlyphCurrent else { return }
        let outgoing = powerGlyphProgress < 0.5 ? powerGlyphPrevious : powerGlyphCurrent
        powerGlyphTimer?.invalidate()
        powerGlyphPrevious = outgoing
        powerGlyphCurrent = target
        guard animatesPowerGlyph else {
            powerGlyphPrevious = .none
            powerGlyphProgress = 1
            powerGlyphTimer = nil
            return
        }
        powerGlyphProgress = 0
        powerGlyphStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.powerGlyphStartTime
            let progress = max(0, min(1, CGFloat(elapsed / 0.22)))
            self.powerGlyphProgress = Easing.outQuart(progress)
            if progress >= 1 {
                timer.invalidate()
                self.powerGlyphTimer = nil
                self.powerGlyphPrevious = .none
            }
            self.needsDisplay = true
            self.onAnimationFrame?()
        }
        RunLoop.main.add(timer, forMode: .common)
        powerGlyphTimer = timer
    }

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
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
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
        guard renderSignature(size: bounds.size) != drawnSignature else { return }
        needsDisplay = true
        onAnimationFrame?()
    }

    // -----------------------------------------------------------------------
    // MARK: - Drawing
    // -----------------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        drawnSignature = renderSignature(size: bounds.size)
        let modules = activeModules()
        guard !modules.isEmpty else { return }

        let drawWidth = bounds.width - leftPadding
        let moduleW = drawWidth / CGFloat(modules.count)

        for (i, mod) in modules.enumerated() {
            var mod = mod
            if !mod.isValue, let shown = displayedRatios[mod.label] { mod.ratio = shown }
            let x = leftPadding + CGFloat(i) * moduleW
            let rect = NSRect(x: x, y: 0, width: moduleW, height: bounds.height)
            if mod.isBatteryModule && usesBatteryPowerReadout {
                drawBatteryPowerReadout(module: mod, in: rect)
            } else if mod.isBatteryModule && batteryRingBlend > 0 {
                if batteryRingBlend < 1 {
                    drawWithOpacity(1 - batteryRingBlend) { drawBaseModule(mod, in: rect) }
                }
                drawWithOpacity(batteryRingBlend) { drawBatteryPowerRing(in: rect) }
            } else {
                drawBaseModule(mod, in: rect)
            }
        }
    }

    private func drawWithOpacity(_ opacity: CGFloat, _ body: () -> Void) {
        guard let context = NSGraphicsContext.current?.cgContext else { body(); return }
        context.saveGState()
        context.setAlpha(opacity)
        body()
        context.restoreGState()
    }

    private func drawBaseModule(_ module: Module, in rect: NSRect) {
        if module.isBatteryIcon {
            drawBatteryIcon(module: module, in: rect)
        } else if module.isValue {
            drawValue(module: module, in: rect)
        } else if barStyle == "circular" {
            drawCircular(module: module, in: rect)
        } else if barStyle == "horizontal" {
            drawHorizontalBar(module: module, in: rect)
        } else if barStyle == "dot" {
            drawDot(module: module, in: rect)
        } else {
            drawVertical(module: module, in: rect)
        }
    }

    /// Live input/draw watts above a charge bar; discharge has no glyph.
    private func drawBatteryPowerReadout(module: Module, in rect: NSRect) {
        let number = batteryPowerText as NSString
        let unit = "W" as NSString
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Self.batteryPowerFont, .foregroundColor: ink]
        let unitAttributes: [NSAttributedString.Key: Any] = [.font: Self.batteryPowerUnitFont, .foregroundColor: ink]
        let numberWidth = number.size(withAttributes: numberAttributes).width
        let unitWidth = unit.size(withAttributes: unitAttributes).width
        let reservedNumberWidth = max(numberWidth, ("100" as NSString).size(withAttributes: numberAttributes).width)
        let barWidth = reservedNumberWidth + 1 + unitWidth
        let numberX = rect.midX - (numberWidth + 1 + unitWidth) / 2
        let iconOffset = Self.batteryPowerGlyphSize + Self.batteryPowerGlyphGap
        let iconX = rect.midX - barWidth / 2 - iconOffset
        let baseline = rect.midY - 1
        func drawGlyph(_ glyph: PowerGlyph, opacity: CGFloat) {
            guard glyph != .none, opacity > 0 else { return }
            let symbolName = glyph == .bolt ? "bolt.fill" : "powerplug.portrait.fill"
            let fallback = glyph == .bolt ? "bolt.fill" : "powerplug.fill"
            guard let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil) else { return }
            let configuration = NSImage.SymbolConfiguration(pointSize: Self.batteryPowerGlyphSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
            let tinted = icon.withSymbolConfiguration(configuration) ?? icon
            let natural = tinted.size
            let scale = Self.batteryPowerGlyphSize * (0.75 + 0.25 * opacity) / max(1, max(natural.width, natural.height))
            let size = NSSize(width: natural.width * scale, height: natural.height * scale)
            tinted.draw(in: NSRect(x: iconX + (Self.batteryPowerGlyphSize - size.width) / 2,
                                  y: baseline + Self.batteryPowerFont.capHeight / 2 - size.height / 2,
                                  width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: opacity)
        }
        if powerGlyphProgress < 1 {
            drawGlyph(powerGlyphPrevious, opacity: 1 - powerGlyphProgress)
            drawGlyph(powerGlyphCurrent, opacity: powerGlyphProgress)
        } else {
            drawGlyph(powerGlyphCurrent, opacity: 1)
        }
        number.draw(at: NSPoint(x: numberX, y: baseline + Self.batteryPowerFont.descender), withAttributes: numberAttributes)
        unit.draw(at: NSPoint(x: numberX + numberWidth + 1, y: baseline + Self.batteryPowerUnitFont.descender), withAttributes: unitAttributes)

        let track = NSRect(x: rect.midX - barWidth / 2, y: 2.5, width: barWidth, height: Self.circularStrokeWidth)
        let radius = Self.circularStrokeWidth / 2
        ink.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        let ratio = max(0, min(1, module.ratio))
        if ratio > 0 {
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * ratio, height: track.height)
            ink.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: fill, xRadius: min(radius, fill.width / 2), yRadius: radius).fill()
        }
    }

    /// The connected-power design: battery level around the outside and live
    /// adapter input watts in the centre. Dots stand in until a fresh sample.
    private func drawBatteryPowerRing(in rect: NSRect) {
        // Same 20 pt, 2 pt, 235° → -55° open ring as EdgeKeyStrip's music
        // visualizer. Keep its flat ends and 70° bottom gap unchanged.
        let side = min(20, rect.height)
        let lineWidth: CGFloat = 2
        let radius = side / 2 - lineWidth / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let startAngle: CGFloat = 235 * .pi / 180
        let endAngle: CGFloat = -55 * .pi / 180
        let track = CGMutablePath()
        track.addArc(center: center, radius: radius,
                     startAngle: startAngle, endAngle: endAngle, clockwise: true)
        if let context = NSGraphicsContext.current?.cgContext {
            context.addPath(track)
            context.setLineWidth(lineWidth)
            context.setLineCap(.butt)
            context.setStrokeColor(ink.withAlphaComponent(0.2).cgColor)
            context.strokePath()
        }

        let ratio = CGFloat(max(0, min(100, stats.batteryPercent ?? 0))) / 100
        if ratio > 0.01, let context = NSGraphicsContext.current?.cgContext {
            let progress = CGMutablePath()
            progress.addArc(center: center, radius: radius,
                            startAngle: startAngle,
                            endAngle: startAngle + (endAngle - startAngle) * ratio,
                            clockwise: true)
            context.addPath(progress)
            context.setLineWidth(lineWidth)
            context.setLineCap(.butt)
            context.setStrokeColor(ink.withAlphaComponent(0.9).cgColor)
            context.strokePath()
        }

        let watts = stats.powerWatts.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
        let label = (watts.map { "\($0)W" } ?? "•••") as NSString
        let availableWidth = max(8, (radius - lineWidth / 2) * 2 - 3)
        var pointSize: CGFloat = watts.map { $0 >= 100 ? 4.8 : 5.6 } ?? 5.5
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold),
            .foregroundColor: ink,
        ]
        let measuredWidth = label.size(withAttributes: attributes).width
        if measuredWidth > availableWidth {
            pointSize *= availableWidth / measuredWidth
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .bold)
        }
        let labelSize = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: center.x - labelSize.width / 2,
                               y: center.y - labelSize.height / 2 - 0.5),
                   withAttributes: attributes)
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
        ink.withAlphaComponent(0.15).setFill()
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
        let isHorizontal = labelPosition == "horizontal" || module.label.isEmpty
        let labelW = module.label.isEmpty ? 0 : estimatedLabelWidth(module.label)
        let trackH: CGFloat = 5
        let trackW: CGFloat
        let trackX: CGFloat
        let trackY: CGFloat

        if isHorizontal {
            trackW = min(28, max(20, rect.width - 4))
            trackX = rect.midX - trackW / 2
            trackY = module.label.isEmpty ? rect.midY - trackH / 2 : 13
        } else {
            trackW = max(18, rect.width - labelW - gap - 4)
            trackX = rect.minX + labelW + gap
            trackY = rect.midY - trackH / 2
        }

        let track = NSRect(x: trackX, y: trackY, width: trackW, height: trackH)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2)
        ink.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        if module.ratio > 0 {
            let fillW = max(trackH, trackW * module.ratio)
            let fillRect = NSRect(x: trackX, y: trackY, width: fillW, height: trackH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2, yRadius: trackH / 2)
            moduleColor(module).setFill()
            fillPath.fill()
        }

        if !module.label.isEmpty {
            if isHorizontal {
                drawHorizontalLabel(module.label, x: rect.midX, y: 1, in: rect)
            } else {
                drawHorizontalLabelCentered(module.label, x: rect.minX + labelW / 2, centerY: rect.midY, in: rect)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Dot
    // -----------------------------------------------------------------------

    private func drawDot(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal" || module.label.isEmpty
        let dotD: CGFloat = isHorizontal ? 7 : 6
        let dotX: CGFloat
        let dotY: CGFloat

        if isHorizontal {
            dotX = rect.midX - dotD / 2
            dotY = module.label.isEmpty ? rect.midY - dotD / 2 : 12
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

        if !module.label.isEmpty {
            if isHorizontal {
                drawHorizontalLabel(module.label, x: rect.midX, y: 1, in: rect)
            } else {
                let labelX = dotX - gap - estimatedCharWidth()
                drawVerticalLabel(module.label, x: labelX, in: rect)
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Circular bar
    // -----------------------------------------------------------------------

    private func drawCircular(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        // Smaller ring when the label sits below, so it fits between the
        // label and the top edge without clipping.
        let r: CGFloat = (isHorizontal && !module.label.isEmpty) ? 5.25 : circularRadius
        let centerY: CGFloat = (isHorizontal && !module.label.isEmpty) ? rect.midY + 4 : rect.midY
        let lineW = Self.circularStrokeWidth
        let strokeInset = lineW / 2
        let labelW = estimatedCharWidth()
        let ringX: CGFloat
        if isHorizontal || module.label.isEmpty {
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
        ink.withAlphaComponent(0.15).setStroke()
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
        if !module.label.isEmpty {
            if isHorizontal {
                drawHorizontalLabel(module.label, x: center.x, y: 1, in: rect, fontSize: circularHorizontalLabelFontSize)
            } else {
                let labelX = center.x - r - strokeInset - gap - labelW
                drawVerticalLabel(module.label, x: labelX, in: rect)
            }
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

        let outlineColor = ink.withAlphaComponent(0.55)
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

    // Both label fonts are fixed sizes (`fontSize` / `horizontalLabelFontSize`
    // are `let`), so their metrics never change for the life of the process —
    // but `draw(_:)` re-measured them on every frame, four times per pass for
    // the char width alone, at 30 fps. Text measurement means building an
    // NSString, resolving the font, and running a layout pass; it showed up in
    // a sample of the idle app. Measure once and keep it.

    /// Rough width of one character in the vertical label font.
    private static let cachedCharWidth: CGFloat = {
        ("X" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: verticalLabelFontSize, weight: .bold),
        ]).width
    }()

    /// Horizontal label widths, keyed by text. The label set is small and fixed
    /// (one per hardware module), so this saturates within the first frame.
    private static var labelWidthCache: [String: CGFloat] = [:]

    private func estimatedCharWidth() -> CGFloat { Self.cachedCharWidth }

    private func estimatedLabelWidth(_ text: String) -> CGFloat {
        if let cached = Self.labelWidthCache[text] { return cached }
        let w = (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: horizontalLabelFontSize, weight: .bold),
        ]).width
        Self.labelWidthCache[text] = w
        return w
    }

    // -----------------------------------------------------------------------
    // MARK: - Labels
    // -----------------------------------------------------------------------

    private func drawVerticalLabel(_ text: String, x: CGFloat, in rect: NSRect) {
        guard !text.isEmpty else { return }
        let chars = Array(text)
        let charH = min(fontSize + 1, (rect.height - 2) / CGFloat(max(1, chars.count)))
        let totalH = charH * CGFloat(chars.count)
        let startY = rect.midY + totalH / 2 - charH / 2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: ink.withAlphaComponent(0.8),
        ]
        for (i, ch) in chars.enumerated() {
            let s = String(ch) as NSString
            let sz = s.size(withAttributes: attrs)
            let cy = startY - CGFloat(i) * charH
            s.draw(at: NSPoint(x: x, y: cy - sz.height / 2), withAttributes: attrs)
        }
    }

    private func drawHorizontalLabel(_ text: String, x: CGFloat, y: CGFloat, in rect: NSRect, fontSize: CGFloat? = nil) {
        guard !text.isEmpty else { return }
        let s = text as NSString
        let labelFontSize = fontSize ?? horizontalLabelFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: labelFontSize, weight: .bold),
            .foregroundColor: ink.withAlphaComponent(0.7),
        ]
        let sz = s.size(withAttributes: attrs)
        let drawY = max(rect.minY + 1, min(y, rect.maxY - sz.height - 1))
        s.draw(at: NSPoint(x: x - sz.width / 2, y: drawY),
               withAttributes: attrs)
    }

    private func drawHorizontalLabelCentered(_ text: String, x: CGFloat, centerY: CGFloat, in rect: NSRect) {
        guard !text.isEmpty else { return }
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: horizontalLabelFontSize, weight: .bold),
            .foregroundColor: ink.withAlphaComponent(0.7),
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
            .foregroundColor: ink,
        ]
        let lblStr = module.label as NSString
        let lblAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueLabelFont,
            .foregroundColor: ink.withAlphaComponent(0.5),
            .kern: -0.4,
        ]
        // Unit drawn one size down and aligned to the number's baseline, so it
        // reads as a suffix ("49°", "12%") rather than a second full-size glyph.
        let unitStr = module.unit as NSString
        let hasUnit = !module.unit.isEmpty
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.valueUnitFont,
            .foregroundColor: ink,   // match the value's color
        ]

        let valSize = valStr.size(withAttributes: valAttrs)
        let unitSize = hasUnit ? unitStr.size(withAttributes: unitAttrs) : .zero
        let unitGap: CGFloat = hasUnit ? 1.5 : 0
        let numberUnitW = valSize.width + unitGap + unitSize.width

        let numberFont = Self.valueFont
        let labelFont = Self.valueLabelFont
        let unitFont = Self.valueUnitFont
        let numberCap = numberFont.capHeight
        let unitCap = unitFont.capHeight
        let unitLift: CGFloat = (module.unit.hasPrefix("°") || module.unit == "%") ? 1.5 : (numberCap - unitCap) / 2

        let fadingOut = module.isPowerValue && animatesPowerGlyph
            && powerGlyphProgress < 1 && powerGlyphPrevious != .none
        if module.showChargeIcon || module.showPlugIcon || fadingOut {
            let iconH: CGFloat = 8.0
            let iconW: CGFloat = 8.0
            let iconGap: CGFloat = 2.0
            let totalWidth = iconW + iconGap + numberUnitW
            let startX = rect.midX - totalWidth / 2
            let baseline = rect.midY - numberCap / 2 - 1.0

            func drawGlyph(_ glyph: PowerGlyph, opacity: CGFloat) {
                guard glyph != .none, opacity > 0 else { return }
                let symbolName = glyph == .bolt ? "bolt.fill" : "powerplug.portrait.fill"
                let fallbackName = glyph == .bolt ? "bolt.fill" : "powerplug.fill"
                guard let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil) else { return }
                let config = NSImage.SymbolConfiguration(pointSize: iconH, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
                let tinted = icon.withSymbolConfiguration(config) ?? icon
                let natural = tinted.size
                let drawW = natural.height > 0 ? min(iconW, iconH * natural.width / natural.height) : iconW
                let iconLift: CGFloat = 1.5
                let iconRect = NSRect(x: startX + (iconW - drawW) / 2,
                                      y: (rect.midY - 1.0 + iconLift) - iconH / 2,
                                      width: drawW, height: iconH)
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: opacity)
            }

            if module.isPowerValue && animatesPowerGlyph && powerGlyphProgress < 1 {
                drawGlyph(powerGlyphPrevious, opacity: 1 - powerGlyphProgress)
                drawGlyph(powerGlyphCurrent, opacity: powerGlyphProgress)
            } else {
                drawGlyph(module.showChargeIcon ? .bolt : .plug, opacity: 1)
            }

            let numX = startX + iconW + iconGap
            valStr.draw(at: NSPoint(x: numX, y: baseline + numberFont.descender), withAttributes: valAttrs)
            if hasUnit {
                let unitBaseline = baseline + unitLift
                unitStr.draw(at: NSPoint(x: numX + valSize.width + unitGap,
                                         y: unitBaseline + unitFont.descender),
                             withAttributes: unitAttrs)
            }
            return
        }

        let startX = rect.midX - numberUnitW / 2

        if module.label.isEmpty {
            let baseline = rect.midY - numberCap / 2 - 1.0
            valStr.draw(at: NSPoint(x: startX, y: baseline + numberFont.descender), withAttributes: valAttrs)
            if hasUnit {
                let unitBaseline = baseline + unitLift
                unitStr.draw(at: NSPoint(x: startX + valSize.width + unitGap,
                                         y: unitBaseline + unitFont.descender),
                             withAttributes: unitAttrs)
            }
        } else {
            let lblSize = lblStr.size(withAttributes: lblAttrs)
            let gap: CGFloat = 3.5    // spacing from the number's baseline to the label's cap
            let lift: CGFloat = -1.0  // nudge the whole block (positive = up, negative = down)
            let labelCap = labelFont.capHeight

            // Baseline that vertically centers [number cap | gap | label cap], + lift.
            let baseline = rect.midY + lift + (gap + labelCap - numberCap) / 2

            // Center the number + unit together, then hang the label under the pair.
            valStr.draw(at: NSPoint(x: startX, y: baseline + numberFont.descender), withAttributes: valAttrs)
            if hasUnit {
                let unitBaseline = baseline + unitLift
                unitStr.draw(at: NSPoint(x: startX + valSize.width + unitGap,
                                         y: unitBaseline + unitFont.descender),
                             withAttributes: unitAttrs)
            }

            let lblX = rect.midX - lblSize.width / 2
            let lblY = baseline - gap + labelFont.descender - labelCap
            lblStr.draw(at: NSPoint(x: lblX, y: lblY), withAttributes: lblAttrs)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Color
    // -----------------------------------------------------------------------

    /// Neutral below 60%, then yellow / orange (75%) / red (90%), eased between.
    private func barColor(ratio: CGFloat, forceWhite: Bool = false, preferredScale: String? = nil) -> NSColor {
        if forceWhite { return ink }
        if let warn = loadWarningColor(ratio) { return adapt(warn) }
        let scale = preferredScale ?? colorScale
        if scale == "green" { return adapt(NSColor(hue: 0.34, saturation: 0.62, brightness: 1.0, alpha: 1.0)) }
        return ink
    }

    /// Battery scale is inverted: low charge is the bad end.
    private func batteryColor(ratio: CGFloat) -> NSColor {
        if stats.isLowPowerMode { return NSColor.systemYellow }
        let r = max(0, min(1, ratio))
        if r <= 0.10 { return adapt(NSColor(hue: 0.0,  saturation: 0.9, brightness: 0.95, alpha: 1.0)) }
        if r <= 0.25 { return adapt(NSColor(hue: 0.10, saturation: 0.9, brightness: 0.95, alpha: 1.0)) }
        if colorScale == "green" { return adapt(NSColor(hue: 0.34, saturation: 0.62, brightness: 1.0, alpha: 1.0)) }
        return ink
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
        /// Draw a small lightning-bolt icon beside the value while charging.
        var showChargeIcon: Bool = false
        /// Show a plug beside the value or over the battery glyph when
        /// connected to power but not charging.
        var showPlugIcon: Bool = false
        /// Enables icon crossfading for numeric power/battery modules.
        var isPowerValue: Bool = false
        /// Battery module may crossfade into the connected-power ring.
        var isBatteryModule: Bool = false
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
                mods.append(Module(label: "", ratio: 0, isValue: true,
                                   valueText: "\(Int(t.rounded()))", unit: "°C", forceWhite: true))
            } else {
                let minT = AppSettings.shared.hardwareStatsTempMin
                let maxT = AppSettings.shared.hardwareStatsTempMax
                let range = max(1.0, maxT - minT)
                let tempRatio = CGFloat(max(0, min(1, (t - minT) / range)))
                mods.append(Module(label: "", ratio: tempRatio))
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
                                   showChargeIcon: stats.isCharging == true,
                                   showPlugIcon: stats.isCharging == false && stats.isExternalPowerConnected,
                                   isPowerValue: true))
            } else if let watts = stats.powerWatts {
                let powerRatio = CGFloat(max(0, min(1, watts / HardwareMonitor.modelMaxChargeWatts)))
                mods.append(Module(label: "PWR", ratio: powerRatio))
            } else {
                mods.append(Module(label: "PWR", ratio: 0, forceWhite: true))
            }
        case "battery":
            guard showBattery else { return }
            if usesBatteryPowerReadout {
                mods.append(Module(label: "", ratio: CGFloat(stats.batteryPercent ?? 0) / 100,
                                   forceWhite: true, isBatteryModule: true))
                return
            }
            // While crossfading to/from the connected-power ring, keep the
            // underlying battery style free of its own bolt/plug. Otherwise
            // that glyph flashes underneath the new ring on the first frame.
            let ringVisible = stats.isExternalPowerConnected || batteryRingBlend > 0
            if batteryStyle == "watts" {
                let valueText = stats.powerWatts.map { "\(Int($0.rounded()))" } ?? "—"
                mods.append(Module(label: "PWR", ratio: 0, isValue: true,
                                   valueText: valueText, unit: "W", forceWhite: true,
                                   showChargeIcon: !ringVisible && stats.isCharging == true,
                                   showPlugIcon: !ringVisible && stats.isCharging == false && stats.isExternalPowerConnected,
                                   isPowerValue: !ringVisible, isBatteryModule: true))
            } else if batteryStyle == "number" {
                let valueText = ringVisible ? stats.batteryPercent.map(String.init) ?? "—"
                    : stats.batteryPercentText(includeSymbol: false) ?? "—"
                mods.append(Module(label: "", ratio: 0, isValue: true,
                                   valueText: valueText, unit: "%", forceWhite: true,
                                   showChargeIcon: !ringVisible && stats.isCharging == true,
                                   showPlugIcon: !ringVisible && stats.isCharging == false && stats.isExternalPowerConnected,
                                   isPowerValue: !ringVisible, isBatteryModule: true))
            } else if batteryStyle == "icon" {
                let ratio = CGFloat(stats.batteryPercent ?? 0) / 100.0
                mods.append(Module(label: "", ratio: ratio,
                                   showChargeIcon: !ringVisible && stats.isCharging == true,
                                   showPlugIcon: !ringVisible && stats.isCharging == false && stats.isExternalPowerConnected,
                                   isBatteryModule: true, isBatteryIcon: true))
            } else if let pct = stats.batteryPercent {
                let ratio = CGFloat(pct) / 100.0
                mods.append(Module(label: "", ratio: ratio,
                                   isBatteryModule: true, customColor: batteryColor(ratio: ratio)))
            } else {
                mods.append(Module(label: "", ratio: 0, forceWhite: true, isBatteryModule: true))
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

        if usesBatteryPowerReadout, count == 1, modules.first?.isBatteryModule == true {
            return NSSize(width: batteryPowerReadoutWidth + 4 + leftPadding, height: 22)
        }

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
        let fadingOut = m.isPowerValue && animatesPowerGlyph
            && powerGlyphProgress < 1 && powerGlyphPrevious != .none
        if m.showChargeIcon || m.showPlugIcon || fadingOut { w += 2 + 8 }   // icon gap + icon
        return w + 6
    }

    func updateSize() {
        frame.size = intrinsicContentSize
        if let btn = superview as? NSStatusBarButton {
            btn.frame = frame
        }
    }

    /// Everything `draw(_:)` reads, flattened into a comparable key.
    ///
    /// Ratios are quantised to 1/1000 — far finer than one pixel at menu bar
    /// scale, so this can never drop a frame the user would have seen, while
    /// still collapsing the common case where a poll lands on identical values.
    /// Anything that changes the drawn pixels but is NOT a module value must be
    /// listed here too, or the cache serves a stale image until some number
    /// happens to move. `colorScale`, `menuBarIsDark` and `isLowPowerMode` all
    /// feed `barColor`/`batteryColor`/`ink` without touching any ratio.
    private func renderSignature(size: NSSize) -> String {
        var parts: [String] = [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            barStyle, labelPosition, colorScale,
            menuBarIsDark ? "dark" : "light",
            stats.isLowPowerMode ? "lpm" : "-",
            usesBatteryPowerReadout ? "battery-readout" : "-",
            stats.isExternalPowerConnected ? "ac" : "dc",
            stats.isCharging == true ? "charging" : "paused",
            powerGlyphCurrent.rawValue, powerGlyphPrevious.rawValue, "\(Int((powerGlyphProgress * 64).rounded()))",
            "ring:\(Int((batteryRingBlend * 64).rounded())):\(stats.batteryPercent ?? -1):\(batteryPowerText)",
        ]
        for m in activeModules() {
            let ratio = m.isValue ? m.ratio : (displayedRatios[m.label] ?? m.ratio)
            parts.append([
                m.label,
                // Quarter-pixel steps of a ~16 pt bar at 2×: finer changes
                // render identically, so they must not count as a new frame.
                String(Int((ratio * 128).rounded())),
                m.valueText, m.unit,
                m.isValue ? "v" : "-",
                m.isBatteryIcon ? "b" : "-",
                m.showChargeIcon ? "c" : "-",
                m.showPlugIcon ? "p" : "-",
                m.forceWhite ? "w" : "-",
                m.customColor.map { "\($0)" } ?? "-",
            ].joined(separator: ":"))
        }
        return parts.joined(separator: "|")
    }

    private var lastRenderSignature: String?
    private var lastRenderedImage: NSImage?

    /// Rebuilding the status item image means a fresh NSImage plus a full
    /// `draw(_:)` pass. HardwareMonitor notifies on every poll whether or not
    /// the numbers moved, and the last frame of a bar animation lands on the
    /// same pixels as the one before it, so a good share of those passes
    /// produced an image identical to the one already on screen. Reuse it.
    func renderedImage() -> NSImage {
        let size = intrinsicContentSize
        frame.size = size

        let signature = renderSignature(size: size)
        if signature == lastRenderSignature, let cached = lastRenderedImage {
            return cached
        }

        // Cache pixels, not a drawing handler that AppKit may invoke again on
        // every menu-bar repaint. The handler also retained this view through
        // lastRenderedImage. Render at Retina resolution without a closure.
        let scale: CGFloat = 2
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * scale)),
                pixelsHigh: Int(ceil(size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: size)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        lastRenderSignature = signature
        lastRenderedImage = image
        return image
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

final class PopoverShellView: NSView {
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

    let cornerRadius: CGFloat
    let arrowWidth: CGFloat
    let arrowHeight: CGFloat

    /// Horizontal center of the arrow, in this view's own bounds.
    var arrowCenterX: CGFloat {
        didSet { needsLayout = true }
    }

    /// False when opened above the Edge Keys strip: a plain rounded card, no arrow.
    var showsArrow = true {
        didSet { needsLayout = true }
    }

    init(cornerRadius: CGFloat, arrowWidth: CGFloat, arrowHeight: CGFloat, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.arrowCenterX = 0
        super.init(frame: .zero)
        wantsLayer = true

        effect.material = blendingMode == .behindWindow ? .fullScreenUI : .popover
        effect.blendingMode = blendingMode
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
            // TokenBar's copy of this shell also sets `glass.effectIsInteractive`
            // on macOS 27 (pointer-reactive glass, as the system's own menu-bar
            // surfaces do). Omitted here only because build.sh compiles against
            // the 26.5 SDK, which has no such property — add it behind an
            // `if #available(macOS 27.0, *)` once this builds on the 27 SDK.
            addSubview(glass)
            glassEffect = glass
        }

        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        strokeLayer.lineWidth = 0.5
        layer?.addSublayer(strokeLayer)

        refreshAppearance()
        // Posted on the workspace's own centre, not NotificationCenter.default.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
                                   arrowWidth: arrowWidth, arrowHeight: showsArrow ? arrowHeight : 0,
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
        guard size.width > 0, size.height > 0 else { return CGMutablePath() }
        if arrowHeight <= 0 || arrowWidth <= 0 {
            let actualRadius = min(r, min(size.width, size.height) / 2)
            return CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: actualRadius, cornerHeight: actualRadius, transform: nil)
        }
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
// HardwarePopoverContentView — content view displaying hardware cards
// ---------------------------------------------------------------------------

final class HardwarePopoverContentView: NSView {
    let shell: PopoverShellView
    let stack: NSStackView

    var energyModes = HardwareMonitor.EnergyModes()
    var lastBarRatios: [String: CGFloat] = [:]
    var lastPowerWatts: Double?

    var cardColumns: [[String]] = AppSettings.shared.hardwareStatsCardColumns {
        didSet {
            columns = cardColumns.count
        }
    }
    var columns: Int = 2
    var moduleOrder: [String] = AppSettings.hardwareModuleIDs
    var hiddenCards: Set<String> = []
    var hidesBatteryCard: Bool = false
    var batteryCardSpan = AppSettings.shared.hardwareStatsBatteryCardSpan
    var batteryCardSide = AppSettings.shared.hardwareStatsBatteryCardSide
    private var cardViews: [String: NSView] = [:]

    /// Geometry comes from the same constraints that draw the live popover.
    var cardFrames: [String: NSRect] {
        cardViews.compactMapValues { view in
            guard view.isDescendant(of: self) else { return nil }
            return view.convert(view.bounds, to: self)
        }
    }


    var isInteractive: Bool = true
    var arrowHeight: CGFloat = 8
    var onSettings: (() -> Void)?
    var onPresetChanged: ((String) -> Void)?
    var onSelectEnergyMode: ((Int) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    let shellRadius = CardStyle.popoverRadius
    let gutter = CardStyle.gutter
    var cardCornerRadius: CGFloat { max(0, shellRadius - gutter) }

    var popWidth: CGFloat {
        cardColumns.count >= 3 ? 368 : 248
    }

    var contentWidth: CGFloat { popWidth - gutter * 2 }

    private var cachedContentHeight: CGFloat = 200

    var contentHeight: CGFloat {
        cachedContentHeight
    }

    private lazy var headerRow: PopoverHeaderRow = {
        let row = PopoverHeaderRow(title: "Hardware")
        return row
    }()

    private lazy var footerRow: PopoverFooterRow = {
        let row = PopoverFooterRow(onSettings: { [weak self] in
            self?.onSettings?()
        })
        return row
    }()

    private var headerWidthConstraint: NSLayoutConstraint?
    private var footerWidthConstraint: NSLayoutConstraint?

    init(isInteractive: Bool = true, arrowHeight: CGFloat = 8, blendingMode: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.isInteractive = isInteractive
        self.arrowHeight = arrowHeight
        self.shell = PopoverShellView(cornerRadius: shellRadius,
                                      arrowWidth: arrowHeight > 0 ? 16 : 0,
                                      arrowHeight: arrowHeight,
                                      blendingMode: blendingMode)
        self.stack = NSStackView()
        let initialW: CGFloat = AppSettings.shared.hardwareStatsCardColumns.count >= 3 ? 368 : 248
        super.init(frame: NSRect(x: 0, y: 0, width: initialW, height: 200))

        shell.frame = bounds
        shell.autoresizingMask = [.width, .height]
        addSubview(shell)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: gutter, bottom: 8, right: gutter)
        addSubview(stack)

        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        trailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: arrowHeight > 0 ? arrowHeight : 0),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        shell.frame = bounds
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: popWidth, height: cachedContentHeight)
    }

    private func makeGridCard(_ id: String, stats s: HardwareStats) -> NSView? {
        let card = makeGridCardContent(id, stats: s)
        cardViews[id] = card
        return card
    }

    private func makeGridCardContent(_ id: String, stats s: HardwareStats) -> NSView? {
        switch id {
        case "cpu":
            let ratio = CGFloat(min(s.cpuPercent / 100.0, 1.0))
            let card = StatCard(caption: "CPU",
                                value: String(format: "%.1f%%", s.cpuPercent),
                                barRatio: ratio,
                                previousBarRatio: lastBarRatios["cpu"],
                                cornerRadius: cardCornerRadius)
            lastBarRatios["cpu"] = ratio
            return card

        case "gpu":
            let ratio = CGFloat(min(s.gpuPercent / 100.0, 1.0))
            let card = StatCard(caption: "GPU",
                                value: String(format: "%.1f%%", s.gpuPercent),
                                barRatio: ratio,
                                previousBarRatio: lastBarRatios["gpu"],
                                cornerRadius: cardCornerRadius)
            lastBarRatios["gpu"] = ratio
            return card

        case "memory":
            let pressure: (pct: Int, ratio: CGFloat) = {
                switch s.memoryPressure {
                case .normal:   return (25, 0.25)
                case .warning:  return (60, 0.60)
                case .critical: return (90, 0.90)
                }
            }()
            let card = StatCard(caption: "MEM",
                                captionDetail: String(format: "%.1f GB", s.memoryUsedGB),
                                value: "\(pressure.pct)%",
                                barRatio: pressure.ratio,
                                previousBarRatio: lastBarRatios["memory"],
                                cornerRadius: cardCornerRadius)
            lastBarRatios["memory"] = pressure.ratio
            return card

        case "temp":
            let t = s.cpuTemp ?? s.gpuTemp
            let minT = AppSettings.shared.hardwareStatsTempMin
            let maxT = AppSettings.shared.hardwareStatsTempMax
            let tempRatio = t.map { CGFloat(max(0, min(1, ($0 - minT) / max(1.0, maxT - minT)))) }
            let card = StatCard(caption: "TEMP",
                                value: t.map { String(format: "%.0f°C", $0) } ?? "—",
                                barRatio: tempRatio,
                                previousBarRatio: tempRatio != nil ? lastBarRatios["temp"] : nil,
                                cornerRadius: cardCornerRadius)
            if let tempRatio {
                lastBarRatios["temp"] = tempRatio
            } else {
                lastBarRatios.removeValue(forKey: "temp")
            }
            return card

        case "fps":
            let card = StatCard(caption: "FPS", value: "\(s.fps)", detail: "frames per second",
                                cornerRadius: cardCornerRadius)
            return card

        default:
            return nil
        }
    }

    func rebuild(stats s: HardwareStats, powerSamples: [Double] = HardwareMonitor.shared.powerHistory) {
        if frame.size.width != popWidth {
            frame.size.width = popWidth
            shell.frame = bounds
        }
        cardViews.removeAll()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        headerRow.update(isActive: HardwareMonitor.shared.isPolling)
        stack.addArrangedSubview(headerRow)
        headerWidthConstraint?.isActive = false
        headerWidthConstraint = headerRow.widthAnchor.constraint(equalToConstant: contentWidth)
        headerWidthConstraint?.isActive = true

        let totalWidth = contentWidth
        let spacing: CGFloat = 8

        let effectiveColumns: [[String]] = {
            let cols = cardColumns.prefix(3).map { col in
                col.filter { !hiddenCards.contains($0) }
            }
            let nonEmpty = cols.filter { !$0.isEmpty }
            return nonEmpty.isEmpty ? [[]] : nonEmpty
        }()

        let columnsRow = NSStackView()
        columnsRow.orientation = .horizontal
        columnsRow.spacing = spacing
        columnsRow.alignment = .top
        columnsRow.distribution = .fillEqually

        var hasGridCards = false
        for colCards in effectiveColumns {
            let colStack = NSStackView()
            colStack.orientation = .vertical
            colStack.spacing = spacing
            colStack.alignment = .leading

            for cardID in colCards {
                if let card = makeGridCard(cardID, stats: s) {
                    colStack.addArrangedSubview(card)
                    card.widthAnchor.constraint(equalTo: colStack.widthAnchor).isActive = true
                    hasGridCards = true
                }
            }
            if !colStack.arrangedSubviews.isEmpty {
                columnsRow.addArrangedSubview(colStack)
            }
        }

        struct PopoverSectionItem {
            let orderIndex: Int
            let view: NSView
        }
        var sections: [PopoverSectionItem] = []

        let showsBatteryCard = s.batteryPercent != nil && !hidesBatteryCard && !hiddenCards.contains("battery")
        let showPowerGraph = powerSamples.count >= 2
        let batteryIndex = moduleOrder.firstIndex(of: "battery") ?? 999
        let gridIndex = moduleOrder.firstIndex { AppSettings.hardwareGridCardIDs.contains($0) && !hiddenCards.contains($0) } ?? 999
        let is3Cols = cardColumns.count >= 3
        let isBattery2x2 = is3Cols && batteryCardSpan == "2x2" && showsBatteryCard
            && effectiveColumns.contains { !$0.isEmpty }

        if isBattery2x2 {
            let allGridCards = effectiveColumns.flatMap { $0 }
            let sideCards = Array(allGridCards.prefix(2))
            let remainingCards = Array(allGridCards.dropFirst(2))

            let sideCol = NSStackView()
            sideCol.orientation = .vertical
            sideCol.distribution = .fillEqually
            sideCol.spacing = spacing
            sideCol.alignment = .leading
            for cardID in sideCards {
                if let card = makeGridCard(cardID, stats: s) {
                    sideCol.addArrangedSubview(card)
                    card.widthAnchor.constraint(equalToConstant: 110).isActive = true
                }
            }
            sideCol.widthAnchor.constraint(equalToConstant: 110).isActive = true

            let batteryW: CGFloat = totalWidth - 110 - spacing
            let battery2x2 = makeBatteryDetailCard(stats: s, contentWidth: batteryW,
                                                   cornerRadius: cardCornerRadius,
                                                   energyModes: energyModes,
                                                   powerSamples: showPowerGraph ? powerSamples : nil,
                                                   previousPowerWatts: lastPowerWatts) { [weak self] mode in
                guard let self, self.isInteractive else { return }
                self.onSelectEnergyMode?(mode)
            }
            cardViews["battery"] = battery2x2
            lastPowerWatts = s.powerWatts
            battery2x2.widthAnchor.constraint(equalToConstant: batteryW).isActive = true

            let compositeRow = NSStackView()
            compositeRow.orientation = .horizontal
            compositeRow.spacing = spacing
            compositeRow.alignment = .top
            if batteryCardSide == "right" {
                compositeRow.addArrangedSubview(sideCol)
                compositeRow.addArrangedSubview(battery2x2)
            } else {
                compositeRow.addArrangedSubview(battery2x2)
                compositeRow.addArrangedSubview(sideCol)
            }
            if !sideCol.arrangedSubviews.isEmpty {
                sideCol.heightAnchor.constraint(equalTo: battery2x2.heightAnchor).isActive = true
            }
            compositeRow.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
            sections.append(PopoverSectionItem(orderIndex: min(batteryIndex, gridIndex), view: compositeRow))

            if !remainingCards.isEmpty {
                let remainingRow = NSStackView()
                remainingRow.orientation = .horizontal
                remainingRow.spacing = spacing
                remainingRow.alignment = .top
                remainingRow.distribution = .fillEqually

                var remCols: [[String]] = [[], [], []]
                for (idx, c) in remainingCards.enumerated() {
                    remCols[idx % 3].append(c)
                }
                for col in remCols where !col.isEmpty {
                    let colStack = NSStackView()
                    colStack.orientation = .vertical
                    colStack.spacing = spacing
                    colStack.alignment = .leading
                    for cardID in col {
                        if let card = makeGridCard(cardID, stats: s) {
                            colStack.addArrangedSubview(card)
                            card.widthAnchor.constraint(equalTo: colStack.widthAnchor).isActive = true
                        }
                    }
                    remainingRow.addArrangedSubview(colStack)
                }
                remainingRow.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
                sections.append(PopoverSectionItem(orderIndex: max(batteryIndex, gridIndex), view: remainingRow))
            }
        } else {
            if hasGridCards {
                columnsRow.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
                sections.append(PopoverSectionItem(orderIndex: gridIndex, view: columnsRow))
            }

            if showsBatteryCard {
                let batteryCard = makeBatteryCard(s, powerSamples: showPowerGraph ? powerSamples : nil)
                cardViews["battery"] = batteryCard
                batteryCard.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
                sections.append(PopoverSectionItem(orderIndex: batteryIndex, view: batteryCard))
            } else if showPowerGraph && !hiddenCards.contains("battery") {
                let graph = PowerGraphCard(samples: powerSamples, cornerRadius: cardCornerRadius)
                cardViews["battery"] = graph
                graph.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
                sections.append(PopoverSectionItem(orderIndex: batteryIndex, view: graph))
            }
        }

        if !s.fans.isEmpty && !hiddenCards.contains("fan") {
            let fansCard = makeFansCard(s.fans)
            cardViews["fan"] = fansCard
            fansCard.widthAnchor.constraint(equalToConstant: totalWidth).isActive = true
            let fanIndex = moduleOrder.firstIndex(of: "fan") ?? 999
            sections.append(PopoverSectionItem(orderIndex: fanIndex, view: fansCard))
        }

        sections.sort { $0.orderIndex < $1.orderIndex }
        for sec in sections {
            stack.addArrangedSubview(sec.view)
        }

        stack.addArrangedSubview(footerRow)
        footerWidthConstraint?.isActive = false
        footerWidthConstraint = footerRow.widthAnchor.constraint(equalToConstant: contentWidth)
        footerWidthConstraint?.isActive = true

        cachedContentHeight = max(60, stack.fittingSize.height) + (arrowHeight > 0 ? arrowHeight : 0)
        invalidateIntrinsicContentSize()
        onHeightChange?(cachedContentHeight)
    }

    private func makeFansCard(_ fans: [FanInfo]) -> NSView {
        let card = CardView(cornerRadius: cardCornerRadius)

        let inner = NSStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 5
        inner.edgeInsets = NSEdgeInsets(top: CardStyle.cardPaddingV, left: CardStyle.cardPaddingH,
                                        bottom: CardStyle.cardPaddingV, right: CardStyle.cardPaddingH)
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let rowWidth = contentWidth - CardStyle.cardPaddingH * 2

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = StatCard.titleString("Fans")
        inner.addArrangedSubview(caption)
        inner.setCustomSpacing(7, after: caption)

        for f in fans {
            let ratio = f.max > 0 ? CGFloat(f.current) / CGFloat(f.max) : 0

            let name = NSTextField(labelWithString: f.name)
            name.font = CardStyle.rowTitleFont
            name.textColor = .labelColor
            name.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let value = NSTextField(labelWithString: "\(f.current) RPM · \(Int(ratio * 100))%")
            value.font = CardStyle.valueFont
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.setContentHuggingPriority(.defaultHigh, for: .horizontal)

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
            bar.heightAnchor.constraint(equalToConstant: CardStyle.barHeight).isActive = true
            inner.setCustomSpacing(8, after: bar)
        }

        let presetLabel = NSTextField(labelWithString: "Preset")
        presetLabel.font = CardStyle.captionFont
        presetLabel.textColor = .secondaryLabelColor
        presetLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

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
        presetBtn.font = NSFont.systemFont(ofSize: 11)
        presetBtn.isEnabled = isInteractive

        let presetRow = NSStackView(views: [presetLabel, presetSpacer, presetBtn])
        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.alignment = .centerY
        inner.addArrangedSubview(presetRow)
        presetRow.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        return card
    }

    private func makeBatteryCard(_ s: HardwareStats, powerSamples: [Double]? = nil) -> NSView {
        let card = makeBatteryDetailCard(stats: s, contentWidth: contentWidth,
                              cornerRadius: cardCornerRadius,
                              energyModes: energyModes,
                              powerSamples: powerSamples,
                              previousPowerWatts: lastPowerWatts) { [weak self] mode in
            guard let self, self.isInteractive else { return }
            self.onSelectEnergyMode?(mode)
        }
        lastPowerWatts = s.powerWatts
        return card
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        guard isInteractive else { return }
        let map = ["Default": "default", "Silent": "silent", "Performance": "performance"]
        guard let title = sender.selectedItem?.title,
              let preset = map[title] else { return }
        onPresetChanged?(preset)
    }
}

// ---------------------------------------------------------------------------
// HardwarePopover — detailed stats shown on click
// ---------------------------------------------------------------------------

final class HardwarePopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HardwarePopover: NSObject {
    private let window: HardwarePopoverPanel
    private let contentView: HardwarePopoverContentView
    private var pollTimer: Timer?
    private var resizeTimer: Timer?
    private var closeMonitor: Any?
    private weak var sourceButton: NSStatusBarButton?
    private var menuTrackingCount = 0
    private var menuTrackingObservers: [NSObjectProtocol] = []

    private var energyModes = HardwareMonitor.EnergyModes()

    var hidesBatteryCard: Bool {
        get { contentView.hidesBatteryCard }
        set { contentView.hidesBatteryCard = newValue }
    }

    var isShown: Bool { window.isVisible }

    override init() {
        contentView = HardwarePopoverContentView(isInteractive: true, arrowHeight: 8, blendingMode: .behindWindow)
        let initialWidth = contentView.popWidth
        let p = HardwarePopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        if #available(macOS 13.0, *) {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        } else {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        p.contentView = contentView
        window = p

        super.init()

        contentView.onSettings = { [weak self] in
            self?.openSettings()
        }
        contentView.onPresetChanged = { [weak self] preset in
            AppSettings.shared.hardwareStatsFanPreset = preset
            HardwareMonitor.shared.applySelectedFanPresetFromUser()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.rebuild()
            }
        }
        contentView.onSelectEnergyMode = { [weak self] mode in
            self?.selectEnergyMode(mode)
        }

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
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.close()
        })
    }

    deinit {
        menuTrackingObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Where it opens above the Edge Keys strip (screen coordinates); nil when
    /// it hangs from the menu bar.
    private var stripAnchor: NSRect?

    /// Above the strip's hardware stats: flush with the display's right edge,
    /// no arrow, growing upward.
    func show(above rect: NSRect) {
        sourceButton = nil
        stripAnchor = rect
        contentView.shell.showsArrow = false
        contentView.shell.refreshAppearance()
        refreshEnergyModes()
        rebuild()
        window.setFrame(stripFrame(for: rect), display: true)
        if let parent = window.parent { parent.removeChildWindow(window) }
        window.orderFrontRegardless()
        startTracking()
    }

    private func stripFrame(for rect: NSRect) -> NSRect {
        let width = contentView.popWidth, height = contentView.contentHeight
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let right = screen?.frame.maxX ?? rect.maxX
        return NSRect(x: right - width, y: rect.maxY + 8, width: width, height: height)
    }

    func show(relativeTo button: NSStatusBarButton) {
        sourceButton = button
        stripAnchor = nil
        contentView.shell.showsArrow = true
        contentView.shell.refreshAppearance()
        refreshEnergyModes()
        rebuild()

        let popWidth = contentView.popWidth
        let contentHeight = contentView.contentHeight

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        let screen = button.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let menuBarBottom: CGFloat
        if screenRect != .zero {
            menuBarBottom = screenRect.maxY - NSStatusBar.system.thickness
        } else if let screen {
            menuBarBottom = screen.frame.maxY - NSStatusBar.system.thickness
        } else {
            menuBarBottom = NSEvent.mouseLocation.y
        }

        let targetMidX = screenRect != .zero ? screenRect.midX : NSEvent.mouseLocation.x
        var origin = NSPoint(x: targetMidX - popWidth / 2,
                             y: menuBarBottom - contentHeight - 4)
        if let screen {
            let vf = screen.visibleFrame
            if origin.x + popWidth > vf.maxX { origin.x = vf.maxX - popWidth - 4 }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
        }

        let minCenter = 16 + contentView.shell.arrowWidth / 2
        let maxCenter = popWidth - 16 - contentView.shell.arrowWidth / 2
        let wanted = targetMidX - origin.x
        contentView.shell.arrowCenterX = max(minCenter, min(maxCenter, wanted))
        contentView.shell.layoutSubtreeIfNeeded()

        window.setFrame(NSRect(x: origin.x, y: origin.y, width: popWidth, height: contentHeight), display: true)
        if let btnWin = button.window, window.parent != btnWin {
            btnWin.addChildWindow(window, ordered: .above)
        }
        window.orderFrontRegardless()
        startTracking()
    }

    /// Closing on outside clicks, and the live refresh while it's open.
    private func startTracking() {
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
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        resizeTimer?.invalidate(); resizeTimer = nil
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        if let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window.orderOut(nil)
    }

    private func rebuild() {
        contentView.cardColumns = AppSettings.shared.hardwareStatsCardColumns
        contentView.columns = AppSettings.shared.hardwareStatsCardColumns.count
        contentView.moduleOrder = AppSettings.shared.hardwareStatsModuleOrder
        contentView.batteryCardSpan = AppSettings.shared.hardwareStatsBatteryCardSpan
        contentView.batteryCardSide = AppSettings.shared.hardwareStatsBatteryCardSide
        contentView.hiddenCards = Set(AppSettings.shared.hardwareStatsHiddenCards)
        contentView.energyModes = energyModes
        contentView.rebuild(stats: HardwareMonitor.shared.stats, powerSamples: HardwareMonitor.shared.powerHistory)
        resizeWindow()
    }

    private func openSettings() {
        close()
        if #available(macOS 14.0, *) {
            SettingsWindowController.shared.show(pane: .hardware)
        }
    }

    private func refreshValues() {
        guard menuTrackingCount == 0 else { return }
        rebuild()
    }

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
        guard window.isVisible else { return }
        if let stripAnchor {
            // Above the strip the bottom stays put and it grows upward.
            window.setFrame(stripFrame(for: stripAnchor), display: true, animate: animated)
            return
        }
        let h = contentView.contentHeight
        let popWidth = contentView.popWidth
        let lockedTopY = window.frame.maxY

        var originX = window.frame.minX
        if let btn = sourceButton {
            let screen = btn.window?.screen
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            let buttonRect = btn.convert(btn.bounds, to: nil)
            let screenRect = btn.window?.convertToScreen(buttonRect) ?? .zero
            let targetMidX = screenRect != .zero ? screenRect.midX : (window.frame.minX + popWidth / 2)
            originX = targetMidX - popWidth / 2
            if let screen {
                let vf = screen.visibleFrame
                if originX + popWidth > vf.maxX { originX = vf.maxX - popWidth - 4 }
                if originX < vf.minX { originX = vf.minX + 4 }
            }

            let minCenter = 16 + contentView.shell.arrowWidth / 2
            let maxCenter = popWidth - 16 - contentView.shell.arrowWidth / 2
            let wanted = targetMidX - originX
            contentView.shell.arrowCenterX = max(minCenter, min(maxCenter, wanted))
            contentView.shell.layoutSubtreeIfNeeded()
        }

        let newFrame = NSRect(x: originX, y: lockedTopY - h, width: popWidth, height: h)
        if animated {
            animateWindowHeight(to: h, targetWidth: popWidth, lockedTopY: lockedTopY)
        } else {
            resizeTimer?.invalidate(); resizeTimer = nil
            window.setFrame(newFrame, display: true, animate: false)
        }
    }

    private func animateWindowHeight(to targetHeight: CGFloat, targetWidth: CGFloat, lockedTopY: CGFloat) {
        resizeTimer?.invalidate()

        let startHeight = window.frame.height
        let delta = targetHeight - startHeight
        guard abs(delta) > 0.5 else {
            window.setFrame(NSRect(x: window.frame.minX, y: lockedTopY - targetHeight,
                                   width: targetWidth, height: targetHeight),
                            display: true, animate: false)
            return
        }

        let start = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.18
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
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
                                        width: targetWidth,
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

// ---------------------------------------------------------------------------
// CardStyle — shared design tokens for the popover surface
// ---------------------------------------------------------------------------

/// The popover's design language, ported from TokenBar's menu (its
/// `CardMetrics` + `providerCard`) so both menu bar apps read as one family.
/// Shared by copy, not by module — when either moves, move the other.
///
/// The radii stay concentric: a card inset by `gutter` inside the shell needs
/// `cardRadius = popoverRadius − gutter`, or the gap pinches at the corners
/// while the straight edges still look right.
enum CardStyle {
    static let popoverRadius: CGFloat = 20
    static let gutter: CGFloat = 8                      // padding around/between cards
    static let cardRadius: CGFloat = popoverRadius - gutter
    static let cardPaddingH: CGFloat = 12
    static let cardPaddingV: CGFloat = 10
    static let footerInset: CGFloat = 4                 // vertical inset for header/footer chrome
    static let panelRadius: CGFloat = 8                 // inner panels and chips
    static let barHeight: CGFloat = 4

    // Label-derived rather than hardcoded white. The glass under these cards is
    // light over a light wallpaper even while the system is in Dark mode, and a
    // white wash disappears there. TokenBar gets this free from `Color.primary`;
    // an AppKit layer has to resolve the dynamic color itself (see CardView).
    static let cardFill = scalingAlpha(.labelColor, by: 0.05)
    static let cardStroke = scalingAlpha(.labelColor, by: 0.07)
    static let barTrack = scalingAlpha(.secondaryLabelColor, by: 0.15)
    static let chipFill = scalingAlpha(.labelColor, by: 0.05)
    static let chipHoverFill = scalingAlpha(.labelColor, by: 0.10)

    /// SwiftUI's `.opacity()` *multiplies* a color's own alpha; AppKit's
    /// `withAlphaComponent` replaces it. The label colors are not opaque —
    /// labelColor carries 0.847, secondaryLabelColor 0.498 light / 0.549 dark —
    /// so replacing rendered these fills ~18% and the bar tracks ~80% heavier
    /// than the identical tokens in TokenBar. Multiply instead, and do it at
    /// resolve time so each appearance multiplies by its own base alpha.
    private static func scalingAlpha(_ base: NSColor, by factor: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            return resolved.withAlphaComponent(resolved.alphaComponent * factor)
        }
    }

    /// Card headline — the name of a full-width card ("Battery", "Fans").
    static let cardTitleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// Field label above a reading ("CPU", "Energy Mode") — TokenBar's "Session".
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Left-hand name of a list row inside a card (a fan's name).
    static let rowTitleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Footnote under a reading ("frames per second", adapter wattage).
    static let detailFont = NSFont.systemFont(ofSize: 10)
    /// Inline reading on a row — TokenBar's "49% left".
    static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold) }
    /// The one big number a stat card exists to show.
    static var heroFont: NSFont { .monospacedDigitSystemFont(ofSize: 16, weight: .semibold) }
    /// Secondary figure sitting beside a caption (the MEM card's "16.2 GB").
    static var captionDetailFont: NSFont { .monospacedDigitSystemFont(ofSize: 10, weight: .medium) }
}

/// Card surface: a soft fill plus a hairline stroke, both re-resolved whenever
/// the effective appearance flips. A CGColor is a *resolved* snapshot, so a
/// layer set once from a dynamic NSColor would keep the old appearance's color
/// forever — hence the explicit re-resolve rather than a plain assignment.
class CardView: NSView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 1
        applyCardColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCardColors()
    }

    private func applyCardColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = CardStyle.cardFill.cgColor
            layer?.borderColor = CardStyle.cardStroke.cgColor
        }
    }
}

// ---------------------------------------------------------------------------
// StatCard — rounded metric card used by HardwarePopover
// ---------------------------------------------------------------------------

/// One metric as a card: dim uppercase caption, large value, and either a
/// thin threshold-tinted bar or a footnote line at the bottom.
/// Full-width card plotting recent system wattage as a filled sparkline.
///
/// The numbers next to it are a single instant; power is the one reading here
/// that swings hard and fast (a build starting, the display waking), and the
/// shape of the last couple of minutes says more about what the machine is
/// doing than the current sample does.
///
/// Deliberately axis-free. The x spacing is the poll interval, which the user
/// can change, so labelling it in seconds would be a lie the moment they move
/// the slider — the caption names the span in samples instead. The y range is
/// autoscaled to the window's own min/max, so small idle wobble stays legible
/// rather than flattening against a fixed 100W ceiling.
/// Sparkline view plotting recent system wattage as a filled green gradient.
final class PowerGraphView: NSView {

    let samples: [Double]

    init(samples: [Double]) {
        self.samples = samples
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Autoscale window. Padded by 10% of the span so the peak never rides the
    /// top edge, and floored to a 1W span so a perfectly flat idle trace draws
    /// as a line through the middle instead of dividing by zero.
    static func range(of samples: [Double]) -> ClosedRange<Double> {
        guard let lo = samples.min(), let hi = samples.max() else { return 0...1 }
        let pad = max(0.5, (hi - lo) * 0.1)
        let low = max(0, lo - pad)
        let high = max(low + 1, hi + pad)
        return low...high
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard samples.count >= 2 else { return }

        let plot = bounds
        guard plot.width > 1, plot.height > 1 else { return }

        let r = Self.range(of: samples)
        let span = r.upperBound - r.lowerBound
        let step = plot.width / CGFloat(samples.count - 1)

        func point(_ i: Int) -> NSPoint {
            let v = (samples[i] - r.lowerBound) / span
            return NSPoint(x: plot.minX + CGFloat(i) * step,
                           y: plot.minY + CGFloat(v) * plot.height)
        }

        let line = NSBezierPath()
        line.move(to: point(0))
        for i in 1..<samples.count { line.line(to: point(i)) }

        // Fill first, so the stroke sits on top of its own gradient edge.
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        fill.line(to: NSPoint(x: plot.minX, y: plot.minY))
        fill.close()

        NSGraphicsContext.saveGraphicsState()
        fill.addClip()
        let tint = NSColor.systemGreen
        NSGradient(colors: [tint.withAlphaComponent(0.32), tint.withAlphaComponent(0.02)])?
            .draw(in: plot, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        tint.setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()
    }
}

private final class PowerGraphCard: CardView {

    init(samples: [Double], cornerRadius: CGFloat = 8) {
        super.init(cornerRadius: cornerRadius)

        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = StatCard.captionString("Power")
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        let range = PowerGraphView.range(of: samples)
        let peak = NSTextField(labelWithString: String(format: "%.1f W peak", range.upperBound))
        peak.font = CardStyle.captionFont
        peak.textColor = .tertiaryLabelColor
        peak.translatesAutoresizingMaskIntoConstraints = false
        addSubview(peak)

        let graph = PowerGraphView(samples: samples)
        graph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graph)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 78),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: CardStyle.cardPaddingV),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            peak.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            peak.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
            graph.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            graph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            graph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
            graph.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CardStyle.cardPaddingV),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

private final class StatCard: CardView {

    init(caption: String,
         captionDetail: String? = nil,
         captionDetailColor: NSColor? = nil,
         value: String,
         detail: String? = nil,
         barRatio: CGFloat? = nil,
         previousBarRatio: CGFloat? = nil,
         showsBolt: Bool = false,
         cornerRadius: CGFloat = 8) {
        super.init(cornerRadius: cornerRadius)

        let captionLabel = NSTextField(labelWithString: "")
        captionLabel.attributedStringValue = Self.captionString(caption)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = CardStyle.heroFont
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)

        // Keep compact cards at their natural height, but let a card stretch
        // when its column must match a taller neighbor such as Battery.
        let compactHeight = heightAnchor.constraint(equalToConstant: 66)
        compactHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            compactHeight,
            heightAnchor.constraint(greaterThanOrEqualToConstant: 66),
            captionLabel.topAnchor.constraint(equalTo: topAnchor, constant: CardStyle.cardPaddingV),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            valueLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 2),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
        ])

        if let captionDetail {
            let cd = NSTextField(labelWithString: captionDetail)
            cd.font = CardStyle.captionDetailFont
            cd.textColor = captionDetailColor ?? .tertiaryLabelColor
            cd.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cd)
            NSLayoutConstraint.activate([
                cd.centerYAnchor.constraint(equalTo: captionLabel.centerYAnchor),
                cd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
                captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: cd.leadingAnchor, constant: -6),
            ])
        } else {
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                   constant: -CardStyle.cardPaddingH).isActive = true
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
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CardStyle.cardPaddingV),
                bar.heightAnchor.constraint(equalToConstant: CardStyle.barHeight),
            ])
        } else if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = CardStyle.detailFont
            d.textColor = .tertiaryLabelColor
            d.lineBreakMode = .byTruncatingTail
            d.translatesAutoresizingMaskIntoConstraints = false
            addSubview(d)
            NSLayoutConstraint.activate([
                d.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
                d.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
                d.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CardStyle.cardPaddingV),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Field label above a reading — TokenBar's "Session"/"Week" tier. Shared
    /// so the fans and battery cards label their rows the same way.
    static func captionString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: CardStyle.captionFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Headline of a full-width card — TokenBar's provider-name tier. Primary
    /// coloured and a step larger, so a card that holds several rows reads as
    /// one titled block rather than a stack of equal labels.
    static func titleString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: CardStyle.cardTitleFont,
            .foregroundColor: NSColor.labelColor,
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
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
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
        CardStyle.barTrack.setFill()
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

/// Load-warning colour shared by the menu-bar gauges and the popover mini bars.
/// Each band holds its colour flat — yellow from 60%, orange from 75%, red from
/// 90% — and the hue only moves inside a short eased crossfade centred on each
/// boundary. So the change reads as a smooth transition rather than a snap,
/// without spending the whole range drifting through in-between hues.
/// Returns nil below the first threshold so the caller supplies its own base.
private let loadWarnStart:  CGFloat = 0.60   // base → yellow
private let loadWarnOrange: CGFloat = 0.75   // yellow → orange
private let loadWarnRed:    CGFloat = 0.90   // orange → red

/// Half-width of the eased crossfade centred on each boundary.
private let loadWarnBlend: CGFloat = 0.03

private func loadWarningColor(_ ratio: CGFloat) -> NSColor? {
    let r = max(0, min(1, ratio))
    guard r >= loadWarnStart else { return nil }

    let yellow: CGFloat = 0.15, orange: CGFloat = 0.083, red: CGFloat = 0.0

    /// Smoothstep across a boundary: 0 below the fade, 1 above it, eased between.
    func blend(_ boundary: CGFloat) -> CGFloat {
        let t = max(0, min(1, (r - (boundary - loadWarnBlend)) / (loadWarnBlend * 2)))
        return t * t * (3 - 2 * t)
    }

    // The fades don't overlap, so the steps compose additively.
    var hue = yellow
    hue += (orange - yellow) * blend(loadWarnOrange)
    hue += (red - orange) * blend(loadWarnRed)

    // Saturation eases in over the first band so leaving the base colour is a
    // fade rather than a pop straight to full yellow.
    let entry = blend(loadWarnStart + loadWarnBlend)
    return NSColor(hue: hue, saturation: 0.35 + 0.55 * entry, brightness: 0.98, alpha: 1.0)
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
            : CardStyle.chipFill.cgColor
    }

    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.isSelected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        background.backgroundColor = restColor
        background.cornerRadius = CardStyle.panelRadius
        layer?.addSublayer(background)

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 10.5, weight: isSelected ? .semibold : .medium)
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
        if !isSelected { background.backgroundColor = CardStyle.chipHoverFill.cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        background.backgroundColor = restColor
    }

    override func mouseDown(with event: NSEvent) {
        if !isSelected { onSelect() }
    }
}

// ---------------------------------------------------------------------------
// Popover chrome — header and footer rows
// ---------------------------------------------------------------------------

/// Identity row at the top of the popover: name, a live-status dot, and the
/// sampling cadence on the right. Deliberately not a card — it is chrome about
/// the data, not a reading — but it keeps the cards' horizontal inset so the
/// title lines up with the card contents below it (as TokenBar's header does).
private final class PopoverHeaderRow: NSView {
    private let dot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)

        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .labelColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        // Flexible spacer pins the status flush to the row's trailing edge, the
        // same trick the card rows use.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [name, spacer, dot, statusLabel])
        row.orientation = .horizontal
        row.spacing = 11
        row.alignment = .centerY
        row.setCustomSpacing(5, after: dot)   // dot reads as part of the word beside it
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CardStyle.footerInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CardStyle.footerInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Cheap enough to call on every poll — the header is kept across rebuilds
    /// (unlike the cards) so its hover targets and tracking areas survive.
    func update(isActive: Bool) {
        statusLabel.stringValue = isActive ? "Active" : "Inactive"
        let color: NSColor = isActive ? .systemGreen : .systemOrange
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = color.cgColor
        }
    }
}

/// One borderless icon action in the footer. Secondary-tinted at rest and
/// full-strength on hover, in place of a stock NSButton bezel — which would
/// read as an OS dialog control rather than part of the popover's own surface.
private final class PopoverIconButton: NSView {
    private let onActivate: () -> Void
    private let icon = NSImageView()
    private var trackingArea: NSTrackingArea?

    init(symbol: String, tooltip: String, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)

        toolTip = tooltip
        setAccessibilityLabel(tooltip)

        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { icon.contentTintColor = .labelColor }
    override func mouseExited(with event: NSEvent) { icon.contentTintColor = .secondaryLabelColor }
    override func mouseDown(with event: NSEvent) { onActivate() }
}

/// Footer chrome: right-aligned icon actions, no fill, sitting directly on the
/// popover's glass — the row TokenBar ends its menu with. Only Settings here:
/// the readings refresh themselves on the poll timer, so a manual refresh has
/// nothing to add, and quitting belongs in Settings rather than one slip away
/// from a stats glance.
private final class PopoverFooterRow: NSView {
    init(onSettings: @escaping () -> Void) {
        super.init(frame: .zero)

        let settings = PopoverIconButton(symbol: "gearshape", tooltip: "Settings",
                                         onActivate: onSettings)

        // Flexible spacer pushes the icon to the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let row = NSStackView(views: [spacer, settings])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardStyle.cardPaddingH),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardStyle.cardPaddingH),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CardStyle.footerInset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CardStyle.footerInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}

/// Full-width battery card: charge level, power graph, and energy-mode picker.
func makeBatteryDetailCard(stats s: HardwareStats,
                            contentWidth: CGFloat,
                            cornerRadius: CGFloat = 8,
                            energyModes: HardwareMonitor.EnergyModes,
                            powerSamples: [Double]? = nil,
                            previousPowerWatts: Double? = nil,
                            onSelectEnergyMode: @escaping (Int) -> Void) -> NSView {
    let card = CardView(cornerRadius: cornerRadius)

    let inner = NSStackView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    inner.orientation = .vertical
    inner.alignment = .leading
    inner.spacing = 5
    inner.edgeInsets = NSEdgeInsets(top: CardStyle.cardPaddingV, left: CardStyle.cardPaddingH,
                                    bottom: CardStyle.cardPaddingV, right: CardStyle.cardPaddingH)
    card.addSubview(inner)
    NSLayoutConstraint.activate([
        inner.topAnchor.constraint(equalTo: card.topAnchor),
        inner.leadingAnchor.constraint(equalTo: card.leadingAnchor),
        inner.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])

    let rowWidth = contentWidth - CardStyle.cardPaddingH * 2
    let pct = s.batteryPercent ?? 0

    // Caption row: BATTERY … charge/adapter status
    let caption = NSTextField(labelWithString: "")
    caption.attributedStringValue = StatCard.titleString("Battery")
    caption.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    let statusText: String = {
        if s.isCharging == true {
            if let aw = s.adapterWatts { return "Charging · \(aw)W adapter" }
            return "Charging"
        }
        if s.isExternalPowerConnected {
            if let aw = s.adapterWatts { return "Plugged in · \(aw)W adapter" }
            return "Plugged in"
        }
        return "Discharging"
    }()
    let status = NSTextField(labelWithString: statusText)
    status.font = CardStyle.detailFont
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
    value.font = CardStyle.heroFont
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
        watt.font = CardStyle.heroFont
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
    let onPower = s.isExternalPowerConnected
    let showsLimit = onPower && (s.chargeLimitPercent.map { $0 < 100 } ?? false)
    if showsLimit, let limit = s.chargeLimitPercent {
        bar.trackThickness = CardStyle.barHeight
        bar.limitRatio = CGFloat(limit) / 100.0
    }
    inner.addArrangedSubview(bar)
    bar.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
    bar.heightAnchor.constraint(equalToConstant: showsLimit ? CardStyle.barHeight * 2
                                                            : CardStyle.barHeight).isActive = true

    // Power history sparkline
    let peakWattText: String? = {
        guard let samples = powerSamples, samples.count >= 2 else { return nil }
        let range = PowerGraphView.range(of: samples)
        return String(format: "%.1f W peak", range.upperBound)
    }()

    if let samples = powerSamples, samples.count >= 2 {
        inner.setCustomSpacing(10, after: bar)

        let graph = PowerGraphView(samples: samples)
        graph.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(graph)
        graph.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 44).isActive = true
        inner.setCustomSpacing(10, after: graph)
    } else {
        inner.setCustomSpacing(10, after: bar)
    }

    // Energy mode picker (at the bottom of the card)
    if energyModes.supported {
        let emCaption = NSTextField(labelWithString: "")
        emCaption.attributedStringValue = StatCard.captionString("Energy Mode")
        emCaption.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        var headerViews: [NSView] = [emCaption]
        if let peakWattText {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            headerViews.append(spacer)

            let peak = NSTextField(labelWithString: peakWattText)
            peak.font = CardStyle.captionFont
            peak.textColor = .tertiaryLabelColor
            peak.alignment = .right
            peak.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            headerViews.append(peak)
        }

        let emHeader = NSStackView(views: headerViews)
        emHeader.orientation = .horizontal
        emHeader.spacing = 6
        emHeader.alignment = .firstBaseline
        inner.addArrangedSubview(emHeader)
        emHeader.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        inner.setCustomSpacing(5, after: emHeader)

        let current = s.isExternalPowerConnected ? energyModes.ac : energyModes.battery
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
    } else if let peakWattText {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let peak = NSTextField(labelWithString: peakWattText)
        peak.font = CardStyle.captionFont
        peak.textColor = .tertiaryLabelColor
        peak.alignment = .right
        peak.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [spacer, peak])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        inner.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
    }

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
            let image = self.barView.renderedImage()
            if abs(self.item.length - image.size.width) > 0.5 { self.item.length = image.size.width }
            self.setImageIfChanged(image)
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
        if abs(item.length - size.width) > 0.5 { item.length = size.width }
        // The button lives in the menu bar, so its appearance is the real one:
        // vibrantLight over a light wallpaper even while the system is in Dark
        // mode. The offscreen bar view can't see that on its own.
        barView.menuBarIsDark = item.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
            .map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
        setImageIfChanged(barView.renderedImage())
    }

    /// Every image or length set on a status item makes AppKit re-publish it
    /// to each display's menu bar (`_updateReplicants…`) — the single largest
    /// idle cost in a profile. The render cache hands back the same image
    /// when nothing visible changed; don't pass that on as a change.
    ///
    /// Hosting the bar view live in the button was measured and is worse: a
    /// content redraw re-publishes the item just the same, and the snapshot
    /// then re-runs `draw(_:)` (text labels included) instead of copying a
    /// finished bitmap.
    private func setImageIfChanged(_ image: NSImage) {
        guard let button = item.button, button.image !== image else { return }
        button.image = image
    }
}

// ---------------------------------------------------------------------------
// BatteryPopover — compact popover for the dedicated battery status item
// ---------------------------------------------------------------------------

final class BatteryPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class BatteryPopover: NSObject {
    private let window: BatteryPopoverPanel
    private let root: NSView
    private let stack: NSStackView
    private var pollTimer: Timer?
    private var resizeTimer: Timer?
    private var closeMonitor: Any?
    private weak var sourceButton: NSStatusBarButton?
    private var menuTrackingCount = 0
    private var menuTrackingObservers: [NSObjectProtocol] = []

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

        let p = BatteryPopoverPanel(
            contentRect: root.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.level = .popUpMenu
        if #available(macOS 13.0, *) {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .canJoinAllApplications]
        } else {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
        p.contentView = root
        window = p

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
        menuTrackingObservers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.close()
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
        refreshEnergyModes()
        rebuild()

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        let screen = button.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let menuBarBottom: CGFloat
        if screenRect != .zero {
            menuBarBottom = screenRect.maxY - NSStatusBar.system.thickness
        } else if let screen {
            menuBarBottom = screen.frame.maxY - NSStatusBar.system.thickness
        } else {
            menuBarBottom = NSEvent.mouseLocation.y
        }

        let targetMidX = screenRect != .zero ? screenRect.midX : NSEvent.mouseLocation.x
        var origin = NSPoint(x: targetMidX - window.frame.width / 2,
                             y: menuBarBottom - window.frame.height - 4)
        if let screen {
            let vf = screen.visibleFrame
            if origin.x + window.frame.width > vf.maxX { origin.x = vf.maxX - window.frame.width - 4 }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
        }

        // Point the arrow at the button's horizontal center, clamped clear
        // of the rounded corners.
        let minCenter = 16 + arrowWidth / 2
        let maxCenter = popWidth - 16 - arrowWidth / 2
        let wanted = targetMidX - origin.x
        shell.arrowCenterX = max(minCenter, min(maxCenter, wanted))
        shell.layoutSubtreeIfNeeded()

        window.setFrameOrigin(origin)
        if let btnWin = button.window, window.parent != btnWin {
            btnWin.addChildWindow(window, ordered: .above)
        }
        window.orderFrontRegardless()

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
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        resizeTimer?.invalidate(); resizeTimer = nil
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        if let parent = window.parent {
            parent.removeChildWindow(window)
        }
        window.orderOut(nil)
    }

    private func rebuild() {
        let s = HardwareMonitor.shared.stats
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let powerSamples = HardwareMonitor.shared.powerHistory
        let showPowerGraph = powerSamples.count >= 2

        let batteryCard = makeBatteryDetailCard(stats: s, contentWidth: contentWidth,
                                                cornerRadius: cardCornerRadius,
                                                energyModes: energyModes,
                                                powerSamples: showPowerGraph ? powerSamples : nil,
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
        rebuild()
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
        let timer = Timer(timeInterval: DisplayRate.interval, repeats: true) { [weak self] timer in
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
