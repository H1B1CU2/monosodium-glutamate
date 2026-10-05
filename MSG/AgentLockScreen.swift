import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import QuartzCore

// MARK: - AI activity on the lock screen
//
// While Claude, Codex or Antigravity is working and the Mac is locked, a card
// on the built-in display says who is working on what and for how long, and
// the display is kept awake to show it. When the run ends the card says it
// finished, and stays up — display held on — for as long as the user chose
// (`LockScreenStay`, default until unlocked). With nothing having run, the
// lock screen is left to macOS. macOS can't sleep one display on its own, so
// while the card holds the display on, every other display gets a black cover
// instead. Unlocking takes it all down.
//
// TokenBar decides what "working" means. Its snapshot's `processing` counts
// come from the same scan that drives its sleep assertion when enabled. A
// TokenBar build that predates them falls back to provider `active` flags, which lag
// by the usage-poll interval.

final class AgentLockScreen {
    static let shared = AgentLockScreen()

    private static let tokenBarBundleID = "com.tokenbar.app"
    private static let providers: [AIProvider] = [.claude, .codex, .antigravity]

    struct Row: Equatable {
        let provider: AIProvider
        let count: Int
        let title: String?
        var sessions: [TokenBarSnapshot.WorkingSession] = []
        var quotaRemaining: Double? = nil
    }

    private var started = false
    private var locked = false

    /// The card and the covers, each in a SkyLight space above the lock screen.
    private var card: (window: NSWindow, view: AgentActivityCardView, space: UInt64)?
    private var quotaCard: (window: NSWindow, view: LockScreenQuotaCardView, space: UInt64)?
    private var covers: [(window: NSWindow, space: UInt64)] = []
    private var displayAssertion: IOPMAssertionID?
    private var clockTimer: Timer?
    private var quotaTimer: Timer?

    /// When the run on screen began (TokenBar's `since`, else when MSG first saw
    /// it), when it ended, and what it was — kept so the finished card still
    /// says who did the work.
    private var runStartedAt: Date?
    private var finishedAt: Date?
    private var lastRows: [Row] = []
    /// When the Mac locked.
    private var lockedAt: Date?
    /// While a preview is up (unlocked), updates leave it alone.
    private var previewUntil: Date?

    private var isEnabled: Bool { AppSettings.shared.lockScreenAgentActivity }

