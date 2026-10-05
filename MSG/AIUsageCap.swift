import AppKit
import QuartzCore

// MARK: - Usage cap

/// The AI usage widget for the esc spot, a sibling of the player and the weather: two pages,
/// each with two providers side by side — Claude | Codex, then Antigravity | DeepSeek. A
/// provider is a progress ring (open at the bottom, like the player's) with its number inside,
/// and two lines of text beside it. A vertical swipe flips the page.
final class UsageCap: CALayer {
    /// Bars (a setting, the default): one provider a page — its icon, session and week
    /// as two stacked bars, and when each resets. Off: the rings, two providers a page.
    static var barsStyle: Bool { AppSettings.shared.edgeKeysUsageBars }

    /// What each page shows, left to right.
    private static func pages(bars: Bool) -> [[AIProvider]] {
        bars ? [[.claude], [.codex], [.antigravity], [.deepseek]] : [[.claude, .codex], [.antigravity, .deepseek]]
    }

    /// The page a provider is on, in the current style.
    static func page(for provider: AIProvider) -> Int {
        pages(bars: barsStyle).firstIndex { $0.contains(provider) } ?? 0
    }

    /// The style this cap was built in; the strip rebuilds it when the setting changes.
    let bars: Bool
    private var pages: [[AIProvider]] { Self.pages(bars: bars) }
    private var countdownTimer: Timer?

    private let contentLayer = CALayer()
    private var pageLayers: [CALayer] = []
    private var halves: [UsageItem] = []
    private(set) var page = 0
    private var shown = false
    private var scale: CGFloat = 2
    private var snapshot: TokenBarSnapshot?
    private var stale = false
    private var pulseAllowed = true
    var isShown: Bool { shown }

    init(frame: CGRect, radius: CGFloat, scale: CGFloat, corners: CACornerMask) {
        bars = Self.barsStyle
        super.init()
        self.scale = scale
        // As the player's: no crossfaded snapshot left standing while it slides.
        for layer in [self, contentLayer] as [CALayer] { layer.actions = Self.quietActions }
        self.frame = frame
        cornerRadius = radius
        cornerCurve = .continuous
        maskedCorners = corners
        backgroundColor = NSColor.clear.cgColor
        opacity = 0

        // Clipped, so a page sliding up or down never shows outside the widget.
        contentLayer.frame = bounds
        contentLayer.masksToBounds = true
        addSublayer(contentLayer)

        // The two halves fill the width evenly, about 15 apart (closer when it's narrow).
        let w = bounds.width, h = bounds.height
        let gap = min(15, max(8, w * 0.1))
        let halfWidth = ((w - gap) / 2).rounded(.down)
        for (index, providers) in pages.enumerated() {
            let pageLayer = CALayer()
            pageLayer.frame = bounds
            pageLayer.actions = Self.quietActions
            pageLayer.opacity = index == page ? 1 : 0
            contentLayer.addSublayer(pageLayer)
            pageLayers.append(pageLayer)
            for (slot, provider) in providers.enumerated() {
                let half: UsageItem
                if bars {
                    half = UsageBars(provider: provider, frame: bounds, scale: scale)
                } else {
                    let x = slot == 0 ? 0 : w - halfWidth
                    half = UsageHalf(provider: provider, frame: CGRect(x: x, y: 0, width: halfWidth, height: h), scale: scale)
                }
                pageLayer.addSublayer(half.root)
                halves.append(half)
            }
        }
        update(nil, stale: false)
    }

    override init(layer: Any) {
        bars = (layer as? UsageCap)?.bars ?? true
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: TokenBarSnapshot?, stale: Bool) {
        self.snapshot = snapshot
        self.stale = stale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for half in halves { half.update(snapshot, stale: stale) }
        centerHalves()
        CATransaction.commit()
        applyPulse()
    }

    /// Each page's two providers as one group in the middle of the widget,
    /// equal room either side, as the player and the weather sit.
    private func centerHalves() {
        guard !bars else { return }   // the bars span the widget
        let perPage = pages.first?.count ?? 2
        let gap = min(15, max(8, bounds.width * 0.1))
        for start in stride(from: 0, to: halves.count, by: perPage) {
            let group = Array(halves[start..<min(halves.count, start + perPage)])
            let total = group.map(\.contentWidth).reduce(0, +) + gap * CGFloat(group.count - 1)
            var x = max(0, ((bounds.width - total) / 2).rounded())
            for half in group {
                half.root.frame.origin.x = x
                x += half.contentWidth + gap
            }
        }
    }

    // MARK: Pages

    /// A vertical swipe: `down` is the way the player's source swipe goes (content leaves upward,
    /// the next page rises from below); back the other way with `false`.
    func flipPage(down: Bool) {
        let count = pages.count
        showPage((page + (down ? 1 : count - 1)) % count, animated: true, forward: down)
    }

