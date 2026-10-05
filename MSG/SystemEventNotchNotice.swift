import AppKit

struct SystemNotchEvent: Equatable {
    static let hold: TimeInterval = 4
    enum Kind { case amphetamine, display, warp }
    let kind: Kind
    let id: String
    let title: String
    let detail: String
    let value: String
    let symbol: String
    var wingText: String { "\(title) · \(value)" }

    static func amphetamine(_ active: Bool) -> Self {
        Self(kind: .amphetamine, id: "amphetamine", title: "Amphetamine",
             detail: active ? "Keeping this Mac awake" : "Keep-awake session ended",
             value: active ? "On" : "Off", symbol: "cup.and.saucer.fill")
    }

    static func warp(_ connected: Bool) -> Self {
        Self(kind: .warp, id: "cloudflare-warp", title: "Cloudflare WARP",
             detail: connected ? "1.1.1.1 connected" : "1.1.1.1 disconnected",
             value: connected ? "On" : "Off", symbol: "network")
    }
}

/// Unknown reads preserve the last known state. The first valid read seeds
/// quietly, and only subsequent changes produce a card.
struct SystemStateChangeTracker {
    private(set) var latest: Bool?
    mutating func update(_ state: Bool?) -> Bool? {
        guard let state else { return nil }
        let changed = latest.map { $0 != state } ?? false
        latest = state
        return changed ? state : nil
    }
}

struct SystemDisplaySnapshot: Equatable {
    let id: String
    let name: String
}

struct DisplayConnectionTracker {
    private var latest: [String: SystemDisplaySnapshot]?
    mutating func update(_ displays: [SystemDisplaySnapshot]?) -> [SystemNotchEvent] {
        guard let displays else { return [] }
        let current = Dictionary(displays.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        defer { latest = current }
        guard let latest else { return [] }
        let removed = latest.keys.filter { current[$0] == nil }.sorted()
        let added = current.keys.filter { latest[$0] == nil }.sorted()
        return removed.compactMap { latest[$0].map { Self.event($0, connected: false) } }
            + added.compactMap { current[$0].map { Self.event($0, connected: true) } }
    }

    private static func event(_ display: SystemDisplaySnapshot, connected: Bool) -> SystemNotchEvent {
        SystemNotchEvent(kind: .display, id: "display-\(display.id)",
                         title: connected ? "Display connected" : "Display disconnected",
                         detail: display.name, value: connected ? "On" : "Off", symbol: "display")
    }
}

struct SystemNotchEventQueue {
    private struct Pending { let event: SystemNotchEvent; let at: Date }
    private var pending: [Pending] = []
    mutating func enqueue(_ event: SystemNotchEvent, at now: Date = Date()) {
        pending.removeAll { $0.event.id == event.id }
        pending.append(Pending(event: event, at: now))
    }
    mutating func next(at now: Date = Date()) -> SystemNotchEvent? {
        pending.removeAll { now.timeIntervalSince($0.at) >= 30 }
        return pending.first?.event
    }
    mutating func remove(_ event: SystemNotchEvent) { pending.removeAll { $0.event == event } }
    mutating func remove(kind: SystemNotchEvent.Kind) { pending.removeAll { $0.event.kind == kind } }
}

/// Read-only event monitoring: display snapshots contain no DDC transactions;
/// Amphetamine queries never start a session, and WARP is only refreshed.
final class SystemEventNotchNotice {
    static let shared = SystemEventNotchNotice()
    private var started = false
    private var amphetamineTracker = SystemStateChangeTracker()
    private var warpTracker = SystemStateChangeTracker()
    private var displayTracker = DisplayConnectionTracker()
    private var events = SystemNotchEventQueue()
    private var pollTimer: Timer?
    private var displayWork: DispatchWorkItem?
    private var presentWork: DispatchWorkItem?
    private var presentAfter = Date.distantPast
    private let presentEvent: (SystemNotchEvent) -> Bool
    private var amphetamineProcess: Process?
    private var amphetamineGeneration = 0
    private var watchingAmphetamine = false
    private var watchingWARP = false
    private var watchingDisplays = false

    init(presentEvent: @escaping (SystemNotchEvent) -> Bool = { NotchHUD.shared.showSystemEvent($0) }) {
        self.presentEvent = presentEvent
    }

    func start() {
        guard !started else { return }
        started = true
        PresentationState.shared.addObserver { [weak self] in self?.flush() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.displaysChanged()
        }
        CloudflareWARP.shared.addObserver { [weak self] in self?.warpChanged() }
        settingChanged()
    }

