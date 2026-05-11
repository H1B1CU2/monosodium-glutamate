import AppKit

// MARK: - NSScreen helpers

extension NSScreen {
    /// True if this screen is the built-in display (laptop screen).
    var isBuiltin: Bool {
        return localizedName.localizedCaseInsensitiveContains("Built-in") ||
               localizedName.localizedCaseInsensitiveContains("Retina") ||
               self == NSScreen.screens.first
    }
}

// MARK: - CornerWindow

/// Transparent, click-through, always-on-top fullscreen overlay that paints
/// black corner masks. One window per managed screen.
final class CornerWindow: NSWindow {

    let targetScreen: NSScreen
    private let view: CornerView

    init(screen: NSScreen, settings: Settings) {
        self.targetScreen = screen
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
        level              = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        contentView = view
    }

    func updateFrame() {
        setFrame(targetScreen.frame, display: true)
        view.targetScreen = targetScreen
        view.needsDisplay = true
    }

    func redraw(skipTop: Bool = false) {
        view.skipTopCorners = skipTop
        view.needsDisplay = true
    }
}

// MARK: - CornerView

final class CornerView: NSView {

    var targetScreen: NSScreen
    var skipTopCorners = false
    private let settings: Settings

    init(screen: NSScreen, settings: Settings) {
        self.targetScreen = screen
        self.settings = settings
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let W = bounds.width
        let H = bounds.height
        let screen = targetScreen
        let isBuiltin = screen.isBuiltin

        let r = isBuiltin ? settings.cornerRadius : settings.extCornerRadius
        let topEnabled = isBuiltin ? settings.topCornersEnabled : settings.extTopCornersEnabled
        let bottomEnabled = isBuiltin ? settings.bottomCornersEnabled : settings.extBottomCornersEnabled
        let underBar = isBuiltin ? settings.topCornersUnderMenuBar : settings.extTopCornersUnderMenuBar

        NSColor.black.setFill()

        let topY: CGFloat = underBar ? (screen.frame.maxY - screen.visibleFrame.maxY) : 0
        // Skip top-below-bar corners during fullscreen or MC (menu bar visible in both cases)
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