    /// `animated` only takes effect while the widget is on screen.
    func showPage(_ index: Int, animated: Bool, forward: Bool? = nil) {
        guard index != page, pageLayers.indices.contains(index) else { return }
        let outgoing = pageLayers[page], incoming = pageLayers[index]
        let forward = forward ?? (index > page)
        page = index
        for half in halves { (half as? UsageBars)?.resetPreviousTexts() }
        outgoing.removeAllAnimations()
        incoming.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoing.opacity = 0
        incoming.opacity = 1
        CATransaction.commit()
        applyPulse()
        guard animated, shown else { return }

        // A few points up or down: the page has faded before it would reach the widget's edge.
        let distance: CGFloat = min(8, bounds.height * 0.3)
        let outY: CGFloat = forward ? distance : -distance
        let outSlide = CABasicAnimation(keyPath: "transform.translation.y")
        outSlide.isAdditive = true
        outSlide.fromValue = 0
        outSlide.toValue = outY
        let outFade = CABasicAnimation(keyPath: "opacity")
        outFade.fromValue = 1
        outFade.toValue = 0
        outFade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let out = CAAnimationGroup()
        out.animations = [outSlide, outFade]
        out.duration = 0.18
        out.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outgoing.add(out, forKey: "pageOut")

        let begin = CACurrentMediaTime() + 0.06
        let slide = CASpringAnimation(keyPath: "transform.translation.y")
        slide.isAdditive = true
        slide.fromValue = -outY * 0.6
        slide.toValue = 0
        slide.damping = 20
        slide.stiffness = 300
        slide.duration = slide.settlingDuration
        slide.beginTime = begin
        slide.fillMode = .backwards
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        incoming.add(slide, forKey: "pageInSlide")
        incoming.add(fade, forKey: "pageInFade")
    }

    // MARK: Active dots

    /// Off while nothing can be seen (see `PresentationState`): the pulse repeats for as long as it runs.
    func setPulseAllowed(_ allowed: Bool) {
        guard allowed != pulseAllowed else { return }
        pulseAllowed = allowed
        applyPulse()
    }

    private func applyPulse() {
        let activityFresh = snapshot?.processing != nil ? AIUsageFeed.shared.isProcessingFresh : !stale
        for half in halves {
            let onPage = pages.firstIndex { $0.contains(half.provider) } == page
            half.setPulsing(shown && pulseAllowed && activityFresh && half.isActive && onPage)
        }
    }

    // MARK: Show and hide

    func show() {
        guard !shown else { return }
        shown = true
        removeAnimation(forKey: "hide")
        let from = presentation()?.opacity ?? 0
        opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 1
        fade.duration = 0.2
        add(fade, forKey: "appear")
        applyPulse()
        // The bars' reset times count down: redrawn every second while up.
        if bars, countdownTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.update(self.snapshot, stale: self.stale)
            }
            RunLoop.main.add(timer, forMode: .common)
            countdownTimer = timer
        }
    }

    /// `animated` false: at once, for a widget that has already slid out of sight.
    func hide(animated: Bool = true) {
        guard shown else { return }
        shown = false
        countdownTimer?.invalidate()
        countdownTimer = nil
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.2
            add(fade, forKey: "hide")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 0
        CATransaction.commit()
        applyPulse()
    }

    func setPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        contentLayer.opacity = pressed ? 0.7 : 1
        contentLayer.transform = pressed ? CATransform3DMakeScale(0.97, 0.97, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    // MARK: Sideways slide (between widgets)

    func slideOut(forward: Bool, completion: (() -> Void)? = nil) {
        let width = contentLayer.bounds.width
        guard width > 20 else { completion?(); return }
        let distance: CGFloat = min(70, width * 0.6)
        let outX: CGFloat = forward ? -distance : distance

        let outSlide = CABasicAnimation(keyPath: "transform.translation.x")
        outSlide.isAdditive = true
        outSlide.fromValue = 0
        outSlide.toValue = outX
        outSlide.duration = 0.20
        outSlide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let outFade = CABasicAnimation(keyPath: "opacity")
        outFade.fromValue = 1
        outFade.toValue = 0
        outFade.duration = 0.17
        outFade.timingFunction = CAMediaTimingFunction(name: .easeIn)

        let outGroup = CAAnimationGroup()
        // Held at 0 until the group ends: the fade is shorter than the slide, and without this the
        // content flashed back at full strength for the last frames.
        outFade.fillMode = .forwards
        outGroup.animations = [outSlide, outFade]
        outGroup.duration = 0.20
        outGroup.fillMode = .forwards
        outGroup.isRemovedOnCompletion = false

        softenSides()
        contentLayer.add(outGroup, forKey: "widgetSwipeOut")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            // Hidden first, then the content put back, in one transaction: it never shows in place.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            completion?()
            self?.contentLayer.removeAnimation(forKey: "widgetSwipeOut")
            self?.contentLayer.transform = CATransform3DIdentity
            self?.mask = nil
            CATransaction.commit()
        }
    }

    func slideIn(forward: Bool) {
        let width = contentLayer.bounds.width
        guard width > 20 else { return }
        let distance: CGFloat = min(70, width * 0.6)
        let inX: CGFloat = forward ? distance : -distance
        let delay: CFTimeInterval = 0.04
        let begin = CACurrentMediaTime() + delay

        contentLayer.removeAllAnimations()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        opacity = 1
        shown = true
        CATransaction.commit()
        applyPulse()

        let slide = CASpringAnimation(keyPath: "transform.translation.x")
        slide.isAdditive = true
        slide.fromValue = inX * 0.6
        slide.toValue = 0
        slide.damping = 20
        slide.stiffness = 300
        slide.duration = slide.settlingDuration
        slide.beginTime = begin
        slide.fillMode = .backwards

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.22
        fade.beginTime = begin
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        contentLayer.add(slide, forKey: "entrySlide")
        contentLayer.add(fade, forKey: "entryFade")

        softenSides()
        let token = UUID()
        sideToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + slide.settlingDuration) { [weak self] in
            guard let self, self.sideToken == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.mask = nil
            CATransaction.commit()
        }
    }

    /// While it slides: clipped to its own spot, fading out in the gap to F1 before reaching it
    /// (the player's mask; its left side is the display's edge).
    private var sideToken: UUID?
    private func softenSides() {
        sideToken = nil
        // Without an implicit crossfade (see the player's `softenEdges`).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The fade lies in the gap to F1, never over the widget: the reset times
        // sit right at its end and showed faded while the slide settled.
        mask = Self.sideMask(size: bounds.size, room: 10, openLeft: true)
        CATransaction.commit()
    }

    /// Keys whose implicit animation is a crossfade of a snapshot, turned off.
    private static let quietActions: [String: CAAction] = [
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        "mask": NSNull(), "masksToBounds": NSNull(),
    ]

    /// Solid over the widget, fading to clear across `room` beyond each side (none on the left when
    /// `openLeft`, the display's own edge). `inside`: the fade on the right starts that far in.
    private static func sideMask(size: CGSize, room: CGFloat, openLeft: Bool, inside: CGFloat = 0) -> CALayer {
        let left: CGFloat = openLeft ? 60 : room
        let width = size.width + left + room
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: -left, y: -4, width: width, height: size.height + 8)
        let clear = NSColor.clear.cgColor, solid = NSColor.black.cgColor
        mask.colors = [openLeft ? solid : clear, solid, solid, clear]
        mask.locations = [0, NSNumber(value: Double(left / width)),
                          NSNumber(value: Double((left + size.width - inside) / width)), 1]
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        return mask
    }
}

