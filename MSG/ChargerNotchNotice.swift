import AppKit
import IOKit.ps

/// The adapter capacity macOS reports, kept separate from live system draw.
struct ChargerPowerState: Equatable {
    let connected: Bool
    let adapterWatts: Int?
    let batteryPercent: Int?
    let charging: Bool?

    var titleText: String { connected ? "Power connected" : "Power disconnected" }
    var symbolName: String {
        guard !connected else { return "powerplug.fill" }
        let level = Int((Double(batteryPercent ?? 100) / 25).rounded()) * 25
        return "battery.\(level)percent"
    }
    var valueText: String {
        connected ? adapterWatts.map { "\($0) W" } ?? "–"
            : batteryPercent.map { "\($0)%" } ?? "–"
    }
    var wingText: String {
        connected ? adapterWatts.map { "\($0) W adapter" } ?? "Power connected"
            : batteryPercent.map { "Unplugged · \($0)%" } ?? "Power disconnected"
    }
    var detailText: String {
        guard connected else { return "Running on battery" }
        guard adapterWatts != nil else { return "Adapter wattage unavailable" }
        guard let batteryPercent else { return "Power adapter connected" }
        let state = charging == true ? "Charging" : batteryPercent == 100 ? "Fully charged"
            : charging == false ? "Charging paused" : nil
        return "\(batteryPercent)% battery" + (state.map { " · \($0)" } ?? "")
    }

    static func read() -> ChargerPowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details["Type"] as? String == "InternalBattery" else { continue }
            let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
            return parse(source: details, adapter: adapter)
        }
        return nil
    }

    static func parse(source: [String: Any], adapter: [String: Any]?) -> ChargerPowerState? {
        guard let power = source["Power Source State"] as? String,
              power == "AC Power" || power == "Battery Power" else { return nil }
        let connected = power == "AC Power"
        let watts = (adapter?["Watts"] as? NSNumber)?.intValue
        let current = (source["Current Capacity"] as? NSNumber)?.doubleValue
        let maximum = (source["Max Capacity"] as? NSNumber)?.doubleValue
        let percent: Int?
        if let current, let maximum, current.isFinite, maximum.isFinite, maximum > 0 {
            percent = Int(min(100, max(0, current / maximum * 100)).rounded())
        } else { percent = nil }
        return ChargerPowerState(connected: connected,
                                 adapterWatts: connected ? watts.flatMap { $0 > 0 ? $0 : nil } : nil,
                                 batteryPercent: percent, charging: source["Is Charging"] as? Bool)
    }
}

/// Seed quietly on launch. Charging pauses, percentages and PD negotiation
/// updates aren't new cable attachments.
struct ChargerConnectionTracker {
    /// AC and adapter watts can arrive before the battery starts charging.
    /// Keep a fresh attachment neutral while those separate updates settle.
    static let settlingDuration: TimeInterval = 3
    private(set) var latest: ChargerPowerState?
    private var attachedAt: Date?

    mutating func update(_ state: ChargerPowerState, at now: Date = Date()) -> Bool {
        let attached = latest?.connected == false && state.connected
        if attached { attachedAt = now }
        if !state.connected { attachedAt = nil }
        latest = state
        return attached
    }

    func isSettling(at now: Date = Date()) -> Bool {
        guard latest?.connected == true, let attachedAt else { return false }
        return now.timeIntervalSince(attachedAt) < Self.settlingDuration
    }

    func noticeState(at now: Date = Date()) -> ChargerPowerState? {
        guard let latest else { return nil }
        guard latest.charging == false, isSettling(at: now) else { return latest }
        // Unknown here means "connected, waiting for the charging status";
        // never invent Charging or mistake the initial false for a pause.
        return ChargerPowerState(connected: latest.connected, adapterWatts: latest.adapterWatts,
                                 batteryPercent: latest.batteryPercent, charging: nil)
    }
}

/// An event-driven power listener independent of the hardware-stats setting.
/// Short retries cover USB-C/MagSafe negotiation; there is no idle polling.
final class ChargerNotchNotice {
    static let shared = ChargerNotchNotice()
    private static let adapterWait: TimeInterval = 2.75

    private var started = false
    private var source: CFRunLoopSource?
    private var settleWork: DispatchWorkItem?
    private var tracker = ChargerConnectionTracker()
    private var pending: (state: ChargerPowerState, at: Date, ready: Bool)?
    private var generation = 0
    private let readPowerState: () -> ChargerPowerState?
    private var enabled: Bool { AppSettings.shared.notchChargerNotice }

    init(readPowerState: @escaping () -> ChargerPowerState? = ChargerPowerState.read) {
        self.readPowerState = readPowerState
    }

    func start() {
        guard !started else { return }
        started = true
        PresentationState.shared.addObserver { [weak self] in self?.flush() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.powerChanged()
        }
        settingChanged()
    }

    func settingChanged() {
        guard enabled else {
            generation += 1
            settleWork?.cancel()
            settleWork = nil
            pending = nil
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            source = nil
            NotchHUD.shared.dismissCharger()
            return
        }
        guard source == nil else { return }
        tracker = ChargerConnectionTracker()
        if let state = readPowerState() { _ = tracker.update(state) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<ChargerNotchNotice>.fromOpaque(context).takeUnretainedValue().powerChanged()
        }, context)?.takeRetainedValue() else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func read(at now: Date = Date()) {
        guard let state = readPowerState() else { return }
        let detached = tracker.latest?.connected == true && !state.connected
        let attached = tracker.update(state, at: now)
        guard let noticeState = tracker.noticeState(at: now) else { return }
        if attached || detached { pending = (noticeState, now, false) }
        if pending != nil { pending?.state = noticeState }
        NotchHUD.shared.updateCharger(noticeState)
    }

    func powerChanged() {
        guard enabled, source != nil else { return }
        generation += 1
        read()
        schedule(after: 0.25)
    }

    private func schedule(after delay: TimeInterval) {
        settleWork?.cancel()
        let generation = self.generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, generation == self.generation else { return }
            self.settleWork = nil
            let now = Date()
            self.read(at: now)
            // Give a new adapter up to 2.75 s to publish Watts before falling
            // back to an honest unavailable label. Never reuse the old adapter.
            let waitingForWatts = self.pending.map {
                $0.state.connected && $0.state.adapterWatts == nil
                    && now.timeIntervalSince($0.at) < Self.adapterWait
            } ?? false
            if self.pending != nil, !waitingForWatts {
                self.pending?.ready = true
                self.flush()
            }
            // Showing the card clears pending, but the charging flag may still
            // be stale. Continue bounded reads even if macOS sends no more events.
            if self.tracker.isSettling(at: now) || waitingForWatts {
                self.schedule(after: 0.5)
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flush() {
        guard enabled, let pending, pending.ready else { return }
        guard tracker.latest?.connected == pending.state.connected,
              Date().timeIntervalSince(pending.at) < 15 else {
            self.pending = nil
            return
        }
        if NotchHUD.shared.showCharger(pending.state) {
            self.pending = nil
        } else {
            // A drop/lock may temporarily own the notch. Keep only this fresh
            // power transition, and let a newer connection change replace it.
            schedule(after: 1)
        }
    }
}
