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

    // MARK: Internals

    private var pollTimer: Timer?
    private var quiesceWorkItem: DispatchWorkItem?
    private let quiesceWindowSec: TimeInterval = 0
    private let detectionQueue = DispatchQueue(label: "msg.sysstate.detect", qos: .userInteractive)

    private var fsObservers: [NSObjectProtocol] = []

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
        
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

    private func refreshState() {
        detectionQueue.async { [weak self] in
            let mc = MissionControlDetector.isActive()
            DispatchQueue.main.async { [weak self] in
                self?.applyDetectedState(mc: mc)
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