// MARK: - One provider

/// One provider's drawing, in either style.
private protocol UsageItem: AnyObject {
    var provider: AIProvider { get }
    var root: CALayer { get }
    var isActive: Bool { get }
    var contentWidth: CGFloat { get }
    func update(_ snapshot: TokenBarSnapshot?, stale: Bool)
    func setPulsing(_ on: Bool)
}

/// A ring with a number (or symbol) in it, and two lines of text beside it.
private final class UsageHalf: UsageItem {
    let provider: AIProvider
    let root = CALayer()
    private let ringTrack = CAShapeLayer()
    private let ringFill = CAShapeLayer()
    private let center = CALayer()
    private let dot = CALayer()
    private let label = CALayer()
    private let subLabel = CALayer()
    private let scale: CGFloat
    private(set) var isActive = false

    private static let ringSide: CGFloat = 22
    /// Ring to text, as the player's ring-to-text gap at its tightest.
    private static let textGap: CGFloat = 7

    init(provider: AIProvider, frame: CGRect, scale: CGFloat) {
        self.provider = provider
        self.scale = scale
        root.frame = frame
        root.actions = ["sublayers": NSNull(), "contents": NSNull(), "opacity": NSNull()]
        let h = frame.height, side = Self.ringSide
        let ring = CGRect(x: 0, y: ((h - side) / 2).rounded(), width: side, height: side)

        // The player's ring: from lower left, clockwise over the top, to lower right.
        let lineWidth: CGFloat = 2
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: side / 2 - lineWidth / 2,
                    startAngle: 235 * .pi / 180, endAngle: -55 * .pi / 180, clockwise: true)
        for shape in [ringTrack, ringFill] {
            shape.frame = ring
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = lineWidth
            shape.lineCap = .butt
            shape.contentsScale = scale
            shape.actions = ["strokeColor": NSNull(), "strokeEnd": NSNull(), "opacity": NSNull()]
            root.addSublayer(shape)
        }
        ringFill.strokeEnd = 0

        center.frame = ring
        center.contentsScale = scale
        center.contentsGravity = .center
        root.addSublayer(center)

        // A small dot at the ring's top right while the provider is working.
        let dotSide: CGFloat = 4
        let r = side / 2 + 1
        dot.bounds = CGRect(x: 0, y: 0, width: dotSide, height: dotSide)
        dot.position = CGPoint(x: ring.midX + r * 0.7071, y: ring.midY + r * 0.7071)
        dot.cornerRadius = dotSide / 2
        dot.backgroundColor = NSColor.systemGreen.cgColor
        dot.isHidden = true
        root.addSublayer(dot)

