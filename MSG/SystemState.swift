import AppKit
import ApplicationServices

/// Tracks Mission Control + fullscreen state so consumers can gate
/// snapshot mutations and animation triggers.
///
/// MC detection uses CGWindowList via `MissionControlDetector`: while Mission
/// Control / App Exposé is open, the `WindowManager` process adds overlay
/// windows ("Spaces Bar", "Expose Overlay", "ExposeShieldWindow") at small
/// positive CGWindowLayers that don't exist on the idle desktop. This is
/// reliable where Dock-frontmost and didActivate/didDeactivate are not.
final class SystemState {

    // MARK: Public

    private(set) var isStable: Bool = true
    private(set) var isFullscreen: Bool = false
    private(set) var isMissionControl: Bool = false

    var didEnterUnstable: (() -> Void)?
    var onChange: (() -> Void)?
    var didStabilize: (() -> Void)?

    /// Published on every scan so the slide detector can consume the menu-bar-pair
    /// count without paying for a second window-list dump.
    var onMenuBarWindowCount: ((Int) -> Void)?
    var slideInProgressProvider: (() -> Bool)?

    /// 30 Hz while the slide detector is listening (the menu-bar-pair signal is the
    /// only slide-start tell for fullscreen-space switches and needs to be caught
    /// within a frame or two); 0.12 s otherwise, which is all Mission Control
    /// detection has ever needed.
    private var scanInterval: TimeInterval { onMenuBarWindowCount == nil ? 0.12 : 1.0 / 30.0 }

    // MARK: Internals

    private var pollTimer: Timer?
    private var quiesceWorkItem: DispatchWorkItem?
    private let quiesceWindowSec: TimeInterval = 0
    private let detectionQueue = DispatchQueue(label: "msg.sysstate.detect", qos: .userInteractive)
    private var scanInFlight = false

    private var fsObservers: [NSObjectProtocol] = []

    func rescheduleScan() {
        pollTimer?.invalidate()
        let wanted = scanInterval
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        t.tolerance = wanted * 0.15
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    /// The display SP8CE's page full screen covers: it has no full screen Space for the checks here
    /// to find, so SP8CE says so (heard by the Edge Keys strip), and it counts as full screen —
    /// while the desktop Space it went full screen on is the one showing. The display's other
    /// Spaces have nothing full screen on them.
    private(set) static var pageFullscreenDisplay: String? {
        didSet { if pageFullscreenDisplay != oldValue { NotificationCenter.default.post(name: pageFullscreenChanged, object: nil) } }
    }
    static let pageFullscreenChanged = Notification.Name("H1D3S1GN.MSG.pageFullscreenChanged")
    /// SP8CE's page full screen as it said: the display, and the Space showing there then.
    private static var pageFullscreen: (display: String, space: UInt64?)?
    private static var pageFullscreenSpaceObserver: NSObjectProtocol?

    /// SP8CE's page went full screen on `display` (on the Space showing there now), or left it (nil).
    static func setPageFullscreen(display: String?) {
        pageFullscreen = display.map { ($0, currentSpace(on: $0)) }
        if pageFullscreenSpaceObserver == nil {
            pageFullscreenSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { _ in refreshPageFullscreen() }
        }
        refreshPageFullscreen()
    }

    private static func refreshPageFullscreen() {
        guard let page = pageFullscreen else { pageFullscreenDisplay = nil; return }
        let current = currentSpace(on: page.display)
        // A Space that can't be read counts as SP8CE's, as before Spaces were told apart.
        pageFullscreenDisplay = page.space == nil || current == nil || current == page.space ? page.display : nil
    }

    private static func currentSpace(on display: String) -> UInt64? {
        NSScreen.screens.first { $0.uuid?.caseInsensitiveCompare(display) == .orderedSame }
            .flatMap(WindowPreviewCapture.currentManagedSpaceID(for:))
    }

    func start() {
        rescheduleScan()
        fsObservers.append(NotificationCenter.default.addObserver(
            forName: Self.pageFullscreenChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFullscreen() })
        
        fsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFullscreen() })
        fsObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshFullscreen() })

        refreshState()
        refreshFullscreen()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        quiesceWorkItem?.cancel(); quiesceWorkItem = nil
        fsObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        fsObservers.removeAll()
    }

    deinit { stop() }

    // MARK: - State refresh

    private static let anyInputEvent = CGEventType(rawValue: UInt32.max)!

    /// Posted on the main queue when a Touch ID prompt appears or goes away;
    /// `userInfo["visible"]` is the new state.
    static let touchIDPromptChanged = Notification.Name("MSGTouchIDPromptChanged")
    private(set) var touchIDPromptVisible = false
    private var lastIdleScanAt: CFTimeInterval = 0

    private func refreshState() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: Self.anyInputEvent)
        let userActive = idle < 3.0
        let slideInProgress = slideInProgressProvider?() == true
        // A Touch ID prompt waits on a finger, which isn't an input event:
        // keep watching so its close is seen without the user touching anything.
        // Idle, one slow pass a second still catches a Touch ID prompt a
        // background app raises while nobody is at the keyboard.
        let now = CACurrentMediaTime()
        guard userActive || isMissionControl || slideInProgress || touchIDPromptVisible
                || now - lastIdleScanAt >= 1 else { return }
        if !userActive { lastIdleScanAt = now }

        guard !scanInFlight else { return }
        scanInFlight = true

        detectionQueue.async { [weak self] in
            let signals = WindowListScanner.scan(maxAge: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.applyDetectedState(mc: signals.missionControlActive)
                if signals.touchIDPromptVisible != self.touchIDPromptVisible {
                    self.touchIDPromptVisible = signals.touchIDPromptVisible
                    NotificationCenter.default.post(name: SystemState.touchIDPromptChanged, object: nil,
                                                    userInfo: ["visible": signals.touchIDPromptVisible])
                }
                self.onMenuBarWindowCount?(signals.menuBarWindowCount)
            }
        }
    }

    private func refreshFullscreen() {
        detectionQueue.async { [weak self] in
            let detected = Self.detectFullscreen()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let fs = detected || Self.pageFullscreenDisplay != nil
                if fs != self.isFullscreen {
                    self.isFullscreen = fs
                    self.onChange?()
                }
            }
        }
    }

    private func applyDetectedState(mc: Bool) {
        let wasStable = isStable

        if mc != isMissionControl {
            isMissionControl = mc
            if mc {
                // Entering MC
                quiesceWorkItem?.cancel(); quiesceWorkItem = nil
                isStable = false
                if wasStable { didEnterUnstable?() }
            } else {
                // Exiting MC — quiesce before declaring stable
                scheduleStabilize()
            }
            onChange?()
        }
    }

    private func scheduleStabilize() {
        quiesceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isStable = true
            self.didStabilize?()
            self.onChange?()
        }
        quiesceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quiesceWindowSec, execute: work)
        onChange?()
    }

    // MARK: - Detection

    static func detectFullscreen() -> Bool {
        if !NSMenu.menuBarVisible() { return true }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return false }
        var fsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, "AXFullScreen" as CFString, &fsRef) == .success else { return false }
        return (fsRef as? NSNumber)?.boolValue == true
    }
}
