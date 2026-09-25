import AppKit
import CoreGraphics

// Shared, single-source-of-truth helpers used across the app. Previously these
// were copy-pasted into Indicator, WallpaperEngine, SettingsMenu, SettingsWindow,
// CornerWindow, SpaceWatcher and Displaplacer.

// MARK: - System search overlays

/// The Cmd-Space surface: Spotlight, and on newer macOS the Siri "Search or
/// Ask" panel and the Siri AI chat it expands into. They take keyboard focus
/// and can briefly activate, but they are transient overlays — tiling, the
/// control bar and the switchers must behave as if they never appeared.
enum SystemSearchOverlay {
    static let bundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.Siri",
        "com.apple.campo",   // Siri AI.app
    ]

    static func contains(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return bundleIDs.contains(id)
    }

    static func contains(pid: pid_t) -> Bool {
        contains(NSRunningApplication(processIdentifier: pid))
    }

    /// Whether a workspace notification is about one of these overlays.
    static func isAbout(_ note: Notification) -> Bool {
        contains(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }
}

// MARK: - Display rate

/// The tick interval for main-thread animation timers: the fastest attached
/// display's refresh rate (120 Hz ProMotion), stepped down under Low Power
/// Mode or thermal pressure by `TilingDisplayClock.maximumRate`. Only for
/// time-based animations — progress from elapsed time — so a faster tick is
/// smoother, never faster.
enum DisplayRate {
    static var interval: TimeInterval {
        let fastest = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
        return TilingDisplayClock.interval(for: fastest)
    }
}

// MARK: - Presentation power state

/// Whether anything this app draws can currently be seen.
///
/// The app is a collection of repeating timers — SMC sampling at 1-10s, the
/// audio visualiser at 30 Hz, bar animations at 30 Hz. None of them checked
/// whether there was a screen to draw on: with the display asleep, the screen
/// locked, or the user switched to another account, they all kept running,
/// sampling sensors and pushing frames at a menu bar nobody could see. Only
/// `didWake` was observed anywhere, and only to rebuild corner windows.
///
/// Observers are notified on the main thread whenever `canPresent` flips.
final class PresentationState {
    static let shared = PresentationState()

    /// False while the displays are asleep, the screen is locked, or this login
    /// session is inactive.
    private(set) var canPresent: Bool = true

    private var observers: [() -> Void] = []
    private var screensAsleep = false
    private var sessionInactive = false
    private var screenLocked = false

    private init() {
        let nc = NSWorkspace.shared.notificationCenter

        // The lock screen covers the menu bar completely and is by far the most
        // common "not looking at it" state — far more common than display sleep,
        // which only follows it after the Energy Saver timeout. macOS publishes
        // it only as a distributed notification; there is no NSWorkspace
        // equivalent.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.set(screenLocked: true)
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            self?.set(screenLocked: false)
        }
        // Seed from the current state: the app can be launched, or the settings
        // changed, while already locked.
        screenLocked = Self.readScreenLocked()
        // Display sleep and system sleep are distinct: the machine can keep
        // running with the panel dark (Energy Saver display timeout), which is
        // exactly the case that used to burn battery.
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(screensAsleep: true)
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(screensAsleep: false)
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(screensAsleep: true)
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(screensAsleep: false)
        }
        // Fast user switching: our menu bar belongs to a session that is no
        // longer on screen.
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(sessionInactive: true)
        }
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.set(sessionInactive: false)
        }
    }

    /// Called on every transition. Not fired immediately — the caller owns its
    /// own initial state.
    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }

    /// Current lock state, straight from the window server session dictionary.
    private static func readScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
    }

    private func set(screensAsleep: Bool? = nil,
                     sessionInactive: Bool? = nil,
                     screenLocked: Bool? = nil) {
        if let screensAsleep { self.screensAsleep = screensAsleep }
        if let sessionInactive { self.sessionInactive = sessionInactive }
        if let screenLocked { self.screenLocked = screenLocked }
        let next = !self.screensAsleep && !self.sessionInactive && !self.screenLocked
        guard next != canPresent else { return }
        canPresent = next
        NSLog("[Power] canPresent = %@ (asleep=%@ locked=%@ inactive=%@)",
              next ? "true" : "false",
              self.screensAsleep ? "y" : "n",
              self.screenLocked ? "y" : "n",
              self.sessionInactive ? "y" : "n")
        observers.forEach { $0() }
    }
}

// MARK: - Display identity

enum DisplayID {
    /// Stable UUID string for a CoreGraphics display ID, or nil if unresolved.
    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
    }
}

extension NSScreen {
    /// Stable UUID string for this screen, or nil if it can't be resolved.
    var uuid: String? {
        guard let dID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return DisplayID.uuid(dID)
    }

    /// True if this is the built-in display (laptop screen).
    var isBuiltin: Bool {
        guard let dID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return self == NSScreen.screens.first
        }
        return CGDisplayIsBuiltin(dID) != 0
    }
}

