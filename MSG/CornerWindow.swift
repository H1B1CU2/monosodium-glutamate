import AppKit

// MARK: - CornerWindow

/// Transparent, click-through, always-on-top fullscreen overlay that paints
/// black corner masks. One window per managed screen.
final class CornerWindow: NSWindow {

    /// Above every normal and assistive-tech window. Hoisted so the watchdog can
    /// re-assert it after something else clobbers the ordering.
    static let cornerLevel = NSWindow.Level(Int(kCGAssistiveTechHighWindowLevel))

    let targetScreen: NSScreen
    var displayUUID: String? { view.displayUUID }
    private let view: CornerView

    init(screen: NSScreen, settings: AppSettings) {
        self.targetScreen = screen
        self.settings = settings
        self.view = CornerView(screen: screen, settings: settings)

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        ignoresMouseEvents = true
        level              = Self.cornerLevel
        animationBehavior  = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        contentView = view

        // The view arms a grow-in when the top corners go hidden→shown (Mission
        // Control closed, or left a fullscreen space). Detection happens at render
        // time off the `skipTopCorners` flag, which AppDelegate drives from the
        // reliable isMissionControl state.
        view.onTopGrowInNeeded = { [weak self] in self?.startGrowIn() }
    }

    func updateFrame() {
        // A stale NSScreen reports .zero — resizing to it would blank the overlay
        // for good. Leave the last good frame up; the watchdog rebuilds us.
        guard targetScreen.frame.width > 0, targetScreen.frame.height > 0 else { return }
        view.alphaValue = 1
        setFrame(targetScreen.frame, display: true)
        view.targetScreen = targetScreen
        view.needsDisplay = true
    }

    func redraw() {
        view.alphaValue = 1
        view.needsDisplay = true
        view.display()
    }

    /// Hide or show the top corners (Mission Control, or the fullscreen-only mode
    /// on a desktop space).
    ///
    /// Redraws only on an actual change — the watchdog calls this every ~2 s to
    /// heal a missed edge, and an unconditional `redraw()` would repaint all four
    /// corners on every pass.
    ///
    /// Do NOT invalidate growTimer here. It is shared with the bottom corners,
    /// which are still on screen; killing it strands bottomGrowProgress at a
    /// partial value with nothing left to re-ramp it. It self-invalidates within
    /// 0.25 s anyway, and the top ramp it drives is invisible while skipped.
    func setSkipTop(_ skip: Bool) {
        guard view.skipTopCorners != skip else { return }
        view.skipTopCorners = skip
        redraw()
    }

    /// Space-switch grow-in, phase 1: the slide just started, so hide all four
    /// corners instantly — the screen is in motion, which masks the change.
    /// They stay hidden until `spaceSlideEnded()` grows them back at landing.
    /// The fallback re-grows them even if the end-of-slide poll never fires.
    func spaceSlideBegan() {
        growTimer?.invalidate(); growTimer = nil
        awaitingSlideGrow = true
        view.topGrowProgress = 0
        view.bottomGrowProgress = 0
        view.display()
        slideGrowFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.spaceSlideEnded() }
        slideGrowFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Space-switch grow-in, phase 2: the slide finished — grow the corners in.
    func spaceSlideEnded() {
        slideGrowFallback?.cancel(); slideGrowFallback = nil
        guard awaitingSlideGrow else { return }
        awaitingSlideGrow = false
        startGrowIn()
    }

    /// Watchdog hook: with no timer running and no slide pending, any progress
    /// below 1 is stranded — snap it to full rather than leaving the corners
    /// permanently undersized.
    func healStrandedGrow() {
        guard growTimer == nil, !awaitingSlideGrow else { return }
        guard view.topGrowProgress < 1 || view.bottomGrowProgress < 1 else { return }
        view.topGrowProgress = 1
        view.bottomGrowProgress = 1
        view.display()
    }

