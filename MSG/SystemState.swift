import AppKit
import ApplicationServices

/// Tracks Mission Control + fullscreen state and surfaces a single
/// `isStable` flag that downstream consumers should gate on.
///
/// The animation bug this solves:
/// When Mission Control is dismissed from a fullscreen app, the system
/// briefly reports a different "active display" before settling back. If
/// downstream state (previousActiveDisplayIndex, previousSpaces) is updated
/// with these transient values, exit‑MC triggers a spurious focus animation.
///
/// SystemState exposes two pieces of information consumers need:
///   1. `isStable` — current snapshot is trustworthy
///   2. `didStabilize` — fires once when the system returns to a stable
///      state; consumers should use it to atomically resync without
///      triggering animation
final class SystemState {

    // MARK: Public

    /// True when MC is not active and we're past any post‑MC settling window.
    private(set) var isStable: Bool = true

    /// Cached fullscreen flag for the currently focused display.
    private(set) var isFullscreen: Bool = false

    /// Cached Mission Control flag.
    private(set) var isMissionControl: Bool = false

    /// Fired on any stability/fullscreen change. Consumers re-render.
    var onChange: (() -> Void)?

    /// Fired exactly once when the system transitions from unstable to stable.
    /// Consumers should resync their "previous state" to current observations
    /// without triggering any animations.
    var didStabilize: (() -> Void)?

    // MARK: Internals

    private var dockActivateObs: NSObjectProtocol?
    private var dockDeactivateObs: NSObjectProtocol?
    private var pollTimer: Timer?
    private var quiesceWorkItem: DispatchWorkItem?

    /// Time after MC exits that we still consider unstable. Lets CGS settle.
    private let quiesceWindowSec: TimeInterval = 0.45

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        dockActivateObs = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self?.enterUnstable()
        }
        dockDeactivateObs = nc.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.dock" else { return }
            self?.scheduleStabilize()
        }

        // Light poll for fullscreen state (menubar/AXFullScreen). 0.3s is fine,
        // since fullscreen toggles are user‑driven and not perf‑critical.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refreshDerivedState()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
        refreshDerivedState()
    }

    func stop() {
        if let o = dockActivateObs   { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = dockDeactivateObs { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        dockActivateObs = nil; dockDeactivateObs = nil
        pollTimer?.invalidate(); pollTimer = nil
        quiesceWorkItem?.cancel(); quiesceWorkItem = nil
    }

    deinit { stop() }

    // MARK: - State transitions

    private func enterUnstable() {
        quiesceWorkItem?.cancel(); quiesceWorkItem = nil
        let wasStable = isStable
        isMissionControl = true
        isStable = false
        if wasStable { onChange?() }
    }

    private func scheduleStabilize() {
        isMissionControl = false
        // Even after Dock loses focus, CGS reads may not have caught up yet.
        // Wait a short window before declaring ourselves stable again.
        quiesceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isStable = true
            self.refreshDerivedState()
            self.didStabilize?()
            self.onChange?()
        }
        quiesceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quiesceWindowSec, execute: work)
        // Push a re-render so UI doesn't look frozen during the quiesce window.
        onChange?()
    }

    // MARK: - Fullscreen sensing

    private func refreshDerivedState() {
        let fs = Self.detectFullscreen()
        if fs != isFullscreen {
            isFullscreen = fs
            onChange?()
        }
    }

    /// True if the focused app is in macOS fullscreen mode. Two signals:
    ///   1. Menu bar hidden — robust default
    ///   2. AXFullScreen on the focused window — backup
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
