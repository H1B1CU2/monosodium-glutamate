import AppKit

// ---------------------------------------------------------------------------
// HardwareStatusItem — dedicated menu bar item for hardware stats
// ---------------------------------------------------------------------------

final class HardwareStatusItem {

    private let item: NSStatusItem
    let barView: HardwareBarView
    private var popover: HardwarePopover?

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MSG.HardwareStats"

        barView = HardwareBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 22))

        if let btn = item.button {
            btn.frame = barView.frame
            btn.addSubview(barView)
            btn.target = self
            btn.action = #selector(togglePopover)
            btn.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        HardwareMonitor.shared.addObserver { [weak self] in
            DispatchQueue.main.async {
                self?.barView.stats = HardwareMonitor.shared.stats
                self?.barView.needsDisplay = true
            }
        }
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.close()
        } else {
            if popover == nil { popover = HardwarePopover() }
            popover?.show(relativeTo: item.button!)
        }
    }

    func remove() {
        popover?.close()
        barView.removeFromSuperview()
        NSStatusBar.system.removeStatusItem(item)
    }
}

// ---------------------------------------------------------------------------
// HardwareBarView — draws bars with labels
// ---------------------------------------------------------------------------

final class HardwareBarView: NSView {

    var stats = HardwareStats() { didSet { needsDisplay = true } }

    var showCPU: Bool = true
    var showGPU: Bool = true
    var showMemory: Bool = true
    var showTemp: Bool = true
    var showFPS: Bool = false
    var showFan: Bool = false

    /// "vertical" | "circular"
    var barStyle: String = "vertical"

    /// "vertical" (beside bar) | "horizontal" (below bar, like preview)
    var labelPosition: String = "vertical"

    // -----------------------------------------------------------------------
    // MARK: - Layout
    // -----------------------------------------------------------------------

    private let barW: CGFloat = 4
    private let gap: CGFloat = 3
    private let leftPadding: CGFloat = 4
    private let fontSize: CGFloat = 7.0
    private let circularRadius: CGFloat = 6

    /// Bar height depends on label position: shorter when text is below.
    private var barH: CGFloat {
        labelPosition == "horizontal" ? 12 : 18
    }

    private var barY: CGFloat {
        labelPosition == "horizontal" ? 4 : 2
    }

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // -----------------------------------------------------------------------
    // MARK: - Drawing
    // -----------------------------------------------------------------------

