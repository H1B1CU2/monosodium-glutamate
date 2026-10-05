import AppKit
import AudioToolbox
import Carbon
import QuartzCore

// MARK: - Volume, brightness and language in the notch
//
// The HUD Replacer's "Notch" presentation. The notch grows into the same black
// card as the TokenBar dashboard (NotchShapeHostView) and shows what just
// changed: the volume with the output it went to, the brightness, or the
// keyboard language. It is a control as well as a readout: the bar can be
// dragged, the volume icon mutes, resting the pointer on a volume HUD lists
// the other outputs to switch to, and the language HUD offers every enabled
// input source as a pill.
//
// Only on a display with a real notch. `show…` returns false otherwise (lid
// closed, no notch, screen locked) and the caller falls back to the other HUDs.

struct NotchMusicTrackChange {
    private var seeded = false
    private var previous: [String]?

    mutating func update(title: String?, artist: String?, source: String?) -> Bool {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previous = nil
            return false
        }
        let track = [title, artist ?? "", source ?? ""]
        let changed = seeded && track != previous
        seeded = true
        previous = track
        return changed
    }
}

/// A change MSG reports small, in the wing of a card that's already open (the
/// notch card's header, or Cortex's launcher) instead of a HUD card of its own:
/// an icon, a level bar when it has one, and a short text. The same `id`
/// updates in place.
struct NotchWingEvent: Equatable {
    let id: String
    /// SF Symbol, for Cortex; MSG draws `level`'s own icon when there is one.
    let symbol: String?
    let iconPath: String?
    let level: NotchHUDView.Level?
    let value: CGFloat?
    let text: String
    /// A finished task's session, opened by a click on the wing.
    var link: AgentSessionLink? = nil

    init?(_ content: NotchHUDView.Content, music: MusicMonitor?) {
        switch content {
        case .level(let level):
            id = level.kind == .volume ? "volume" : "brightness"
            symbol = Self.symbol(for: level)
            iconPath = nil
            self.level = level
            value = level.unknown ? nil : level.muted ? 0 : level.value
            text = level.unknown ? "–" : level.muted ? "Muted" : "\(Int((level.value * 100).rounded()))%"
        case .inputSource(let label, _):
            id = "language"
            symbol = "globe"
            iconPath = nil
            level = nil
            value = nil
            text = label
        case .notice(let notice):
            id = "notice-\(notice.provider.rawValue)"
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TokenBar/icons/\(notice.provider.rawValue).png").path
            iconPath = FileManager.default.fileExists(atPath: path) ? path : nil
            symbol = iconPath == nil ? "sparkle" : nil
            level = nil
            value = nil
            // A wing has room for who and how long, not the thread's name.
            let who = notice.title.components(separatedBy: " · ").first ?? notice.title
            text = notice.value.isEmpty ? who : "\(who) · \(notice.value)"
            link = notice.link
        case .charger(let state):
            id = "charger"
            symbol = state.symbolName
            iconPath = nil
            level = nil
            value = nil
            text = state.wingText
        case .systemEvent(let event):
            id = event.id
            symbol = event.symbol
            iconPath = nil
            level = nil
            value = nil
            text = event.wingText
        case .appNotification:
            // App messages need their readable body and clickable card.
            return nil
        case .music:
            guard let title = music?.currentTitle, !title.isEmpty else { return nil }
            id = "music"
            symbol = "music.note"
            iconPath = nil
            level = nil
            value = nil
            text = title
        }
    }

    /// A plain event: a symbol and a line (Cortex's answer landing).
    init(id: String, symbol: String, text: String) {
        self.id = id
        self.symbol = symbol
        iconPath = nil
        level = nil
        value = nil
        self.text = text
    }

