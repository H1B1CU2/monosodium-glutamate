import AppKit
import QuartzCore

// MARK: - AI activity in the notch
//
// Hovering restores the last page: AI usage and tasks, Calendar, Clipboard,
// Tray or Audio (dots under the notch, or a sideways swipe, change it).
// Moving away folds it back in; clicking a task opens its session, while the
// rest of the AI page opens TokenBar's popover.
//
// The shape is pure black, so it reads as the notch itself growing, with a
// hairline around it the way Apple outlines its dark HUDs. Along the top edge
// the hairline fades out as it nears the notch: the hardware cutout would cut
// it off, and a line that simply stopped there would show the seam.
//
// Opening, closing and page changes morph GPU paths in a fixed backing window.
// Pane contents retain their final layout beneath the animated clipping mask.
// It only appears on a display with a real notch.

/// Session IDs prevent an old closing animation from releasing a newer launcher.
struct CortexNotchSession {
    private(set) var id: String?
    private(set) var pid: Int32?
    private var resumeDashboard = false
    var isActive: Bool { id != nil }
    mutating func open(id: String, pid: Int32, dashboardVisible: Bool) {
        if self.id == nil { resumeDashboard = dashboardVisible }
        self.id = id
        self.pid = pid
    }
    mutating func cancelResume() { resumeDashboard = false }
    mutating func close(id: String, resume: Bool) -> Bool? {
        guard self.id == id else { return nil }
        let restore = resume && resumeDashboard
        self.id = nil
        pid = nil
        resumeDashboard = false
        return restore
    }
}

final class AgentNotchCard {
    static let shared = AgentNotchCard()

    private var panel: NSPanel?
    private var host: NotchCardHostView?
    private var monitors: [Any] = []
    private var pointerTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var lastMove: CFAbsoluteTime = 0
    private var expanded = false
    private var clockTimer: Timer?
    private var resizeCompletion: DispatchWorkItem?
    private var resizeTarget: CGRect?
    private var resizeGeneration = 0
    private var observing = false
    private var cortex = CortexNotchSession()

    /// Deferring to Notch Previews while that's on: both answer the same hover.
    private var isEnabled: Bool {
        AppSettings.shared.notchAgentCard && !AppSettings.shared.notchPreviewEnabled
            && AgentNotchDashboardView.Page.allCases.contains {
                !AppSettings.shared.notchDisabledPanes.contains($0.rawValue)
            }
    }