    override func draw(_ dirtyRect: NSRect) {
        let modules = activeModules()
        guard !modules.isEmpty else { return }

        let drawWidth = bounds.width - leftPadding
        let moduleW = drawWidth / CGFloat(modules.count)

        for (i, mod) in modules.enumerated() {
            let x = leftPadding + CGFloat(i) * moduleW
            let rect = NSRect(x: x, y: 0, width: moduleW, height: bounds.height)
            if mod.isValue {
                drawValue(module: mod, in: rect)
            } else if barStyle == "circular" {
                drawCircular(module: mod, in: rect)
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
        let barOriginX = rect.midX - barW / 2

        // Background track
        let track = NSRect(x: barOriginX, y: barY, width: barW, height: barH)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: barW / 2, yRadius: barW / 2)
        NSColor.white.withAlphaComponent(0.15).setFill()
        trackPath.fill()

        // Filled portion
        if module.ratio > 0 {
            let fillH = max(2, barH * module.ratio)
            let fillRect = NSRect(x: barOriginX, y: barY, width: barW, height: fillH)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barW / 2, yRadius: barW / 2)
            barColor(ratio: module.ratio, forceWhite: module.forceWhite).setFill()
            fillPath.fill()
        }

        if isHorizontal {
            drawHorizontalLabel(module.label, x: rect.midX, y: barY - 2, in: rect)
        } else {
            // Label on the left side of the bar
            let labelX = barOriginX - gap - estimatedCharWidth()
            drawVerticalLabel(module.label, x: labelX, in: rect)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: - Circular bar
    // -----------------------------------------------------------------------

    private func drawCircular(module: Module, in rect: NSRect) {
        let isHorizontal = labelPosition == "horizontal"
        let r = circularRadius
        let centerY: CGFloat = isHorizontal ? rect.midY + 4 : rect.midY
        // Bar and label share the module; ring is left-aligned, label follows
        let ringX = rect.minX + r + 2
        let center = NSPoint(x: ringX, y: centerY)
        let lineW: CGFloat = 2.5

        // Background ring
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
        bgPath.lineWidth = lineW
        NSColor.white.withAlphaComponent(0.15).setStroke()
        bgPath.stroke()

        // Filled arc
        let endAngle: CGFloat = -90 + 360 * module.ratio
        if module.ratio > 0.01 {
            let arcPath = NSBezierPath()
            arcPath.appendArc(withCenter: center, radius: r,
                              startAngle: -90, endAngle: endAngle, clockwise: true)
            arcPath.lineWidth = lineW
            arcPath.lineCapStyle = .round
            barColor(ratio: module.ratio, forceWhite: module.forceWhite).setStroke()
            arcPath.stroke()
        }

        // Label on the left side of the ring
        if isHorizontal {
            drawHorizontalLabel(module.label, x: center.x, y: center.y - r - 4, in: rect)
        } else {
            let labelX = center.x - r - gap - estimatedCharWidth()
            drawVerticalLabel(module.label, x: labelX, in: rect)
        }
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

    private func drawHorizontalLabel(_ text: String, x: CGFloat, y: CGFloat, in rect: NSRect) {
        let s = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 6.5, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: x - sz.width / 2, y: y - sz.height),
               withAttributes: attrs)
    }

    // -----------------------------------------------------------------------
    // MARK: - Value drawing (FPS)
    // -----------------------------------------------------------------------

    private func drawValue(module: Module, in rect: NSRect) {
        let valStr = module.valueText as NSString
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let lblStr = module.label as NSString
        let lblAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]

        let valSize = valStr.size(withAttributes: valAttrs)
        let lblSize = lblStr.size(withAttributes: lblAttrs)
        let gap: CGFloat = 1
        let blockHeight = valSize.height + gap + lblSize.height + 2
        let blockTop = rect.midY + blockHeight / 2

        let valX = rect.midX - valSize.width / 2
        valStr.draw(at: NSPoint(x: valX, y: blockTop - valSize.height),
                    withAttributes: valAttrs)

        let lblX = rect.midX - lblSize.width / 2
        lblStr.draw(at: NSPoint(x: lblX, y: blockTop - valSize.height - gap - lblSize.height),
                    withAttributes: lblAttrs)
    }

    // -----------------------------------------------------------------------
    // MARK: - Color
    // -----------------------------------------------------------------------

    /// White ≤ 50%, yellow at 50%+, orange at 65%+, red at 80%+.
    private func barColor(ratio: CGFloat, forceWhite: Bool = false) -> NSColor {
        if forceWhite { return NSColor.white }
        let r = max(0, min(1, ratio))
        if r < 0.5 { return NSColor.white }
        let hue: CGFloat
        if r < 0.65 {
            // 50–65%: yellow (0.15) → orange (0.10)
            let t = (r - 0.5) / 0.15
            hue = 0.15 - 0.05 * t
        } else if r < 0.8 {
            // 65–80%: orange (0.10) → red (0.0)
            let t = (r - 0.65) / 0.15
            hue = 0.10 * (1.0 - t)
        } else {
            // 80%+: red
            hue = 0.0
        }
        return NSColor(hue: hue, saturation: 0.9, brightness: 0.95, alpha: 1.0)
    }

    // -----------------------------------------------------------------------
    // MARK: - Modules
    // -----------------------------------------------------------------------

    private struct Module {
        let label: String
        let ratio: CGFloat
        var isValue: Bool = false
        var valueText: String = ""
        var forceWhite: Bool = false
    }