    /// The SF Symbol nearest the HUD's own icon (MSG draws a few by hand).
    private static func symbol(for level: NotchHUDView.Level) -> String {
        if level.kind == .brightness { return level.value < 0.5 ? "sun.min.fill" : "sun.max.fill" }
        if level.muted { return "speaker.slash.fill" }
        switch level.output {
        case .airPodsPro?: return "airpodspro"
        case .airPods?: return "airpods"
        case .headphones?, .nothingHeadphone?: return "headphones"
        case .displaySpeaker?: return "hifispeaker.fill"
        default:
            return level.value <= 0.001 ? "speaker.fill" : level.value < 0.33 ? "speaker.wave.1.fill"
                : level.value < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }

    /// The icon as MSG draws it: the HUD's own glyph for a level, else the
    /// image or symbol.
    func image(size: CGFloat) -> NSImage? {
        if let level {
            return IndicatorRenderer.systemHUDIcon(kind: level.kind, value: level.value, muted: level.muted,
                                                   audioOutputKind: level.output,
                                                   deviceIcons: AppSettings.shared.systemHUDDeviceIcons,
                                                   pointSize: size - 3, color: .white)
        }
        if let iconPath, let mark = NSImage(contentsOfFile: iconPath) {
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                mark.draw(in: rect)
                return true
            }
        }
        guard let symbol else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size - 3, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// While Cortex's launcher holds the notch, MSG's changes show in its right
/// wing instead: Cortex draws them and swaps back after `hold`, so the launcher
/// keeps its place and its keyboard focus. A JSON object on
/// `com.h1d3s1gn.MSG.notch.wing`: `symbol` (SF Symbol) or `icon` (image path),
/// optional `value` (0…1, drawn as a bar), `text`, `hold` (seconds) and `id`
/// (the same id updates in place).
enum CortexWing {
    static let name = Notification.Name("com.h1d3s1gn.MSG.notch.wing")

    static func show(_ event: NotchWingEvent, hold: TimeInterval) {
        var object: [String: Any] = ["id": event.id, "text": event.text, "hold": hold]
        if let symbol = event.symbol { object["symbol"] = symbol }
        if let path = event.iconPath { object["icon"] = path }
        if let value = event.value { object["value"] = Double(value) }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object: text, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}

/// The wing's view in MSG's own notch card: the icon, a level bar when the
/// event has one, and its text, right-aligned. Repeats of the same event move
/// the bar and change the number in place; a different one, or a word (TH →
/// ENG), fades in whole.
final class NotchWingIndicator: NSView {
    private static let iconSize: CGFloat = 16
    private static let barWidth: CGFloat = 72
    private static let gap: CGFloat = 8
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var event: NotchWingEvent?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleNone
        icon.unregisterDraggedTypes()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        track.cornerRadius = 2.5
        track.masksToBounds = true
        fill.backgroundColor = NSColor.white.cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        layer?.addSublayer(track)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        super.resetCursorRects()
        if event?.link != nil {
            let drawn = CGRect(x: icon.frame.minX, y: bounds.minY,
                               width: max(0, bounds.maxX - icon.frame.minX), height: bounds.height)
            addCursorRect(drawn.insetBy(dx: -8, dy: -8), cursor: .pointingHand)
        }
    }

    func show(_ next: NotchWingEvent) {
        let previous = event
        event = next
        toolTip = next.link?.helpText
        window?.invalidateCursorRects(for: self)
        icon.image = next.image(size: Self.iconSize)
        label.font = next.value == nil ? .systemFont(ofSize: 12, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        if previous?.id == next.id, next.value == nil, previous?.text != next.text {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            label.layer?.add(fade, forKey: "swap")
        }
        label.stringValue = next.text
        track.isHidden = next.value == nil
        let from = fill.presentation()?.bounds.width ?? fill.bounds.width
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard previous?.id == next.id, next.value != nil, from != fill.bounds.width else { return }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = from
        grow.toValue = fill.bounds.width
        grow.duration = 0.18
        grow.timingFunction = NotchTransition.timingFunction
        fill.add(grow, forKey: "level")
    }

    override func layout() {
        super.layout()
        guard let event else { return }
        // The cell's size, padding included: a label's intrinsic width is the
        // glyphs' alone (28 pt for "80%" against the 32 its cell needs), and
        // that cut the last digits off ("8…").
        let text = (label.cell?.cellSize.width ?? label.intrinsicContentSize.width).rounded(.up) + 1
        let barSpace = event.value == nil ? 0 : Self.barWidth + Self.gap
        let maxText = max(0, bounds.width - Self.iconSize - Self.gap - barSpace)
        let textWidth = min(text, maxText)
        var x = bounds.width - textWidth
        label.frame = CGRect(x: x, y: (bounds.height - 16) / 2, width: textWidth, height: 16)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let value = event.value {
            x -= Self.gap + Self.barWidth
            track.frame = CGRect(x: x, y: (bounds.height - 5) / 2, width: Self.barWidth, height: 5)
            fill.bounds = CGRect(x: 0, y: 0, width: (Self.barWidth * max(0, min(1, value))).rounded(), height: 5)
            fill.position = CGPoint(x: 0, y: 2.5)
        }
        CATransaction.commit()
        x -= Self.gap + Self.iconSize
        icon.frame = CGRect(x: x, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
    }

    /// Where it draws: the icon to the right edge (the label is right-aligned
    /// in a wider frame).
    var drawnFrame: CGRect {
        frame.divided(atDistance: max(0, bounds.width - icon.frame.minX), from: .maxXEdge).slice
    }
}

final class NotchHUD {
    static let shared = NotchHUD()

    /// Applies drags and mute clicks, and reads the output after a switch. Set
    /// by AppDelegate while the key tap runs; without it the HUD only shows.
    weak var levels: SystemHUDMonitor?

    private(set) var isShowing = false
    private var panel: NSPanel?
    private var host: NotchShapeHostView?
    private let view = NotchHUDView()
    private var notch: CGRect = .zero
    private var hideWork: DispatchWorkItem?
    private var orderOutWork: DispatchWorkItem?
    private var resizeCompletion: DispatchWorkItem?
    private var resizeTarget: CGRect?
    private var resizeGeneration = 0
    private var observing = false
    private var embeddedInDashboard = false
    private weak var musicMonitor: MusicMonitor?
    private var musicChanges = NotchMusicTrackChange()

    func attachMusic(_ monitor: MusicMonitor) {
        guard musicMonitor !== monitor else { return }
        musicMonitor = monitor
        monitor.addObserver { [weak self] in self?.musicChanged() }
    }

    private func musicChanged() {
        guard let monitor = musicMonitor else { return }
        let changed = musicChanges.update(title: monitor.currentTitle, artist: monitor.currentArtist,
                                          source: monitor.currentSourceBundleID)
        guard let title = monitor.currentTitle, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if isShowing, case .music? = view.content { hide(animated: true) }
            return
        }
        if isShowing, case .music? = view.content { view.refreshMusic() }
        guard changed, !view.isDragging, AppSettings.shared.notchAgentCard,
              !AppSettings.shared.notchPreviewEnabled,
              !AppSettings.shared.notchDisabledPanes.contains("music") else { return }
        _ = present(.music)
    }

    /// How long it stays after the last change, and after the pointer leaves.
    private static let hold: TimeInterval = 1.5
    /// A notice (an AI limit reset, a task done) is read, not glanced at: it
    /// stays longer (8 s, was 4; the user asked for longer), and while the
    /// pointer is on it.
    private static let noticeHold: TimeInterval = 8
    /// Notices waiting for the HUD on screen to go.
    private var noticeQueue: [NotchHUDView.Notice] = []
    private static let leaveHold: TimeInterval = 0.6

    private init() {
        view.onLevel = { [weak self] kind, value, final in self?.drag(kind, to: value, final: final) }
        view.onMute = { [weak self] in MainActor.assumeIsolated { self?.levels?.toggleMute() } }
        view.onSelectOutput = { [weak self] uid in self?.selectOutput(uid) }
        view.onSelectSource = { id in InputSources.select(id) }
        view.onHoverChanged = { [weak self] hovering in self?.hoverChanged(hovering) }
        view.onOpenNotice = { [weak self] link in
            self?.hide(animated: true, resumeDashboard: false)
            AgentNotchCard.shared.openSession(link)
        }
        view.onOpenAppNotification = { [weak self] notice in
            self?.hide(animated: true, resumeDashboard: false)
            SystemNotificationNotch.shared.openApp(notice)
        }
        view.onDragEnded = { [weak self] in
            guard let self, !self.view.isHovered || self.embeddedInDashboard else { return }
            self.scheduleHide(after: self.embeddedInDashboard ? Self.hold : Self.leaveHold)
        }
    }

    // MARK: Showing

    /// A volume or brightness change. False when there's no notch to show it in.
    @discardableResult
    func show(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?) -> Bool {
        let title: String
        switch kind {
        case .volume:     title = MainActor.assumeIsolated { levels?.outputState()?.name } ?? "Volume"
        case .brightness: title = MainActor.assumeIsolated { levels?.brightnessDisplayName } ?? "\(MacModel.name) Display"
        }
        let level = NotchHUDView.Level(kind: kind, value: value, muted: muted,
                                       output: audioOutputKind, title: title)
        return present(.level(level))
    }

    /// A keyboard language switch; `label` is the monitor's short name (TH, ENG…).
    @discardableResult
    func showInputSource(label: String) -> Bool {
        present(.inputSource(label: label, sources: InputSources.enabled()))
    }

    /// A fresh power connection change uses the same shape, wings and two-line
    /// layout as the other HUDs, with a short hold and no AI-notice sound.
    @discardableResult
    func showCharger(_ state: ChargerPowerState) -> Bool {
        present(.charger(state), hold: 4)
    }

    func updateCharger(_ state: ChargerPowerState) {
        guard isShowing, case .charger? = view.content else { return }
        view.apply(.charger(state), animated: true)
        relayout()
    }

    func dismissCharger() {
        guard isShowing, case .charger? = view.content else { return }
        hide(animated: true)
    }

    /// Let simultaneous power/display/app events take turns on the card.
    /// A newer state for the same event may update its existing surface.
    @discardableResult
    func showSystemEvent(_ event: SystemNotchEvent) -> Bool {
        if isShowing {
            guard case .systemEvent(let visible)? = view.content, visible.id == event.id else { return false }
        }
        return present(.systemEvent(event), hold: SystemNotchEvent.hold)
    }

    func dismissSystemEvent(kind: SystemNotchEvent.Kind) {
        guard isShowing, case .systemEvent(let event)? = view.content, event.kind == kind else { return }
        hide(animated: true)
    }

    @discardableResult
    func showAppNotification(_ notice: NotchAppNotification) -> Bool {
        guard !AgentNotchCard.shared.isSuppressedByCortex else { return false }
        if isShowing {
            guard case .appNotification(let visible)? = view.content, visible.id == notice.id else { return false }
        }
        return present(.appNotification(notice), hold: 8)
    }

    func isShowingAppNotification(_ id: String) -> Bool {
        guard isShowing, case .appNotification(let notice)? = view.content else { return false }
        return notice.id == id
    }

    func dismissAppNotification() {
        guard isShowing, case .appNotification? = view.content else { return }
        hide(animated: true)
    }

    private func appNotificationEnded() {
        guard isShowing, case .appNotification(let notice)? = view.content else { return }
        SystemNotificationNotch.shared.cardEnded(notice.id)
    }

    /// A one-off notice, such as an AI limit reset. It waits its turn behind
    /// whatever the notch is showing. False when there's no notch to show it in
    /// (lid closed, screen locked): the caller keeps it for later.
    func showNotice(_ notice: NotchHUDView.Notice) -> Bool {
        guard PresentationState.shared.canPresent, AgentNotchCard.notchScreen() != nil else { return false }
        if AgentNotchCard.shared.isSuppressedByCortex { return present(.notice(notice), hold: Self.noticeHold) }
        if isShowing {
            noticeQueue.append(notice)
            return true
        }
        return present(.notice(notice), hold: Self.noticeHold)
    }

    private func present(_ content: NotchHUDView.Content, hold: TimeInterval = NotchHUD.hold) -> Bool {
        // Cortex has the notch and the keyboard: what changed goes in its wing.
        if AgentNotchCard.shared.isSuppressedByCortex {
            guard PresentationState.shared.canPresent else { return false }
            if let event = NotchWingEvent(content, music: musicMonitor) { CortexWing.show(event, hold: hold) }
            if case .notice = content, AppSettings.shared.notchNoticeSound { Self.ding() }
            return true
        }
        // A file is being dragged to the notch: the HUDs elsewhere show this one.
        guard !AgentNotchCard.shared.isSuppressedByCortex, PresentationState.shared.canPresent, !NotchDropZone.shared.isShowing,
              let screen = AgentNotchCard.notchScreen() else { return false }
        // The card is open on Audio: its own output bar shows the change.
        if case .level(let level) = content, level.kind == .volume, !isShowing,
           AgentNotchCard.shared.showVolumeInAudioPane() { return true }
        // The card is open on any other page: the change shows small in its
        // header, where the page dots are, and the page stays as it was.
        if !isShowing, let event = NotchWingEvent(content, music: musicMonitor),
           AgentNotchCard.shared.showWing(event, hold: hold) {
            if case .notice = content, AppSettings.shared.notchNoticeSound { Self.ding() }
            return true
        }
        observe()
        let notch = AgentNotchCard.notchRect(screen)
        orderOutWork?.cancel()
        orderOutWork = nil
        let reuse = isShowing && (embeddedInDashboard || panel?.isVisible == true) && notch == self.notch
        self.notch = notch
        // A fresh open forgets the last one's pointer and outputs list (cleared
        // here, not on hide, so nothing pops out while it folds away).
        if !reuse { view.reset() }
        view.configure(notch: notch.size, available: screen.frame.size)
        if case .appNotification(let previous)? = view.content {
            if case .appNotification(let next) = content, previous.id == next.id {} else { appNotificationEnded() }
        }
        view.apply(content, animated: reuse)
        if case .level(let level) = content, level.kind == .volume, view.isHovered {
            view.outputs = outputs()
        }
        // Finish the old window's resize before lending its content elsewhere.
        cancelResize()
        if AgentNotchCard.shared.presentHUD(view, size: view.cardSize) {
            panel?.orderOut(nil)
            embeddedInDashboard = true
            isShowing = true
            if case .notice = content, AppSettings.shared.notchNoticeSound { Self.ding() }
            if !view.isDragging { scheduleHide(after: hold) }
            return true
        }
        embeddedInDashboard = false
        AgentNotchCard.shared.yieldToHUD()
        let panel = self.panel ?? makePanel()
        guard let host else { return false }
        let target = frame(for: view.cardSize, on: screen)
        if reuse {
            resize(to: target)
        } else {
            cancelResize()
            panel.setFrame(target, display: false)
            host.layout(notch: notch, in: target)
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            host.animateOpen()
        }
        isShowing = true
        if case .notice = content, AppSettings.shared.notchNoticeSound { Self.ding() }
        if !view.isHovered && !view.isDragging { scheduleHide(after: hold) }
        return true
    }

    /// The sound the ChatGPT app's Codex plays when a task is done: whichever
    /// one it last staged in ~/Library/Sounds ("codex-alert-<sound>.wav", the
    /// user's pick in its settings), else its default from the app, else
    /// macOS's Glass. Played as a system sound: at the alert volume, through
    /// the device chosen for sound effects.
    private static var dingSound: (path: String, id: SystemSoundID)?

    private static func dingPath() -> String {
        let fm = FileManager.default
        let sounds = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds")
        let staged = ((try? fm.contentsOfDirectory(at: sounds, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("codex-alert-") && $0.pathExtension == "wav" }
            .max { a, b in
                let date: (URL) -> Date = {
                    (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                }
                return date(a) < date(b)
            }
        if let staged { return staged.path }
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex-notification.wav"
        return fm.fileExists(atPath: bundled) ? bundled : "/System/Library/Sounds/Glass.aiff"
    }

    static func ding() {
        let path = dingPath()
        if dingSound?.path != path {
            if let old = dingSound { AudioServicesDisposeSystemSoundID(old.id) }
            var id: SystemSoundID = 0
            dingSound = AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &id) == noErr
                ? (path, id) : nil
        }
        if let dingSound { AudioServicesPlaySystemSound(dingSound.id) }
    }

    func hide(animated: Bool, resumeDashboard: Bool = true) {
        appNotificationEnded()
        hideWork?.cancel()
        hideWork = nil
        cancelResize()
        view.setMusicPresented(false)
        if embeddedInDashboard {
            embeddedInDashboard = false
            isShowing = false
            AgentNotchCard.shared.restoreAfterHUD(animated: animated, resume: resumeDashboard)
            if animated, !noticeQueue.isEmpty {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.isShowing, !self.noticeQueue.isEmpty else { return }
                    let next = self.noticeQueue.removeFirst()
                    _ = self.present(.notice(next), hold: Self.noticeHold)
                }
                orderOutWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NotchTransition.duration, execute: work)
            }
            return
        }
        guard isShowing, let panel, let host else { return }
        isShowing = false
        panel.ignoresMouseEvents = true
        guard animated else {
            panel.orderOut(nil)
            return
        }
        host.animateClosed()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowing else { return }
            self.panel?.orderOut(nil)
            // The next notice in line, out of the bare notch again.
            if !self.noticeQueue.isEmpty {
                let next = self.noticeQueue.removeFirst()
                _ = self.present(.notice(next), hold: Self.noticeHold)
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchShapeHostView.closeDuration + 0.05, execute: work)
    }

    private func scheduleHide(after delay: TimeInterval = NotchHUD.hold) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            // Held open under the pointer; leaving it (or ending a drag) reschedules.
            guard !self.view.isDragging, !self.view.isHovered || self.embeddedInDashboard else { return }
            self.hide(animated: true)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Controls

    private func hoverChanged(_ hovering: Bool) {
        guard isShowing else { return }
        if embeddedInDashboard {
            if hovering, case .level(let level)? = view.content, level.kind == .volume {
                view.outputs = outputs()
                relayout()
            }
            if !view.isDragging { scheduleHide(after: Self.hold) }
            return
        }
        if hovering {
            hideWork?.cancel()
            hideWork = nil
            // Resting on a volume HUD offers the other outputs.
            if case .level(let level)? = view.content, level.kind == .volume {
                view.outputs = outputs()
                relayout()
            }
        } else if !view.isDragging {
            scheduleHide(after: Self.leaveHold)
        }
    }

    /// Everything here runs on main: AppKit events and the key tap's callbacks.
    private func drag(_ kind: SystemHUDKind, to value: CGFloat, final: Bool) {
        MainActor.assumeIsolated { applyDrag(kind, to: value, final: final) }
    }

    @MainActor
    private func applyDrag(_ kind: SystemHUDKind, to value: CGFloat, final: Bool) {
        guard let levels else { return }
        switch kind {
        case .volume:
            guard let result = levels.setOutputVolume(value, final: final) else { return }
            // Mid-drag the bar follows the pointer; the device's own reading
            // (Bluetooth outputs round to their steps) lands when it lets go.
            if final { view.setLevel(result.value, muted: result.muted) }
        case .brightness:
            guard let result = levels.setBrightnessLevel(value) else { return }
            if final { view.setLevel(result, muted: false) }
        }
    }

    private func selectOutput(_ uid: String) {
        guard AudioDeviceRouting.select(.output, uid: uid) else { return }
        showCurrentOutput()
        // CoreAudio can take a moment to report the new default's volume.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isShowing else { return }
            self.showCurrentOutput()
        }
    }

    private func showCurrentOutput() {
        guard let state = MainActor.assumeIsolated({ levels?.outputState() }) else { return }
        var level = NotchHUDView.Level(kind: .volume, value: state.value ?? 0, muted: state.muted,
                                       output: state.kind, title: state.name)
        level.unknown = state.value == nil
        _ = present(.level(level))
    }

    private func outputs() -> [NotchHUDView.Output] {
        let snapshot = AudioDeviceRouting.snapshot(.output)
        guard snapshot.devices.count > 1 else { return [] }
        return snapshot.devices.map { device in
            NotchHUDView.Output(uid: device.uid, name: device.name,
                                kind: levels?.audioOutputKind(for: device.id) ?? .speaker,
                                selected: device.uid == snapshot.selectedUID)
        }
    }

    // MARK: Geometry

    private func relayout() {
        guard isShowing, let screen = AgentNotchCard.notchScreen() else { return }
        if embeddedInDashboard {
            _ = AgentNotchCard.shared.presentHUD(view, size: view.cardSize)
            return
        }
        resize(to: frame(for: view.cardSize, on: screen))
    }

    private func frame(for card: CGSize, on screen: NSScreen) -> CGRect {
        CGRect(x: (notch.midX - card.width / 2).rounded(), y: screen.frame.maxY - card.height,
               width: card.width, height: card.height)
    }

    private func cancelResize() {
        resizeCompletion?.cancel()
        resizeCompletion = nil
        resizeTarget = nil
        resizeGeneration += 1
    }

    /// Same motion as the TokenBar card's page changes: the transparent backing
    /// grows once, the silhouette animates inside it, then the backing shrinks.
    private func resize(to target: CGRect) {
        guard let panel, let host else { return }
        // Same size (a new level, a new device name): the contents re-laid out
        // themselves; leave a running open animation alone.
        if target == (resizeTarget ?? panel.frame) { return }
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
        if panel.frame != canvas { panel.setFrame(canvas, display: false) }
        host.layout(notch: notch, in: canvas, cardSize: fromSize)
        host.showOpenInstantly()
        host.animateResize(to: target.size, notch: notch, in: canvas, beginTime: CACurrentMediaTime())
        let generation = resizeGeneration
        let completion = DispatchWorkItem { [weak self] in
            guard let self, self.isShowing, self.resizeGeneration == generation,
                  let panel = self.panel, let host = self.host else { return }
            self.cancelResize()
            panel.setFrame(target, display: false)
            host.layout(notch: self.notch, in: target)
            host.showOpenInstantly()
        }
        resizeCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchTransition.duration, execute: completion)
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        PresentationState.shared.addObserver { [weak self] in
            if !PresentationState.shared.canPresent { self?.hide(animated: false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hide(animated: false)
        }
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

// MARK: - Keyboard input sources

struct InputSourceOption: Equatable {
    let id: String
    let name: String
    let selected: Bool
}

enum InputSources {
    /// The keyboard sources the Input menu offers, in its order.
    static func enabled() -> [InputSourceOption] {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let currentID = current.flatMap { string($0, kTISPropertyInputSourceID) }
        let sources = list()
        // Two sources writing the same script (ABC and U.S.) keep their names.
        let samples = sources.map(sample)
        return sources.enumerated().compactMap { index, source in
            guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
            let shared = samples.filter { $0 != nil && $0 == samples[index] }.count > 1
            let name = (shared ? nil : samples[index]) ?? string(source, kTISPropertyLocalizedName) ?? id
            return InputSourceOption(id: id, name: name, selected: id == currentID)
        }
    }

    /// The first letters of the source's alphabet ("ABC", "กขค"), so the pills
    /// show what each one types; nil for a script not listed here.
    private static func sample(_ source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let language = (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first
        else { return nil }
        return alphabets[language.split(separator: "-").first.map(String.init) ?? language]
    }

    private static let alphabets = [
        "en": "ABC", "th": "กขค", "ja": "あいう", "ko": "가나다", "zh": "中文",
        "ru": "АБВ", "uk": "АБВ", "el": "ΑΒΓ", "he": "אבג", "ar": "أبج",
    ]

    static func select(_ id: String) {
        guard let source = list().first(where: { string($0, kTISPropertyInputSourceID) == id }) else { return }
        TISSelectInputSource(source)
    }

    private static func list() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return sources.filter {
            let type = string($0, kTISPropertyInputSourceType)
            return type == kTISTypeKeyboardLayout as String || type == kTISTypeKeyboardInputMode as String
        }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

// MARK: - Card contents

private final class NotchNotificationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Flipped: laid out from the top of the card, which is the screen's top edge.
/// The icon and the value sit in the notch's side wings; the body below.
final class NotchHUDView: NSView {
    struct Level: Equatable {
        var kind: SystemHUDKind
        var value: CGFloat
        var muted: Bool
        var output: AudioOutputKind?
        var title: String
        /// No level to show: a monitor not read yet, an output without volume.
        var unknown = false
    }

    struct Output: Equatable {
        let uid: String
        let name: String
        let kind: AudioOutputKind
        let selected: Bool
    }

    struct Notice: Equatable {
        let provider: AIProvider
        let title: String
        let detail: String
        let value: String
        /// A finished task's session: a click opens it.
        var link: AgentSessionLink? = nil
    }

    enum Content: Equatable {
        case level(Level)
        case music
        case inputSource(label: String, sources: [InputSourceOption])
        case notice(Notice)
        case charger(ChargerPowerState)
        case systemEvent(SystemNotchEvent)
        case appNotification(NotchAppNotification)
    }

    var onLevel: ((SystemHUDKind, CGFloat, Bool) -> Void)?
    var onMute: (() -> Void)?
    var onSelectOutput: ((String) -> Void)?
    var onSelectSource: ((String) -> Void)? {
        get { picker.onSelect }
        set { picker.onSelect = newValue }
    }
    var onHoverChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onOpenNotice: ((AgentSessionLink) -> Void)?
    var onOpenAppNotification: ((NotchAppNotification) -> Void)?

    private(set) var content: Content?
    private(set) var isHovered = false
    var isDragging: Bool { bar.isDragging }
    var outputs: [Output] = [] {
        didSet { if outputs != oldValue { rebuildRows() } }
    }

    private static let wing: CGFloat = 80
    /// One margin all round: the top row sits this far from the top and the
    /// sides, the body this far below the top row, and the card ends this far
    /// below the body.
    private static let padding: CGFloat = 20
    /// The top row's glyphs (icon, value), about 16 pt tall at their sizes.
    private static let glyph: CGFloat = 16
    private static let rowHeight: CGFloat = 26
    /// Output rows' hover highlight reaches this far out into the margin, so
    /// their icons and checkmarks still line up with the padding.
    private static let rowInset: CGFloat = 8
    /// The selection's slide when the language changes under an open card.
    private static let switchDuration: CFTimeInterval = 0.24

    private var notchSize = CGSize(width: 185, height: 32)
    private var availableSize = CGSize(width: 1200, height: 800)
    private var cachedNotificationMetrics: NotchNotificationMetrics?
    private let icon = NSImageView()
    private let value = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    /// A notice's first line; `title` is its second.
    private let headline = NSTextField(labelWithString: "")
    private let notificationBody = NSTextField(wrappingLabelWithString: "")
    private let notificationScroll = NSScrollView()
    private let notificationDocument = NotchNotificationDocumentView()
    private let bar = NotchLevelBar()
    private let separator = NSView()
    private let picker = NotchSourcePicker()
    private let music = NotchCompactMusicPane()
    private var rows: [NotchHUDRow] = []
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignLeft
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.textColor = .white
        value.alignment = .right
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)
        title.lineBreakMode = .byTruncatingTail
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.textColor = .white
        headline.lineBreakMode = .byTruncatingTail
        notificationBody.font = .systemFont(ofSize: 12, weight: .medium)
        notificationBody.textColor = NSColor(white: 1, alpha: 0.65)
        notificationBody.maximumNumberOfLines = 0
        notificationBody.lineBreakMode = .byWordWrapping
        value.lineBreakMode = .byTruncatingTail
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        bar.onChange = { [weak self] value, final in self?.barMoved(to: value, final: final) }
        bar.onDragEnded = { [weak self] in self?.onDragEnded?() }
        notificationScroll.drawsBackground = false
        notificationScroll.borderType = .noBorder
        notificationScroll.scrollerStyle = .overlay
        notificationScroll.autohidesScrollers = true
        notificationScroll.documentView = notificationDocument
        notificationDocument.addSubview(notificationBody)
        for view in [icon, value, headline, title, notificationScroll, bar, separator, picker, music] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var notificationMetrics: NotchNotificationMetrics? {
        guard case .appNotification(let notice)? = content else { return nil }
        if let cachedNotificationMetrics { return cachedNotificationMetrics }
        let metrics = NotchNotificationMetrics(notice: notice, notch: notchSize, available: availableSize)
        cachedNotificationMetrics = metrics
        return metrics
    }

    var cardWidth: CGFloat { notificationMetrics?.size.width ?? notchSize.width + 2 * Self.wing }
    private var band: CGFloat { notchSize.height }
    private var bodyWidth: CGFloat { cardWidth - 2 * Self.padding }

    // Geometry, from the top of the card.
    private var rowCenter: CGFloat { Self.padding + Self.glyph / 2 }
    /// Never under the notch, whatever its height.
    private var bodyTop: CGFloat { max(Self.padding * 2 + Self.glyph, band + 8) }
    /// A label's frame starts ~3 pt above its capitals.
    private var titleTop: CGFloat { bodyTop - 3 }
    private var noticeDetailTop: CGFloat { titleTop + 21 }
    private var trackTop: CGFloat { titleTop + 16 + 10 }
    private var trackBottom: CGFloat { trackTop + NotchLevelBar.thickness }
    private var rowsTop: CGFloat { trackBottom + 14 + 1 + 6 }

    /// The notification's text block has the same inset on every side:
    /// below the header/notch, from both side edges, and above the bottom.
    private var appNotificationTop: CGFloat { notificationMetrics?.textFrame.minY ?? bodyTop }
    private var appNotificationTitleHeight: CGFloat {
        notificationMetrics?.titleFrame.height ?? 0
    }
    private var appNotificationBodyTop: CGFloat { notificationMetrics?.detailFrame.minY ?? 0 }
    private var appNotificationBodyHeight: CGFloat {
        notificationMetrics?.detailFrame.height ?? 0
    }

    var cardSize: CGSize {
        let height: CGFloat
        switch content {
        case .music?:
            height = bodyTop + 44 + Self.padding
        case .inputSource?:
            height = bodyTop + picker.height(for: bodyWidth) + Self.padding
        case .notice?, .charger?, .systemEvent?:
            // Two lines; the second's frame ends ~3 pt below its letters.
            height = noticeDetailTop + 16 - 3 + Self.padding
        case .appNotification?:
            height = notificationMetrics?.size.height ?? bodyTop + Self.padding
        default:
            if outputs.isEmpty {
                height = trackBottom + Self.padding
            } else {
                // The last row's highlight keeps the same distance from the
                // bottom as from the sides.
                height = rowsTop + CGFloat(outputs.count) * Self.rowHeight + Self.padding - Self.rowInset
            }
        }
        return CGSize(width: cardWidth, height: height)
    }

    func configure(notch: CGSize, available: CGSize) {
        guard notch != notchSize || available != availableSize else { return }
        notchSize = notch
        availableSize = available
        cachedNotificationMetrics = nil
        needsLayout = true
    }

    func apply(_ new: Content, animated: Bool) {
        let swapped: Bool
        switch (content, new) {
        case (.level(let a)?, .level(let b)): swapped = a.kind != b.kind
        case (.inputSource?, .inputSource): swapped = false
        case (.notice(let a)?, .notice(let b)): swapped = a != b
        case (.charger?, .charger): swapped = false
        case (.systemEvent(let a)?, .systemEvent(let b)): swapped = a.id != b.id
        case (.appNotification(let a)?, .appNotification(let b)): swapped = a.id != b.id
        default: swapped = true
        }
        if swapped, animated, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            layer.add(fade, forKey: "swap")
        }
        content = new
        cachedNotificationMetrics = nil
        let isNotification: Bool
        if case .appNotification = new { isNotification = true } else { isNotification = false }
        headline.lineBreakMode = isNotification ? .byWordWrapping : .byTruncatingTail
        headline.maximumNumberOfLines = isNotification ? 0 : 1
        headline.cell?.wraps = isNotification
        value.lineBreakMode = isNotification ? .byWordWrapping : .byTruncatingTail
        value.maximumNumberOfLines = isNotification ? 0 : 1
        value.cell?.wraps = isNotification
        if case .notice(let notice) = new { toolTip = notice.link?.helpText }
        else if case .appNotification(let notice) = new {
            let action = notice.app.isUnresolved ? "Click to open notification" : "Click to open \(notice.app.name)"
            toolTip = "\(notice.app.name)\n\(notice.title)\n\(notice.detail)\n\(action)"
        }
        else { toolTip = nil }
        window?.invalidateCursorRects(for: self)
        if case .music = new { music.setPresented(true) } else { music.setPresented(false) }
        switch new {
        case .music:
            outputs = []
            music.reload()
            renderWing()
        case .level(let level):
            if level.kind != .volume { outputs = [] }
            title.stringValue = level.title
            bar.isEnabled = !level.unknown
            if !bar.isDragging {
                bar.set(level.unknown ? 0 : level.value, muted: level.muted, animated: animated && !swapped)
            }
            renderWing()
        case .inputSource(let label, let sources):
            outputs = []
            renderWing()
            showSources(label: label, sources: sources, open: !animated || swapped)
        case .notice(let notice):
            outputs = []
            headline.stringValue = notice.title
            title.stringValue = notice.detail
            renderWing()
        case .charger(let state):
            outputs = []
            headline.stringValue = state.titleText
            title.stringValue = state.detailText
            renderWing()
        case .systemEvent(let event):
            outputs = []
            headline.stringValue = event.title
            title.stringValue = event.detail
            renderWing()
        case .appNotification(let notice):
            outputs = []
            headline.stringValue = notice.displayTitle
            notificationBody.stringValue = notice.displayDetail
            if swapped { notificationScroll.contentView.scroll(to: .zero) }
            renderWing()
        }
        needsLayout = true
    }

    func refreshMusic() { music.reload() }
    func setMusicPresented(_ presented: Bool) { music.setPresented(presented) }

    /// A switch while the card is already up slides the selection over to the
    /// new source; a fresh open shows it in place, without motion.
    private func showSources(label: String, sources: [InputSourceOption], open: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fromID = open || reduceMotion ? nil : picker.selectedID
        picker.frame.size.width = bodyWidth
        picker.set(sources, slideFrom: fromID, duration: Self.switchDuration)
        value.stringValue = label
    }

    /// The device's own reading at the end of a drag.
    func setLevel(_ level: CGFloat, muted: Bool) {
        guard case .level(var current)? = content else { return }
        current.value = level
        current.muted = muted
        current.unknown = false
        content = .level(current)
        bar.isEnabled = true
        bar.set(level, muted: muted, animated: false)
        renderWing()
    }

    /// Opening afresh: forget the pointer and the outputs list.
    func reset() {
        isHovered = false
        outputs = []
        needsLayout = true
    }

    private func barMoved(to level: CGFloat, final: Bool) {
        guard case .level(var current)? = content else { return }
        current.value = level
        // Dragging the volume up unmutes, like the keys.
        if current.kind == .volume, level > 0 { current.muted = false }
        content = .level(current)
        bar.set(level, muted: current.muted, animated: false)
        renderWing()
        onLevel?(current.kind, level, final)
    }

    private func renderWing() {
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        switch content {
        case .music?:
            icon.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
            value.stringValue = "Music"
        case .level(let level)?:
            icon.image = IndicatorRenderer.systemHUDIcon(
                kind: level.kind, value: level.value, muted: level.muted,
                audioOutputKind: level.output, deviceIcons: AppSettings.shared.systemHUDDeviceIcons,
                pointSize: 14, color: .white)
            if level.unknown {
                value.stringValue = "–"
            } else if level.muted {
                value.stringValue = "Muted"
            } else {
                value.stringValue = "\(Int((level.value * 100).rounded()))%"
            }
        case .notice(let notice)?:
            icon.image = AgentActivityCardView.icon(for: notice.provider).map { mark in
                NSImage(size: NSSize(width: Self.glyph, height: Self.glyph), flipped: false) { rect in
                    mark.draw(in: rect)
                    return true
                }
            }
            value.stringValue = notice.value
        case .charger(let state)?:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            icon.image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: state.titleText)?
                .withSymbolConfiguration(config)
            value.stringValue = state.valueText
        case .systemEvent(let event)?:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            icon.image = NSImage(systemSymbolName: event.symbol, accessibilityDescription: event.title)?
                .withSymbolConfiguration(config)
            value.stringValue = event.value
        case .appNotification(let notice)?:
            let mark = notice.iconData.flatMap { NSImage(data: $0) } ?? (notice.app.isUnresolved
                ? NSImage(systemSymbolName: "app.badge", accessibilityDescription: notice.app.name)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? NSImage()
                : NSWorkspace.shared.icon(forFile: notice.app.path))
            icon.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                mark.draw(in: rect)
                return true
            }
            icon.setAccessibilityLabel(notice.app.name)
            value.font = .systemFont(ofSize: 11, weight: .medium)
            value.stringValue = notice.app.name
        case .inputSource?:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        case nil:
            icon.image = nil
            value.stringValue = ""
        }
    }

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows = outputs.map { output in
            let row = NotchHUDRow(output: output, inset: Self.rowInset)
            row.onClick = { [weak self] in self?.onSelectOutput?(output.uid) }
            addSubview(row)
            return row
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let x0 = ((bounds.width - cardWidth) / 2).rounded()
        let left = x0 + Self.padding
        icon.frame = CGRect(x: left, y: rowCenter - 12, width: 30, height: 24)
        value.frame = CGRect(x: x0 + cardWidth - Self.wing + 8, y: (rowCenter - 8.5).rounded(),
                             width: Self.wing - 8 - Self.padding, height: 17)
        if let metrics = notificationMetrics { value.frame = metrics.sourceFrame.offsetBy(dx: x0, dy: 0) }

        let isLevel: Bool, isNotice: Bool, isMusic: Bool, isAppNotification: Bool
        if case .appNotification? = content { isAppNotification = true } else { isAppNotification = false }
        if case .music? = content { isMusic = true } else { isMusic = false }
        if case .level? = content { isLevel = true } else { isLevel = false }
        switch content {
        case .notice?, .charger?, .systemEvent?: isNotice = true
        default: isNotice = false
        }
        title.isHidden = !isLevel && !isNotice
        headline.isHidden = isAppNotification ? appNotificationTitleHeight == 0 : !isNotice
        notificationBody.isHidden = !isAppNotification || appNotificationBodyHeight == 0
        notificationScroll.isHidden = !isAppNotification || notificationMetrics?.documentHeight == 0
        bar.isHidden = !isLevel
        picker.isHidden = isLevel || isNotice || isMusic || isAppNotification
        music.isHidden = !isMusic
        music.frame = CGRect(x: left, y: bodyTop, width: bodyWidth, height: 44)
        if let metrics = notificationMetrics {
            if headline.superview !== notificationDocument { notificationDocument.addSubview(headline) }
            notificationScroll.frame = metrics.textFrame.offsetBy(dx: x0, dy: 0)
            notificationScroll.hasVerticalScroller = metrics.needsScrolling
            notificationDocument.frame = CGRect(x: 0, y: 0, width: metrics.textFrame.width, height: metrics.documentHeight)
            headline.frame = metrics.titleFrame
            notificationBody.frame = metrics.detailFrame
        } else {
            if headline.superview !== self { addSubview(headline) }
            headline.frame = CGRect(x: left, y: titleTop - 1, width: bodyWidth, height: 17)
        }
        title.frame = CGRect(x: left, y: isNotice ? noticeDetailTop : titleTop, width: bodyWidth, height: 16)
        // The bar's hit area is taller than its track, centred on it.
        bar.frame = CGRect(x: left, y: trackTop - 8, width: bodyWidth, height: NotchLevelBar.thickness + 16)

        separator.isHidden = !isLevel || rows.isEmpty
        separator.frame = CGRect(x: left, y: trackBottom + 14, width: bodyWidth, height: 1)
        for (index, row) in rows.enumerated() {
            row.isHidden = !isLevel
            row.frame = CGRect(x: left - Self.rowInset, y: rowsTop + CGFloat(index) * Self.rowHeight,
                               width: bodyWidth + 2 * Self.rowInset, height: Self.rowHeight)
        }
        picker.frame = CGRect(x: left, y: bodyTop, width: bodyWidth,
                              height: picker.height(for: bodyWidth))
    }

    // MARK: Pointer

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if notificationMetrics?.needsScrolling == true { notificationScroll.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }

    /// The bar, rows and pills take their own clicks; everything else here
    /// (labels, the icon, the black around them) comes to this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !notificationScroll.isHidden, notificationScroll.frame.contains(local) {
            let hit = notificationScroll.hitTest(convert(local, to: notificationScroll.superview))
            if hit is NSTextField || hit === notificationDocument { return self }
            return hit ?? self
        }
        for view in ([bar, picker] as [NSView]) + rows where !view.isHidden && view.frame.contains(local) {
            return view.hitTest(local) ?? self
        }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if case .notice(let notice)? = content, notice.link != nil { addCursorRect(bounds, cursor: .pointingHand) }
        if case .appNotification? = content { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        if case .appNotification(let notice)? = content {
            onOpenAppNotification?(notice)
            return
        }
        if case .notice(let notice)? = content, let link = notice.link {
            onOpenNotice?(link)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard case .level(let level)? = content, level.kind == .volume,
              icon.frame.insetBy(dx: -8, dy: -6).contains(point) else { return }
        onMute?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovered else { return }
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        isHovered = false
        onHoverChanged?(false)
    }
}

// MARK: - Level bar

/// A pill track with a white fill, clipped to the track so the fill's end is
/// square like the system HUD's. Drag anywhere along it to set the level.
final class NotchLevelBar: NSView {
    var onChange: ((CGFloat, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var isEnabled = true { didSet { if isEnabled != oldValue { placeFill() } } }
    private(set) var isDragging = false

    static let thickness: CGFloat = 6
    private let track = CALayer()
    private let fill = CALayer()
    private var level: CGFloat = 0
    private var muted = false
    private var lastSent: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        track.cornerRadius = Self.thickness / 2
        track.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        track.addSublayer(fill)
        layer?.addSublayer(track)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: ((bounds.height - Self.thickness) / 2).rounded(),
                             width: bounds.width, height: Self.thickness)
        placeFill()
        CATransaction.commit()
    }

    func set(_ value: CGFloat, muted: Bool, animated: Bool) {
        let from = fill.presentation()?.bounds.width ?? fill.bounds.width
        level = max(0, min(1, value))
        self.muted = muted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeFill()
        CATransaction.commit()
        fill.removeAnimation(forKey: "level")
        guard animated, from != fill.bounds.width else { return }
        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = from
        grow.toValue = fill.bounds.width
        grow.duration = 0.18
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.5, 1)
        fill.add(grow, forKey: "level")
    }

    private func placeFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = CGRect(x: 0, y: 0, width: (track.bounds.width * level).rounded(), height: Self.thickness)
        fill.position = CGPoint(x: 0, y: Self.thickness / 2)
        fill.backgroundColor = NSColor(white: 1, alpha: muted || !isEnabled ? 0.35 : 1).cgColor
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        follow(event, final: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        follow(event, final: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        follow(event, final: true)
        isDragging = false
        onDragEnded?()
    }

    /// Every pointer move redraws; the level itself is applied at most 30
    /// times a second, and always on release.
    private func follow(_ event: NSEvent, final: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        let value = max(0, min(1, x / max(1, bounds.width)))
        let now = CACurrentMediaTime()
        guard final || now - lastSent >= 1.0 / 30 else {
            set(value, muted: muted, animated: false)
            return
        }
        lastSent = now
        onChange?(value, final)
    }
}

// MARK: - Output row

/// One output in the volume HUD's list; a click makes it the default.
final class NotchHUDRow: NSView {
    var onClick: (() -> Void)?
    private let output: NotchHUDView.Output
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { updateBackground() } }

    private let inset: CGFloat

    /// `inset`: how far the hover highlight reaches past the icon and checkmark.
    /// `icon` replaces the output's own (an input device's microphone).
    init(output: NotchHUDView.Output, inset: CGFloat, icon customIcon: NSImage? = nil) {
        self.output = output
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let tint = NSColor(white: 1, alpha: output.selected ? 1 : 0.7)
        let symbol = NotchAudioDeviceIcon.symbolName(for: output.name)
        let fallback = symbol == "iphone.gen3" ? "iphone" : "laptopcomputer"
        let deviceIcon = symbol.flatMap {
            (NSImage(systemSymbolName: $0, accessibilityDescription: output.name)
             ?? NSImage(systemSymbolName: fallback, accessibilityDescription: output.name))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
        }
        icon.image = deviceIcon ?? customIcon ?? IndicatorRenderer.systemHUDIcon(kind: .volume, value: 1, muted: false,
                                                                   audioOutputKind: output.kind, deviceIcons: true,
                                                                   pointSize: 12, color: tint)
        icon.imageScaling = .scaleNone
        icon.imageAlignment = .alignCenter
        name.stringValue = output.name
        name.font = .systemFont(ofSize: 12.5, weight: output.selected ? .semibold : .regular)
        name.textColor = tint
        name.lineBreakMode = .byTruncatingTail
        if output.selected {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }
        for view in [icon, name, check] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: inset, y: (bounds.height - 18) / 2, width: 18, height: 18)
        check.frame = CGRect(x: bounds.width - inset - 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        name.frame = CGRect(x: inset + 26, y: (bounds.height - 16) / 2,
                            width: bounds.width - 2 * inset - 26 - 24, height: 16)
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.08 : 0).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), !output.selected else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

// MARK: - Input source picker

/// The language HUD's sources as one row of equal pills filling the body, so
/// both margins match. A single white selection slides between them; where it
/// passes, the names turn black (a black copy of the row, masked to it).
final class NotchSourcePicker: NSView {
    var onSelect: ((String) -> Void)?
    private(set) var selectedID: String?

    private static let height: CGFloat = 28
    private static let gap: CGFloat = 8
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private var options: [InputSourceOption] = []
    private var pills: [NotchHUDPill] = []
    private var inkLabels: [NSTextField] = []
    // Not flipped, so their sublayers' coordinates are the plain AppKit ones.
    private let selection = NotchPassthroughView()
    private let ink = NotchPassthroughView()
    private let fill = CAShapeLayer()
    private let inkMask = CAShapeLayer()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        selection.wantsLayer = true
        fill.fillColor = NSColor.white.cgColor
        selection.layer?.addSublayer(fill)
        ink.wantsLayer = true
        inkMask.fillColor = NSColor.black.cgColor
        ink.layer?.mask = inkMask
        addSubview(selection)
        addSubview(ink)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func height(for width: CGFloat) -> CGFloat {
        frames(for: width).map(\.maxY).max() ?? Self.height
    }

    /// New sources or a new selection. The selection slides from `slideFrom`
    /// (or carries on from wherever a running slide is); nil puts it in place.
    func set(_ options: [InputSourceOption], slideFrom: String?, duration: CFTimeInterval) {
        if options.map({ [$0.id, $0.name] }) != self.options.map({ [$0.id, $0.name] }) { rebuild(options) }
        self.options = options
        let newID = options.first(where: \.selected)?.id
        let changed = newID != selectedID
        selectedID = newID
        // Sized now: the slide's paths are computed against this height.
        setFrameSize(NSSize(width: bounds.width, height: height(for: bounds.width)))
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Same selection: whatever slide is running already ends there.
        guard changed || slideFrom != newID else { return }
        slide(from: slideFrom, duration: duration)
    }

    private func rebuild(_ options: [InputSourceOption]) {
        pills.forEach { $0.removeFromSuperview() }
        inkLabels.forEach { $0.removeFromSuperview() }
        pills = options.map { option in
            let pill = NotchHUDPill(name: option.name)
            pill.onClick = { [weak self] in
                guard let self, option.id != self.selectedID else { return }
                self.onSelect?(option.id)
            }
            addSubview(pill, positioned: .below, relativeTo: selection)
            return pill
        }
        inkLabels = options.map { option in
            let label = NotchHUDPill.label(option.name, color: .black)
            ink.addSubview(label)
            return label
        }
    }

    /// As many equal pills per row as the widest name allows, filling the width.
    private func frames(for width: CGFloat) -> [CGRect] {
        guard !pills.isEmpty else { return [] }
        let widest = pills.map(\.preferredWidth).max() ?? 0
        let columns = max(1, min(pills.count, Int((width + Self.gap) / (widest + Self.gap))))
        let pillWidth = (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        return pills.indices.map { index in
            let minX = (CGFloat(index % columns) * (pillWidth + Self.gap)).rounded()
            let maxX = (CGFloat(index % columns) * (pillWidth + Self.gap) + pillWidth).rounded()
            return CGRect(x: minX, y: CGFloat(index / columns) * (Self.height + Self.gap),
                          width: maxX - minX, height: Self.height)
        }
    }

    override func layout() {
        super.layout()
        selection.frame = bounds
        ink.frame = bounds
        for (index, frame) in frames(for: bounds.width).enumerated() {
            pills[index].frame = frame
            inkLabels[index].frame = unflipped(NotchHUDPill.labelFrame(in: frame))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        inkMask.frame = bounds
        // Only the model value: a running slide keeps going toward it.
        let target = path(for: selectedID)
        fill.path = target
        inkMask.path = target
        CATransaction.commit()
    }

    private func unflipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func path(for id: String?) -> CGPath? {
        guard let id, let index = options.firstIndex(where: { $0.id == id }), index < pills.count else { return nil }
        return Self.capsule(unflipped(pills[index].frame))
    }

    private func slide(from previousID: String?, duration: CFTimeInterval) {
        // A slide in flight carries on from where it is now; otherwise from
        // the previous source. No previous source: straight to the new one.
        let running = fill.animation(forKey: "slide") != nil ? fill.presentation()?.path : nil
        guard previousID != nil, let target = path(for: selectedID),
              let from = running ?? path(for: previousID), from != target else {
            fill.removeAnimation(forKey: "slide")
            inkMask.removeAnimation(forKey: "slide")
            return
        }
        let begin = CACurrentMediaTime()
        for layer in [fill, inkMask] {
            let move = CABasicAnimation(keyPath: "path")
            move.fromValue = from
            move.toValue = target
            move.beginTime = begin
            move.duration = duration
            move.timingFunction = NotchTransition.timingFunction
            move.fillMode = .backwards
            layer.add(move, forKey: "slide")
        }
    }

    /// The same elements for any width, so two capsules morph cleanly.
    private static func capsule(_ r: CGRect) -> CGPath {
        let radius = min(r.height, r.width) / 2
        let k: CGFloat = 0.5523 * radius
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addCurve(to: CGPoint(x: r.maxX, y: r.midY),
                      control1: CGPoint(x: r.maxX - radius + k, y: r.minY),
                      control2: CGPoint(x: r.maxX, y: r.midY - k))
        path.addCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY),
                      control1: CGPoint(x: r.maxX, y: r.midY + k),
                      control2: CGPoint(x: r.maxX - radius + k, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addCurve(to: CGPoint(x: r.minX, y: r.midY),
                      control1: CGPoint(x: r.minX + radius - k, y: r.maxY),
                      control2: CGPoint(x: r.minX, y: r.midY + k))
        path.addCurve(to: CGPoint(x: r.minX + radius, y: r.minY),
                      control1: CGPoint(x: r.minX, y: r.midY - k),
                      control2: CGPoint(x: r.minX + radius - k, y: r.minY))
        path.closeSubpath()
        return path
    }
}

/// Drawing only; clicks fall through to the pills beneath.
final class NotchPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One source under the selection: a dim capsule with its name in white.
final class NotchHUDPill: NSView {
    var onClick: (() -> Void)?
    private let name: String
    private let label: NSTextField
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { updateBackground() } }

    var preferredWidth: CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NotchSourcePicker.font]).width) + 28
    }

    static func label(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NotchSourcePicker.font
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = color
        return label
    }

    /// The name's frame for a pill at `frame`, in the same coordinates.
    static func labelFrame(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + 10, y: frame.minY + ((frame.height - 16) / 2).rounded(),
               width: frame.width - 20, height: 16)
    }

    init(name: String) {
        self.name = name
        label = Self.label(name, color: NSColor(white: 1, alpha: 0.8))
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        updateBackground()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.frame = Self.labelFrame(in: bounds)
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.2 : 0.12).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