    /// Ramps armed corners' radius from 0 → full over `duration` using the
    /// project's main-thread Timer + time-based progress pattern (not CVDisplayLink).
    /// Corners are armed by zeroing their progress before this starts; unarmed
    /// corners sit at 1 and `max` leaves them untouched, so a top-only grow can
    /// restart mid-flight of a full grow without freezing the bottom corners.
    private func startGrowIn(duration: TimeInterval = 0.25) {
        growTimer?.invalidate()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min(1.0, CGFloat((CACurrentMediaTime() - start) / duration))
            self.view.topGrowProgress = max(self.view.topGrowProgress, p)
            self.view.bottomGrowProgress = max(self.view.bottomGrowProgress, p)
            self.view.display()
            if p >= 1.0 { t.invalidate(); self.growTimer = nil }
        }
        RunLoop.current.add(timer, forMode: .common)
        growTimer = timer
    }

    deinit { growTimer?.invalidate(); slideGrowFallback?.cancel() }

    private let settings: AppSettings
    private var growTimer: Timer?
    private var awaitingSlideGrow = false
    private var slideGrowFallback: DispatchWorkItem?
}

// MARK: - CornerView

final class CornerView: NSView {

    var targetScreen: NSScreen
    var skipTopCorners = false
    /// Top-corner radius scale (0 = invisible, 1 = full). Animated on grow-in.
    var topGrowProgress: CGFloat = 1.0
    /// Bottom-corner radius scale (0 = invisible, 1 = full). Animated on space-switch grow-in.
    var bottomGrowProgress: CGFloat = 1.0
    /// Called when the top corners transition hidden→shown so the window grows them in.
    var onTopGrowInNeeded: (() -> Void)?
    var displayUUID: String?
    private let settings: AppSettings
    /// Whether the top corners were shown on the previous draw (transition detection).
    private var wasTopShown = true

    private let topLeftView = SingleCornerView()
    private let topRightView = SingleCornerView()
    private let bottomLeftView = SingleCornerView()
    private let bottomRightView = SingleCornerView()

