import AppKit
import CoreGraphics

// MARK: - External brightness sync
//
// Keeps external monitors' backlight following the built-in panel, so macOS's
// auto-brightness drives them too — and so does anything else that moves the
// built-in panel (the brightness keys, Control Centre). One control covers
// every screen.
//
// DDC sets the pace. The MP341CQ behind a USB-C→HDMI adapter wedges under
// bursts of I2C, and auto-brightness moves the built-in panel in small steps.
// So a monitor is only written when its value would move by at least
// `minDelta`, at most once per `minInterval`, with whatever level is latest;
// and never while the displays are asleep or DisplayInputEngine reports the
// link stalled. DisplayInputEngine adds its own settle window after display
// changes on top of this.
//
// The built-in panel announces its changes (DisplayServices posts
// "DisplayServicesBrightness" with the new value), so nothing polls.

final class ExternalBrightnessSync {
    static let shared = ExternalBrightnessSync()

    private let minInterval: TimeInterval = 1
    private let minDelta = 0.03

    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let register: RegisterFn?
    private let getBrightness: GetFn?

    /// Built-in panels already subscribed to. There's no unsubscribing: the
    /// callback checks the setting instead.
    private var subscribed: Set<CGDirectDisplayID> = []
    /// The level waiting to go out; nil when nothing is due.
    private var pendingLevel: Double?
    private var flushScheduled = false
    private var lastFlush = Date.distantPast
    /// What each monitor was last sent, keyed like `DisplayInputEngine.Monitor.key`.
    private var lastSent: [String: Double] = [:]

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        register = handle.flatMap { dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") }
            .map { unsafeBitCast($0, to: RegisterFn.self) }
        getBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetFn.self) }
    }

    private var enabled: Bool { AppSettings.shared.externalBrightnessSync }

    /// Call at launch and on every display change: subscribes to the built-in
    /// panel if it's new, then brings the monitors in line with it. Main thread.
    func displaysChanged() {
        if let builtin = builtinDisplay(), !subscribed.contains(builtin), let register {
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let status = register(builtin, observer) { _, observer, _, _, _ in
                guard let observer else { return }
                let sync = Unmanaged<ExternalBrightnessSync>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { sync.builtinChanged() }
            }
            if status == 0 { subscribed.insert(builtin) }
        }
        resync()
    }

    /// Sends the built-in panel's level to every monitor, whatever it was sent
    /// before: after a wake or a plug the monitor may have reset itself.
    /// Main thread.
    func resync() {
        lastSent.removeAll()
        builtinChanged()
    }

    private func builtinChanged() {
        guard enabled, let level = builtinLevel() else { return }
        pendingLevel = level
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, minInterval - Date().timeIntervalSince(lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            flushScheduled = false
            flush()
        }
    }

    private func flush() {
        // Asleep, locked or wedged: drop it. The wake resync (or the next
        // change) sends the level that matters then.
        guard enabled, let level = pendingLevel,
              PresentationState.shared.canPresent, !DisplayInputEngine.isStalled
        else { pendingLevel = nil; return }
        pendingLevel = nil
        lastFlush = Date()
        for monitor in DisplayInputEngine.monitors where monitor.reachable {
            if let sent = lastSent[monitor.key], abs(sent - level) < minDelta { continue }
            lastSent[monitor.key] = level
            DisplayInputEngine.setLevel(.brightness, monitorKey: monitor.key, to: level)
        }
    }

    private func builtinLevel() -> Double? {
        guard let getBrightness, let builtin = builtinDisplay() else { return nil }
        var value: Float = 0
        guard getBrightness(builtin, &value) == 0 else { return nil }
        return Double(max(0, min(1, value)))
    }

    private func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }
}
