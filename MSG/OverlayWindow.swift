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
}

// MARK: - CornerView

class CornerView: NSView {

    weak var appDelegate: AppDelegate?
    var targetScreen: NSScreen

    init(appDelegate: AppDelegate, screen: NSScreen) {
        self.appDelegate = appDelegate
        self.targetScreen = screen
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ad = appDelegate else { return }

        let bounds = self.bounds
        let W      = bounds.width
        let H      = bounds.height
        let screen = targetScreen

        let isBuiltin = screen.isBuiltin
        let r = isBuiltin ? ad.cornerRadius : ad.extCornerRadius
        let topEnabled = isBuiltin ? ad.topCornersEnabled : ad.extTopCornersEnabled
        let bottomEnabled = isBuiltin ? ad.bottomCornersEnabled : ad.extBottomCornersEnabled
        let underBar = isBuiltin ? ad.topCornersUnderMenuBar : ad.extTopCornersUnderMenuBar

        NSColor.black.setFill()

        // ── Top Offset ────────────────────────────────────────────────────────
        let topY: CGFloat = underBar ? (screen.frame.maxY - screen.visibleFrame.maxY) : 0
        
        // Hide top corners if menu bar is not visible (fullscreen)
        var skipTopCorners = false
        if underBar && !NSMenu.menuBarVisible() {
            skipTopCorners = true
        }

        if topEnabled && !skipTopCorners {
            // Top-left
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

            // Top-right
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

        // ── Bottom ────────────────────────────────────────────────────────────
        if bottomEnabled {
            // Bottom-left
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

            // Bottom-right
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
        level              = .init(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

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

extension NSScreen {
    var isBuiltin: Bool {
        return localizedName.localizedCaseInsensitiveContains("Built-in") ||
               localizedName.localizedCaseInsensitiveContains("Retina") ||
               self == NSScreen.screens.first
    }
}
