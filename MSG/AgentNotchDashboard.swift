import AppKit
import QuartzCore
import SwiftUI

enum NotchTransition {
    static let duration: TimeInterval = 0.36
    static var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
    // The control bar and its overflow covers use statusBar. Menus stay above.
    static let windowLevel = NSWindow.Level(NSWindow.Level.statusBar.rawValue + 1)

    static func eased(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        // Match the compositor's cubic curve so the underline and silhouette
        // settle together. Solve x(u) before evaluating y(u).
        func cubic(_ u: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<16 {
            let u = (low + high) / 2
            if cubic(u, 0.22, 0.36) < t { low = u } else { high = u }
        }
        if t == 0 || t == 1 { return t }
        return cubic((low + high) / 2, 1, 1)
    }

    /// One fixed backing surface while the compositor animates the silhouette.
    static func canvas(from start: CGRect, to end: CGRect) -> CGRect {
        let width = max(start.width, end.width)
        let height = max(start.height, end.height)
        return CGRect(x: end.midX - width / 2, y: end.maxY - height, width: width, height: height)
    }
}

/// Pages: AI usage and live tasks together, then Calendar, Clipboard, Tray and
/// Audio (NotchPanes.swift, NotchDropZone.swift). They change by their dots at the top right or a sideways
/// two-finger swipe; the last one shown comes back. Usage is the first default.
final class AgentNotchDashboardView: NSView {
    enum Page: String, CaseIterable {
        // Keep the existing Usage preference key for the combined AI page.
        case usage, music, calendar, clipboard, tray, audio
        var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var title: String {
            switch self {
            case .usage: return "AI"
            case .music: return "Music"
            case .calendar: return "Calendar"
            case .clipboard: return "Clipboard"
            case .tray: return "Tray"
            case .audio: return "Audio"
            }
        }
        var detail: String {
            switch self {
            case .usage: return "Usage limits and live tasks, grouped by AI. Click a task to open its session, or elsewhere to open TokenBar."
            case .music: return "Album artwork, track information and playback controls."
            case .calendar: return "Upcoming events and unfinished reminders. Click a reminder’s circle to complete it."
            case .clipboard: return "Recent copies as cards. Click one to copy it again."
            case .tray: return "Files kept in the notch tray to drag out later."
            case .audio: return "Choose input and output devices and adjust their levels."
            }
        }
        /// TokenBar's own pages: a click on them opens its popover.
        var isTokenBar: Bool { self == .usage }
    }
    static let pageDefaultsKey = "notchDashboardPage"
    static let disabledPanesKey = "notchDisabledPanes"
    private let defaults: UserDefaults
    private(set) var page: Page
    private(set) var availablePages = Page.allCases
    var onPageChanged: (() -> Void)?
    var onOpenSession: ((AgentSessionLink) -> Void)?
    /// The page on show changed size by itself (a new copy, a device switched).
    var onContentChanged: (() -> Void)?
    private var activityRows: [AgentLockScreen.Row] = []
    private var expandedHistories: Set<AIProvider> = []
    private var temporaryHUD: NSView?
    private var temporaryHUDSize: CGSize?
    var isPresentingHUD: Bool { temporaryHUD != nil }
    private let usage = NSHostingView(rootView: NotchUsageView(snapshot: nil, stale: false, width: 680))
    private let scroll = NSScrollView()
    private let calendar = NSHostingView(rootView: NotchCalendarView(days: [], access: .unknown, width: 680))
    private let calendarScroll = NSScrollView()
    private let clipboard = NotchClipboardPane()
    private let music = NotchMusicPane()
    private let tray = NotchTrayPane()
    private let audio = NotchAudioPane()
    private let dots = NotchPageDots(count: Page.allCases.count)
    private let paneName = NSTextField(labelWithString: "")
    /// Changes reported while the card is open take the dots' place for a moment.
    private let wing = NotchWingIndicator()
    private var wingWork: DispatchWorkItem?
    private var wingShowing = false
    private(set) var selectionProgress: CGFloat = 0
    private var selectionTimer: Timer?
    private var selectionClock: TilingDisplayClock?
    private(set) var pageTransitionStart: CFTimeInterval = 0
    private(set) var isPageTransitioning = false
    private var notchWidth: CGFloat = 0
    private var notchHeight: CGFloat = 0
    private var maximumHeight: CGFloat = 900
    private var usageHeight: CGFloat = 0
    private var calendarHeight: CGFloat = 0
    private var swipeTravel: CGFloat = 0
    private var swipeTurned = false
    /// Sideways travel that turns the page, in points.
    private static let swipeDistance: CGFloat = 40
    private var headerHeight: CGFloat { max(46, notchHeight + 14) }
    private var cardWidth: CGFloat { max(680, notchWidth + 440) }
    override var isFlipped: Bool { true }

