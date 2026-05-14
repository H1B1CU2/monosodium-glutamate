import AppKit
import ApplicationServices

/// Tracks Mission Control + fullscreen state so consumers can gate
/// snapshot mutations and animation triggers.
///
/// MC detection uses CGWindowList: during Mission Control, Dock creates
/// temporary windows at CGWindowLayer 15-25 for space previews. These
/// windows exist only during MC. This is reliable where Dock-frontmost
/// and didActivate/didDeactivate are not.
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

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
        refreshState()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        quiesceWorkItem?.cancel(); quiesceWorkItem = nil
    }

    deinit { stop() }

    // MARK: - State refresh

    private func refreshState() {
        let mc = MissionControlDetector.isActive()
        let fs = Self.detectFullscreen()
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

        if fs != isFullscreen {
            isFullscreen = fs
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
