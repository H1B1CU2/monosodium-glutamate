import AppKit
import QuartzCore

// MARK: - Cortex in the notch while its bar is closed
//
// Closing Cortex's ⌥Space bar before the answer comes no longer loses it: the
// answer carries on, and Cortex reports what it's doing (Cortex's
// CortexActivityReporter). MSG shows that as a pill a little taller than the
// notch, like a live activity on the Dynamic Island: Cortex's brain on the
// left, what it's doing on the right ("Thinking", "Searching the web"). When
// the answer lands the pill grows into a card for a few seconds, with the
// question, the start of the answer and the notch's ding, then shrinks back
// to "Answer ready", which goes by itself after 30 s or as soon as the bar
// opens again.
//
// While the pill is up, the notch is Cortex's: pointing at it grows the pill
// into Cortex's card (the question and what it's doing, or the answer) rather
// than MSG's notch card, and a click opens the ⌥Space bar on that chat.
// Two fingers swiping up over it, into the notch, put it away (NotchSwipeUp).

final class CortexActivityPill {
    static let shared = CortexActivityPill()

    private enum Stage: Equatable {
        case working(text: String, symbol: String)
        /// The card shown by itself when the answer lands.
        case answered
        /// "Answer ready" until it times out or the bar opens.
        case ready
    }

    private var stage: Stage?
    private var query: String?
    private var answer: String?
    private var elapsed = 0
    private var hovered = false
    /// The live pill was swiped away: it stays gone until the answer lands.
    private var liveDismissed = false
    private var swipe = NotchSwipeUp()

    private(set) var isShowing = false
    private var panel: NSPanel?
    private var host: NotchShapeHostView?
    private let view = CortexPillView()
    private var notch: CGRect = .zero
    private var shownSize: CGSize?
    private var stepWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var resizeCompletion: DispatchWorkItem?
    private var resizeGeneration = 0
    private var hoverWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var lastMove: CFAbsoluteTime = 0
    private var started = false