    private var panes: [(page: Page, view: NSView)] {
        [(.usage, scroll), (.music, music), (.calendar, calendarScroll), (.clipboard, clipboard), (.tray, tray),
         (.audio, audio)]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        page = defaults.string(forKey: Self.pageDefaultsKey).flatMap(Page.init(rawValue:)) ?? .usage
        if defaults.string(forKey: Self.pageDefaultsKey) == "sessions" {
            defaults.set(Page.usage.rawValue, forKey: Self.pageDefaultsKey)
        }
        super.init(frame: .zero)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        usage.appearance = NSAppearance(named: .darkAqua)
        calendar.appearance = NSAppearance(named: .darkAqua)
        calendarScroll.drawsBackground = false
        calendarScroll.scrollerStyle = .overlay
        calendarScroll.horizontalScrollElasticity = .none
        calendarScroll.autohidesScrollers = true
        calendarScroll.documentView = calendar
        for (_, pane) in panes {
            pane.wantsLayer = true
            addSubview(pane)
        }
        addSubview(dots)
        wing.isHidden = true
        addSubview(wing)
        paneName.font = .systemFont(ofSize: 16, weight: .semibold)
        paneName.textColor = NSColor(white: 1, alpha: 0.9)
        paneName.lineBreakMode = .byTruncatingTail
        addSubview(paneName)
        clipboard.onContentChanged = { [weak self] in self?.contentChanged(on: .clipboard) }
        tray.onContentChanged = { [weak self] in self?.contentChanged(on: .tray) }
        audio.onContentChanged = { [weak self] in self?.contentChanged(on: .audio) }
        NotchCalendar.shared.addObserver { [weak self] in
            self?.refreshCalendar()
            self?.contentChanged(on: .calendar)
        }
        prepareForPresentation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureNotch(width: CGFloat, height: CGFloat, maximumHeight: CGFloat) {
        notchWidth = width
        notchHeight = height
        self.maximumHeight = maximumHeight
        refreshUsage()
    }

    func prepareForPresentation() {
        resetWing()
        stopSelectionClock()
        isPageTransitioning = false
        let disabled = Set(defaults.stringArray(forKey: Self.disabledPanesKey) ?? [])
        availablePages = Page.allCases.filter { !disabled.contains($0.rawValue) }
        dots.count = availablePages.count
        if !availablePages.contains(page) {
            page = availablePages.first ?? .usage
            defaults.set(page.rawValue, forKey: Self.pageDefaultsKey)
        }
        paneName.stringValue = page.title
        selectionProgress = CGFloat(availablePages.firstIndex(of: page) ?? 0)
        dots.progress = selectionProgress
        refresh(page)
        settlePanes()
        music.setPresented(!isPresentingHUD && page == .music && window?.isVisible == true)
    }

    func didPresent() { music.setPresented(!isPresentingHUD && page == .music) }

    /// Fresh contents for a page about to show. Calendar asks for access the
    /// first time it's opened.
    private func refresh(_ page: Page) {
        switch page {
        case .calendar:
            NotchCalendar.shared.requestAccessIfNeeded()
            NotchCalendar.shared.requestRemindersAccessIfNeeded()
            refreshCalendar()
        case .clipboard: clipboard.reload()
        case .tray: tray.reload()
        case .audio: audio.reload()
        case .music: music.reload()
        case .usage: refreshUsage()
        }
    }

    private func contentChanged(on pane: Page) {
        guard pane == page, window?.isVisible == true else { return }
        needsLayout = true
        pageTransitionStart = CACurrentMediaTime()
        onContentChanged?()
    }

    func update(rows: [AgentLockScreen.Row], state: AgentActivityCardView.State) {
        activityRows = rows
        refreshUsage()
        // The controller animates the attached window's frame. Don't jump the
        // contents to the final height before that animation starts.
        if window == nil { setFrameSize(fittingCardSize) }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func refreshUsage() {
        usage.rootView = NotchUsageView(snapshot: AIUsageFeed.shared.snapshot,
                                       stale: AIUsageFeed.shared.isStale,
                                       tokenBarRunning: AIUsageFeed.shared.isTokenBarRunning,
                                       width: cardWidth,
                                       rows: activityRows, expandedHistories: expandedHistories,
                                       onToggleHistory: { [weak self] in self?.toggleHistory($0) },
                                       onOpenSession: { [weak self] in self?.onOpenSession?($0) })
        usageHeight = ceil(usage.fittingSize.height)
    }

    private func refreshCalendar() {
        NotchCalendar.shared.refreshReminders()
        calendar.rootView = NotchCalendarView(days: NotchCalendar.shared.days(), access: NotchCalendar.shared.access,
                                              width: cardWidth, reminders: NotchCalendar.shared.reminders,
                                              remindersAccess: NotchCalendar.shared.remindersAccess,
                                              remindersLoading: NotchCalendar.shared.isLoadingReminders,
                                              remindersError: NotchCalendar.shared.remindersError,
                                              onCompleteReminder: { NotchCalendar.shared.completeReminder($0) })
        calendarHeight = ceil(calendar.fittingSize.height)
    }

    private func bodyHeight(_ page: Page) -> CGFloat {
        switch page {
        case .usage: return usageHeight
        case .music: return music.fittingHeight(width: cardWidth)
        case .calendar: return calendarHeight
        case .clipboard: return clipboard.fittingHeight(width: cardWidth)
        case .tray: return tray.fittingHeight(width: cardWidth)
        case .audio: return audio.fittingHeight(width: cardWidth)
        }
    }

    var fittingCardSize: CGSize {
        if let temporaryHUDSize { return temporaryHUDSize }
        return CGSize(width: cardWidth, height: min(maximumHeight, headerHeight + bodyHeight(page)))
    }

    /// Temporarily borrow the card without changing the selected page or its scroll position.
    /// Shows `event` where the dots are, swapping back after `hold`. Another
    /// change meanwhile updates it in place and starts the hold again.
    func showWing(_ event: NotchWingEvent, hold: TimeInterval) {
        wing.show(event)
        if !wingShowing {
            wingShowing = true
            swap(out: dots, in: wing)
        }
        wingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wingShowing else { return }
            self.wingShowing = false
            self.swap(out: self.wing, in: self.dots)
        }
        wingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// The finished task on the wing under `point` (a notice's), to open.
    func wingLink(at point: CGPoint) -> AgentSessionLink? {
        guard wingShowing, let link = wing.event?.link,
              wing.drawnFrame.insetBy(dx: -8, dy: -8).contains(point) else { return nil }
        return link
    }

    /// Closed or reopened: the dots, with no change left showing.
    private func resetWing() {
        wingWork?.cancel()
        wingWork = nil
        wingShowing = false
        wing.isHidden = true
        wing.alphaValue = 1
        dots.isHidden = false
        dots.alphaValue = 1
        dots.layer?.removeAllAnimations()
        wing.layer?.removeAllAnimations()
    }

    /// One rolls up and out as the other rolls up into its place.
    private func swap(out old: NSView, in new: NSView) {
        new.isHidden = false
        for (view, show) in [(old, false), (new, true)] {
            guard let layer = view.layer else { continue }
            let fromOpacity = layer.presentation()?.opacity ?? Float(view.alphaValue)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.alphaValue = show ? 1 : 0
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = show ? 0 : fromOpacity
            opacity.toValue = show ? 1 : 0
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = show ? 6 : 0
            rise.toValue = show ? 0 : -6
            let group = CAAnimationGroup()
            group.animations = [opacity, rise]
            group.duration = 0.28
            group.timingFunction = NotchTransition.timingFunction
            layer.add(group, forKey: "wingSwap")
        }
    }

    /// On the Audio page a volume change moves the page's own output bar
    /// instead of bringing up the HUD. False on any other page.
    func showVolumeInAudioPane() -> Bool {
        guard page == .audio, !isPresentingHUD, !isPageTransitioning else { return false }
        audio.refreshOutputLevel()
        return true
    }

    func presentHUD(_ view: NSView, size: CGSize) {
        pageTransitionStart = CACurrentMediaTime()
        if temporaryHUD !== view || view.superview !== self {
            transitionContents()
            stopPageTransition()
            temporaryHUD?.removeFromSuperview()
            // A standalone host fades this view to zero on close. Borrow it
            // without carrying that host's opacity/position animations along.
            view.layer?.removeAllAnimations()
            temporaryHUD = view
            addSubview(view)
        }
        view.isHidden = false
        view.alphaValue = 1
        temporaryHUDSize = size
        panes.forEach { $0.view.isHidden = true }
        dots.isHidden = true
        paneName.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func transitionContents() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        layer.add(fade, forKey: "temporaryContent")
    }

    func dismissHUD() {
        pageTransitionStart = CACurrentMediaTime()
        transitionContents()
        temporaryHUD?.removeFromSuperview()
        temporaryHUD = nil
        temporaryHUDSize = nil
        dots.isHidden = false
        paneName.isHidden = false
        settlePanes()
        needsLayout = true
    }

    func refreshClock() {
        refreshUsage()
        if page == .calendar { refreshCalendar() }
        needsLayout = true
    }

    /// A task row's current destination, in document coordinates even after scrolling.
    func sessionLink(at point: CGPoint) -> AgentSessionLink? {
        guard page == .usage, !isPresentingHUD, !isPageTransitioning,
              scroll.contentView.bounds.contains(scroll.contentView.convert(point, from: self)) else { return nil }
        let local = usage.convert(point, from: self)
        guard let hit = NotchSessionMode.hitFrames.first(where: { $0.frame.contains(local) }),
              let session = NotchAIContent.sessions(for: hit.provider, rows: activityRows)
                .first(where: { $0.id == hit.sessionID }) else { return nil }
        return NotchAIContent.link(session, provider: hit.provider)
    }

    /// Handle dot clicks before the controller's click-to-open-popover action.
    @discardableResult
    func selectTab(at point: CGPoint) -> Bool {
        guard !isPresentingHUD else { return false }
        if page == .usage, !isPageTransitioning {
            if toggleUsageControl(at: point) { return true }
        }
        guard let index = dots.index(at: convert(point, to: dots)) else { return false }
        guard availablePages.indices.contains(index) else { return false }
        selectPage(availablePages[index])
        return true
    }

    /// A sideways two-finger swipe turns the page, once per gesture; true when
    /// the event was taken for that. Vertical scrolling stays the page's own,
    /// and a mouse wheel never turns pages.
    func swipe(_ event: NSEvent) -> Bool {
        guard !isPresentingHUD else { return false }
        guard event.hasPreciseScrollingDeltas else { return false }
        if event.phase == .began || event.phase == .mayBegin {
            swipeTravel = 0
            swipeTurned = false
        }
        // The glide after lifting the fingers belongs to whatever the gesture did.
        if !event.momentumPhase.isEmpty { return swipeTurned }
        guard swipeTravel != 0 || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }
        swipeTravel += event.scrollingDeltaX
        if !swipeTurned, abs(swipeTravel) >= Self.swipeDistance {
            swipeTurned = true
            // Content follows the fingers: moving it left brings the next page.
            let next = (availablePages.firstIndex(of: page) ?? 0) + (swipeTravel < 0 ? 1 : -1)
            if availablePages.indices.contains(next) { selectPage(availablePages[next]) }
        }
        return true
    }

    private func toggleUsageControl(at point: CGPoint) -> Bool {
        let local = usage.convert(point, from: self)
        // Offscreen document controls must not catch clicks outside the viewport.
        guard scroll.bounds.contains(scroll.convert(point, from: self)) else { return false }
        if let button = NotchUsageButton.hitFrames.first(where: { $0.value.insetBy(dx: -6, dy: -6).contains(local) })?.key {
            button.perform()
            return true
        }
        if let provider = NotchHistoryMode.hitFrames.first(where: { $0.value.contains(local) })?.key {
            toggleHistory(provider)
            return true
        }
        guard NotchResetMode.hitFrames.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(local) }) else { return false }
        let store = UserDefaults.standard // what the view's @AppStorage reads
        store.set(!store.bool(forKey: NotchResetMode.defaultsKey), forKey: NotchResetMode.defaultsKey)
        refreshUsage()
        needsLayout = true
        return true
    }