    private func activeModules() -> [Module] {
        var mods: [Module] = []
        if showCPU {
            mods.append(Module(label: "CPU",
                               ratio: CGFloat(min(stats.cpuPercent / 100.0, 1.0))))
        }
        if showGPU {
            mods.append(Module(label: "GPU",
                               ratio: CGFloat(min(stats.gpuPercent / 100.0, 1.0))))
        }
        if showMemory {
            let memRatio: CGFloat
            let memMode = AppSettings.shared.hardwareStatsMemMode
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
        if showTemp {
            let sensor = AppSettings.shared.hardwareStatsTempSensor
            let t: Double
            switch sensor {
            case "cpu":  t = stats.cpuTemp ?? 30
            case "gpu":  t = stats.gpuTemp ?? 30
            default:     t = stats.cpuTemp ?? stats.gpuTemp ?? 30
            }
            let minT = AppSettings.shared.hardwareStatsTempMin
            let maxT = AppSettings.shared.hardwareStatsTempMax
            let range = max(1.0, maxT - minT)
            let tempRatio = CGFloat(max(0, min(1, (t - minT) / range)))
            mods.append(Module(label: "TMP", ratio: tempRatio))
        }
        if showFPS {
            mods.append(Module(label: "FPS", ratio: 0,
                               isValue: true, valueText: "\(stats.fps)",
                               forceWhite: true))
        }
        if showFan {
            if let fan = stats.fans.first {
                let fanRatio = CGFloat(fan.current) / CGFloat(max(1, fan.max))
                mods.append(Module(label: "FAN", ratio: fanRatio))
            } else {
                mods.append(Module(label: "FAN", ratio: 0, forceWhite: true))
            }
        }
        return mods
    }

    // -----------------------------------------------------------------------
    // MARK: - Size
    // -----------------------------------------------------------------------

    override var intrinsicContentSize: NSSize {
        let count = max(1, activeModules().count)
        let perModule: CGFloat = barStyle == "circular"
            ? (labelPosition == "horizontal" ? 22 : 22)
            : (labelPosition == "horizontal" ? 16 : 20)
        return NSSize(width: perModule * CGFloat(count) + 4 + leftPadding, height: 22)
    }

    func updateSize() {
        frame.size = intrinsicContentSize
        if let btn = superview as? NSStatusBarButton {
            btn.frame = frame
        }
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
    private var closeMonitor: Any?
    private weak var sourceButton: NSStatusBarButton?

    private let popWidth: CGFloat = 210
    private let labelColWidth: CGFloat = 72

    var isShown: Bool { window.isVisible }

    override init() {
        root = NSView(frame: NSRect(x: 0, y: 0, width: popWidth, height: 200))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.97).cgColor
        root.layer?.cornerRadius = 10

        stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        root.addSubview(stack)

        // Pin the stack to all edges so content never clips and the view's
        // fittingSize reflects the stack's intrinsic height.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
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
    }

    func show(relativeTo button: NSStatusBarButton) {
        sourceButton = button
        rebuild()

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = button.window?.convertToScreen(buttonRect) ?? .zero
        var origin = NSPoint(x: screenRect.minX,
                             y: screenRect.minY - window.frame.height - 4)
        if let screen = button.window?.screen {
            let vf = screen.visibleFrame
            if origin.x + window.frame.width > vf.maxX { origin.x = vf.maxX - window.frame.width - 4 }
            if origin.x < vf.minX { origin.x = vf.minX + 4 }
        }
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
    }

    func close() {
        pollTimer?.invalidate(); pollTimer = nil
        if let m = closeMonitor { NSEvent.removeMonitor(m); closeMonitor = nil }
        window.orderOut(nil)
    }

    // Rebuild the whole layout (structure may change: fans appear/disappear).
    private func rebuild() {
        let s = HardwareMonitor.shared.stats
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        addRow("CPU Usage", String(format: "%.1f%%", s.cpuPercent))
        addRow("GPU Usage", String(format: "%.1f%%", s.gpuPercent))
        addRow("MEM Usage", String(format: "%.1f GB", s.memoryUsedGB))
        let pressureLabel: String = {
            let pct: Int = {
                switch s.memoryPressure {
                case .normal:  return 25
                case .warning: return 60
                case .critical: return 90
                }
            }()
            return String(format: "%d%%", pct)
        }()
        let pressureColor: NSColor = {
            switch s.memoryPressure {
            case .normal:  return .labelColor
            case .warning: return .orange
            case .critical: return .red
            }
        }()
        addRow("MEM Pressure", pressureLabel, valueColor: pressureColor)
        let t = s.cpuTemp ?? s.gpuTemp
        let tempStr = t.map { String(format: "%.0f°C", $0) } ?? "—"
        addRow("Temp", tempStr)
        addRow("FPS", "\(s.fps) fps")

        if !s.fans.isEmpty {
            let sep = NSBox()
            sep.boxType = .separator
            sep.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalToConstant: popWidth - 28).isActive = true

            let fanTitle = NSTextField(labelWithString: "Fans")
            fanTitle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            stack.addArrangedSubview(fanTitle)

            for f in s.fans {
                var pct = 0
                if f.max > 0 {
                    let ratio = Double(f.current) / Double(f.max)
                    pct = Int(ratio * 100.0)
                }
                addRow(f.name, "\(f.current) RPM (\(pct)%)")
            }

            // Preset picker
            let presetLabel = NSTextField(labelWithString: "Preset:")
            presetLabel.font = NSFont.systemFont(ofSize: 10)
            presetLabel.textColor = .secondaryLabelColor
            let presetBtn = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 20), pullsDown: false)
            let presetTitles = ["silent": "Silent", "default": "Default",
                                "performance": "Performance", "fullBlast": "Full Blast"]
            presetBtn.addItems(withTitles: ["Silent", "Default", "Performance", "Full Blast"])
            if let title = presetTitles[AppSettings.shared.hardwareStatsFanPreset] {
                presetBtn.selectItem(withTitle: title)
            }
            presetBtn.target = self
            presetBtn.action = #selector(presetChanged(_:))
            presetBtn.controlSize = .small
            presetBtn.font = NSFont.systemFont(ofSize: 10)