    /// The answer's card (15 s, the user's choice), then "Answer ready" (30 s).
    private static let answeredHold: TimeInterval = 15
    private static let readyHold: TimeInterval = 30

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.pongsiri.cortex.activity"),
                                                            object: nil, queue: .main) { [weak self] note in
            guard let text = note.object as? String, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self?.receive(object)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.pongsiri.cortex" else { return }
            self?.dismiss(animated: true)
        }
        // Locked or asleep: out of sight, and back on return if it still holds.
        PresentationState.shared.addObserver { [weak self] in
            guard let self else { return }
            if PresentationState.shared.canPresent { self.present() } else { self.hide(animated: false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hide(animated: false)
            self?.present()
        }
    }

    private func receive(_ object: [String: Any]) {
        if let question = object["query"] as? String, !question.isEmpty { query = question }
        switch object["state"] as? String {
        case "thinking", "tool", "writing":
            stepWork?.cancel()
            answer = nil
            stage = .working(text: object["text"] as? String ?? "Thinking", symbol: object["symbol"] as? String ?? "brain")
            present()
        case "answered":
            liveDismissed = false
            elapsed = (object["elapsed"] as? NSNumber)?.intValue ?? 0
            answer = object["answer"] as? String
            if AppSettings.shared.notchNoticeSound { NotchHUD.ding() }
            // The notch card is open: it says so in its header, and the pill
            // waits behind it already showing "Answer ready".
            let wing = NotchWingEvent(id: "cortex", symbol: "brain", text: "Cortex answered · \(Self.duration(elapsed))")
            if AgentNotchCard.shared.showWing(wing, hold: 4) {
                becomeReady()
                return
            }
            stage = .answered
            present()
            step(after: Self.answeredHold) { $0.becomeReady() }
        default:
            dismiss(animated: true)
        }
    }

    private func becomeReady() {
        stage = .ready
        present()
        step(after: Self.readyHold) { pill in
            // Not while it's being read: when the pointer leaves.
            if pill.hovered { pill.stage = .ready } else { pill.dismiss(animated: true) }
        }
    }

    private func step(after delay: TimeInterval, _ action: @escaping (CortexActivityPill) -> Void) {
        stepWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stepWork = nil
            action(self)
        }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// "12s", "3m", "1h 5m".
    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(max(0, seconds))s" : seconds < 3600 ? "\(seconds / 60)m"
            : "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }

    /// What the view shows now: the pill, or Cortex's card when it has just
    /// answered or the pointer is on it.
    private var display: CortexPillView.Mode? {
        switch stage {
        case .working(let text, let symbol)?:
            if liveDismissed { return nil }
            guard hovered else { return .live(text: text, symbol: symbol) }
            return .card(symbol: symbol, status: text, dim: nil, body: query ?? "Working on it", working: true,
                         hint: "Click to open")
        case .answered?:
            return answerCard
        case .ready?:
            return hovered ? answerCard : .ready
        case nil:
            return nil
        }
    }

    private var answerCard: CortexPillView.Mode {
        .card(symbol: "brain", status: "Answered · \(Self.duration(elapsed))", dim: query,
              body: answer ?? "Your answer is ready.", working: false, hint: "Click or ⌥ Space to continue")
    }

    // MARK: Showing

    private func present() {
        guard let display, PresentationState.shared.canPresent, let screen = AgentNotchCard.notchScreen() else { return }
        let notch = AgentNotchCard.notchRect(screen)
        let panel = self.panel ?? makePanel()
        guard let host else { return }
        orderOutWork?.cancel()
        orderOutWork = nil
        let fresh = !isShowing || notch != self.notch
        self.notch = notch
        view.configure(notch: notch.size)
        let size = view.show(display, animated: !fresh)
        let target = CGRect(x: (notch.midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                            width: size.width, height: size.height)
        if fresh {
            cancelResize()
            panel.setFrame(target, display: false)
            host.layout(notch: notch, in: target)
            // Behind MSG's own notch cards (same level), over everything else.
            panel.orderBack(nil)
            panel.ignoresMouseEvents = false
            host.animateOpen()
            isShowing = true
            startWatching()
        } else if size != shownSize {
            resize(to: target, from: shownSize ?? size)
        }
        shownSize = size
    }

    /// The transparent backing grows once to hold both shapes, the silhouette
    /// animates inside it, then the backing shrinks to the card again, so only
    /// the card itself ever takes the pointer.
    private func resize(to target: CGRect, from size: CGSize) {
        guard let panel, let host else { return }
        cancelResize()
        let canvas = NotchTransition.canvas(from: panel.frame, to: target)
        if panel.frame != canvas { panel.setFrame(canvas, display: false) }
        host.layout(notch: notch, in: canvas, cardSize: host.presentedCardSize)
        host.showOpenInstantly()
        host.animateResize(to: target.size, notch: notch, in: canvas, beginTime: CACurrentMediaTime())
        let generation = resizeGeneration
        let completion = DispatchWorkItem { [weak self] in
            guard let self, self.isShowing, self.resizeGeneration == generation,
                  let panel = self.panel, let host = self.host else { return }
            panel.setFrame(target, display: false)
            host.layout(notch: self.notch, in: target)
            host.showOpenInstantly()
        }
        resizeCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTransition.duration, execute: completion)
    }

    private func cancelResize() {
        resizeCompletion?.cancel()
        resizeCompletion = nil
        resizeGeneration += 1
    }

    private func dismiss(animated: Bool) {
        stage = nil
        liveDismissed = false
        query = nil
        answer = nil
        hovered = false
        stepWork?.cancel()
        stepWork = nil
        hide(animated: animated)
    }

    private func hide(animated: Bool) {
        stopWatching()
        cancelResize()
        guard isShowing, let panel, let host else { return }
        isShowing = false
        shownSize = nil
        panel.ignoresMouseEvents = true
        view.stopPulse()
        guard animated else {
            panel.orderOut(nil)
            return
        }
        host.animateClosed()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel?.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchShapeHostView.closeDuration + 0.05, execute: work)
    }

    // MARK: Pointer

    /// While the pill is up the notch is Cortex's: pointing at it grows the
    /// card (MSG's own card stays shut, see AgentNotchCard.expand), and moving
    /// away shrinks it back. Watched only while the pill shows.
    private func startWatching() {
        guard monitors.isEmpty else { return }
        let move: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: move) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { move($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard let self, self.cardContains(NSEvent.mouseLocation) else { return event }
            self.openCortex()
            return nil
        }) { monitors.append(m) }
        swipe = NotchSwipeUp()
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            switch self.swipe.handle(event, in: panel.contentView) {
            case .pass: return event
            case .consume: return nil
            case .close:
                self.swipedAway()
                return nil
            }
        }) { monitors.append(m) }
    }

    /// Swiped up into the notch. The answer's card and "Answer ready" go for
    /// good; the live pill goes until the answer lands, which still shows.
    private func swipedAway() {
        guard case .working? = stage else { return dismiss(animated: true) }
        liveDismissed = true
        hovered = false
        hide(animated: true)
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hoverWork?.cancel()
        hoverWork = nil
        leaveWork?.cancel()
        leaveWork = nil
    }

    private func cardContains(_ point: CGPoint) -> Bool {
        guard isShowing, let size = shownSize else { return false }
        let card = CGRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height, width: size.width, height: size.height)
        return card.insetBy(dx: -8, dy: -8).contains(point)
    }

    private func pointerMoved() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastMove >= 0.025, isShowing else { return }
        lastMove = now
        let point = NSEvent.mouseLocation
        let inside = cardContains(point)
            || CGRect(x: notch.minX - 10, y: notch.minY - 4, width: notch.width + 20, height: notch.height + 8).contains(point)
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
            guard !hovered, hoverWork == nil else { return }
            // A beat of dwell, so passing through to the menu bar doesn't pop it.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverWork = nil
                self.hovered = true
                self.present()
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            hoverWork?.cancel()
            hoverWork = nil
            guard hovered, leaveWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.leaveWork = nil
                self.hovered = false
                // "Answer ready" ran out while it was being read.
                if self.stage == .ready, self.stepWork == nil { self.dismiss(animated: true) } else { self.present() }
            }
            leaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    /// Cortex opens its bar on this chat (and reports idle, which takes the pill away).
    private func openCortex() {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.pongsiri.cortex.notch.show"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NotchTransition.windowLevel
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        let host = NotchShapeHostView(content: view)
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

// MARK: - Contents

/// Flipped. The pill: Cortex's brain in the left wing, what it's doing in the
/// right one. The card: the same row on top, then a dim line (the question),
/// the body (the answer, or the question while it works) and a hint. Laid out
/// in the visible card, centred at the top of whatever the window is.
final class CortexPillView: NSView {
    enum Mode: Equatable {
        case live(text: String, symbol: String)
        case ready
        case card(symbol: String, status: String, dim: String?, body: String, working: Bool, hint: String)
    }

    private static let pillPadding: CGFloat = 14
    private static let padding: CGFloat = 20
    private static let cardWing: CGFloat = 150
    /// The pill reaches this far below the notch, so its edge shows all along
    /// instead of meeting the notch's own rounded bottom.
    private static let pillDrop: CGFloat = 2

    private var notchSize = CGSize(width: 185, height: 32)
    private var mode: Mode?
    private var card = CGSize.zero
    private let icon = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private let dim = NSTextField(labelWithString: "")
    /// The whole answer: the card grows to fit it, up to `maxBody`, then scrolls.
    private let bodyScroll = NSScrollView()
    private let body = NSTextView()
    private let hint = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleNone
        icon.unregisterDraggedTypes()
        icon.wantsLayer = true
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .white
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        dot.backgroundColor = NSColor(calibratedRed: 0.36, green: 0.79, blue: 0.65, alpha: 1).cgColor
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
        dim.font = .systemFont(ofSize: 12, weight: .medium)
        dim.textColor = NSColor(white: 1, alpha: 0.5)
        dim.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 13)
        body.textColor = .white
        body.isEditable = false
        body.isSelectable = false
        body.drawsBackground = false
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = 0
        body.textContainer?.widthTracksTextView = true
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        bodyScroll.documentView = body
        bodyScroll.drawsBackground = false
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.autohidesScrollers = true
        bodyScroll.hasHorizontalScroller = false
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor(white: 1, alpha: 0.45)
        hint.alignment = .right
        for view in [icon, status, dim, bodyScroll, hint] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(notch: CGSize) {
        notchSize = notch
    }

    /// Shows `next` and returns the card's size for it. `animated`: a change of
    /// kind crossfades (a new status just replaces the old).
    @discardableResult
    func show(_ next: Mode, animated: Bool) -> CGSize {
        let kindChanged: Bool
        switch (mode, next) {
        case (.live?, .live), (.ready?, .ready): kindChanged = false
        case (.card?, .card): kindChanged = mode != next
        default: kindChanged = true
        }
        if animated, kindChanged, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer.add(fade, forKey: "mode")
        }
        mode = next
        switch next {
        case .live(let text, let symbol):
            icon.image = Self.symbol(symbol)
            status.stringValue = text
            startPulse()
        case .ready:
            stopPulse()
            icon.image = Self.symbol("brain")
            status.stringValue = "Answer ready"
        case .card(let symbol, let text, let line, let main, let working, let tip):
            icon.image = Self.symbol(symbol)
            status.stringValue = text
            dim.stringValue = line ?? ""
            body.string = main
            body.textColor = .white
            body.font = .systemFont(ofSize: 13)
            body.scroll(.zero)
            hint.stringValue = tip
            if working { startPulse() } else { stopPulse() }
        }
        card = size(for: next)
        needsLayout = true
        layoutSubtreeIfNeeded()
        return card
    }

    private var pillHeight: CGFloat { notchSize.height + Self.pillDrop }

    /// The answer's full height at `width`.
    private func fullBodyHeight(width: CGFloat) -> CGFloat {
        guard let container = body.textContainer, let layout = body.layoutManager else { return 18 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    /// Up to half the screen; a longer answer scrolls inside the card.
    private var maxBody: CGFloat {
        max(120, ((NSScreen.main?.frame.height ?? 900) * 0.5).rounded())
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        min(maxBody, fullBodyHeight(width: width))
    }

    private func size(for mode: Mode) -> CGSize {
        switch mode {
        case .card(_, _, let line, _, _, _):
            let width = notchSize.width + 2 * Self.cardWing
            let top = pillHeight + 8
            let dimHeight: CGFloat = (line?.isEmpty == false) ? 22 : 0
            return CGSize(width: width,
                          height: top + dimHeight + bodyHeight(width: width - 2 * Self.padding - 4) + 12 + 14 + Self.padding)
        case .live, .ready:
            // The wings fit the status (and the dot), within reason, and match.
            let text = (status.cell?.cellSize.width ?? 60).rounded(.up)
            let dotRoom: CGFloat = mode == .ready ? 12 : 0
            let wing = max(76, min(180, text + dotRoom + Self.pillPadding + 10))
            return CGSize(width: notchSize.width + 2 * wing, height: pillHeight)
        }
    }

    override func layout() {
        super.layout()
        guard let mode else { return }
        let x0 = ((bounds.width - card.width) / 2).rounded()
        let isCard: Bool
        if case .card = mode { isCard = true } else { isCard = false }
        let inset = isCard ? Self.padding : Self.pillPadding
        // The row sits in the middle of the pill, which hangs below the notch.
        let rowCenter = (pillHeight / 2).rounded()
        icon.frame = CGRect(x: x0 + inset, y: rowCenter - 12, width: 24, height: 24)
        let statusWidth = (status.cell?.cellSize.width ?? 60).rounded(.up) + 1
        status.frame = CGRect(x: x0 + card.width - inset - statusWidth, y: rowCenter - 8,
                              width: statusWidth, height: 17)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = mode != .ready
        dot.frame = CGRect(x: status.frame.minX - 12, y: rowCenter - 3, width: 6, height: 6)
        CATransaction.commit()

        dim.isHidden = !isCard || dim.stringValue.isEmpty
        bodyScroll.isHidden = !isCard
        hint.isHidden = !isCard
        guard isCard else { return }
        let width = card.width - 2 * Self.padding
        var y = pillHeight + 8
        if !dim.isHidden {
            dim.frame = CGRect(x: x0 + Self.padding, y: y, width: width, height: 16)
            y += 22
        }
        // In by the 2 pt a label pads its text, so the answer lines up with
        // the question above it.
        let textWidth = width - 4
        let full = fullBodyHeight(width: textWidth)
        let height = min(maxBody, full)
        bodyScroll.frame = CGRect(x: x0 + Self.padding + 2, y: y, width: textWidth, height: height)
        body.frame = CGRect(x: 0, y: 0, width: textWidth, height: full)
        bodyScroll.hasVerticalScroller = full > height
        y += height + 12
        hint.frame = CGRect(x: x0 + Self.padding, y: y, width: width, height: 14)
    }

    /// The brain breathes while Cortex works.
    private func startPulse() {
        guard let layer = icon.layer, layer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    func stopPulse() {
        icon.layer?.removeAnimation(forKey: "pulse")
    }

    private static func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "brain", accessibilityDescription: nil))?.withSymbolConfiguration(config)
    }
}