    func start() {
        if !observing {
            observing = true
            AIUsageFeed.shared.addObserver { [weak self] _ in self?.refreshIfExpanded() }
            AIUsageFeed.shared.start()
            PresentationState.shared.addObserver { [weak self] in
                if !PresentationState.shared.canPresent {
                    self?.cortex.cancelResume()
                    self?.collapse(animated: false)
                }
            }
            NotificationCenter.default.addObserver(forName: .notchPreviewChanged, object: nil, queue: .main) { [weak self] _ in
                self?.settingChanged()
            }
        }
        if !observingCortex { observeCortex() }
        guard isEnabled else { return }
        startPointerPolling()
        guard monitors.isEmpty else { return }
        ClipboardHistory.shared.start()
        let move: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: move) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { move($0); return $0 }) { monitors.append(m) }
        // Sideways swipes over the card turn its pages (events in our own windows only).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, self.expanded, let panel = self.panel, let card = self.host?.card,
                  self.visibleFrame(panel).contains(NSEvent.mouseLocation) else { return event }
            return card.swipe(event) ? nil : event
        }) { monitors.append(m) }
        let click: (NSEvent) -> Void = { [weak self] event in _ = self?.mouseDown(event) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: click) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            self?.mouseDown(event) == true ? nil : event
        }) { monitors.append(m) }
    }

    func stop() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        cortex.cancelResume()
        ClipboardHistory.shared.stop()
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hoverWork?.cancel()
        hoverWork = nil
        collapse(animated: false)
    }

    /// Open on its Tray page: a file dragged to the notch drops there instead
    /// of on the drop card, which would fold this away.
    var isSuppressedByCortex: Bool { cortex.isActive }

    var isShowingTray: Bool { expanded && host?.card.page == .tray }

    /// A notice click leaves the notch before bringing its session forward.
    func openSession(_ link: AgentSessionLink) {
        hoverWork?.cancel()
        hoverWork = nil
        collapse(animated: true)
        link.open()
    }

    /// The card is open: a change shows small in its header for `hold`.
    func showWing(_ event: NotchWingEvent, hold: TimeInterval) -> Bool {
        guard !isSuppressedByCortex, isEnabled, expanded, let host, !host.card.isPresentingHUD else { return false }
        host.card.showWing(event, hold: hold)
        return true
    }

    /// The card is open on its Audio page: a volume change shows there.
    func showVolumeInAudioPane() -> Bool {
        guard !isSuppressedByCortex, isEnabled, expanded, let host else { return false }
        return host.card.showVolumeInAudioPane()
    }

    /// Volume/brightness temporarily use the same surface, retaining the user's page.
    func presentHUD(_ view: NSView, size: CGSize) -> Bool {
        guard !isSuppressedByCortex, isEnabled, expanded, let host else { return false }
        hoverWork?.cancel()
        hoverWork = nil
        collapseWork?.cancel()
        collapseWork = nil
        host.card.presentHUD(view, size: size)
        refreshIfExpanded(animated: true)
        return true
    }

    func restoreAfterHUD(animated: Bool, resume: Bool) {
        guard let host, host.card.isPresentingHUD else { return }
        host.card.dismissHUD()
        guard resume, expanded, isEnabled, PresentationState.shared.canPresent else { return }
        refreshIfExpanded(animated: animated)
        host.card.didPresent()
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? NotchTransition.duration : 0)) { [weak self] in
            guard let self, self.expanded, self.host?.card.isPresentingHUD == false else { return }
            self.mouseMoved()
        }
    }

    /// The notch HUD is taking the notch: fold away at once so the HUD grows
    /// out of the bare notch rather than over this card.
    func yieldToHUD() {
        hoverWork?.cancel()
        hoverWork = nil
        collapse(animated: false)
    }

    /// The setting (or Notch Previews) flipped. Main thread.
    func settingChanged() {
        if isEnabled { start() } else { stop() }
        host?.card.prepareForPresentation()
        refreshIfExpanded()
    }

    // Cortex retains its own Option + Space shortcut and text field.
    private var observingCortex = false
    private func observeCortex() {
        observingCortex = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.pongsiri.cortex.notch.opened"),
                           object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String,
                  let pid = (note.userInfo?["pid"] as? NSNumber)?.int32Value,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.pongsiri.cortex" else { return }
            self.cortex.open(id: id, pid: pid, dashboardVisible: self.expanded)
            self.hoverWork?.cancel()
            self.hoverWork = nil
            NotchHUD.shared.hide(animated: false, resumeDashboard: false)
            self.collapse(animated: false)
        }
        center.addObserver(forName: Notification.Name("com.pongsiri.cortex.notch.closed"),
                           object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String,
                  let restore = self.cortex.close(id: id, resume: (note.userInfo?["resume"] as? NSNumber)?.boolValue ?? false) else { return }
            self.resumeAfterCortex(restore)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.cortex.pid, let id = self.cortex.id,
                  let restore = self.cortex.close(id: id, resume: true) else { return }
            self.resumeAfterCortex(restore)
        }
        center.postNotificationName(Notification.Name("com.pongsiri.cortex.notch.requestState"),
                                    object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func resumeAfterCortex(_ restore: Bool) {
        guard restore, isEnabled, PresentationState.shared.canPresent, let screen = Self.notchScreen() else { return }
        expand(on: screen, restoring: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTransition.duration) { [weak self] in self?.mouseMoved() }
    }

    // MARK: Pointer

    /// The menu bar and fullscreen overlays can stop delivering mouse-moved
    /// events at the notch. Read the pointer independently, including while a
    /// menu is tracking; keep the same dwell, collapse and ownership rules.
    private func startPointerPolling() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, PresentationState.shared.canPresent,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.mouseMoved()
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func mouseMoved() {
        guard !isSuppressedByCortex else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMove >= 0.025 else { return }
        lastMove = now
        let point = NSEvent.mouseLocation
        guard let screen = Self.notchScreen() else { return }
        let trigger = Self.triggerRect(screen)

        if expanded, let panel {
            // The temporary HUD owns hover/drag timing until it returns this page.
            if host?.card.isPresentingHUD == true { return }
            if visibleFrame(panel).insetBy(dx: -8, dy: -8).union(trigger).contains(point) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let panel = self.panel else { return }
                    self.collapseWork = nil
                    let point = NSEvent.mouseLocation
                    if !self.visibleFrame(panel).insetBy(dx: -8, dy: -8).union(Self.triggerRect(screen)).contains(point) {
                        self.collapse(animated: true)
                    }
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            return
        }

        if trigger.contains(point) {
            guard hoverWork == nil else { return }
            // A beat of dwell, so passing through to the menu bar doesn't pop it.
            let work = DispatchWorkItem { [weak self] in
                self?.hoverWork = nil
                guard Self.triggerRect(screen).contains(NSEvent.mouseLocation) else { return }
                self?.expand(on: screen)
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            hoverWork?.cancel()
            hoverWork = nil
        }
    }

    private func mouseDown(_ event: NSEvent) -> Bool {
        guard expanded, let panel else { return false }
        if host?.card.isPresentingHUD == true {
            if !visibleFrame(panel).contains(NSEvent.mouseLocation) {
                NotchHUD.shared.hide(animated: false, resumeDashboard: false)
                collapse(animated: true)
            }
            return false
        }
        if visibleFrame(panel).contains(NSEvent.mouseLocation) {
            if let card = host?.card {
                let point = card.convert(panel.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                // A finished task on the header's wing: off to its session.
                if event.type == .leftMouseDown, let link = card.wingLink(at: point) {
                    openSession(link)
                    return true
                }
                if event.type == .leftMouseDown, let link = card.sessionLink(at: point) {
                    openSession(link)
                    return true
                }
                if event.type == .leftMouseDown, card.selectTab(at: point) { return true }
                // Only TokenBar's pages open its popover. Calendar handles Reminders;
                // Clipboard and Audio handle their own clicks.
                guard card.page.isTokenBar else { return false }
            }
            AIUsageFeed.showPopover(anchor: visibleFrame(panel))
            collapse(animated: true)
            return true
        }
        collapse(animated: true)
        return false
    }

    // MARK: Showing

    private func content() -> ([AgentLockScreen.Row], AgentActivityCardView.State) {
        let rows = AgentLockScreen.activityRows()
        guard !rows.isEmpty else { return (rows, .idle) }
        let since = AIUsageFeed.shared.snapshot?.processing?.since.map { Date(timeIntervalSince1970: $0) }
        return (rows, .working(since: since ?? Date()))
    }

    private func expand(on screen: NSScreen, restoring: Bool = false) {
        // The notch HUD has the notch while it's up (the pointer may be on it).
        // Cortex's pill holds the notch while it's up: pointing at it opens Cortex's card.
        guard !isSuppressedByCortex, isEnabled, PresentationState.shared.canPresent, !expanded, !NotchHUD.shared.isShowing,
              !CortexActivityPill.shared.isShowing else { return }
        orderOutWork?.cancel()
        orderOutWork = nil
        let (rows, state) = content()
        let panel = self.panel ?? makePanel()
        guard let host else { return }
        let notch = Self.notchRect(screen)
        host.card.configureNotch(width: notch.width, height: notch.height,
                                 maximumHeight: screen.frame.height - 32)
        if !restoring { host.card.prepareForPresentation() }
        host.card.update(rows: rows, state: state)
        let target = frame(for: host.card.fittingCardSize, on: screen)
        panel.setFrame(target, display: false)
        host.layout(notch: Self.notchRect(screen), in: target)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        expanded = true
        host.card.didPresent()
        host.animateOpen()
        // A tap under the finger as it opens (felt only with a finger on a
        // Force Touch trackpad).
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        clockTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.host?.card.refreshClock()
        }
        timer.tolerance = 5
        clockTimer = timer
    }

    private func collapse(animated: Bool) {
        if host?.card.isPresentingHUD == true {
            NotchHUD.shared.hide(animated: false, resumeDashboard: false)
        }
        cancelResize()
        host?.card.stopPageTransition()
        collapseWork?.cancel()
        collapseWork = nil
        clockTimer?.invalidate()
        clockTimer = nil
        guard expanded, let panel, let host else { return }
        expanded = false
        panel.ignoresMouseEvents = true
        guard animated else {
            panel.orderOut(nil)
            return
        }
        host.animateClosed()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded else { return }
            self.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchCardHostView.closeDuration + 0.05, execute: work)
    }

    /// New counts or titles while the card is up: lay it out again in place.
    private func refreshIfExpanded(animated: Bool = false) {
        guard expanded, let panel, let host, let screen = Self.notchScreen() else { return }
        let notch = Self.notchRect(screen)
        if !animated {
            let (rows, state) = content()
            host.card.configureNotch(width: notch.width, height: notch.height,
                                     maximumHeight: screen.frame.height - 32)
            host.card.update(rows: rows, state: state)
        }
        let target = frame(for: host.card.fittingCardSize, on: screen)
        if animated || resizeCompletion != nil {
            animateResize(to: target, notch: notch,
                          beginTime: animated ? host.card.pageTransitionStart : CACurrentMediaTime())
            return
        }
        if target != panel.frame {
            panel.setFrame(target, display: true)
            host.layout(notch: Self.notchRect(screen), in: target)
            host.showOpenInstantly()
        }
    }

    private func cancelResize() {
        resizeCompletion?.cancel()
        resizeCompletion = nil
        resizeTarget = nil
        resizeGeneration += 1
    }

    private func visibleFrame(_ panel: NSPanel) -> CGRect {
        let size = host?.presentedCardSize ?? panel.frame.size
        return CGRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func animateResize(to target: CGRect, notch: CGRect, beginTime: CFTimeInterval) {
        guard let panel, let host, target != resizeTarget else { return }
        let fromSize = host.presentedCardSize
        cancelResize()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(target, display: true)
            host.layout(notch: notch, in: target)
            host.showOpenInstantly()
            return
        }
        resizeTarget = target
        let canvas = NotchTransition.canvas(from: panel.frame, to: target)
        // Grow the transparent backing once, then let Core Animation animate
        // the black silhouette and mask. No WindowServer resize on each frame.
        if panel.frame != canvas { panel.setFrame(canvas, display: false) }
        host.layout(notch: notch, in: canvas, cardSize: fromSize)
        host.showOpenInstantly()
        host.animateResize(to: target.size, notch: notch, in: canvas, beginTime: beginTime)
        let generation = resizeGeneration
        let completion = DispatchWorkItem { [weak self] in
            guard let self, self.expanded, self.resizeGeneration == generation,
                  let panel = self.panel, let host = self.host else { return }
            self.cancelResize()
            // Shrink the transparent backing after the visible motion finishes.
            panel.setFrame(target, display: false)
            host.layout(notch: notch, in: target)
            host.showOpenInstantly()
        }
        resizeCompletion = completion
        let remaining = max(0, beginTime + NotchTransition.duration - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: completion)
    }

    private func frame(for card: CGSize, on screen: NSScreen) -> CGRect {
        let notch = Self.notchRect(screen)
        let width = max(card.width, notch.width + 80)
        // The dashboard header occupies the notch's side wings.
        let height = card.height
        return CGRect(x: (notch.midX - width / 2).rounded(), y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    private func makePanel() -> NSPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // Above the control bar/overflow covers even when they reorder themselves.
        panel.level = NotchTransition.windowLevel
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let host = NotchCardHostView()
        host.card.onPageChanged = { [weak self] in self?.refreshIfExpanded(animated: true) }
        host.card.onContentChanged = { [weak self] in self?.refreshIfExpanded(animated: true) }
        host.card.onOpenSession = { [weak self] in self?.openSession($0) }
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    // MARK: Geometry

    /// The built-in display, when it has a notch.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
    }

    /// The notch, between the two menu-bar areas beside it (bottom-left origin).
    static func notchRect(_ screen: NSScreen) -> CGRect {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else {
            return CGRect(x: screen.frame.midX - 92, y: screen.frame.maxY - 32, width: 185, height: 32)
        }
        return CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
    }

    private static func triggerRect(_ screen: NSScreen) -> CGRect {
        let notch = notchRect(screen)
        return CGRect(x: notch.minX - 10, y: notch.minY - 4,
                      width: notch.width + 20, height: screen.frame.maxY - notch.minY + 4)
    }
}

/// AppKit keeps windows below the menu bar; this one has to reach the top of
/// the display, where the notch is.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// MARK: - Host view

final class NotchCardHostView: NotchShapeHostView {
    let card: AgentNotchDashboardView

    init() {
        let card = AgentNotchDashboardView()
        self.card = card
        super.init(content: card)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The black shape, its hairline, and the content inside. Not flipped: the top
/// edge is the screen's top edge. Shared by the TokenBar card and the notch HUD.
class NotchShapeHostView: NSView {
    static let closeDuration: TimeInterval = 0.3

    let content: NSView
    private let cardContainer = NSView()
    private let contentMask = CAShapeLayer()
    private let shape = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let outlineMask = CALayer()
    private let maskBody = CALayer()
    private let maskTop = CAGradientLayer()

    private var closedPath: CGPath?
    private var openPath: CGPath?
    private var closedOutline: CGPath?
    private var openOutline: CGPath?

    /// Every corner alike, top ones included.
    private static let radius: CGFloat = 24
    private static let hairline: CGFloat = 0.75
    /// How far from the notch the top hairline starts to fade, and how close to
    /// it the fade reaches nothing.
    private static let fadeReach: CGFloat = 70
    private static let fadeGap: CGFloat = 6

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shape.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shape)

        outline.fillColor = nil
        outline.strokeColor = NSColor(white: 1, alpha: 0.22).cgColor
        outline.lineWidth = Self.hairline
        outline.opacity = 0
        outlineMask.addSublayer(maskBody)
        outlineMask.addSublayer(maskTop)
        maskBody.backgroundColor = NSColor.black.cgColor
        maskTop.startPoint = CGPoint(x: 0, y: 0.5)
        maskTop.endPoint = CGPoint(x: 1, y: 0.5)
        outline.mask = outlineMask
        layer?.addSublayer(outline)

        content.alphaValue = 0
        cardContainer.wantsLayer = true
        cardContainer.layer?.mask = contentMask
        addSubview(cardContainer)
        cardContainer.addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Lays out for a panel at `frame` whose notch is at `notch` (both in screen
    /// coordinates).
    var presentedCardSize: CGSize {
        shape.presentation()?.path?.boundingBoxOfPath.size
            ?? shape.path?.boundingBoxOfPath.size ?? bounds.size
    }

    func layout(notch: CGRect, in frame: CGRect, cardSize: CGSize? = nil) {
        // A HUD can lend its content to the dashboard, then reclaim it next time.
        if content.superview !== cardContainer { cardContainer.addSubview(content) }
        let bounds = CGRect(origin: .zero, size: frame.size)
        let size = cardSize ?? frame.size
        let visible = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height,
                             width: size.width, height: size.height)
        let local = notch.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // The notch's own shape: square at the screen edge, rounded below.
        let notchShape = CGRect(x: local.minX, y: bounds.maxY - local.height,
                                width: local.width, height: local.height)
        let notchRadius = min(10, local.height / 3)
        closedPath = Self.path(notchShape, top: 0, bottom: notchRadius)
        openPath = Self.path(visible, top: Self.radius, bottom: Self.radius)
        let inset = Self.hairline / 2
        closedOutline = Self.path(notchShape.insetBy(dx: inset, dy: inset), top: 0, bottom: notchRadius)
        openOutline = Self.path(visible.insetBy(dx: inset, dy: inset),
                                top: Self.radius - inset, bottom: Self.radius - inset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        outline.frame = bounds
        outlineMask.frame = bounds
        contentMask.frame = bounds
        // Everything below the top edge's band keeps its hairline; along the band
        // it fades out toward the notch.
        let band = Self.radius + 2
        maskBody.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - band)
        maskTop.frame = CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        let w = max(1, bounds.width)
        func at(_ x: CGFloat) -> NSNumber { NSNumber(value: Double(min(1, max(0, x / w)))) }
        maskTop.colors = [NSColor.black, .black, .clear, .clear, .black, .black].map(\.cgColor)
        maskTop.locations = [0, at(local.minX - Self.fadeReach), at(local.minX - Self.fadeGap),
                             at(local.maxX + Self.fadeGap), at(local.maxX + Self.fadeReach), 1]
        CATransaction.commit()

        cardContainer.frame = bounds
        content.frame = bounds
        content.layoutSubtreeIfNeeded()
    }

    /// The notch grows into the card: the shape first, then its hairline and
    /// contents a beat behind.
    func animateOpen() {
        guard let closedPath, let openPath, let closedOutline, let openOutline else { return }
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fromShape = shape.presentation()?.path ?? closedPath
        let fromOutline = outline.presentation()?.path ?? closedOutline
        let fromOutlineOpacity = outline.presentation()?.opacity ?? 0
        shape.path = openPath
        contentMask.path = openPath
        outline.path = openOutline
        outline.opacity = 1
        CATransaction.commit()
        shape.removeAllAnimations()
        contentMask.removeAllAnimations()
        outline.removeAllAnimations()

        // Eased to a stop, never past it: the notch grows and settles, no bounce.
        for (layer, from, to) in [(shape, fromShape, openPath), (contentMask, fromShape, openPath), (outline, fromOutline, openOutline)] {
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = from
            grow.toValue = to
            grow.duration = 0.36
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(grow, forKey: "grow")
        }
        let line = CABasicAnimation(keyPath: "opacity")
        line.fromValue = fromOutlineOpacity
        line.toValue = 1
        line.beginTime = now + 0.08
        line.duration = 0.25
        line.fillMode = .backwards
        outline.add(line, forKey: "lineIn")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.animator().alphaValue = 1
        }
        if let layer = content.layer {
            let drop = CABasicAnimation(keyPath: "transform.translation.y")
            drop.fromValue = 8
            drop.toValue = 0
            drop.beginTime = now + 0.04
            drop.duration = 0.32
            drop.fillMode = .backwards
            drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(drop, forKey: "drop")
        }
    }

    /// Folds back into the notch: contents and hairline go first, then the
    /// shape shrinks to exactly the notch and vanishes into it.
    func animateClosed() {
        guard let closedPath, let closedOutline else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fromShape = shape.presentation()?.path ?? openPath
        let fromOutline = outline.presentation()?.path ?? openOutline
        let fromOpacity = outline.presentation()?.opacity ?? 1
        shape.path = closedPath
        contentMask.path = closedPath
        outline.path = closedOutline
        outline.opacity = 0
        CATransaction.commit()
        shape.removeAllAnimations()
        contentMask.removeAllAnimations()
        outline.removeAllAnimations()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            content.animator().alphaValue = 0
        }
        let line = CABasicAnimation(keyPath: "opacity")
        line.fromValue = fromOpacity
        line.toValue = 0
        line.duration = 0.14
        outline.add(line, forKey: "lineOut")
        for (layer, from, to) in [(shape, fromShape, closedPath), (contentMask, fromShape, closedPath), (outline, fromOutline, closedOutline)] {
            let shrink = CABasicAnimation(keyPath: "path")
            shrink.fromValue = from
            shrink.toValue = to
            shrink.duration = Self.closeDuration
            shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            layer.add(shrink, forKey: "shrink")
        }
    }

    /// Already open, only re-laid out (a provider joined or left).
    func showOpenInstantly() {
        shape.removeAllAnimations()
        contentMask.removeAllAnimations()
        outline.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = openPath
        contentMask.path = openPath
        outline.path = openOutline
        outline.opacity = 1
        CATransaction.commit()
        content.alphaValue = 1
    }

    /// Animate all three paths on the compositor's clock in a fixed canvas.
    /// The starting silhouette is supplied from the presentation layer when a
    /// previous animation was interrupted, avoiding a jump on quick reversals.
    func animateResize(to size: CGSize, notch: CGRect, in canvas: CGRect, beginTime: CFTimeInterval) {
        guard let fromPath = shape.path, let fromOutline = outline.path else { return }
        layout(notch: notch, in: canvas, cardSize: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = openPath
        contentMask.path = openPath
        outline.path = openOutline
        CATransaction.commit()
        for (layer, from, to) in [(shape, fromPath, openPath), (contentMask, fromPath, openPath),
                                  (outline, fromOutline, openOutline)] {
            let resize = CABasicAnimation(keyPath: "path")
            resize.fromValue = from
            resize.toValue = to
            resize.beginTime = beginTime
            resize.duration = NotchTransition.duration
            resize.timingFunction = NotchTransition.timingFunction
            layer.add(resize, forKey: "paneResize")
        }
    }

    /// A rounded rect whose element count is the same for any radii (a square
    /// corner is a zero-length curve), so the closed and open shapes morph.
    private static func path(_ r: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let k: CGFloat = 0.5523
        let t = min(top, r.width / 2, r.height / 2), b = min(bottom, r.width / 2, r.height / 2)
        path.move(to: CGPoint(x: r.minX + b, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - b, y: r.minY))
        path.addCurve(to: CGPoint(x: r.maxX, y: r.minY + b),
                      control1: CGPoint(x: r.maxX - b + b * k, y: r.minY),
                      control2: CGPoint(x: r.maxX, y: r.minY + b - b * k))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - t))
        path.addCurve(to: CGPoint(x: r.maxX - t, y: r.maxY),
                      control1: CGPoint(x: r.maxX, y: r.maxY - t + t * k),
                      control2: CGPoint(x: r.maxX - t + t * k, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + t, y: r.maxY))
        path.addCurve(to: CGPoint(x: r.minX, y: r.maxY - t),
                      control1: CGPoint(x: r.minX + t - t * k, y: r.maxY),
                      control2: CGPoint(x: r.minX, y: r.maxY - t + t * k))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + b))
        path.addCurve(to: CGPoint(x: r.minX + b, y: r.minY),
                      control1: CGPoint(x: r.minX, y: r.minY + b - b * k),
                      control2: CGPoint(x: r.minX + b - b * k, y: r.minY))
        path.closeSubpath()
        return path
    }
}