        // Two lines like the player's, centred in the height.
        let textX = ring.maxX + Self.textGap
        let textWidth = max(0, frame.width - textX)
        label.frame = CGRect(x: textX, y: (h / 2).rounded(), width: textWidth, height: 12)
        subLabel.frame = CGRect(x: textX, y: (h / 2 - 11.5).rounded(), width: textWidth, height: 11)
        for layer in [label, subLabel] {
            layer.contentsScale = scale
            layer.contentsGravity = .left
            layer.isHidden = textWidth < 20
            root.addSublayer(layer)
        }
    }

    // MARK: Content

    private enum Center {
        case number(Int)
        case symbol(String)
        case dash
    }

    private struct Content {
        var fraction: Double?
        var center: Center
        var line1: String
        var line2: String
        var muted = false
        var active = false
    }

    private var symbolName: String {
        switch provider {
        case .claude:      return "sparkle"
        case .codex:       return "chevron.left.forwardslash.chevron.right"
        case .antigravity: return "sparkles"
        case .deepseek:    return "dollarsign"
        }
    }

    private var name: String {
        switch provider {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .deepseek:    return "DeepSeek"
        }
    }

    /// What's left of a limit, from TokenBar's used percent.
    private static func left(_ used: Double?) -> Double? {
        used.map { 100 - min(100, max(0, $0)) }
    }

    private static func percentText(_ value: Double?) -> String {
        value.map { "\(Int(min(100, max(0, $0)).rounded()))%" } ?? "—"
    }

    private func content(for snapshot: TokenBarSnapshot?) -> Content {
        // Nothing to show: no file yet, or the provider is off or can't be read.
        func unavailable(enabled: Bool?) -> Content {
            let working = snapshot?.isActive(provider) == true && AIUsageFeed.shared.isProcessingFresh
            return Content(fraction: nil, center: .dash, line1: name,
                           line2: enabled == false ? "Off" : (working ? "Working" : "No data"),
                           muted: !working, active: working)
        }
        switch provider {
        case .claude, .codex:
            guard let s = provider == .claude ? snapshot?.claude : snapshot?.codex,
                  s.enabled != false, s.available != false else {
                return unavailable(enabled: (provider == .claude ? snapshot?.claude?.enabled : snapshot?.codex?.enabled))
            }
            let left = Self.left(s.sessionPercent)
            return Content(fraction: left.map { $0 / 100 },
                           center: left.map { .number(Int($0.rounded())) } ?? .symbol(symbolName),
                           line1: name, line2: Self.percentText(Self.left(s.weekPercent)), active: snapshot?.isActive(provider) == true)
        case .antigravity:
            guard let s = snapshot?.antigravity, s.enabled != false, s.available != false else {
                return unavailable(enabled: snapshot?.antigravity?.enabled)
            }
            let left = Self.left(s.geminiPercent)
            return Content(fraction: left.map { $0 / 100 },
                           center: left.map { .number(Int($0.rounded())) } ?? .symbol(symbolName),
                           line1: name, line2: Self.percentText(Self.left(s.claudeGptPercent)), active: snapshot?.isActive(provider) == true)
        case .deepseek:
            guard let s = snapshot?.deepseek, s.enabled != false, s.available != false else {
                return unavailable(enabled: snapshot?.deepseek?.enabled)
            }
            // Baht when TokenBar has converted it, else the account's own currency.
            var money = "—"
            if let thb = s.balanceTHB {
                money = "฿" + String(Int(thb.rounded()))
            } else if let balance = s.balance {
                let symbols = ["USD": "$", "CNY": "¥", "EUR": "€", "THB": "฿"]
                let prefix = s.currency.map { symbols[$0.uppercased()] ?? $0 + " " } ?? "$"
                money = prefix + String(format: "%.2f", balance)
            }
            return Content(fraction: nil, center: .symbol(symbolName), line1: money, line2: name)
        }
    }

    func update(_ snapshot: TokenBarSnapshot?, stale: Bool) {
        let c = content(for: snapshot)
        // Stale (TokenBar stopped updating) or nothing to show: the same picture, dimmer.
        let dim: CGFloat = c.muted ? 0.4 : (stale ? 0.55 : 1)
        let activityFresh = snapshot?.processing != nil ? AIUsageFeed.shared.isProcessingFresh : !stale
        isActive = c.active && !c.muted && activityFresh

        ringTrack.strokeColor = NSColor(white: 1, alpha: 0.2 * dim).cgColor
        ringFill.strokeEnd = CGFloat(c.fraction ?? 0)
        ringFill.isHidden = c.fraction == nil
        // The ring is what's left: orange at 20 % or less, red at 5 %.
        let left = (c.fraction ?? 1) * 100
        let fillColor = left <= 5 ? NSColor.systemRed : left <= 20 ? NSColor.systemOrange : NSColor(white: 1, alpha: 0.9)
        ringFill.strokeColor = fillColor.withAlphaComponent(fillColor.alphaComponent * dim).cgColor

        center.contents = centerImage(c.center, alpha: 0.9 * dim)?.layerContents(forContentsScale: scale)
        dot.isHidden = !isActive

        let text = Self.line(c.line1, size: 10, bold: true, color: NSColor(white: 1, alpha: 0.92 * dim))
        let sub = Self.line(c.line2, size: 9, bold: false, color: NSColor(white: 1, alpha: 0.55 * dim))
        label.contents = Self.draw(text, in: label.bounds.size)?.layerContents(forContentsScale: scale)
        subLabel.contents = Self.draw(sub, in: subLabel.bounds.size)?.layerContents(forContentsScale: scale)
        let textWidth = ceil(max(text.size().width, sub.size().width))
        contentWidth = label.frame.minX + min(label.frame.width, textWidth)
    }

    /// Ring, gap and the longer text line: what the widget centres.
    private(set) var contentWidth: CGFloat = 0

    /// The number, or the symbol, centred in the ring.
    private func centerImage(_ center: Center, alpha: CGFloat) -> NSImage? {
        let size = CGSize(width: Self.ringSide, height: Self.ringSide)
        func centred(_ text: String) -> NSImage {
            let string = NSAttributedString(string: text, attributes: [
                .font: Self.font(size: 8, bold: true),
                .foregroundColor: NSColor(white: 1, alpha: alpha),
            ])
            return NSImage(size: size, flipped: false) { rect in
                let drawn = string.size()
                string.draw(at: CGPoint(x: ((rect.width - drawn.width) / 2).rounded(),
                                        y: ((rect.height - drawn.height) / 2).rounded()))
                return true
            }
        }
        switch center {
        case .number(let value):
            return centred(String(min(100, max(0, value))))
        case .dash:
            return centred("—")
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(white: 1, alpha: alpha)]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return nil }
            return NSImage(size: size, flipped: false) { rect in
                let drawn = symbol.size
                symbol.draw(in: CGRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
                return true
            }
        }
    }

    // MARK: Pulse

    func setPulsing(_ on: Bool) {
        if !on {
            dot.removeAnimation(forKey: "pulse")
        } else if dot.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }

    // MARK: Text

    /// SF Pro, with Thai drawn in Sukhumvit Set (the system otherwise falls back to Thonburi).
    private static func font(size: CGFloat, bold: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let thai = NSFontDescriptor(name: bold ? "SukhumvitSet-SemiBold" : "SukhumvitSet-Text", size: size)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [thai]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func line(_ string: String, size: CGFloat, bold: Bool, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font(size: size, bold: bold), .foregroundColor: color])
    }

    /// One line, cut short with an ellipsis when it doesn't fit.
    private static func draw(_ text: NSAttributedString, in size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let line = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return NSImage(size: size, flipped: false) { rect in
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }
}