            let presetRow = NSStackView(views: [presetLabel, presetBtn])
            presetRow.orientation = .horizontal
            presetRow.spacing = 6
            presetRow.alignment = .centerY
            stack.addArrangedSubview(presetRow)
            presetRow.widthAnchor.constraint(equalToConstant: popWidth - 28).isActive = true
        }

        resizeWindow()
    }

    private func refreshValues() {
        rebuild()
    }

    private func resizeWindow() {
        stack.layoutSubtreeIfNeeded()
        let h = max(60, stack.fittingSize.height)
        let newFrame = NSRect(x: window.frame.minX,
                              y: window.frame.maxY - h,   // grow/shrink from top
                              width: popWidth, height: h)
        window.setFrame(newFrame, display: true, animate: false)
    }

    private func addRow(_ label: String, _ value: String, valueColor: NSColor? = nil) {
        let l = NSTextField(labelWithString: label)
        l.font = NSFont.systemFont(ofSize: 11)
        l.alignment = .left
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: labelColWidth).isActive = true

        let r = NSTextField(labelWithString: value)
        r.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        r.alignment = .right
        r.lineBreakMode = .byTruncatingTail
        r.textColor = valueColor ?? .labelColor
        r.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [l, r])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 6
        row.alignment = .firstBaseline
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: popWidth - 28).isActive = true
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let map = ["Silent": "silent", "Default": "default",
                   "Performance": "performance", "Full Blast": "fullBlast"]
        guard let title = sender.selectedItem?.title,
              let preset = map[title] else { return }
        AppSettings.shared.hardwareStatsFanPreset = preset
        if preset == "fullBlast" {
            HardwareMonitor.shared.fanFullBlast()
        } else if preset == "default" {
            HardwareMonitor.shared.fanReset()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuild()
        }
    }

}
