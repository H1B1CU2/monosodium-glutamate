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

    func start() {
        rescheduleScan()
        
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

    private func refreshState() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: Self.anyInputEvent)
        let userActive = idle < 3.0
        let slideInProgress = slideInProgressProvider?() == true
        guard userActive || isMissionControl || slideInProgress else { return }

        guard !scanInFlight else { return }
        scanInFlight = true

        detectionQueue.async { [weak self] in
            let signals = WindowListScanner.scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.applyDetectedState(mc: signals.missionControlActive)
                self.onMenuBarWindowCount?(signals.menuBarWindowCount)
            }
        }
    }

    private func refreshFullscreen() {
        detectionQueue.async { [weak self] in
            let fs = Self.detectFullscreen()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