// MARK: - One provider, bars

/// The detailed style: the provider's icon, then its session (top) and week
/// (bottom) as two stacked bars of what's left, each with when it resets at
/// the end, as TokenBar shows it. DeepSeek, which has no limits, shows its
/// balance instead.
private final class UsageBars: UsageItem {
    let provider: AIProvider
    let root = CALayer()
    private let icon = CALayer()
    private let dot = CALayer()
    private let tracks = [CALayer(), CALayer()]
    private let fills = [CALayer(), CALayer()]
    private let rowLabels = [CALayer(), CALayer()]
    private let times = [CALayer(), CALayer()]
    private let timeTextLayers = [CALayer(), CALayer()]
    private var previousTexts = ["", ""]
    private var previousCountdownText = ""
    private var countdownCharSlots: [CALayer] = []
    /// DeepSeek's two lines in place of the bars.
    private let label = CALayer()
    private let subLabel = CALayer()
    private let scale: CGFloat
    private(set) var isActive = false
    var contentWidth: CGFloat { root.bounds.width }

    func resetPreviousTexts() {
        previousTexts = ["", ""]
        previousCountdownText = ""
        countdownCharSlots.forEach { $0.removeFromSuperlayer() }
        countdownCharSlots.removeAll()
    }

    private static let inset: CGFloat = 6
    private static let iconSide: CGFloat = 22
    private static let barHeight: CGFloat = 3
    /// Between the two bars' centres.
    private static let barPitch: CGFloat = 11
    private static let gap: CGFloat = 8

    init(provider: AIProvider, frame: CGRect, scale: CGFloat) {
        self.provider = provider
        self.scale = scale
        root.frame = frame
        root.actions = ["sublayers": NSNull(), "contents": NSNull(), "opacity": NSNull()]
        let h = frame.height
        icon.frame = CGRect(x: Self.inset, y: ((h - Self.iconSide) / 2).rounded(),
                            width: Self.iconSide, height: Self.iconSide)
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = scale
        root.addSublayer(icon)

        let dotSide: CGFloat = 4
        dot.frame = CGRect(x: icon.frame.maxX - dotSide + 1, y: icon.frame.maxY - dotSide + 1,
                           width: dotSide, height: dotSide)
        dot.cornerRadius = dotSide / 2
        dot.backgroundColor = NSColor.systemGreen.cgColor
        dot.isHidden = true
        root.addSublayer(dot)

        for (track, fill) in zip(tracks, fills) {
            track.cornerRadius = Self.barHeight / 2
            track.masksToBounds = true
            track.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
            track.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            fill.anchorPoint = CGPoint(x: 0, y: 0.5)
            fill.cornerRadius = Self.barHeight / 2
            fill.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            track.addSublayer(fill)
            root.addSublayer(track)
        }
        for (container, textLayer) in zip(times, timeTextLayers) {
            container.masksToBounds = true
            container.actions = ["bounds": NSNull(), "position": NSNull()]
            textLayer.contentsScale = scale
            textLayer.contentsGravity = .right
            textLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
            container.addSublayer(textLayer)
            root.addSublayer(container)
        }
        for layer in rowLabels + [label, subLabel] {
            layer.contentsScale = scale
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            root.addSublayer(layer)
        }
        label.contentsGravity = .left
        subLabel.contentsGravity = .left
        loadIcon()
    }

    private var iconDate: Date?