    init(screen: NSScreen, settings: AppSettings) {
        self.targetScreen = screen
        self.settings = settings
        super.init(frame: .zero)
        displayUUID = screen.uuid
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        addSubview(topLeftView)
        addSubview(topRightView)
        addSubview(bottomLeftView)
        addSubview(bottomRightView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func updateCorners() {
        let W = bounds.width
        let H = bounds.height
        guard W > 0, H > 0 else { return }
        let screen = targetScreen
        let isBuiltin = screen.isBuiltin

        let uuid = displayUUID ?? "_default"
        let r = isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
        let topEnabled = isBuiltin ? settings.topCornersEnabled : settings.extTopCornersEnabled(for: uuid)
        let bottomEnabled = isBuiltin ? settings.bottomCornersEnabled : settings.extBottomCornersEnabled(for: uuid)
        let underBar = isBuiltin ? settings.topCornersUnderMenuBar : settings.extTopCornersUnderMenuBar(for: uuid)

        // Same inset on desktop and fullscreen spaces. Measured on macOS 26 with a
        // fullscreen Safari: the menu bar is still on screen (Window Server window
        // 1512x33 at y=0) and the app's content starts at y=33, exactly as on the
        // desktop. Snapping this to 0 for fullscreen puts the masks on the
        // display's hardware-rounded corner, where they are invisible.
        let topY: CGFloat = underBar ? (screen.frame.maxY - screen.visibleFrame.maxY) : 0
        // No menu-bar proxy here. `underBar && !NSMenu.menuBarVisible()` used to
        // stand in for "no menu bar, so nothing to sit below", but hiding is the
        // wrong response — an invisible corner mask is the one failure mode with
        // no recovery the user can see. Measured on macOS 26: menuBarVisible() is
        // true on fullscreen spaces anyway (the bar really is on screen), so the
        // clause was inert here regardless.
        let skipTop = skipTopCorners
        let topShown = topEnabled && !skipTop

        // Detect a hidden→shown transition (Mission Control closed, or left a
        // fullscreen space) and arm a grow-in. `wasTopShown` guarantees we arm exactly
        // once per transition. Set progress to 0 first so this frame renders nothing
        // (no full-size flash) before the timer ramps it up. With the grow-in
        // setting off, snap straight to full size instead.
        if topShown && !wasTopShown {
            if settings.cornerGrowEnabled {
                topGrowProgress = 0
                onTopGrowInNeeded?()
            } else {
                topGrowProgress = 1
            }
        }
        wasTopShown = topShown

        let topR = topShown ? r * Easing.outQuart(min(1, max(0, topGrowProgress))) : 0
        let bottomR = bottomEnabled ? r * Easing.outQuart(min(1, max(0, bottomGrowProgress))) : 0

        let sizeR = ceil(max(r, 64)) + 1

        topLeftView.frame = NSRect(x: 0, y: H - topY - sizeR, width: sizeR, height: sizeR)
        topLeftView.corner(radius: topR, kind: .topLeft)
        topLeftView.isHidden = !topShown || topR <= 0

        topRightView.frame = NSRect(x: W - sizeR, y: H - topY - sizeR, width: sizeR, height: sizeR)
        topRightView.corner(radius: topR, kind: .topRight)
        topRightView.isHidden = !topShown || topR <= 0

        bottomLeftView.frame = NSRect(x: 0, y: 0, width: sizeR, height: sizeR)
        bottomLeftView.corner(radius: bottomR, kind: .bottomLeft)
        bottomLeftView.isHidden = !bottomEnabled || bottomR <= 0

        bottomRightView.frame = NSRect(x: W - sizeR, y: 0, width: sizeR, height: sizeR)
        bottomRightView.corner(radius: bottomR, kind: .bottomRight)
        bottomRightView.isHidden = !bottomEnabled || bottomR <= 0
    }

    override func layout() {
        super.layout()
        updateCorners()
    }

    override func display() {
        updateCorners()
        super.display()
        if !topLeftView.isHidden { topLeftView.display() }
        if !topRightView.isHidden { topRightView.display() }
        if !bottomLeftView.isHidden { bottomLeftView.display() }
        if !bottomRightView.isHidden { bottomRightView.display() }
    }
}

// MARK: - SingleCornerView

final class SingleCornerView: NSView {
    enum CornerKind { case topLeft, topRight, bottomLeft, bottomRight }

    private(set) var radius: CGFloat = 0
    private(set) var kind: CornerKind = .topLeft

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func corner(radius r: CGFloat, kind k: CornerKind) {
        let changed = radius != r || kind != k
        radius = r
        kind = k
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard radius > 0 else { return }
        NSColor.black.setFill()
        let path = NSBezierPath()
        let r = radius
        let w = bounds.width
        let h = bounds.height

        switch kind {
        case .topLeft:
            let p = NSPoint(x: 0, y: h)
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x + r, y: p.y - r),
                           radius: r, startAngle: 90, endAngle: 180)
            path.line(to: p)
        case .topRight:
            let p = NSPoint(x: w, y: h)
            path.move(to: p)
            path.line(to: NSPoint(x: p.x - r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x - r, y: p.y - r),
                           radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: p)
        case .bottomLeft:
            let p = NSPoint(x: 0, y: 0)
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x + r, y: p.y + r),
                           radius: r, startAngle: 270, endAngle: 180, clockwise: true)
            path.line(to: p)
        case .bottomRight:
            let p = NSPoint(x: w, y: 0)
            path.move(to: p)
            path.line(to: NSPoint(x: p.x - r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x - r, y: p.y + r),
                           radius: r, startAngle: 270, endAngle: 0)
            path.line(to: p)
        }
        path.close()
        path.fill()
    }
}