    func start() {
        guard !started else { return }
        started = true
        locked = Self.screenIsLocked()
        if locked { lockedAt = Date() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.lockedAt = Date()
            self?.evaluate()
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.locked = false
            self.previewUntil = nil
            self.teardown(unlocking: true)
        }
        // Preview without locking: the card over the desktop for a few seconds,
        // e.g. `notifyutil`-style from a script or the terminal.
        dnc.addObserver(forName: Notification.Name("H1D3S1GN.MSG.previewAgentLockScreen"), object: nil, queue: .main) { [weak self] _ in
            self?.preview()
        }
        // TokenBar posts a snapshot the moment its processing state changes.
        AIUsageFeed.shared.addObserver { [weak self] _ in self?.evaluate() }
        AIUsageFeed.shared.start()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.tokenBarBundleID else { return }
                self?.evaluate()
            }
        }
        // Displays asleep: nothing to count down for. Awake: catch up at once.
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quotaTimer?.invalidate()
            self?.quotaTimer = nil
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.evaluate()
        }
        // Lid closed or a monitor plugged while locked: lay out again.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.card != nil || self.quotaCard != nil else { return }
            self.removeWindows()
            self.evaluate()
        }
        evaluate()
    }

    /// The setting flipped. Main thread.
    func settingChanged() { evaluate() }

    private func preview() {
        guard !locked else { return }
        previewUntil = Date().addingTimeInterval(6)
        let live = currentRows()
        let rows = live.isEmpty ? [Row(provider: .claude, count: 1, title: "Preview of the lock-screen card")] : live
        show(rows: rows, state: .working(since: Date().addingTimeInterval(-12 * 60)), covered: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, !self.locked else { return }
            self.previewUntil = nil
            self.teardown()
        }
    }

    // MARK: State

    private func evaluate() {
        guard isEnabled, locked else {
            if let previewUntil, previewUntil > Date() { return }
            teardown()
            return
        }
        ensureClockTimer()
        let now = Date()
        let rows = currentRows()
        if !rows.isEmpty {
            let since = AIUsageFeed.shared.snapshot?.processing?.since.map { Date(timeIntervalSince1970: $0) }
            if let since {
                runStartedAt = since
            } else if runStartedAt == nil || finishedAt != nil {
                runStartedAt = now   // a new run, first seen now
            }
            finishedAt = nil
            lastRows = rows
            let awake = canHoldDisplay()
            holdDisplayAwake(awake)
            show(rows: rows, state: .working(since: runStartedAt ?? now), covered: awake)
            return
        }

        // Nothing running. Only a run that ended during this lock earns the
        // screen anything: its "Finished" card, with the display held on for the
        // chosen time. With nothing having run, the lock screen is macOS's.
        let showFinished: Bool
        if lastRows.isEmpty {
            showFinished = false
        } else {
            if finishedAt == nil { finishedAt = now }
            let limit = AppSettings.shared.lockScreenAgentStay.idleLimit
            showFinished = limit.map { now.timeIntervalSince(finishedAt ?? now) < $0 } ?? true
        }
        let awake = showFinished && canHoldDisplay()
        holdDisplayAwake(awake)
        if showFinished {
            show(rows: lastRows, state: .finished(at: finishedAt ?? now), covered: awake)
            return
        }
        removeActivityCard()
        removeCovers()
        if SkyLightSpace.isAvailable, let screen = NSScreen.screens.first(where: \.isBuiltin) ?? NSScreen.main {
            syncQuotaCard(screen: screen, cardFrame: nil)
        } else {
            removeQuotaCard()
        }
    }

    /// Never hold the display on a Mac with no headroom: nearly flat on
    /// battery, or thermally critical. The same line TokenBar's own sleep
    /// protection draws.
    private func canHoldDisplay() -> Bool {
        if ProcessInfo.processInfo.thermalState == .critical { return false }
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String? == kIOPSBatteryPowerValue,
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return true }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Double(current) / Double(maximum) > 0.10
        }
        return true
    }

    private func currentRows() -> [Row] { Self.activityRows() }

    /// Who is working right now, per TokenBar. Nothing when TokenBar isn't
    /// running: a snapshot left behind by a quit or crashed TokenBar would
    /// otherwise keep the display on forever. Shared with the notch card.
    static func activityRows() -> [Row] {
        guard let snapshot = AIUsageFeed.shared.snapshot,
              !NSRunningApplication.runningApplications(withBundleIdentifier: Self.tokenBarBundleID).isEmpty
        else { return [] }
        if let processing = snapshot.processing {
            guard AIUsageFeed.shared.isProcessingFresh else { return [] }
            return Self.providers.compactMap { provider in
                let count = processing.count(provider)
                guard count > 0, snapshot.isEnabled(provider) else { return nil }
                // The thread's name as the app shows it, from the same scan as the
                // count; the thread list's title only as a fallback for older TokenBars.
                return Row(provider: provider, count: count,
                           title: processing.titles(provider).first ?? snapshot.activeTitle(provider),
                           sessions: snapshot.workingSessions(provider),
                           quotaRemaining: AIUsageFeed.shared.isStale ? nil : snapshot.sessionQuotaRemaining(provider))
            }
        }
        guard !AIUsageFeed.shared.isStale else { return [] }
        return Self.providers.compactMap { provider in
            guard snapshot.isActive(provider) else { return nil }
            return Row(provider: provider, count: 1, title: snapshot.activeTitle(provider),
                       sessions: snapshot.workingSessions(provider),
                       quotaRemaining: snapshot.sessionQuotaRemaining(provider))
        }
    }

    private static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Display sleep

    /// Only the idle timer is held off: an explicit "sleep displays" still wins.
    private func holdDisplayAwake(_ hold: Bool) {
        if hold {
            guard displayAssertion == nil else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "MSG: showing AI activity on the lock screen" as CFString, &id)
            if result == kIOReturnSuccess { displayAssertion = id }
        } else if let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }
    }

    // MARK: Windows

    private func show(rows: [Row], state: AgentActivityCardView.State, covered: Bool) {
        guard !rows.isEmpty, SkyLightSpace.isAvailable,
              let screen = NSScreen.screens.first(where: \.isBuiltin) ?? NSScreen.main
        else { return }

        func placement(_ view: AgentActivityCardView) -> CGRect {
            // Centred below the lock screen's clock, where iOS puts a Live Activity.
            let size = view.fittingCardSize
            let frame = screen.frame
            return CGRect(x: (frame.midX - size.width / 2).rounded(),
                          y: (frame.maxY - frame.height * 0.28 - size.height).rounded(),
                          width: size.width, height: size.height)
        }
        if let card {
            card.view.update(rows: rows, state: state)
            let target = placement(card.view)
            if card.window.frame != target {
                // A provider joining or leaving: grow or shrink into place.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    card.window.animator().setFrame(target, display: true)
                }
            }
        } else {
            let view = AgentActivityCardView()
            view.update(rows: rows, state: state)
            let window = Self.overlayWindow(frame: placement(view))
            window.contentView = view
            window.alphaValue = 0
            window.orderFrontRegardless()
            guard let space = SkyLightSpace.present(window) else {
                window.orderOut(nil)
                return
            }
            card = (window, view, space)
            Self.animateIn(window)
        }
        guard let card else { return }
        syncQuotaCard(screen: screen, cardFrame: placement(card.view))

        if covered {
            if covers.isEmpty { addCovers(except: screen) }
        } else {
            removeCovers()
        }
    }

    /// Time moves the clock, the stay-on limit and the battery: look again
    /// every half minute, including while the task card is hidden.
    private func ensureClockTimer() {
        if clockTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.evaluate()
            }
            timer.tolerance = 5
            clockTimer = timer
        }
    }

    /// The quota card sits below the task card while it runs, then occupies
    /// the main card position by itself. Multiple providers share the card.
    private func syncQuotaCard(screen: NSScreen, cardFrame: CGRect?) {
        let snapshot = AIUsageFeed.shared.snapshot
        let limits: [TokenBarSnapshot.ExhaustedPrimaryLimit]
        if locked, isEnabled, !AIUsageFeed.shared.isStale,
           !NSRunningApplication.runningApplications(withBundleIdentifier: Self.tokenBarBundleID).isEmpty,
           let snapshot {
            limits = snapshot.exhaustedPrimaryLimits()
        } else {
            limits = []
        }

        guard !limits.isEmpty else {
            removeQuotaCard()
            return
        }

        let size = LockScreenQuotaCardView.size(for: limits.count)
        let y = cardFrame.map { max(screen.frame.minY + 16, $0.minY - 12 - size.height) }
            ?? (screen.frame.maxY - screen.frame.height * 0.28 - size.height)
        let position = CGRect(x: ((cardFrame?.midX ?? screen.frame.midX) - size.width / 2).rounded(),
                              y: y.rounded(),
                              width: size.width, height: size.height)
        if quotaCard == nil {
            let view = LockScreenQuotaCardView()
            view.update(limits)
            let window = Self.overlayWindow(frame: position)
            window.contentView = view
            window.alphaValue = 0
            window.orderFrontRegardless()
            guard let space = SkyLightSpace.present(window) else {
                window.orderOut(nil)
                return
            }
            quotaCard = (window, view, space)
            Self.animateIn(window)
        }
        guard let quotaCard else { return }
        if quotaCard.window.frame != position { quotaCard.window.setFrame(position, display: true) }
        quotaCard.view.update(limits)

        scheduleQuotaTick(soonestReset: limits.map(\.resetAt).min())
    }

    /// One tick, timed to when the countdown's text next changes: every second
    /// only in its last hour ("12 min 30 sec"), on the minute before that
    /// ("3 hr 12 min left"), and not at all while it is still days out ("Mon
    /// 14:00") until it comes within a day. None while the displays are asleep —
    /// nobody can see it, and a limit can sit exhausted for days; waking them
    /// re-evaluates (see `start`).
    private func scheduleQuotaTick(soonestReset: Double?) {
        quotaTimer?.invalidate()
        quotaTimer = nil
        guard let soonestReset, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else { return }
        let now = Date().timeIntervalSince1970
        let remaining = soonestReset - now
        let interval: TimeInterval
        if remaining <= 3600 {
            interval = 1
        } else if remaining <= 24 * 3600 {
            interval = 60 - now.truncatingRemainder(dividingBy: 60) + 0.05
        } else {
            interval = remaining - 24 * 3600 + 0.05
        }
        let timer = Timer.scheduledTimer(withTimeInterval: max(0.2, interval), repeats: false) { [weak self] _ in
            guard let self,
                  let screen = NSScreen.screens.first(where: \.isBuiltin) ?? NSScreen.main else {
                self?.removeQuotaCard()
                return
            }
            self.quotaTimer = nil
            self.syncQuotaCard(screen: screen, cardFrame: self.card?.window.frame)
        }
        timer.tolerance = interval <= 1 ? 0.1 : 1
        quotaTimer = timer
    }

    private func removeQuotaCard(unlocking: Bool = false) {
        quotaTimer?.invalidate()
        quotaTimer = nil
        if let quotaCard {
            if unlocking { Self.animateUnlocked(quotaCard.window, space: quotaCard.space) }
            else { Self.animateOut(quotaCard.window, space: quotaCard.space) }
        }
        quotaCard = nil
    }

    /// Black over every display but the card's, fading in.
    private func addCovers(except screen: NSScreen) {
        for other in NSScreen.screens where other != screen {
            let window = Self.overlayWindow(frame: other.frame)
            // Keep the black backing inside the layer tree so it can fade
            // with the Touch ID scrim on unlock, in its SkyLight space.
            let view = NSView(frame: CGRect(origin: .zero, size: other.frame.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            window.contentView = view
            window.alphaValue = 0
            window.orderFrontRegardless()
            guard let space = SkyLightSpace.present(window) else {
                window.orderOut(nil)
                continue
            }
            covers.append((window, space))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                window.animator().alphaValue = 1
            }
        }
    }

    private static func overlayWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        return window
    }

    private func removeCovers(unlocking: Bool = false) {
        for cover in covers {
            if unlocking { Self.animateUnlocked(cover.window, space: cover.space, shrink: false) }
            else { Self.animateOut(cover.window, space: cover.space, sink: 0, duration: 0.4) }
        }
        covers.removeAll()
    }

    private func removeWindows(unlocking: Bool = false) {
        removeQuotaCard(unlocking: unlocking)
        removeCovers(unlocking: unlocking)
        removeActivityCard(unlocking: unlocking)
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func removeActivityCard(unlocking: Bool = false) {
        if let card {
            if unlocking { Self.animateUnlocked(card.window, space: card.space) }
            else { Self.animateOut(card.window, space: card.space) }
        }
        card = nil
    }

    // MARK: Motion
    //
    // Cards rise a little into place as they fade in, and sink a little as they
    // fade out; only once faded do they leave their SkyLight space. The black
    // covers just fade, both ways. A card replaced while it is fading out simply
    // crossfades with its successor.

    private static let appearDuration: TimeInterval = 0.34
    private static let disappearDuration: TimeInterval = 0.22

    private static func animateIn(_ window: NSWindow, rise: CGFloat = 10) {
        window.alphaValue = 0
        if let layer = window.contentView?.layer {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -rise
            move.toValue = 0
            move.duration = appearDuration
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            layer.add(move, forKey: "appear")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private static func animateOut(_ window: NSWindow, space: UInt64, sink: CGFloat = 6,
                                   duration: TimeInterval = disappearDuration) {
        if sink != 0, let layer = window.contentView?.layer {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = 0
            move.toValue = -sink
            move.duration = duration
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
            layer.add(move, forKey: "disappear")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            SkyLightSpace.dismiss(space)
            window.orderOut(nil)
        })
    }

    /// Like TouchIDHintView.playUnlocked: spend the card immediately, within
    /// the lock screen's exit. Animate its layer rather than the window alpha;
    /// keep the SkyLight space alive only until the animation has finished.
    private static func animateUnlocked(_ window: NSWindow, space: UInt64, shrink: Bool = true) {
        guard let layer = window.contentView?.layer else {
            SkyLightSpace.dismiss(space)
            window.orderOut(nil)
            return
        }
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        let transform = layer.presentation()?.transform ?? layer.transform
        layer.removeAllAnimations()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity
        fade.toValue = 0
        var animations: [CAAnimation] = [fade]
        var target = CATransform3DIdentity
        if shrink {
            let scale: CGFloat = 0.94
            target = CATransform3DMakeScale(scale, scale, 1)
            // AppKit owns the backing layer's anchor point. Compensate for
            // it so the card shrinks into its center without moving its frame.
            target.m41 = layer.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale)
            target.m42 = layer.bounds.height * (0.5 - layer.anchorPoint.y) * (1 - scale)
            let pinch = CABasicAnimation(keyPath: "transform")
            pinch.fromValue = NSValue(caTransform3D: transform)
            pinch.toValue = NSValue(caTransform3D: target)
            animations.append(pinch)
        }
        let leave = CAAnimationGroup()
        leave.animations = animations
        leave.duration = shrink ? 0.16 : 0.14
        leave.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.5)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = target
        layer.add(leave, forKey: "unlock")
        CATransaction.commit()

        // Capture this window and space: a quick re-lock may already have
        // created new ones when this cleanup runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + TouchIDHintView.unlockDuration) {
            SkyLightSpace.dismiss(space)
            window.orderOut(nil)
        }
    }

    private func teardown(unlocking: Bool = false) {
        removeWindows(unlocking: unlocking)
        holdDisplayAwake(false)
        runStartedAt = nil
        finishedAt = nil
        lastRows = []
    }
}