    private func toggleHistory(_ provider: AIProvider) {
        if !expandedHistories.insert(provider).inserted { expandedHistories.remove(provider) }
        refreshUsage()
        needsLayout = true
        onContentChanged?()
    }

    private func selectPage(_ selected: Page) {
        guard availablePages.contains(selected), page != selected else { return }
        let previous = page
        page = selected
        paneName.stringValue = page.title
        music.setPresented(page == .music && window?.isVisible == true)
        defaults.set(selected.rawValue, forKey: Self.pageDefaultsKey)
        refresh(selected)
        pageTransitionStart = CACurrentMediaTime()
        animateSelection(forward: (availablePages.firstIndex(of: selected) ?? 0)
                         > (availablePages.firstIndex(of: previous) ?? 0))
        needsLayout = true
        onPageChanged?()
    }

    private func animateSelection(forward: Bool) {
        stopSelectionClock()
        let target = CGFloat(availablePages.firstIndex(of: page) ?? 0)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isPageTransitioning = false
            selectionProgress = target
            dots.progress = target
            settlePanes()
            return
        }
        isPageTransitioning = true
        animatePanes(forward: forward)
        let from = selectionProgress
        let start = pageTransitionStart
        let tick: () -> Void = { [weak self] in
            guard let self else { return }
            let progress = CGFloat((CACurrentMediaTime() - start) / NotchTransition.duration)
            self.selectionProgress = from + (target - from) * NotchTransition.eased(progress)
            self.dots.progress = self.selectionProgress
            if progress >= 1 {
                self.stopSelectionClock()
                self.isPageTransitioning = false
                self.settlePanes()
            }
        }
        if let screen = window?.screen {
            selectionClock = TilingDisplayClock(screen: screen, update: tick)
        } else {
            // Offscreen view tests don't have a display link.
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { _ in tick() }
            selectionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopSelectionClock() {
        selectionClock?.invalidate()
        selectionClock = nil
        selectionTimer?.invalidate()
        selectionTimer = nil
    }

    /// The new page slides in from the side it lies on; whatever was showing
    /// slides the other way and fades. Interrupted, each starts from where it is.
    private func animatePanes(forward: Bool) {
        let shift: CGFloat = forward ? 10 : -10
        for (pane, view) in panes {
            guard let layer = view.layer else { continue }
            let selected = pane == page
            guard selected || !view.isHidden else { continue }
            // A page that wasn't showing comes in from the side, from nothing.
            let wasHidden = view.isHidden
            let fromOpacity = wasHidden ? 0 : layer.presentation()?.opacity ?? Float(view.alphaValue)
            let fromX = wasHidden ? shift : layer.presentation()?.transform.m41 ?? layer.transform.m41
            let toX = selected ? 0 : -shift
            view.isHidden = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.alphaValue = selected ? 1 : 0
            layer.transform = CATransform3DMakeTranslation(toX, 0, 0)
            CATransaction.commit()
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = fromOpacity
            opacity.toValue = selected ? 1 : 0
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = fromX
            slide.toValue = toX
            let group = CAAnimationGroup()
            group.animations = [opacity, slide]
            group.beginTime = pageTransitionStart
            group.duration = NotchTransition.duration
            group.timingFunction = NotchTransition.timingFunction
            layer.add(group, forKey: "paneTransition")
        }
    }

    private func settlePanes() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (pane, view) in panes {
            let selected = !isPresentingHUD && pane == page
            view.layer?.removeAnimation(forKey: "paneTransition")
            view.alphaValue = selected ? 1 : 0
            view.layer?.transform = CATransform3DIdentity
            view.isHidden = !selected
        }
        CATransaction.commit()
    }

