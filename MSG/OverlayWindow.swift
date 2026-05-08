import AppKit

// MARK: - CornerWindow

/// Transparent, click-through, always-on-top fullscreen window that hosts CornerView.
class CornerWindow: NSWindow {

    weak var appDelegate: AppDelegate?
    private(set) var cornerView: CornerView?
    /// The screen this corner window is associated with.
    private(set) var targetScreen: NSScreen

    init(appDelegate: AppDelegate, screen: NSScreen) {
        self.appDelegate = appDelegate
        self.targetScreen = screen

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Window appearance
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        ignoresMouseEvents = true
        level              = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))

        // Space / Mission Control behaviour
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        // Content view
        let view = CornerView(appDelegate: appDelegate, screen: screen)
        contentView = view
        cornerView  = view
    }

    /// Resize to the associated screen (handles display changes).
    func updateFrame() {
        setFrame(targetScreen.frame, display: true)
        cornerView?.targetScreen = targetScreen
    }

    /// Update the associated screen reference (used when rebuilding).
    func updateScreen(_ screen: NSScreen) {
        targetScreen = screen
        cornerView?.targetScreen = screen
        updateFrame()
    }
}

// MARK: - CornerView

/// Draws four black rounded-corner masks at the edges of the screen.
class CornerView: NSView {

    weak var appDelegate: AppDelegate?
    /// The screen this view draws corners for.
    var targetScreen: NSScreen

    init(appDelegate: AppDelegate, screen: NSScreen) {
        self.appDelegate = appDelegate
        self.targetScreen = screen
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false } // macOS bottom-up by default

    /// Whether this view's screen is the main screen (has menu bar).
    private var isMainScreen: Bool {
        targetScreen == NSScreen.main
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ad = appDelegate else { return }

        NSColor.black.setFill()

        let r      = ad.cornerRadius
        let bounds = self.bounds
        let W      = bounds.width
        let H      = bounds.height

        let skipTopCorners = ad.topCornersUnderMenuBar && ad.fullscreenOnly && !ad.isFullscreen

        // Menu bar offset applies to any screen that has one
        let topY: CGFloat
        if ad.topCornersUnderMenuBar, !ad.isFullscreen {
            topY = targetScreen.frame.maxY - targetScreen.visibleFrame.maxY
        } else {
            topY = 0
        }

        if ad.topCornersEnabled && !skipTopCorners {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0,   y: H - topY))
            path.line(to: NSPoint(x: r,   y: H - topY))
            path.appendArc(
                withCenter: NSPoint(x: r,     y: H - topY - r),
                radius:     r,
                startAngle: 90,
                endAngle:   180
            )
            path.line(to: NSPoint(x: 0, y: H - topY))
            path.close()
            path.fill()

            // ── Top-right ─────────────────────────────────────────────────────
            let path2 = NSBezierPath()
            path2.move(to: NSPoint(x: W,     y: H - topY))
            path2.line(to: NSPoint(x: W - r, y: H - topY))
            path2.appendArc(
                withCenter: NSPoint(x: W - r, y: H - topY - r),
                radius:     r,
                startAngle: 90,
                endAngle:   0,
                clockwise:  true
            )
            path2.line(to: NSPoint(x: W, y: H - topY))
            path2.close()
            path2.fill()
        }

        // ── Bottom-left ───────────────────────────────────────────────────────
        if ad.bottomCornersEnabled {
            let path3 = NSBezierPath()
            path3.move(to: NSPoint(x: 0, y: 0))
            path3.line(to: NSPoint(x: r, y: 0))
            path3.appendArc(
                withCenter: NSPoint(x: r, y: r),
                radius:     r,
                startAngle: 270,
                endAngle:   180,
                clockwise:  true
            )
            path3.line(to: NSPoint(x: 0, y: 0))
            path3.close()
            path3.fill()

            // ── Bottom-right ──────────────────────────────────────────────────
            let path4 = NSBezierPath()
            path4.move(to: NSPoint(x: W,     y: 0))
            path4.line(to: NSPoint(x: W - r, y: 0))
            path4.appendArc(
                withCenter: NSPoint(x: W - r, y: r),
                radius:     r,
                startAngle: 270,
                endAngle:   0
            )
            path4.line(to: NSPoint(x: W, y: 0))
            path4.close()
            path4.fill()
        }
    }
}

// MARK: - MenuBarWindow

/// Fullscreen overlay for the black bar, matching the architecture of CornerWindow.
class MenuBarWindow: NSWindow {

    private(set) var menuBarView: MenuBarView?
    private(set) var targetScreen: NSScreen

    init(screen: NSScreen) {
        self.targetScreen = screen
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

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        let view = MenuBarView(screen: screen)
        contentView = view
        menuBarView = view
    }

    func updateFrame() {
        setFrame(targetScreen.frame, display: true)
        menuBarView?.targetScreen = targetScreen
    }
}

class MenuBarView: NSView {
    var targetScreen: NSScreen
    
    init(screen: NSScreen) {
        self.targetScreen = screen
        super.init(frame: .zero)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func draw(_ dirtyRect: NSRect) {
        let screen = targetScreen
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        
        // Only draw if menu bar exists
        if menuBarHeight > 5 {
            NSColor.black.setFill()
            let barRect = NSRect(
                x: 0,
                y: bounds.height - menuBarHeight,
                width: bounds.width,
                height: menuBarHeight
            )
            barRect.fill()
        }
    }
}
