import AppKit
import AudioToolbox
import Carbon
import QuartzCore
import IOKit.ps

// Isolated routing/timer tests: no windows, audio capture, permissions or personal data.
enum SystemHUDKind: Equatable { case volume, brightness }
enum AudioOutputKind: Equatable { case speaker, airPodsPro, airPods, headphones, nothingHeadphone, displaySpeaker }
enum AIProvider: String { case codex }
struct AgentSessionLink: Equatable {
    static var opens = 0
    func open() { Self.opens += 1 }
}
enum IndicatorRenderer {
    static func systemHUDIcon(kind: SystemHUDKind, value: CGFloat, muted: Bool,
                              audioOutputKind: AudioOutputKind?, deviceIcons: Bool,
                              pointSize: CGFloat, color: NSColor) -> NSImage? { nil }
}
enum CortexWing {
    static var events: [NotchWingEvent] = []
    static func show(_ event: NotchWingEvent, hold: TimeInterval) { events.append(event) }
}
enum MacModel { static let name = "MacBook Pro" }
struct InputSourceOption: Equatable { let id: String }
enum InputSources {
    static func enabled() -> [InputSourceOption] { [] }
    static func select(_ id: String) {}
}
final class MusicMonitor {
    var currentTitle: String? = "Song A"
    var currentArtist: String? = "Artist"
    var currentSourceBundleID: String? = "Music"
    private var observers: [() -> Void] = []
    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }
    func notify() { observers.forEach { $0() } }
}
final class PresentationState {
    static let shared = PresentationState()
    var canPresent = true
    var observers: [() -> Void] = []
    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }
}
final class AppSettings {
    static let shared = AppSettings()
    var notchAgentCard = true
    var notchPreviewEnabled = false
    var notchDisabledPanes: [String] = []
    var notchNoticeSound = false
    var systemHUDDeviceIcons = true
}
final class NotchDropZone { static let shared = NotchDropZone(); let isShowing = false }
final class SystemNotificationNotch {
    static let shared = SystemNotificationNotch()
    var ended: [String] = []
    var opened: [String] = []
    func openApp(_ notice: NotchAppNotification) { opened.append(notice.id) }
    func cardEnded(_ id: String) { ended.append(id) }
}
final class SystemHUDMonitor {
    var brightnessDisplayName: String { "MacBook Pro Display" }
    struct State { var value: CGFloat?; let muted: Bool; let kind: AudioOutputKind; let name: String }
    struct Result { let value: CGFloat; let muted: Bool }
    func outputState() -> State? { nil }
    func toggleMute() {}
    func setOutputVolume(_ value: CGFloat, final: Bool) -> Result? { nil }
    func setBrightnessLevel(_ value: CGFloat) -> CGFloat? { value }
    func audioOutputKind(for id: UInt32) -> AudioOutputKind { .speaker }
}
enum AudioDeviceRouting {
    struct Device { let uid: String; let name: String; let id: UInt32 }
    struct Snapshot { let devices: [Device]; let selectedUID: String? }
    enum Direction { case output }
    static func select(_ direction: Direction, uid: String) -> Bool { false }
    static func snapshot(_ direction: Direction) -> Snapshot { Snapshot(devices: [], selectedUID: nil) }
}
final class NotchPanel: NSPanel {}
enum NotchTransition {
    static let duration: TimeInterval = 0.01
    static let windowLevel = NSWindow.Level.statusBar
    static func canvas(from: CGRect, to: CGRect) -> CGRect { to }
}
final class NotchShapeHostView: NSView {
    static let closeDuration: TimeInterval = 0.01
    var presentedCardSize = CGSize.zero
    init(content: NSView) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func layout(notch: CGRect, in frame: CGRect, cardSize: CGSize? = nil) {}
    func showOpenInstantly() {}
    func animateOpen() {}
    func animateClosed() {}
    func animateResize(to: CGSize, notch: CGRect, in frame: CGRect, beginTime: CFTimeInterval) {}
}
final class AgentNotchCard {
    static let shared = AgentNotchCard()
    var isSuppressedByCortex = false
    var presentations = 0
    var restores: [Bool] = []
    var currentHUD: NotchHUDView?
    var wingEnabled = false
    var wingEvents: [NotchWingEvent] = []
    func showVolumeInAudioPane() -> Bool { false }
    func showWing(_ event: NotchWingEvent, hold: TimeInterval) -> Bool {
        guard wingEnabled else { return false }
        wingEvents.append(event)
        return true
    }
    static func notchScreen() -> NSScreen? { NSScreen.main }
    static func notchRect(_ screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - 92.5, y: screen.frame.maxY - 32, width: 185, height: 32)
    }
    func presentHUD(_ view: NSView, size: CGSize) -> Bool {
        presentations += 1
        currentHUD = view as? NotchHUDView
        return true
    }
    func restoreAfterHUD(animated: Bool, resume: Bool) { restores.append(resume) }
    func openSession(_ link: AgentSessionLink) { link.open() }
    func yieldToHUD() { fatalError("An open dashboard must use its existing window") }
}
final class NotchHUDView: NSView {
    struct Level: Equatable {
        var kind: SystemHUDKind; var value: CGFloat; var muted: Bool
        var output: AudioOutputKind?; var title: String; var unknown = false
    }
    struct Output { let uid: String; let name: String; let kind: AudioOutputKind; let selected: Bool }
    struct Notice: Equatable {
        var provider: AIProvider = .codex
        let title: String
        var value = ""
        var link: AgentSessionLink? = nil
    }
    enum Content: Equatable {
        case level(Level), music, inputSource(label: String, sources: [InputSourceOption]), notice(Notice)
        case charger(ChargerPowerState)
        case systemEvent(SystemNotchEvent)
        case appNotification(NotchAppNotification)
    }
    var onLevel: ((SystemHUDKind, CGFloat, Bool) -> Void)?
    var onMute: (() -> Void)?
    var onSelectOutput: ((String) -> Void)?
    var onSelectSource: ((String) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var onOpenNotice: ((AgentSessionLink) -> Void)?
    var onOpenAppNotification: ((NotchAppNotification) -> Void)?
    var content: Content?
    var outputs: [Output] = []
    var isHovered = false
    var isDragging = false
    let cardSize = CGSize(width: 345, height: 128)
    func configure(notch: CGSize, available: CGSize) {}
    func apply(_ new: Content, animated: Bool) { content = new }
    func reset() { isHovered = false; outputs = [] }
    func setLevel(_ value: CGFloat, muted: Bool) {}
    func refreshMusic() {}
    func setMusicPresented(_ presented: Bool) {}
}

// PRODUCTION_NOTCH_HUD_CONTROLLER

@main
struct NotchHUDControllerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let card = AgentNotchCard.shared
        let hud = NotchHUD.shared
        let music = MusicMonitor()
        hud.attachMusic(music)
        music.notify()
        precondition(!hud.isShowing && card.presentations == 0, "No startup music popup")
        music.notify()
        precondition(card.presentations == 0, "No progress/duplicate popup")
        music.currentTitle = "Song B"
        music.notify()
        precondition(hud.isShowing && card.currentHUD!.content == .music)
        let before = card.presentations
        music.notify()
        precondition(card.presentations == before)
        precondition(hud.show(kind: .volume, value: 0.5, muted: false, audioOutputKind: .speaker))
        precondition(hud.show(kind: .brightness, value: 0.8, muted: false, audioOutputKind: nil))
        if case .level(let level)? = card.currentHUD!.content { precondition(level.kind == .brightness) }
        else { preconditionFailure("Brightness must replace volume") }
        card.currentHUD!.isHovered = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.65))
        precondition(!hud.isShowing && card.restores == [true], "Return to the dashboard even with the pointer still over it")
        precondition(hud.show(kind: .volume, value: 0.5, muted: false, audioOutputKind: .speaker))
        card.currentHUD!.isDragging = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.65))
        precondition(hud.isShowing, "Do not dismiss an active drag")
        card.currentHUD!.isDragging = false
        card.currentHUD!.onDragEnded?()
        RunLoop.main.run(until: Date().addingTimeInterval(1.65))
        precondition(!hud.isShowing && card.restores == [true, true])
        precondition(hud.show(kind: .brightness, value: 0.5, muted: false, audioOutputKind: nil))
        hud.hide(animated: false, resumeDashboard: false)
        precondition(!hud.isShowing && card.restores.last == false, "Closing must not reopen the dashboard")
        AppSettings.shared.notchDisabledPanes = ["music"]
        music.currentTitle = "Song C"
        music.notify()
        precondition(!hud.isShowing, "Respect the disabled music pane")
        precondition(hud.showNotice(.init(title: "Task finished")))
        if case .notice(let notice)? = card.currentHUD!.content { precondition(notice.title == "Task finished") }
        else { preconditionFailure("Notices must use the open dashboard surface") }
        hud.hide(animated: false)
        precondition(card.restores.last == true)
        let link = AgentSessionLink()
        precondition(hud.showNotice(.init(title: "Clickable task", link: link)))
        card.currentHUD!.onOpenNotice?(link)
        precondition(!hud.isShowing && card.restores.last == false && AgentSessionLink.opens == 1,
                     "A notice click opens once and does not restore the dashboard")
        let charger = ChargerPowerState(connected: true, adapterWatts: 60, batteryPercent: 86, charging: true)
        precondition(hud.showCharger(charger))
        precondition(card.currentHUD!.content == .charger(charger), "Power uses the existing HUD surface")
        let paused = ChargerPowerState(connected: true, adapterWatts: 60, batteryPercent: 87, charging: false)
        let powerSurface = card.currentHUD
        hud.updateCharger(paused)
        precondition(card.currentHUD!.content == .charger(paused) && card.currentHUD === powerSurface,
                     "Charging updates the existing card view")
        let unplugged = ChargerPowerState(connected: false, adapterWatts: nil, batteryPercent: 87, charging: false)
        precondition(hud.showCharger(unplugged) && card.currentHUD!.content == .charger(unplugged)
                     && card.currentHUD === powerSurface,
                     "An unplug event replaces the charger card on the same surface")
        RunLoop.main.run(until: Date().addingTimeInterval(4.15))
        precondition(!hud.isShowing, "The unplug card returns to the dashboard after four seconds")
        let awake = SystemNotchEvent.amphetamine(true)
        precondition(hud.showSystemEvent(awake) && card.currentHUD!.content == .systemEvent(awake))
        precondition(!hud.showSystemEvent(.warp(true)), "Different app events wait instead of erasing a visible card")
        let stopped = SystemNotchEvent.amphetamine(false)
        precondition(hud.showSystemEvent(stopped) && card.currentHUD!.content == .systemEvent(stopped),
                     "The same app's new state updates its existing card")
        hud.dismissSystemEvent(kind: .warp)
        precondition(hud.isShowing, "Disabling WARP must not dismiss an Amphetamine card")
        hud.dismissSystemEvent(kind: .amphetamine)
        precondition(!hud.isShowing)
        precondition(hud.showCharger(charger))
        hud.dismissCharger()
        precondition(!hud.isShowing, "Disabling the charger notice dismisses the power card")
        precondition(hud.showNotice(.init(title: "Keep this notice")))
        hud.dismissCharger()
        hud.updateCharger(charger)
        precondition(hud.isShowing && card.currentHUD!.content == .notice(.init(title: "Keep this notice")),
                     "Power events must not dismiss or alter another notice")
        hud.hide(animated: false)
        PresentationState.shared.canPresent = false
        precondition(!hud.showCharger(charger), "A locked screen does not present a power card")
        PresentationState.shared.canPresent = true
        card.wingEnabled = true
        precondition(hud.showCharger(charger) && !hud.isShowing)
        precondition(card.wingEvents.last?.id == "charger" && card.wingEvents.last?.text == "60 W adapter",
                     "An open dashboard shows the power event in its wing")
        precondition(hud.showCharger(unplugged) && !hud.isShowing)
        precondition(card.wingEvents.last?.text == "Unplugged · 87%" && card.wingEvents.last?.symbol == unplugged.symbolName,
                     "The dashboard wing distinguishes an unplug from an attachment")
        card.wingEnabled = false
        let app = NotchNotificationApp(id: "test.messages", name: "Messages", path: "/Applications/Messages.app", aliases: ["Messages"])
        let message = NotchAppNotification(id: "banner-1", app: app, title: "Hello", subtitle: "", body: "A new message")
        card.wingEnabled = true
        precondition(hud.showAppNotification(message) && hud.isShowingAppNotification(message.id),
                     "Messages use a readable card rather than the dashboard wing")
        let endedBefore = SystemNotificationNotch.shared.ended.count
        precondition(hud.showAppNotification(message), "Hydration may update the same banner")
        let hydratedMessage = NotchAppNotification(id: message.id, app: app, title: message.title, subtitle: "", body: "Updated preview")
        precondition(hud.showAppNotification(hydratedMessage))
        precondition(SystemNotificationNotch.shared.ended.count == endedBefore, "An identical update must not restore its native banner")
        precondition(hud.showCharger(charger), "Power may preempt an app card")
        precondition(SystemNotificationNotch.shared.ended.last == message.id, "Preemption restores the native banner")
        hud.dismissCharger()
        precondition(hud.showAppNotification(message))
        card.currentHUD!.onOpenAppNotification?(message)
        precondition(!hud.isShowing && SystemNotificationNotch.shared.opened == [message.id], "A card click opens its source app")
        precondition(SystemNotificationNotch.shared.ended.count == endedBefore + 2, "Closing restores each native lease once")
        hud.hide(animated: false)
        precondition(SystemNotificationNotch.shared.ended.count == endedBefore + 2)
        card.wingEnabled = false
        card.isSuppressedByCortex = true
        precondition(!hud.showAppNotification(message), "Keep native banners when Cortex owns the notch")
        precondition(hud.showCharger(charger) && !hud.isShowing)
        precondition(CortexWing.events.last?.id == "charger" && CortexWing.events.last?.symbol == "powerplug.fill",
                     "Cortex receives the same power event")
        precondition(hud.showCharger(unplugged) && !hud.isShowing)
        precondition(CortexWing.events.last?.text == "Unplugged · 87%" && CortexWing.events.last?.symbol == unplugged.symbolName,
                     "Cortex receives the disconnected battery event")
        print("HUD routing, timers, charger updates, unplug cards and dashboard/Cortex wings passed")
    }
}