    func stopPageTransition() {
        stopSelectionClock()
        isPageTransitioning = false
        selectionProgress = CGFloat(availablePages.firstIndex(of: page) ?? 0)
        dots.progress = selectionProgress
        settlePanes()
        music.setPresented(false)
    }

    override func layout() {
        super.layout()
        if let temporaryHUD, let size = temporaryHUDSize {
            temporaryHUD.frame = CGRect(x: (bounds.width - size.width) / 2, y: 0,
                                        width: size.width, height: size.height)
            temporaryHUD.layoutSubtreeIfNeeded()
            return
        }
        // Match the 24-point top and side insets, centring the indicator with the title.
        let dotsCenter: CGFloat = 24 + 11
        dots.frame = CGRect(x: max(24, bounds.width - 24 - dots.naturalWidth),
                            y: dotsCenter - 6, width: dots.naturalWidth, height: 12)
        // The wing takes the dots' row, right-aligned with them.
        wing.frame = CGRect(x: bounds.width - 24 - 300, y: dotsCenter - 9, width: 300, height: 18)
        // Match the page's inset, leaving a 24-point gap before the indicator.
        paneName.frame = CGRect(x: 24, y: dotsCenter - 11,
                                width: max(0, dots.frame.minX - 48), height: 22)
        if !isPageTransitioning { settlePanes() }
        // Each pane retains its own final viewport. The outer mask reveals it;
        // text, scrollbars and footers never reflow during a size transition.
        let maxBodyHeight = max(0, maximumHeight - headerHeight)
        let usageBodyHeight = min(maxBodyHeight, usageHeight)
        scroll.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: usageBodyHeight)
        if scroll.documentView !== usage { scroll.documentView = usage }
        usage.frame = CGRect(x: 0, y: 0, width: bounds.width, height: usageHeight)
        scroll.hasVerticalScroller = usageHeight > usageBodyHeight
        calendarScroll.frame = CGRect(x: 0, y: headerHeight, width: bounds.width, height: min(maxBodyHeight, calendarHeight))
        calendar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: calendarHeight)
        calendarScroll.hasVerticalScroller = calendarHeight > calendarScroll.bounds.height
        for (pane, view) in [(Page.clipboard, clipboard as NSView), (.music, music), (.tray, tray), (.audio, audio)] {
            view.frame = CGRect(x: 0, y: headerHeight, width: bounds.width,
                                height: min(maxBodyHeight, bodyHeight(pane)))
        }
    }
}