// MARK: - Card

/// Provider groups with every live session, its clock and observed activity.
/// The notch host supplies a header band whose middle is reserved for hardware.
final class AgentActivityCardView: NSView {
    enum State: Equatable {
        case working(since: Date)
        case finished(at: Date)
        case idle
    }

    private(set) var state: State = .working(since: Date())
    private var rows: [AgentLockScreen.Row] = []
    private static let width: CGFloat = 440
    private static let inset: CGFloat = 24
    private static let iconSize: CGFloat = 28
    private static let textX: CGFloat = inset + iconSize + 12
    private static let bottomInset: CGFloat = inset
    private static let groupSpacing: CGFloat = 24
    private static let headerGap: CGFloat = 24
    private static let sessionHeight: CGFloat = 39
    private static let sessionGap: CGFloat = 12
    private static let headerHeight: CGFloat = iconSize
    private static let quotaGap: CGFloat = 8
    private static let quotaHeight: CGFloat = 24 + quotaBarHeight
    private static let quotaBarHeight: CGFloat = 3

    private var notchWidth: CGFloat = 0
    private var embeddedWidth: CGFloat?
    private var notchHeight: CGFloat = 0
    private var maximumHeight: CGFloat = .greatestFiniteMagnitude
    private let document = FlippedView()
    private let scroll = NSScrollView()
    private var fixedHeader: NSView?
    private let footer = NSTextField(labelWithString: "")
    private var clocks: [(field: NSTextField, since: Double?)] = []
    private var contentHeight: CGFloat = 0
    private var geometryChanged = false