    func settingChanged() {
        let settings = AppSettings.shared
        if watchingAmphetamine != settings.notchAmphetamineNotice {
            watchingAmphetamine = settings.notchAmphetamineNotice
            amphetamineGeneration += 1
            amphetamineProcess?.terminate()
            amphetamineProcess = nil
            amphetamineTracker = SystemStateChangeTracker()
            events.remove(kind: .amphetamine)
            if !watchingAmphetamine { NotchHUD.shared.dismissSystemEvent(kind: .amphetamine) }
        }
        if watchingWARP != settings.notchWARPNotice {
            watchingWARP = settings.notchWARPNotice
            warpTracker = SystemStateChangeTracker()
            events.remove(kind: .warp)
            if !watchingWARP { NotchHUD.shared.dismissSystemEvent(kind: .warp) }
        }
        if watchingDisplays != settings.notchDisplayNotice {
            watchingDisplays = settings.notchDisplayNotice
            displayWork?.cancel()
            displayWork = nil
            displayTracker = DisplayConnectionTracker()
            _ = displayTracker.update(Self.readDisplays())
            events.remove(kind: .display)
            if !watchingDisplays { NotchHUD.shared.dismissSystemEvent(kind: .display) }
        }
        pollTimer?.invalidate()
        pollTimer = nil
        if watchingAmphetamine || watchingWARP {
            poll()
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        flush()
    }

    private func poll() {
        if watchingAmphetamine { readAmphetamine() }
        if watchingWARP, CloudflareWARP.executableURL != nil { CloudflareWARP.shared.refresh() }
    }

    private func readAmphetamine() {
        guard amphetamineProcess == nil else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.if.Amphetamine").isEmpty else {
            amphetamineChanged(false)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
        if application id "com.if.Amphetamine" is running then
            tell application id "com.if.Amphetamine" to session is active
        end if
        """]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let generation = amphetamineGeneration
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            timeout.cancel()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let active: Bool? = finished.terminationStatus == 0 ? (text == "true" ? true : text == "false" ? false : nil) : nil
            DispatchQueue.main.async {
                guard let self, generation == self.amphetamineGeneration else { return }
                self.amphetamineProcess = nil
                self.amphetamineChanged(active)
            }
        }
        do {
            try process.run()
            amphetamineProcess = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        } catch {
            // Preserve the last known session; a failed read isn't an Off event.
        }
    }

    func amphetamineToggled() {
        guard watchingAmphetamine else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.readAmphetamine() }
    }

    private func amphetamineChanged(_ active: Bool?) {
        guard watchingAmphetamine, let changed = amphetamineTracker.update(active) else { return }
        enqueue(.amphetamine(changed))
    }

    private func warpChanged() {
        guard watchingWARP else { return }
        let connected: Bool?
        switch CloudflareWARP.shared.state {
        case .connected: connected = true
        case .disconnected: connected = false
        default: connected = nil
        }
        guard let changed = warpTracker.update(connected) else { return }
        enqueue(.warp(changed))
    }

    private func displaysChanged() {
        guard watchingDisplays else { return }
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.watchingDisplays else { return }
            self.displayWork = nil
            for event in self.displayTracker.update(Self.readDisplays()) { self.enqueue(event) }
        }
        displayWork = work
        // MSG's automatic relink temporarily disables a panel for 1.2–1.5 s.
        // Observe the final connection, rather than presenting that bounce.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func enqueue(_ event: SystemNotchEvent) {
        events.enqueue(event)
        flush()
    }

    private func flush() {
        presentWork?.cancel()
        presentWork = nil
        guard let event = events.next() else { return }
        let wait = presentAfter.timeIntervalSinceNow
        if wait > 0 {
            retryPresentation(after: wait)
            return
        }
        guard presentEvent(event) else {
            retryPresentation(after: 1)
            return
        }
        events.remove(event)
        // Wings don't set NotchHUD.isShowing. Reserve the same hold there so
        // simultaneous events cannot overwrite each other in a single turn.
        presentAfter = Date().addingTimeInterval(SystemNotchEvent.hold)
        if events.next() != nil { retryPresentation(after: SystemNotchEvent.hold) }
    }

    private func retryPresentation(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func readDisplays() -> [SystemDisplaySnapshot]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0,
                  CGDisplayIsActive(id) != 0 || CGDisplayIsAsleep(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let name = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }?.localizedName ?? "External display"
            return SystemDisplaySnapshot(id: CFUUIDCreateString(nil, uuid) as String, name: name)
        }
    }
}