// MARK: - Swipe up to close

/// Two fingers swiping up over a notch card, into the notch, close it the way
/// the Dynamic Island takes a swipe. Trackpad gestures only, and the gesture
/// decides once, on its first movement: when a scroll view under the pointer
/// can still move that way it gets the whole gesture instead, so a long answer
/// scrolls to its end first and the next swipe closes the card.
struct NotchSwipeUp {
    enum Verdict { case pass, consume, close }

    private enum Claim { case idle, undecided, tracking, closed, passing }
    private var claim = Claim.idle
    private var travel: CGFloat = 0
    /// Finger travel, in points, before it closes.
    private static let distance: CGFloat = 40

    mutating func handle(_ event: NSEvent, in root: NSView?) -> Verdict {
        guard event.hasPreciseScrollingDeltas else { return .pass }
        // The glide after the fingers lift belongs to whoever had the gesture.
        if !event.momentumPhase.isEmpty { return claim == .tracking || claim == .closed ? .consume : .pass }
        guard !event.phase.isEmpty else { return .pass }
        if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
            claim = .undecided
            travel = 0
        }
        if claim == .undecided, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            claim = vertical && Self.upward(event) > 0 && !Self.scrollable(under: event, in: root) ? .tracking : .passing
        }
        switch claim {
        case .tracking:
            travel += Self.upward(event)
            guard travel >= Self.distance else { return .consume }
            claim = .closed
            return .close
        case .closed:
            return .consume
        case .idle, .undecided, .passing:
            return .pass
        }
    }

    /// How far the fingers moved up: scroll deltas follow the content, which
    /// natural scrolling moves with the fingers and classic scrolling against.
    private static func upward(_ event: NSEvent) -> CGFloat {
        event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
    }

    /// A visible scroll view under the pointer with room to move the way this
    /// gesture scrolls.
    private static func scrollable(under event: NSEvent, in root: NSView?) -> Bool {
        guard let root, event.window === root.window else { return false }
        var stack = [root]
        while let view = stack.popLast() {
            guard !view.isHidden else { continue }
            if let scroll = view as? NSScrollView, scroll.convert(scroll.bounds, to: nil).contains(event.locationInWindow),
               canMove(scroll, deltaY: event.scrollingDeltaY) { return true }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    private static func canMove(_ scroll: NSScrollView, deltaY: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        let visible = scroll.contentView.bounds, content = document.frame
        guard content.height > visible.height + 1 else { return false }
        let flipped = scroll.contentView.isFlipped
        let atTop = flipped ? visible.minY <= content.minY + 1 : visible.maxY >= content.maxY - 1
        let atBottom = flipped ? visible.maxY >= content.maxY - 1 : visible.minY <= content.minY + 1
        // A negative delta scrolls on toward the end.
        return deltaY < 0 ? !atBottom : !atTop
    }
}