    override var isFlipped: Bool { true }

    init(chrome: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        if chrome {
            layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.9).cgColor
            layer?.cornerRadius = 26
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        }
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        footer.font = .systemFont(ofSize: 11.5, weight: .medium)
        footer.textColor = NSColor(white: 1, alpha: 0.5)
        addSubview(footer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Real screen geometry, not a hard-coded notch width. Both header wings
    /// remain readable even when the first provider has a long name.
    func configureNotch(width: CGFloat, height: CGFloat, maximumHeight: CGFloat) {
        geometryChanged = geometryChanged || notchWidth != width || notchHeight != height || self.maximumHeight != maximumHeight
        self.notchWidth = width
        self.notchHeight = height
        self.maximumHeight = maximumHeight
    }

    /// The dashboard supplies its own notch header and outer chrome.
    func configureEmbedded(width: CGFloat, maximumHeight: CGFloat) {
        geometryChanged = geometryChanged || embeddedWidth != width || self.maximumHeight != maximumHeight
        embeddedWidth = width
        notchWidth = 0
        notchHeight = 0
        self.maximumHeight = maximumHeight
    }

    private var cardWidth: CGFloat {
        if let embeddedWidth { return embeddedWidth }
        guard notchHeight > 0 else { return Self.width }
        let name = Self.name(for: rows.first?.provider ?? .claude) as NSString
        let nameWidth = ceil(name.size(withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .bold)]).width)
        let wing = Self.textX + nameWidth + 8 + 7 + Self.inset
        return max(Self.width, notchWidth + wing * 2)
    }

    private var topBand: CGFloat {
        notchHeight > 0 && !rows.isEmpty ? max(Self.inset + Self.headerHeight, notchHeight) : 0
    }
    private var contentTopInset: CGFloat { topBand > 0 ? Self.headerGap : Self.inset }
    private var footerHeight: CGFloat { state.kind == 2 || (state.kind == 0 && !rows.isEmpty) ? 0 : 30 }

    private func sessions(for row: AgentLockScreen.Row) -> [TokenBarSnapshot.WorkingSession] {
        if !row.sessions.isEmpty { return row.sessions }
        return [.init(title: row.title)]
    }

    private var naturalContentHeight: CGFloat {
        guard !rows.isEmpty else { return Self.inset + 20 + 8 + 18 + Self.bottomInset }
        return rows.enumerated().reduce(contentTopInset + Self.bottomInset) { height, entry in
            let (index, row) = entry
            let header = index == 0 && topBand > 0 ? CGFloat(0) : Self.headerHeight + Self.headerGap
            return height + (index == 0 ? 0 : Self.groupSpacing) + header
                + CGFloat(sessions(for: row).count) * Self.sessionHeight
                + CGFloat(max(0, sessions(for: row).count - 1)) * Self.sessionGap
                + (row.quotaRemaining == nil ? 0 : Self.quotaGap + Self.quotaHeight)
        }
    }

    var fittingCardSize: CGSize {
        CGSize(width: cardWidth, height: min(maximumHeight, topBand + naturalContentHeight + footerHeight))
    }

    func update(rows: [AgentLockScreen.Row], state: State) {
        let rebuild = geometryChanged || rows != self.rows || state.kind != self.state.kind || document.subviews.isEmpty
        self.rows = rows
        self.state = state
        setFrameSize(fittingCardSize)
        if rebuild {
            geometryChanged = false
            if window != nil, let layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.2
                layer.add(fade, forKey: "contentChange")
            }
            rebuildRows()
        }
        refreshClock()
    }

    override func layout() {
        super.layout()
        let viewport = max(0, bounds.height - topBand - footerHeight)
        scroll.frame = CGRect(x: 0, y: topBand, width: bounds.width, height: viewport)
        scroll.hasVerticalScroller = contentHeight > viewport
        document.setFrameSize(CGSize(width: bounds.width, height: contentHeight))
        footer.frame = CGRect(x: Self.inset, y: bounds.height - Self.inset - 18,
                              width: bounds.width - Self.inset * 2, height: 18)
    }

    func refreshClock() {
        let now: Date
        if case .finished(let at) = state { now = at } else { now = Date() }
        for clock in clocks {
            guard let epoch = clock.since, epoch.isFinite else { clock.field.stringValue = "—"; continue }
            let seconds = min(31_536_000, max(0, now.timeIntervalSince1970 - epoch))
            let minutes = Int(seconds / 60)
            clock.field.stringValue = minutes < 1 ? "just started"
                : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) hr \(minutes % 60) min"
        }
        switch state {
        case .working: footer.stringValue = ""
        case .finished(let at):
            footer.stringValue = "Finished at \(DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short))"
        case .idle: footer.stringValue = ""
        }
        footer.isHidden = footerHeight == 0
        needsLayout = true
    }

    private func rebuildRows() {
        let offset = scroll.contentView.bounds.origin
        document.subviews.forEach { $0.removeFromSuperview() }
        fixedHeader?.removeFromSuperview()
        fixedHeader = nil
        clocks = []
        guard !rows.isEmpty else {
            let name = label("No AI tasks running", font: .systemFont(ofSize: 15, weight: .semibold), alpha: 1)
            name.frame = CGRect(x: Self.inset, y: Self.inset, width: cardWidth - Self.inset * 2, height: 20)
            document.addSubview(name)
            let detail = label("Claude, Codex and Antigravity", font: .systemFont(ofSize: 12), alpha: 0.55)
            detail.frame = CGRect(x: Self.inset, y: name.frame.maxY + 8, width: cardWidth - Self.inset * 2, height: 18)
            document.addSubview(detail)
            contentHeight = detail.frame.maxY + Self.bottomInset
            needsLayout = true
            return
        }
        var y = contentTopInset
        for (index, row) in rows.enumerated() {
            let header = makeHeader(row, height: Self.headerHeight)
            if index > 0 {
                // Center the separator against the provider's text, which sits
                // below the icon's top edge within the header.
                let nameTop = header.subviews.compactMap { $0 as? NSTextField }.first?.frame.minY ?? 0
                let lineHeight: CGFloat = 0.5
                let line = NSView(frame: CGRect(x: Self.textX,
                                               y: y + (Self.groupSpacing + nameTop - lineHeight) / 2,
                                               width: cardWidth - Self.textX - Self.inset, height: lineHeight))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
                document.addSubview(line)
                y += Self.groupSpacing
            }
            if index == 0, topBand > 0 {
                header.frame = CGRect(x: 0, y: Self.inset, width: cardWidth, height: Self.headerHeight)
                addSubview(header)
                fixedHeader = header
            } else {
                header.frame.origin.y = y
                document.addSubview(header)
                y += Self.headerHeight + Self.headerGap
            }
            for (sessionIndex, session) in sessions(for: row).enumerated() {
                if sessionIndex > 0 { y += Self.sessionGap }
                let view = makeSession(session, row: row, index: sessionIndex)
                view.frame = CGRect(x: 0, y: y, width: cardWidth, height: Self.sessionHeight)
                document.addSubview(view)
                y += Self.sessionHeight
            }
            if let remaining = row.quotaRemaining {
                y += Self.quotaGap
                let quota = makeQuota(remaining, provider: row.provider)
                quota.frame = CGRect(x: 0, y: y, width: cardWidth, height: Self.quotaHeight)
                document.addSubview(quota)
                y += Self.quotaHeight
            }
        }
        contentHeight = y + Self.bottomInset
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(offset.y, max(0, contentHeight - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func label(_ text: String, font: NSFont, alpha: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = NSColor(white: 1, alpha: alpha)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func makeHeader(_ row: AgentLockScreen.Row, height: CGFloat) -> NSView {
        let view = FlippedView(frame: CGRect(x: 0, y: 0, width: cardWidth, height: height))
        let iconSize = Self.iconSize
        let icon = NSImageView(frame: CGRect(x: Self.inset, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
        icon.image = Self.icon(for: row.provider)
        icon.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(icon)
        let name = label(Self.name(for: row.provider), font: .systemFont(ofSize: 16, weight: .bold), alpha: 1)
        name.sizeToFit()
        name.frame.origin = CGPoint(x: Self.textX, y: (height - name.frame.height) / 2)
        view.addSubview(name)
        let dot = NSView(frame: CGRect(x: name.frame.maxX + 8, y: (height - 7) / 2, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        if !state.isFinished {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1; breathe.toValue = 0.25; breathe.duration = 1.1
            breathe.autoreverses = true; breathe.repeatCount = .infinity
            dot.layer?.add(breathe, forKey: "breathe")
        }
        view.addSubview(dot)
        let count = label(state.isFinished ? "Done" : "\(max(row.count, sessions(for: row).count)) working",
                          font: .systemFont(ofSize: 11.5, weight: .medium), alpha: 0.55)
        count.sizeToFit()
        count.frame.origin = CGPoint(x: cardWidth - Self.inset - count.frame.width, y: (height - count.frame.height) / 2)
        view.addSubview(count)
        return view
    }

    private func makeSession(_ session: TokenBarSnapshot.WorkingSession, row: AgentLockScreen.Row, index: Int) -> NSView {
        let view = FlippedView()
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = session.id.map { "Session " + String($0.prefix(8)) } ?? "Session \(index + 1)"
        let name = label(title?.isEmpty == false ? title! : fallback, font: .systemFont(ofSize: 13, weight: .medium), alpha: 0.9)
        // Reserve the timer's width so long names truncate, never collide.
        let timerWidth: CGFloat = 92
        name.frame = CGRect(x: Self.textX, y: 0, width: cardWidth - Self.textX - Self.inset - timerWidth - 12, height: 19)
        name.toolTip = title
        view.addSubview(name)
        let clock = label("", font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), alpha: 0.60)
        clock.alignment = .right
        clock.frame = CGRect(x: cardWidth - Self.inset - timerWidth, y: 0, width: timerWidth, height: 19)
        view.addSubview(clock)
        clocks.append((clock, session.since))
        var activity = state.isFinished ? "Completed" : (session.activity ?? "Processing…")
        if !state.isFinished, let done = session.completedSteps, let total = session.totalSteps,
           total > 0, done >= 0, done <= total { activity += " · \(done)/\(total) steps" }
        let detail = label(activity, font: .systemFont(ofSize: 11.5, weight: .medium), alpha: 0.55)
        detail.frame = CGRect(x: Self.textX, y: 22, width: cardWidth - Self.textX - Self.inset, height: 17)
        view.addSubview(detail)
        return view
    }

    private func makeQuota(_ remaining: Double, provider: AIProvider) -> NSView {
        let view = FlippedView()
        let width = cardWidth - Self.textX - Self.inset
        let title = label("Session quota", font: .systemFont(ofSize: 11.5, weight: .medium), alpha: 0.55)
        title.frame = CGRect(x: Self.textX, y: 0, width: width / 2, height: 17)
        view.addSubview(title)
        let value = label("\(Int(remaining.rounded()))% left", font: .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium), alpha: 0.60)
        value.alignment = .right
        value.frame = CGRect(x: Self.textX + width / 2, y: 0, width: width / 2, height: 17)
        view.addSubview(value)
        let track = NSView(frame: CGRect(x: Self.textX, y: 24, width: width, height: Self.quotaBarHeight))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        track.layer?.cornerRadius = Self.quotaBarHeight / 2
        let fill = NSView(frame: CGRect(x: 0, y: 0, width: track.frame.width * remaining / 100, height: Self.quotaBarHeight))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Self.tint(for: provider).cgColor
        fill.layer?.cornerRadius = Self.quotaBarHeight / 2
        track.addSubview(fill)
        view.addSubview(track)
        return view
    }

    static func name(for provider: AIProvider) -> String {
        switch provider {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        case .deepseek:    return "DeepSeek"
        }
    }

    private static func tint(for provider: AIProvider) -> NSColor {
        switch provider {
        case .claude:      return NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex:       return NSColor(white: 0.9, alpha: 1)
        case .antigravity: return NSColor(red: 0.30, green: 0.75, blue: 0.40, alpha: 1)
        case .deepseek:    return .systemBlue
        }
    }

    /// TokenBar's own mark for the provider, from the PNGs it leaves next to its snapshot.
    static func icon(for provider: AIProvider) -> NSImage? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TokenBar/icons/\(provider.rawValue).png")
        if let image = NSImage(contentsOf: url) { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            .applying(.init(paletteColors: [tint(for: provider)]))
        return NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// Quota status has its own glass card below the AI activity card. Its rows
/// retain the provider identity while the reset text ticks once per second.
final class LockScreenQuotaCardView: NSView {
    private static let width: CGFloat = 440
    private static let topInset: CGFloat = 8
    private static let rowHeight: CGFloat = 62
    private static let bottomInset: CGFloat = 8

    private var providers: [AIProvider] = []
    private var rows: [NSView] = []
    private var countdowns: [AIProvider: NSTextField] = [:]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.9).cgColor
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func size(for count: Int) -> CGSize {
        CGSize(width: width, height: topInset + CGFloat(count) * rowHeight + bottomInset)
    }

    func update(_ limits: [TokenBarSnapshot.ExhaustedPrimaryLimit]) {
        let next = limits.map(\.provider)
        setFrameSize(Self.size(for: limits.count))
        if next != providers {
            rows.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            countdowns.removeAll()
            providers = next
            for (index, provider) in next.enumerated() {
                let row = makeRow(provider)
                row.frame = CGRect(x: 0, y: Self.topInset + CGFloat(index) * Self.rowHeight,
                                   width: Self.width, height: Self.rowHeight)
                addSubview(row)
                rows.append(row)
                if index > 0 {
                    let divider = NSView(frame: CGRect(x: 18, y: 0, width: Self.width - 36, height: 0.5))
                    divider.wantsLayer = true
                    divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.11).cgColor
                    row.addSubview(divider)
                }
            }
        }
        for limit in limits {
            countdowns[limit.provider]?.stringValue = UsageResetCountdown.text(until: limit.resetAt)
        }
    }

    private func makeRow(_ provider: AIProvider) -> NSView {
        let row = FlippedView()
        let icon = NSImageView(frame: CGRect(x: 18, y: 13, width: 34, height: 34))
        icon.image = AgentActivityCardView.icon(for: provider)
        icon.imageScaling = .scaleProportionallyUpOrDown
        row.addSubview(icon)

        let name = NSTextField(labelWithString: AgentActivityCardView.name(for: provider))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = .white
        name.frame = CGRect(x: 64, y: 9, width: 150, height: 21)
        row.addSubview(name)

        let detail = NSTextField(labelWithString: "Primary quota exhausted")
        detail.font = .systemFont(ofSize: 11.5, weight: .medium)
        detail.textColor = NSColor(white: 1, alpha: 0.48)
        detail.frame = CGRect(x: 64, y: 32, width: 160, height: 17)
        row.addSubview(detail)

        let countdown = NSTextField(labelWithString: "")
        countdown.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        countdown.textColor = .white
        countdown.alignment = .right
        countdown.frame = CGRect(x: 222, y: 20, width: Self.width - 240, height: 23)
        row.addSubview(countdown)
        countdowns[provider] = countdown
        return row
    }
}

/// Rows lay out top-down like the card itself.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension AgentActivityCardView.State {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }

    /// Which kind of card, ignoring the times: a change of kind rebuilds the rows.
    var kind: Int {
        switch self {
        case .working: return 0
        case .finished: return 1
        case .idle: return 2
        }
    }
}