// MARK: - Display geometry

/// Human-readable position of `screen` relative to `other` (e.g. "Above & Left").
func displayPosition(for screen: NSScreen, relativeTo other: NSScreen) -> String {
    let e = screen.frame, m = other.frame
    var h = "", v = ""
    if e.maxX <= m.minX { h = "Left" } else if e.minX >= m.maxX { h = "Right" }
    if e.minY >= m.maxY { v = "Above" } else if e.maxY <= m.minY { v = "Below" }
    if h.isEmpty && v.isEmpty { return "Overlapping" }
    if h.isEmpty { return v }
    if v.isEmpty { return h }
    return "\(v) & \(h)"
}

// MARK: - Menu bar item spacing

/// Adjusts the global macOS menu bar item spacing/padding, mirroring the
/// `beyondthecode-bc/MenuBarSpacing` tool. These two undocumented keys live in
/// the per-host global domain (`~/Library/Preferences/ByHost/.GlobalPreferences…`).
/// macOS reads them when a status-item owner launches, so a full effect requires
/// a logout/restart — `refreshMenuBar()` is only a best-effort live nudge.
enum MenuBarSpacingManager {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"

    /// macOS default for both keys when unset.
    static let systemDefault = 16
    static let spacingRange: ClosedRange<Int> = 0...30
    static let paddingRange: ClosedRange<Int> = 0...20

    /// Writes both keys to the per-host global domain.
    static func apply(spacing: Int, padding: Int) {
        write(spacingKey, spacing)
        write(paddingKey, padding)
    }

    /// Removes both keys, restoring macOS defaults.
    static func reset() {
        delete(spacingKey)
        delete(paddingKey)
    }

    /// Writes the values, restarts the system menu bar so its own items pick up
    /// the change immediately, then offers a logout for any third-party items
    /// that only read the value when their owning app launches.
    static func applyAndOfferLogout(spacing: Int, padding: Int) {
        apply(spacing: spacing, padding: padding)
        restartMenuBar()
        promptLogout()
    }

    /// Restarts the system menu bar processes. launchd relaunches both
    /// immediately, so the system icons re-read the new spacing.
    static func restartMenuBar() {
        killall("ControlCenter")
        killall("SystemUIServer")
    }

    /// Triggers a standard macOS logout (shows the system confirmation dialog).
    static func logOut() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to log out"])
    }

    private static func promptLogout() {
        let alert = NSAlert()
        alert.messageText = "Menu bar spacing applied"
        alert.informativeText = "The system menu bar was restarted, so its icons update now. Third-party menu bar icons only pick up the new spacing after you log out.\n\nLog out now to apply everywhere?"
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            logOut()
        }
    }

    // MARK: Private

    private static func write(_ key: String, _ value: Int) {
        defaults(["-currentHost", "write", "-globalDomain", key, "-int", String(value)])
    }

    private static func delete(_ key: String) {
        defaults(["-currentHost", "delete", "-globalDomain", key])
    }

    private static func defaults(_ args: [String]) {
        run("/usr/bin/defaults", args)
    }

    private static func killall(_ name: String) {
        run("/usr/bin/killall", [name])
    }

    private static func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("MenuBarSpacingManager: \(launchPath) \(args) failed: \(error)")
        }
    }
}

// MARK: - Hardware

enum MacModel {
    /// Marketing model name (e.g. "MacBook Pro"), resolved once via system_profiler.
    static let name: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: data, encoding: .utf8),
               let line = out.components(separatedBy: "\n").first(where: { $0.contains("Model Name") }),
               let name = line.split(separator: ":").last {
                return name.trimmingCharacters(in: .whitespaces)
            }
        } catch {}
        return "Mac"
    }()
}

// MARK: - Haptic Feedback