/// Session reset times flip between "in 32 min" and the clock time on click.
/// Week already reads as a clock, so only Session labels take part.
enum NotchResetMode {
    static let defaultsKey = "notchSessionResetExact"
    static let space = "notchUsage"
    /// Frames of the clickable Session labels, in the usage view's space. The
    /// controller's global click handler can't see SwiftUI gestures, so the
    /// card hit-tests these itself.
    static var hitFrames: [CGRect] = []

    struct FramesKey: PreferenceKey {
        static var defaultValue: [CGRect] { [] }
        static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
    }
}

/// The usage page's buttons — Claude's "Sign In", "Open TokenBar" — in the same
/// scrolling document coordinates.
enum NotchUsageButton: Hashable {
    case claudeSignIn, openTokenBar

    static var hitFrames: [NotchUsageButton: CGRect] = [:]

    struct FramesKey: PreferenceKey {
        static var defaultValue: [NotchUsageButton: CGRect] { [:] }
        static func reduce(value: inout [NotchUsageButton: CGRect], nextValue: () -> [NotchUsageButton: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    func perform() {
        switch self {
        case .claudeSignIn: AIUsageFeed.requestClaudeSignIn()
        case .openTokenBar: AIUsageFeed.openTokenBar()
        }
    }
}

/// Hit frames share the document's coordinate space, including when it scrolls.
enum NotchHistoryMode {
    static var hitFrames: [AIProvider: CGRect] = [:]

    struct FramesKey: PreferenceKey {
        static var defaultValue: [AIProvider: CGRect] { [:] }
        static func reduce(value: inout [AIProvider: CGRect], nextValue: () -> [AIProvider: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }
}

/// Task hit areas use the same scrolling document coordinates as quota/history controls.
enum NotchSessionMode {
    struct Hit: Equatable {
        let provider: AIProvider
        let sessionID: String?
        let frame: CGRect
    }
    static var hitFrames: [Hit] = []
    struct FramesKey: PreferenceKey {
        static var defaultValue: [Hit] { [] }
        static func reduce(value: inout [Hit], nextValue: () -> [Hit]) { value += nextValue() }
    }
}

enum NotchAIContent {
    static func providers(snapshot: TokenBarSnapshot, rows: [AgentLockScreen.Row]) -> [AIProvider] {
        [AIProvider.claude, .codex, .deepseek, .antigravity].filter { provider in
            guard snapshot.isEnabled(provider) else { return false }
            if rows.contains(where: { $0.provider == provider }) { return true }
            switch provider {
            case .claude: return snapshot.claude != nil
            case .codex: return snapshot.codex != nil
            case .deepseek: return snapshot.deepseek != nil
            case .antigravity: return snapshot.antigravity?.available == true
            }
        }
    }

    static func sessions(for provider: AIProvider, rows: [AgentLockScreen.Row]) -> [TokenBarSnapshot.WorkingSession] {
        rows.filter { $0.provider == provider }.flatMap { row in
            row.sessions.isEmpty ? [.init(title: row.title)] : row.sessions
        }
    }

    static func title(_ session: TokenBarSnapshot.WorkingSession, index: Int) -> String {
        if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return session.id.map { "Session " + String($0.prefix(8)) } ?? "Session \(index + 1)"
    }

    static func detail(_ session: TokenBarSnapshot.WorkingSession) -> String {
        var text = session.activity ?? "Processing…"
        if let done = session.completedSteps, let total = session.totalSteps,
           total > 0, done >= 0, done <= total { text += " · \(done)/\(total) steps" }
        return text
    }

    static func link(_ session: TokenBarSnapshot.WorkingSession, provider: AIProvider) -> AgentSessionLink {
        let id = session.id.flatMap { $0.hasPrefix("unknown-") ? nil : $0 }
        return AgentSessionLink(provider: provider, session: id, destination: session.destination)
    }

    static func elapsed(since: Double?, now: Date = Date()) -> String {
        guard let since, since.isFinite else { return "" }
        let seconds = Int(min(315_360_000, max(0, now.timeIntervalSince1970 - since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// The AI page keeps each provider's limits, live tasks and history together.
struct NotchUsageView: View {
    let snapshot: TokenBarSnapshot?
    let stale: Bool
    var tokenBarRunning = true
    let width: CGFloat
    var rows: [AgentLockScreen.Row] = []
    var expandedHistories: Set<AIProvider> = []
    var onToggleHistory: ((AIProvider) -> Void)? = nil
    var onOpenSession: ((AgentSessionLink) -> Void)? = nil
    @AppStorage(NotchResetMode.defaultsKey) private var exactSessionReset = false
    @State private var hoveredDays: [AIProvider: String] = [:]
    @State private var hoveredSession: String?
    private var columnWidth: CGFloat { (width - 48 - 24) / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !tokenBarRunning {
                notRunning
            } else if let snapshot {
                if stale {
                    Text("Usage may be out of date").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                let providers = NotchAIContent.providers(snapshot: snapshot, rows: rows)
                ForEach(Array(stride(from: 0, to: providers.count, by: 2)), id: \.self) { start in
                    if start > 0 { divider }
                    let pair = Array(providers.dropFirst(start).prefix(2))
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(pair, id: \.rawValue) { provider in
                            providerColumn(provider, snapshot: snapshot)
                                .frame(width: pair.count == 1 ? width - 48 : columnWidth, alignment: .leading)
                        }
                    }
                    .overlay { if pair.count == 2 { verticalDivider } }
                }
                if providers.isEmpty {
                    Text("Enable a provider in TokenBar to see usage")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            } else {
                Text("Waiting for TokenBar usage").font(.system(size: 14, weight: .semibold))
                Text("Open TokenBar to load your limits and history")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .opacity(stale && tokenBarRunning ? 0.65 : 1)
        .coordinateSpace(name: NotchResetMode.space)
        .onPreferenceChange(NotchResetMode.FramesKey.self) { NotchResetMode.hitFrames = $0 }
        .onPreferenceChange(NotchHistoryMode.FramesKey.self) { NotchHistoryMode.hitFrames = $0 }
        .onPreferenceChange(NotchUsageButton.FramesKey.self) { NotchUsageButton.hitFrames = $0 }
        .onPreferenceChange(NotchSessionMode.FramesKey.self) { NotchSessionMode.hitFrames = $0 }
        .onDisappear { NotchSessionMode.hitFrames = [] }
    }

    @ViewBuilder
    private func providerColumn(_ provider: AIProvider, snapshot: TokenBarSnapshot) -> some View {
        switch provider {
        case .claude, .codex: limitProvider(provider, snapshot: snapshot)
        case .deepseek: deepseek(snapshot)
        case .antigravity: antigravity(snapshot)
        }
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5) }
    private var verticalDivider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5)
    }

    private func tint(_ provider: AIProvider) -> Color {
        switch provider {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(white: 0.9)
        case .deepseek: return Color(red: 0.30, green: 0.40, blue: 1)
        case .antigravity: return Color(red: 0.30, green: 0.75, blue: 0.40)
        }
    }

    private func providerTitle(_ provider: AIProvider) -> some View {
        let sessions = NotchAIContent.sessions(for: provider, rows: rows)
        let count = max(sessions.count, rows.first(where: { $0.provider == provider })?.count ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let icon = AgentActivityCardView.icon(for: provider) {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28)
                }
                Text(provider == .codex ? "ChatGPT" : AgentActivityCardView.name(for: provider))
                    .font(.system(size: 16, weight: .bold))
            }
            if count > 0 {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(count) working").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func tasks(_ provider: AIProvider) -> some View {
        let sessions = NotchAIContent.sessions(for: provider, rows: rows)
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                    let link = NotchAIContent.link(session, provider: provider)
                    let hoverID = "\(provider.rawValue):\(session.id ?? "#\(index)")"
                    Button { onOpenSession?(link) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(NotchAIContent.title(session, index: index))
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                Text(NotchAIContent.elapsed(since: session.since))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary).fixedSize()
                            }
                            Text(NotchAIContent.detail(session)).font(.system(size: 11.5))
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(hoveredSession == hoverID ? 0.08 : 0)))
                        .padding(-5)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        hoveredSession = inside ? hoverID : (hoveredSession == hoverID ? nil : hoveredSession)
                    }
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NotchSessionMode.FramesKey.self,
                            value: [.init(provider: provider, sessionID: session.id,
                                          frame: geometry.frame(in: .named(NotchResetMode.space)))])
                    })
                    .help([session.prompt ?? session.title, link.helpText].compactMap { $0 }.joined(separator: "\n"))
                }
            }
        }
    }

    private func limitProvider(_ provider: AIProvider, snapshot: TokenBarSnapshot) -> some View {
        let limits = provider == .claude ? snapshot.claude : snapshot.codex
        return VStack(alignment: .leading, spacing: 20) {
            providerTitle(provider)
            if limits?.signInRequired == true {
                signInRow(color: tint(provider))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    quota("Session", used: limits?.available == true ? limits?.sessionPercent : nil,
                          reset: limits?.sessionResetAt, color: tint(provider), weekly: false)
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: 48)
                    quota("Week", used: limits?.available == true ? limits?.weekPercent : nil,
                          reset: limits?.weekResetAt, color: tint(provider), weekly: true)
                }
            }
            tasks(provider)
            graph(snapshot.usage?.days(for: provider), provider: provider, color: tint(provider), currency: nil)
        }
    }

    // TokenBar couldn't renew the Claude login by itself. Same height as the
    // quotas it stands in for, so the column doesn't jump when it clears.
    private func signInRow(color: Color) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Login expired").font(.system(size: 11.5, weight: .semibold))
                Text("Limits return after you sign in")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            usageButton("Sign In", .claudeSignIn, color: color)
        }
        .frame(minHeight: 48)
    }

    // A capsule the card hit-tests itself (see NotchUsageButton).
    private func usageButton(_ title: String, _ button: NotchUsageButton, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(color))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: NotchUsageButton.FramesKey.self,
                                           value: [button: proxy.frame(in: .named(NotchResetMode.space))])
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { button.perform() }
    }

    // TokenBar quit or never started (e.g. after a restart): the snapshot on disk
    // is a leftover, so say so rather than show its numbers as if they were live.
    private var notRunning: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TokenBar isn't running").font(.system(size: 14, weight: .semibold))
                Text("Limits and usage update only while it's open")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            usageButton("Open TokenBar", .openTokenBar, color: .white.opacity(0.18))
        }
    }

    private func quota(_ title: String, used: Double?, reset: Double?, color: Color, weekly: Bool) -> some View {
        // Once the reset time has passed, the last poll's percentage belongs to the
        // old window: the new one is untouched until its first request, and the
        // next poll will say so too.
        let resetPassed = reset.map { $0 <= Date().timeIntervalSince1970 } ?? false
        let remaining = resetPassed && used != nil
            ? 100 : used.flatMap { $0.isFinite ? 100 - min(100, max(0, $0)) : nil }
        // A known percentage with no reset time: the window hasn't begun — its clock
        // starts with the first request. The full bar already says "100% left".
        let notStarted = remaining != nil && (reset == nil || resetPassed)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    if let remaining, remaining > 0 {
                        Capsule().fill(color).frame(width: max(3, geometry.size.width * remaining / 100))
                    }
                }
            }.frame(height: 3)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notStarted ? "Not started" : remaining.map { "\(Int($0.rounded()))% left" } ?? "—")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .fixedSize()
                Spacer(minLength: 0)
                Text(notStarted ? "" : NotchUsageText.reset(reset, weekly: weekly, exact: exactSessionReset))
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .background {
                        if !weekly {
                            GeometryReader { proxy in
                                Color.clear.preference(key: NotchResetMode.FramesKey.self,
                                                       value: [proxy.frame(in: .named(NotchResetMode.space))])
                            }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func graph(_ days: [TokenBarSnapshot.Usage.Day]?, provider: AIProvider, color: Color, currency: String?) -> some View {
        let hoveredDay = expandedHistories.contains(provider)
            ? days?.first(where: { $0.id == hoveredDays[provider] }) : nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: expandedHistories.contains(provider) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text("7-Day Usage").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(hoveredDay.map { NotchUsageText.amount($0.value, currency: currency) }
                     ?? days.map { NotchUsageText.amount($0.reduce(0) { $0 + $1.value }, currency: currency) } ?? "—")
                    .font(.system(size: 11.5, weight: hoveredDay == nil ? .medium : .bold, design: .monospaced))
                    .foregroundStyle(hoveredDay == nil ? Color.white : color)
            }
            .frame(minHeight: 24)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: NotchHistoryMode.FramesKey.self,
                                           value: [provider: proxy.frame(in: .named(NotchResetMode.space))])
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(expandedHistories.contains(provider) ? "Hide 7-day usage" : "Show 7-day usage")
            .accessibilityAction { onToggleHistory?(provider) }
            if expandedHistories.contains(provider) {
                if let days {
                    let peak = max(1e-9, days.map(\.value).max() ?? 0) * 1.15
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(days) { day in
                            let isHovered = hoveredDay?.id == day.id
                            VStack(spacing: 6) {
                                ZStack(alignment: .bottom) {
                                    Color.clear
                                    if day.value > 0 {
                                        NotchUsageBarShape()
                                            .fill(color).frame(width: 12, height: max(2, CGFloat(day.value / peak) * 44))
                                    } else {
                                        Capsule().fill(.white.opacity(0.12)).frame(width: 12, height: 1)
                                    }
                                }
                                .scaleEffect(isHovered ? 1.08 : 1, anchor: .bottom)
                                .shadow(color: isHovered ? color.opacity(0.3) : .clear, radius: 3, y: -1)
                                .frame(height: 44)
                                Text(day.label)
                                    .font(.system(size: 9.5, weight: isHovered ? .bold : .medium))
                                    .foregroundStyle(isHovered ? color : Color.secondary)
                            }.frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if inside { hoveredDays[provider] = day.id }
                                        else if hoveredDays[provider] == day.id { hoveredDays[provider] = nil }
                                    }
                                }
                                .help("\(day.id): \(NotchUsageText.amount(day.value, currency: currency))")
                        }
                    }
                    .onDisappear { hoveredDays[provider] = nil }
                } else {
                    Text("Usage history unavailable").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(height: 61, alignment: .center)
                }
            }
        }
    }

    /// Laid out like a Claude/ChatGPT column: title, a two-cell row, then the graph.
    private func deepseek(_ snapshot: TokenBarSnapshot) -> some View {
        let currency = snapshot.usage?.deepseekCurrency ?? snapshot.deepseek?.currency ?? "USD"
        let balance = currency == "THB" ? snapshot.deepseek?.balanceTHB : snapshot.deepseek?.balance
        return VStack(alignment: .leading, spacing: 20) {
            providerTitle(.deepseek)
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Balance left").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(balance.flatMap { $0.isFinite ? NotchUsageText.amount($0, currency: currency) : nil } ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: 48)
                billing(snapshot).frame(maxWidth: .infinity, alignment: .leading)
            }
            tasks(.deepseek)
            graph(snapshot.usage?.days(for: .deepseek), provider: .deepseek, color: tint(.deepseek), currency: currency)
        }
    }

    private func billing(_ snapshot: TokenBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let transition = snapshot.usage?.billingTransitionAt, transition > Date().timeIntervalSince1970,
               let period = snapshot.usage?.billingPeriod {
                HStack(spacing: 6) {
                    Circle().fill(period == "Off-Peak" ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(period).font(.system(size: 11.5, weight: .semibold))
                    if let discount = NotchUsageText.discount(snapshot.usage?.billingDetail) {
                        Text(discount).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
                // Its own line: a half column can't fit "until Fri 00:00" beside the period.
                Text("until " + NotchUsageText.clock(transition)).font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Billing status updating…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    /// One column like DeepSeek's. Only the Gemini group for now; the
    /// Claude/GPT group is left out (user's choice, 2026-10-01).
    private func antigravity(_ snapshot: TokenBarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                providerTitle(.antigravity)
                Spacer()
                if snapshot.antigravity?.available != true {
                    Text(snapshot.usage?.antigravityStatus ?? "Connecting…")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Gemini").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            if let ag = snapshot.antigravity, ag.available == true {
                HStack(alignment: .top, spacing: 12) {
                    // Older TokenBar builds send only the weekly window.
                    if ag.geminiSessionPercent != nil || ag.geminiSessionResetAt != nil {
                        quota("Session", used: ag.geminiSessionPercent, reset: ag.geminiSessionResetAt,
                              color: tint(.antigravity), weekly: false)
                        Rectangle().fill(.white.opacity(0.10)).frame(width: 0.5, height: 48)
                    }
                    quota("Week", used: ag.geminiPercent, reset: ag.geminiResetAt,
                          color: tint(.antigravity), weekly: true)
                }
            }
            tasks(.antigravity)
            graph(snapshot.usage?.days(for: .antigravity), provider: .antigravity, color: tint(.antigravity), currency: nil)
        }
    }
}

/// Round only the top corners; every bar sits on a flat baseline.
struct NotchUsageBarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(3, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum NotchUsageText {
    static func reset(_ epoch: Double?, weekly: Bool, exact: Bool = false, now: Date = Date()) -> String {
        guard let epoch, epoch.isFinite else { return "—" }
        if epoch <= now.timeIntervalSince1970 { return "ready" }
        if weekly { return clock(epoch, now: now, includeDay: true) }
        if exact { return clock(epoch, now: now) }
        let minutes = Int(min(525_600, ceil((epoch - now.timeIntervalSince1970) / 60)))
        return minutes < 60 ? "in \(minutes) min" : "in \(minutes / 60) hr \(minutes % 60) min"
    }
    /// "50% lower rates" → "−50%"; nil for anything else (Peak sends "Peak rates").
    static func discount(_ detail: String?) -> String? {
        guard let detail,
              let match = detail.range(of: #"\d+(\.\d+)?%(?=\s*lower)"#, options: .regularExpression) else { return nil }
        return "−" + detail[match]
    }
    static func clock(_ epoch: Double, now: Date = Date(), includeDay: Bool = false) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = includeDay || !Calendar.current.isDate(date, inSameDayAs: now) ? "E HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }
    static func amount(_ value: Double, currency: String?) -> String {
        if let currency {
            let symbol = currency == "THB" ? "฿" : currency == "CNY" ? "¥" : "$"
            return String(format: value > 0 && value < 0.01 ? "%@%.4f" : "%@%.2f", symbol, value)
        }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fk", value / 1_000) }
        return String(format: "%.0f", value)
    }
}
