import AppKit

// MARK: - NSScreen helpers

extension NSScreen {
    /// True if this screen is the built-in display (laptop screen).
    var isBuiltin: Bool {
        guard let dID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return self == NSScreen.screens.first
        }
        return CGDisplayIsBuiltin(dID) != 0
    }
}

// MARK: - CornerWindow

/// Transparent, click-through, always-on-top fullscreen overlay that paints
/// black corner masks. One window per managed screen.
final class CornerWindow: NSWindow {

    let targetScreen: NSScreen
    var displayUUID: String? { view.displayUUID }
    private let view: CornerView
    private var growTimer: Timer?

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
        level              = NSWindow.Level(Int(kCGAssistiveTechHighWindowLevel))
        animationBehavior  = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        contentView = view
    }

    func updateFrame() {
        growTimer?.invalidate(); growTimer = nil
        view.growRadius = nil
        view.alphaValue = 1
        setFrame(targetScreen.frame, display: true)
        view.targetScreen = targetScreen
        view.needsDisplay = true
    }

    func redraw() {
        growTimer?.invalidate(); growTimer = nil
        view.growRadius = nil
        view.alphaValue = 1
        view.needsDisplay = true
        view.display()
    }

    func setSkipTop(_ skip: Bool) {
        view.skipTopCorners = skip
        redraw()
    }

    /// 0.5s grow-in animation — triggered when exiting Mission Control.
    func animateGrowIn() {
        growTimer?.invalidate()
        let uuid = view.displayUUID ?? "_default"
        let isBuiltin = targetScreen.isBuiltin
        let target = isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
        guard target > 0 else { view.growRadius = nil; redraw(); return }

        view.alphaValue = 1
        view.growRadius = 0
        view.needsDisplay = true
        view.display()

        let start = ProcessInfo.processInfo.systemUptime
        let t = Timer(fire: Date(), interval: 0.016, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let p = min((ProcessInfo.processInfo.systemUptime - start) / 0.5, 1.0)
            let eased = 1.0 - pow(1.0 - p, 3)
            self.view.growRadius = target * eased
            self.view.needsDisplay = true
            self.view.displayIfNeeded()
            if p >= 1.0 {
                self.view.growRadius = nil
                self.view.needsDisplay = true
                self.view.displayIfNeeded()
                t.invalidate()
                self.growTimer = nil
            }
        }
        growTimer = t
        RunLoop.current.add(t, forMode: .common)
    }

    private let settings: AppSettings
}

// MARK: - CornerView

final class CornerView: NSView {

    var targetScreen: NSScreen
    var skipTopCorners = false
    var displayUUID: String?
    var growRadius: CGFloat?
    private let settings: AppSettings

    init(screen: NSScreen, settings: AppSettings) {
        self.targetScreen = screen
        self.settings = settings
        super.init(frame: .zero)
        if let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           let u = CGDisplayCreateUUIDFromDisplayID(dID),
           let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String? {
            displayUUID = s
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width
        let H = bounds.height
        let screen = targetScreen
        let isBuiltin = screen.isBuiltin

        let uuid = displayUUID ?? "_default"
        let r: CGFloat
        if let gr = growRadius { r = gr }
        else { r = isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid) }
        let topEnabled = isBuiltin ? settings.topCornersEnabled : settings.extTopCornersEnabled(for: uuid)
        let bottomEnabled = isBuiltin ? settings.bottomCornersEnabled : settings.extBottomCornersEnabled(for: uuid)
        let underBar = isBuiltin ? settings.topCornersUnderMenuBar : settings.extTopCornersUnderMenuBar(for: uuid)

        NSColor.black.setFill()

        let topY: CGFloat = underBar ? (screen.frame.maxY - screen.visibleFrame.maxY) : 0
        let skipTop = skipTopCorners || (underBar && !NSMenu.menuBarVisible())

        if topEnabled && !skipTop {
            drawCorner(at: NSPoint(x: 0,     y: H - topY), radius: r, kind: .topLeft)
            drawCorner(at: NSPoint(x: W,     y: H - topY), radius: r, kind: .topRight)
        }
        if bottomEnabled {
            drawCorner(at: NSPoint(x: 0, y: 0), radius: r, kind: .bottomLeft)
            drawCorner(at: NSPoint(x: W, y: 0), radius: r, kind: .bottomRight)
        }
    }

    private enum CornerKind { case topLeft, topRight, bottomLeft, bottomRight }

    private func drawCorner(at p: NSPoint, radius r: CGFloat, kind: CornerKind) {
        let path = NSBezierPath()
        switch kind {
        case .topLeft:
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x + r, y: p.y - r),
                           radius: r, startAngle: 90, endAngle: 180)
            path.line(to: p)
        case .topRight:
            path.move(to: p)
            path.line(to: NSPoint(x: p.x - r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x - r, y: p.y - r),
                           radius: r, startAngle: 90, endAngle: 0, clockwise: true)
            path.line(to: p)
        case .bottomLeft:
            path.move(to: p)
            path.line(to: NSPoint(x: p.x + r, y: p.y))
            path.appendArc(withCenter: NSPoint(x: p.x + r, y: p.y + r),
                           radius: r, startAngle: 270, endAngle: 180, clockwise: true)
            path.line(to: p)
        case .bottomRight:
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