enum HapticFeedback {
    private typealias MTDeviceCreateListFunc = @convention(c) () -> CFArray?
    private typealias MTDeviceGetDeviceIDFunc = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias MTActuatorCreateFromDeviceIDFunc = @convention(c) (UInt64) -> UnsafeMutableRawPointer?
    private typealias MTActuatorOpenFunc = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias MTActuatorActuateFunc = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32
    private typealias MTActuatorCloseFunc = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private typealias CGSMainConnectionIDFunc = @convention(c) () -> Int32
    private typealias SLSActuateDeviceWithPatternFunc = @convention(c) (Int32, UInt64, Int32, Int32) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)
    private static let devListFn: MTDeviceCreateListFunc? = handle.flatMap { dlsym($0, "MTDeviceCreateList") }.map { unsafeBitCast($0, to: MTDeviceCreateListFunc.self) }
    private static let devGetIDFn: MTDeviceGetDeviceIDFunc? = handle.flatMap { dlsym($0, "MTDeviceGetDeviceID") }.map { unsafeBitCast($0, to: MTDeviceGetDeviceIDFunc.self) }
    private static let actCreateFn: MTActuatorCreateFromDeviceIDFunc? = handle.flatMap { dlsym($0, "MTActuatorCreateFromDeviceID") }.map { unsafeBitCast($0, to: MTActuatorCreateFromDeviceIDFunc.self) }
    private static let actOpenFn: MTActuatorOpenFunc? = handle.flatMap { dlsym($0, "MTActuatorOpen") }.map { unsafeBitCast($0, to: MTActuatorOpenFunc.self) }
    private static let actActuateFn: MTActuatorActuateFunc? = handle.flatMap { dlsym($0, "MTActuatorActuate") }.map { unsafeBitCast($0, to: MTActuatorActuateFunc.self) }
    private static let actCloseFn: MTActuatorCloseFunc? = handle.flatMap { dlsym($0, "MTActuatorClose") }.map { unsafeBitCast($0, to: MTActuatorCloseFunc.self) }

    private static let slHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let cidFn: CGSMainConnectionIDFunc? = slHandle.flatMap { dlsym($0, "CGSMainConnectionID") }.map { unsafeBitCast($0, to: CGSMainConnectionIDFunc.self) }
    private static let slActuateFn: SLSActuateDeviceWithPatternFunc? = slHandle.flatMap { dlsym($0, "SLSActuateDeviceWithPattern") }.map { unsafeBitCast($0, to: SLSActuateDeviceWithPatternFunc.self) }

    /// Triggers trackpad haptic feedback (works unconditionally even for background/LSUIElement apps).
    /// actuationType 1 is standard click; 2 is double tap; 3 is subtle tick; 6 is detent.
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment, actuationType: Int32 = 1) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)

        guard let devListFn, let devGetIDFn,
              let actCreateFn, let actOpenFn,
              let actActuateFn, let actCloseFn else { return }

        guard let devices = devListFn() as? [AnyObject] else { return }
        for dev in devices {
            let devPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(dev).toOpaque())
            var devID: UInt64 = 0
            guard devGetIDFn(devPtr, &devID) == 0 else { continue }
            guard let actuator = actCreateFn(devID) else { continue }
            if actOpenFn(actuator) == 0 {
                _ = actActuateFn(actuator, actuationType, 0, 0.0, 0.0)
                _ = actCloseFn(actuator)
            }
        }
    }

    private static let tickQueue = DispatchQueue(label: "msg.haptic-tick", qos: .userInteractive)
    /// Actuators opened once and kept, touched only on `tickQueue`.
    private static var tickActuators: [UnsafeMutableRawPointer] = []

    /// A subtle detent for rapid repeated steps — a swipe passing item after
    /// item. `perform` re-lists the devices and opens and closes an actuator
    /// each call, on the calling thread; at swipe rate that stalled the main
    /// thread. This keeps the actuators open and runs off the main thread.
    static func tick() {
        tickQueue.async {
            if tickActuators.isEmpty {
                guard let devListFn, let devGetIDFn, let actCreateFn, let actOpenFn,
                      let devices = devListFn() as? [AnyObject] else { return }
                for dev in devices {
                    var devID: UInt64 = 0
                    let devPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(dev).toOpaque())
                    guard devGetIDFn(devPtr, &devID) == 0, let actuator = actCreateFn(devID),
                          actOpenFn(actuator) == 0 else { continue }
                    tickActuators.append(actuator)
                }
            }
            guard let actActuateFn else { return }
            var failed = false
            for actuator in tickActuators where actActuateFn(actuator, 3, 0, 0.0, 0.0) != 0 {
                failed = true
            }
            // A trackpad that went away leaves a dead actuator; reopen next time.
            if failed {
                tickActuators.forEach { _ = actCloseFn?($0) }
                tickActuators = []
            }
        }
    }

    /// Triggers a harder/firmer tactile haptic punch.
    /// Combines Force Click (actuation 5) with reinforced pulse (actuation 1),
    /// SkyLight window server actuation, and standard AppKit performer.
    static func performHarder() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        if let cidFn, let slActuateFn {
            _ = slActuateFn(cidFn(), 0, 15, 0)
        }

        guard let devListFn, let devGetIDFn,
              let actCreateFn, let actOpenFn,
              let actActuateFn, let actCloseFn else { return }

        guard let devices = devListFn() as? [AnyObject] else { return }
        for dev in devices {
            let devPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(dev).toOpaque())
            var devID: UInt64 = 0
            guard devGetIDFn(devPtr, &devID) == 0 else { continue }
            guard let actuator = actCreateFn(devID) else { continue }
            if actOpenFn(actuator) == 0 {
                _ = actActuateFn(actuator, 5, 0, 0.0, 0.0)
                _ = actActuateFn(actuator, 1, 0, 0.0, 0.0)
                _ = actCloseFn(actuator)
            }
        }
    }
}