    /// TokenBar's own mark for the provider, from the PNGs it leaves next to the
    /// snapshot — read again whenever TokenBar has rewritten it.
    private func loadIcon() {
        let name: String
        switch provider {
        case .claude: name = "claude"
        case .codex: name = "codex"
        case .antigravity: name = "antigravity"
        case .deepseek: name = "deepseek"
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBar/icons/\(name).png")
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if icon.contents != nil, modified == iconDate { return }
        iconDate = modified
        if let image = NSImage(contentsOf: url) {
            icon.contents = image.layerContents(forContentsScale: scale)
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(white: 1, alpha: 0.9)]))
            icon.contents = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)?.layerContents(forContentsScale: scale)
        }
    }

    private struct Row {
        var left: Double?     // 0–100 left
        var resetAt: Double?  // epoch
    }

    func update(_ snapshot: TokenBarSnapshot?, stale: Bool) {
        loadIcon()
        var rows: [Row] = []
        var enabled: Bool? = nil, available: Bool? = nil, active = false
        func left(_ used: Double?) -> Double? { used.map { 100 - min(100, max(0, $0)) } }
        switch provider {
        case .claude, .codex:
            let s = provider == .claude ? snapshot?.claude : snapshot?.codex
            enabled = s?.enabled; available = s?.available; active = snapshot?.isActive(provider) == true
            rows = [Row(left: left(s?.sessionPercent), resetAt: s?.sessionResetAt),
                    Row(left: left(s?.weekPercent), resetAt: s?.weekResetAt)]
        case .antigravity:
            let s = snapshot?.antigravity
            enabled = s?.enabled; available = s?.available; active = snapshot?.isActive(provider) == true
            rows = [Row(left: left(s?.geminiPercent), resetAt: s?.geminiResetAt),
                    Row(left: left(s?.claudeGptPercent), resetAt: s?.claudeGptResetAt)]
        case .deepseek:
            let s = snapshot?.deepseek
            enabled = s?.enabled; available = s?.available
        }
        let activityFresh = snapshot?.processing != nil ? AIUsageFeed.shared.isProcessingFresh : !stale
        let muted = snapshot == nil || enabled == false || (available == false && !active)
        let dim: CGFloat = muted ? 0.4 : (stale ? 0.55 : 1)
        isActive = active && !muted && activityFresh
        dot.isHidden = !isActive
        icon.opacity = Float(muted ? 0.5 : 1)

        if provider == .deepseek {
            layoutBalance(snapshot?.deepseek, muted: muted, dim: dim)
        } else {
            let isSessionUsedUp = (rows.first?.left ?? 100) <= 0 && rows.first?.resetAt != nil
            if isSessionUsedUp {
                layoutCountdown(rows.first?.resetAt, muted: muted, dim: dim)
            } else {
                layoutBars(rows, muted: muted, dim: dim)
            }
        }
    }

    /// When the session limit (5 hr limit) is used up: show only the provider icon and the ticking countdown time.
    private func layoutCountdown(_ resetAt: Double?, muted: Bool, dim: CGFloat) {
        tracks.forEach { $0.isHidden = true }
        fills.forEach { $0.isHidden = true }
        rowLabels.forEach { $0.isHidden = true }
        times[1].isHidden = true
        label.isHidden = true
        subLabel.isHidden = true
        timeTextLayers[0].contents = nil
        timeTextLayers[0].isHidden = true

        let text = Self.countdownText(resetAt, muted: muted)
        let font = Self.font(size: 11, weight: .semibold, monospacedDigits: true)
        let color = NSColor(white: 1, alpha: 0.92 * dim)

        let chars = Array(text)
        let charWidths = chars.map { char -> CGFloat in
            let str = NSAttributedString(string: String(char), attributes: [.font: font, .foregroundColor: color])
            return ceil(str.size().width)
        }
        let totalCharsWidth = charWidths.reduce(0, +)
        let sampleStr = NSAttributedString(string: "0", attributes: [.font: font, .foregroundColor: color])
        let textHeight = ceil(sampleStr.size().height)
        let totalWidth = Self.iconSide + Self.gap + totalCharsWidth
        let startX = max(Self.inset, ((root.bounds.width - totalWidth) / 2).rounded())
        let h = root.bounds.height
        let dotSide: CGFloat = 4

        icon.frame = CGRect(x: startX, y: ((h - Self.iconSide) / 2).rounded(),
                            width: Self.iconSide, height: Self.iconSide)
        dot.frame = CGRect(x: icon.frame.maxX - dotSide + 1, y: icon.frame.maxY - dotSide + 1,
                           width: dotSide, height: dotSide)

        let textX = icon.frame.maxX + Self.gap
        let container = times[0]
        container.frame = CGRect(x: textX, y: ((h - textHeight) / 2).rounded(),
                                 width: totalCharsWidth, height: textHeight)
        container.isHidden = false

        updateCountdownSlots(chars: chars, charWidths: charWidths, font: font, color: color, height: textHeight)
    }

    private func updateCountdownSlots(chars: [Character], charWidths: [CGFloat], font: NSFont, color: NSColor, height: CGFloat) {
        let oldChars = Array(previousCountdownText)
        let sameStructure = chars.count == oldChars.count && countdownCharSlots.count == chars.count

        if !sameStructure {
            countdownCharSlots.forEach { $0.removeFromSuperlayer() }
            countdownCharSlots.removeAll()

            var x: CGFloat = 0
            for (char, charW) in zip(chars, charWidths) {
                let slot = CALayer()
                slot.masksToBounds = true
                slot.actions = ["bounds": NSNull(), "position": NSNull()]
                slot.frame = CGRect(x: x, y: 0, width: charW, height: height)

                let str = NSAttributedString(string: String(char), attributes: [.font: font, .foregroundColor: color])
                let glyph = CALayer()
                glyph.frame = slot.bounds
                glyph.contentsScale = scale
                glyph.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
                glyph.contents = Self.draw(str, width: charW, alignRight: false)?.layerContents(forContentsScale: scale)
                slot.addSublayer(glyph)

                times[0].addSublayer(slot)
                countdownCharSlots.append(slot)
                x += charW
            }
            previousCountdownText = String(chars)
            return
        }

        // Same structure: only animate changed digits!
        for (i, (oldChar, newChar)) in zip(oldChars, chars).enumerated() {
            guard oldChar != newChar else { continue }

            let slot = countdownCharSlots[i]
            let charW = charWidths[i]
            let str = NSAttributedString(string: String(newChar), attributes: [.font: font, .foregroundColor: color])
            let newContents = Self.draw(str, width: charW, alignRight: false)?.layerContents(forContentsScale: scale)
            guard let glyph = slot.sublayers?.first else { continue }
            let oldContents = glyph.contents

            slot.sublayers?.filter { $0 !== glyph }.forEach { $0.removeFromSuperlayer() }

            glyph.contents = newContents
            glyph.removeAnimation(forKey: "rollIn")

            // The animation occurs ONLY on the digit number that got changed!
            if newChar.isNumber, let oldContents {
                let oldGlyph = CALayer()
                oldGlyph.frame = slot.bounds
                oldGlyph.contents = oldContents
                oldGlyph.contentsScale = scale
                oldGlyph.actions = ["opacity": NSNull(), "transform": NSNull()]
                slot.addSublayer(oldGlyph)

                let distance: CGFloat = 6
                let slideOut = CABasicAnimation(keyPath: "transform.translation.y")
                slideOut.fromValue = 0
                slideOut.toValue = -distance
                let fadeOut = CABasicAnimation(keyPath: "opacity")
                fadeOut.fromValue = 1
                fadeOut.toValue = 0

                let outGroup = CAAnimationGroup()
                outGroup.animations = [slideOut, fadeOut]
                outGroup.duration = 0.20
                outGroup.timingFunction = CAMediaTimingFunction(name: .easeIn)
                outGroup.fillMode = .forwards
                outGroup.isRemovedOnCompletion = false
                oldGlyph.add(outGroup, forKey: "rollOut")

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak oldGlyph] in
                    oldGlyph?.removeFromSuperlayer()
                }

                let slideIn = CABasicAnimation(keyPath: "transform.translation.y")
                slideIn.fromValue = distance
                slideIn.toValue = 0
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0.2
                fadeIn.toValue = 1

                let inGroup = CAAnimationGroup()
                inGroup.animations = [slideIn, fadeIn]
                inGroup.duration = 0.20
                inGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glyph.add(inGroup, forKey: "rollIn")
            }
        }
        previousCountdownText = String(chars)
    }

    private func layoutBars(_ rows: [Row], muted: Bool, dim: CGFloat) {
        countdownCharSlots.forEach { $0.removeFromSuperlayer() }
        countdownCharSlots.removeAll()
        previousCountdownText = ""
        label.isHidden = true
        subLabel.isHidden = true
        let h = root.bounds.height, w = root.bounds.width
        let dotSide: CGFloat = 4
        icon.frame = CGRect(x: Self.inset, y: ((h - Self.iconSide) / 2).rounded(),
                            width: Self.iconSide, height: Self.iconSide)
        dot.frame = CGRect(x: icon.frame.maxX - dotSide + 1, y: icon.frame.maxY - dotSide + 1,
                           width: dotSide, height: dotSide)
        // The reset times first, right-aligned, so the bars take what's left.
        let texts = rows.map { Self.timeText($0.resetAt, muted: muted) }
        let strings = texts.map { Self.line($0, color: NSColor(white: 1, alpha: 0.6 * dim)) }
        let timeWidth = ceil(strings.map { $0.size().width }.max() ?? 0)
        let timeX = w - Self.inset - timeWidth
        let names = provider == .antigravity ? ["Gemini", "Claude/GPT"] : ["5 hr", "Week"]
        let nameStrings = names.map { Self.line($0, color: NSColor(white: 1, alpha: 0.55 * dim)) }
        let nameWidth = ceil(nameStrings.map { $0.size().width }.max() ?? 0)
        let nameX = icon.frame.maxX + Self.gap
        let barX = nameX + nameWidth + 5
        let barWidth = max(10, timeX - Self.gap - barX)
        for index in 0..<2 {
            let midY = h / 2 + (index == 0 ? Self.barPitch / 2 : -Self.barPitch / 2)
            let nameSize = nameStrings[index].size()
            rowLabels[index].frame = CGRect(x: nameX, y: (midY - ceil(nameSize.height) / 2).rounded(),
                                            width: nameWidth, height: ceil(nameSize.height))
            rowLabels[index].contents = Self.draw(nameStrings[index], width: nameWidth, alignRight: false)?
                .layerContents(forContentsScale: scale)
            rowLabels[index].isHidden = false
            tracks[index].isHidden = false
            tracks[index].frame = CGRect(x: barX, y: (midY - Self.barHeight / 2).rounded(),
                                         width: barWidth, height: Self.barHeight)
            let leftPct = rows.indices.contains(index) ? rows[index].left : nil
            let fraction = CGFloat((leftPct ?? 0) / 100)
            fills[index].frame = CGRect(x: 0, y: 0, width: barWidth * fraction, height: Self.barHeight)
            // In the provider's own colour, as TokenBar draws it, toned down to sit
            // quietly on the strip.
            let color = Self.muted(accent)
            fills[index].backgroundColor = color.withAlphaComponent(color.alphaComponent * dim).cgColor
            fills[index].isHidden = leftPct == nil || fraction == 0

            let size = strings[index].size()
            let timeHeight = ceil(size.height)
            let container = times[index]
            container.frame = CGRect(x: timeX, y: (midY - timeHeight / 2).rounded(),
                                     width: timeWidth, height: timeHeight)
            container.isHidden = false

            let textLayer = timeTextLayers[index]
            textLayer.isHidden = false
            textLayer.frame = container.bounds
            textLayer.contents = Self.draw(strings[index], width: timeWidth, alignRight: true)?
                .layerContents(forContentsScale: scale)
            textLayer.contentsGravity = .right
            container.sublayers?.filter { $0 !== textLayer }.forEach { $0.removeFromSuperlayer() }
            previousTexts[index] = texts.indices.contains(index) ? texts[index] : ""
        }
    }

    private func layoutBalance(_ s: TokenBarSnapshot.DeepSeek?, muted: Bool, dim: CGFloat) {
        tracks.forEach { $0.isHidden = true }
        fills.forEach { $0.isHidden = true }
        rowLabels.forEach { $0.isHidden = true }
        times.forEach { $0.isHidden = true }
        label.isHidden = false
        subLabel.isHidden = false
        var money = "—"
        if let thb = s?.balanceTHB {
            money = "฿" + String(format: "%.2f", thb)
        } else if let balance = s?.balance {
            money = (s?.currency == "CNY" ? "¥" : "$") + String(format: "%.2f", balance)
        }
        let top = NSAttributedString(string: muted ? "DeepSeek" : money, attributes: [
            .font: Self.font(size: 10, weight: .semibold),
            .foregroundColor: NSColor(white: 1, alpha: 0.92 * dim)])
        let bottom = Self.line(muted ? (s?.enabled == false ? "Off" : "No data") : "Balance",
                               color: NSColor(white: 1, alpha: 0.55 * dim))
        let textWidth = ceil(max(top.size().width, bottom.size().width))
        let totalWidth = Self.iconSide + Self.gap + textWidth
        let startX = max(Self.inset, ((root.bounds.width - totalWidth) / 2).rounded())
        let h = root.bounds.height
        let dotSide: CGFloat = 4

        icon.frame = CGRect(x: startX, y: ((h - Self.iconSide) / 2).rounded(),
                            width: Self.iconSide, height: Self.iconSide)
        dot.frame = CGRect(x: icon.frame.maxX - dotSide + 1, y: icon.frame.maxY - dotSide + 1,
                           width: dotSide, height: dotSide)

        let textX = icon.frame.maxX + Self.gap
        let maxTextWidth = max(0, root.bounds.width - textX - Self.inset)
        let width = min(maxTextWidth, textWidth)
        label.frame = CGRect(x: textX, y: (h / 2 - 0.5).rounded(), width: width, height: 12)
        subLabel.frame = CGRect(x: textX, y: (h / 2 - 11).rounded(), width: width, height: 11)
        label.contents = Self.draw(top, width: width, alignRight: false)?.layerContents(forContentsScale: scale)
        subLabel.contents = Self.draw(bottom, width: width, alignRight: false)?.layerContents(forContentsScale: scale)
    }

    /// As TokenBar writes it: within a day, "1 hr 59 min"; further off, "Mon 01:00".
    private static func timeText(_ epoch: Double?, muted: Bool) -> String {
        guard !muted, let epoch else { return "—" }
        let date = Date(timeIntervalSince1970: epoch)
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "now" }
        if seconds < 24 * 3600 {
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "E HH:mm"
        return formatter.string(from: date)
    }

    /// Countdown when a limit is used up: "2 hr 3 min left", "3 min 54 sec", "46 sec".
    private static func countdownText(_ epoch: Double?, muted: Bool) -> String {
        guard !muted, let epoch else { return "—" }
        return UsageResetCountdown.text(until: epoch)
    }

    /// TokenBar's accents.
    private var accent: NSColor {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        switch provider {
        case .claude:      return rgb(0xD9, 0x77, 0x57)
        case .codex:       return rgb(142, 142, 147)
        case .antigravity: return rgb(0x00, 0xB9, 0x5C)
        case .deepseek:    return rgb(0x4D, 0x6B, 0xFE)
        }
    }

    /// The accent a little softer: three quarters of its saturation, a touch darker.
    private static func muted(_ color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s * 0.75, brightness: b * 0.9, alpha: a)
    }

    /// Apple's native font: SF Pro, with Thai drawn in Sukhumvit Set.
    private static func font(size: CGFloat, weight: NSFont.Weight = .medium, monospacedDigits: Bool = false) -> NSFont {
        let base = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                    : NSFont.systemFont(ofSize: size, weight: weight)
        let bold = weight == .semibold || weight == .bold
        let thai = NSFontDescriptor(name: bold ? "SukhumvitSet-SemiBold" : "SukhumvitSet-Text", size: size)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [thai]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func line(_ string: String, color: NSColor, monospacedDigits: Bool = false) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font(size: 8, weight: .medium, monospacedDigits: monospacedDigits),
            .foregroundColor: color])
    }

    private static func draw(_ text: NSAttributedString, width: CGFloat, alignRight: Bool) -> NSImage? {
        let height = ceil(text.size().height)
        guard width > 0, height > 0 else { return nil }
        let line = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignRight ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    func setPulsing(_ on: Bool) {
        if !on {
            dot.removeAnimation(forKey: "pulse")
        } else if dot.animation(forKey: "pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(pulse, forKey: "pulse")
        }
    }
}
