import IOKit
import AppKit
import Darwin

// ---------------------------------------------------------------------------
// Mach / sysctl runtime bindings
//
// All C functions are resolved via dlsym (Pattern B from MusicMonitor) so
// missing symbols never become linker errors — they just return nil at
// runtime and the monitor returns 0 for that metric.
// ---------------------------------------------------------------------------

private func machSym<T>(_ name: String) -> T? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

// -- host_statistics (CPU load) --------------------------------------------

private typealias HostStatisticsFunc = @convention(c) (
    mach_port_t, Int32, UnsafeMutablePointer<host_cpu_load_info_data_t>?,
    UnsafeMutablePointer<mach_msg_type_number_t>
) -> kern_return_t

private let _host_statistics: HostStatisticsFunc? = machSym("host_statistics")

// -- host_statistics64 (VM / memory) ---------------------------------------

private typealias HostStatistics64Func = @convention(c) (
    mach_port_t, Int32, UnsafeMutablePointer<vm_statistics64_data_t>?,
    UnsafeMutablePointer<mach_msg_type_number_t>
) -> kern_return_t

private let _host_statistics64: HostStatistics64Func? = machSym("host_statistics64")

// -- mach_host_self --------------------------------------------------------

private typealias MachHostSelfFunc = @convention(c) () -> mach_port_t
private let _mach_host_self: MachHostSelfFunc? = machSym("mach_host_self")

// -- sysctlbyname ----------------------------------------------------------

private typealias SysctlbynameFunc = @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?,
    UnsafeMutablePointer<Int>?, UnsafeMutableRawPointer?, Int
) -> Int32

private let _sysctlbyname: SysctlbynameFunc? = machSym("sysctlbyname")

// -- vm_page_size (global int) --------------------------------------------

private typealias VmPageSizePtr = UnsafeMutablePointer<Int32>
private let _vm_page_size_ptr: VmPageSizePtr? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vm_page_size") else {
        return nil
    }
    return sym.assumingMemoryBound(to: Int32.self)
}()

// -- SkyLight WindowServer frame counter ------------------------------------
//
// SLSGetPerformanceTotalUpdateCount returns the WindowServer's cumulative
// presented-frame count plus a monotonic timestamp (same data Quartz Debug's
// frame meter reads). Delta between polls = real rendering FPS, unlike
// CGDisplayModeGetRefreshRate which only reports the panel's fixed Hz.

private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
private typealias SLSGetPerformanceTotalUpdateCountFunc = @convention(c) (
    Int32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<Double>
) -> Int32

private let _SLSMainConnectionID: SLSMainConnectionIDFunc? = machSym("SLSMainConnectionID")
private let _SLSGetPerformanceTotalUpdateCount: SLSGetPerformanceTotalUpdateCountFunc? =
    machSym("SLSGetPerformanceTotalUpdateCount")

// -- Flame constants -------------------------------------------------------

private let HOST_CPU_LOAD_INFO: Int32 = 3
private let HOST_VM_INFO64: Int32      = 4
private let CPU_STATE_USER   = 0
private let CPU_STATE_SYSTEM = 1
private let CPU_STATE_IDLE   = 2
private let CPU_STATE_NICE   = 3

/// Build a 4-char-code SMC key (UInt32) from a string, e.g. "TC0D".
private func smcFourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

// ---------------------------------------------------------------------------
// FanInfo
// ---------------------------------------------------------------------------

struct FanInfo: Identifiable {
    var id: Int { index }
    let index: Int
    let name: String
    let current: Int     // RPM
    let min: Int
    let max: Int
}

// ---------------------------------------------------------------------------
// HardwareStats
// ---------------------------------------------------------------------------

struct HardwareStats {
    var cpuPercent: Double = 0
    var gpuPercent: Double = 0
    var memoryPressure: MemoryPressure = .normal
    var memoryUsedGB: Double = 0
    var memoryTotalGB: Double = 0
    var cpuTemp: Double? = nil   // °C, nil = unavailable
    var gpuTemp: Double? = nil
    var fps: Int = 0             // frames actually presented per second (0 = idle screen)
    var fans: [FanInfo] = []
    var powerWatts: Double? = nil // system power draw, nil = unavailable
    var isCharging: Bool? = nil   // nil = no battery / charge state unknown (e.g. desktop Mac)
    var adapterWatts: Int? = nil  // rated wattage of the connected AC adapter, nil = none connected
    var batteryPercent: Int? = nil // 0–100 charge level, nil = no battery
    var batteryRawPercent: Double? = nil // raw charge estimate used for one decimal while charging
    var chargeLimitPercent: Int? = nil // user-set macOS charge limit %, nil = none/unknown
    var isLowPowerMode: Bool = false

    enum MemoryPressure: String {
        case normal  = "N"
        case warning = "W"
        case critical = "C"
    }

    func batteryPercentText(includeSymbol: Bool = true) -> String? {
        guard let percent = batteryPercent else { return nil }
        let value: String
        if isCharging == true, let raw = batteryRawPercent {
            value = String(format: "%.2f", raw)
        } else {
            value = "\(percent)"
        }
        return value + (includeSymbol ? "%" : "")
    }
}

// ---------------------------------------------------------------------------
// HardwareMonitor
// ---------------------------------------------------------------------------

final class HardwareMonitor {

    static let shared = HardwareMonitor()

    private var timer: Timer?
    private var batteryTimer: Timer?
    private var fpsTimer: Timer?
    private var hardwarePollInterval = 2.0
    private var observers: [() -> Void] = []

    private(set) var stats = HardwareStats()

    /// Previous CPU tick snapshot for delta computation.
    private var prevCPU: [UInt32]?

    /// Last non-nil AdapterDetails.Watts while on AC. The key drops out of
    /// the IORegistry for a beat during PD renegotiation; falling back to the
    /// held value keeps the adapter label from flickering (same
    /// previous-value pattern as SpaceWatcher).
    private var lastAdapterWatts: Int?

    /// Smooth one-second charge estimate between the battery controller's
    /// coarse raw-capacity publications.
    private var estimatedChargePercent: Double?
    private var estimatedChargeTimestamp: TimeInterval?
    private var estimatedChargeWholePercent: Int?

    /// Number of logical CPUs (including hyperthreading).
    private var cpuCount: Int32 = 0

    private init() {
        PresentationState.shared.addObserver { [weak self] in
            self?.restartPollingIfNeeded()
        }
    }

    // MARK: - Observer list

    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }
    private func notify() { observers.forEach { $0() } }

    // MARK: - Power history

    /// Recent system wattage, oldest first, for the popover's watt graph.
    ///
    /// Sampling is driven by the poll timer, so the spacing between points is
    /// whatever interval the user picked — the graph is "the last N readings",
    /// not a fixed time window, which is why it carries no time axis.
    private(set) var powerHistory: [Double] = []
    /// Dynamic sample limit, configured in Settings.
    var powerHistoryLimit: Int { max(2, AppSettings.shared.hardwareStatsPowerSamples) }

    /// Appended once per completed sweep. A poll that resolves no wattage
    /// contributes nothing rather than a fake zero, which would draw a cliff
    /// down to the axis that never happened.
    private func recordPowerSample() {
        guard let w = stats.powerWatts, w.isFinite, w >= 0 else { return }
        powerHistory.append(w)
        trimPowerHistory()
    }

    func trimPowerHistory() {
        let trim = {
            let limit = self.powerHistoryLimit
            if self.powerHistory.count > limit {
                self.powerHistory.removeFirst(self.powerHistory.count - limit)
            }
        }
        if Thread.isMainThread {
            trim()
        } else {
            DispatchQueue.main.async(execute: trim)
        }
    }

    // MARK: - Demand Gating & Lifecycle

    private var demandTokens = 0

    func retainPolling() {
        demandTokens += 1
        if demandTokens == 1 { restartPollingIfNeeded() }
    }

    func releasePolling() {
        demandTokens = max(0, demandTokens - 1)
        if demandTokens == 0 { restartPollingIfNeeded() }
    }

    private var wantsPolling: Bool {
        // A fan preset puts the fans in SMC *manual* mode at whatever RPM the
        // curve last wrote, and manual mode survives both display sleep and app
        // relaunch. Stop polling and `applyFanCurve()` stops with it — the fans
        // would then hold that RPM while the machine keeps working with the
        // display off (a build running past the Energy Saver timeout). So the
        // presentation gate applies only when the curve isn't driving anything.
        let drivingFans = AppSettings.shared.hardwareStatsFanPreset != "default"
            || fansForced || helperFanControlActive
        if !drivingFans, !PresentationState.shared.canPresent { return false }
        return AppSettings.shared.hardwareStatsEnabled || demandTokens > 0
    }

    private func restartPollingIfNeeded() {
        if wantsPolling {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard timer == nil else { return }
        // Open the SMC connection for temperature / fan reads.
        _ = SMCController.open()
        stats.memoryTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if let sb = _sysctlbyname {
            var count: Int32 = 0
            var size = MemoryLayout<Int32>.size
            _ = sb("hw.logicalcpu", &count, &size, nil, 0)
            cpuCount = count
        }
        if cpuCount < 1 { cpuCount = Int32(ProcessInfo.processInfo.activeProcessorCount) }

        timer = Timer.scheduledTimer(withTimeInterval: hardwarePollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = hardwarePollInterval * 0.15
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollFPS()
        }
        fpsTimer?.tolerance = 0.15
        if let t = fpsTimer { RunLoop.current.add(t, forMode: .common) }
        poll()
        pollFPS()

        // The SMC keeps manual fan mode across app relaunches, but the
        // ownership flags don't. Reconcile once after launch: re-apply a
        // persisted performance preset, or release fans a previous run
        // (crash, Xcode stop, quit with dead helper) left stuck in manual.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            let preset = AppSettings.shared.hardwareStatsFanPreset
            if preset != "default" {
                self.applySelectedFanPresetFromUser()
            } else if self.anyFanManual() {
                NSLog("[HW] leftover manual fan control detected at launch — resetting to auto")
                self.fanReset()
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        batteryTimer?.invalidate(); batteryTimer = nil
        fpsTimer?.invalidate(); fpsTimer = nil
    }

    /// True while the sampling timers are live — what the popover header's
    /// status dot reports.
    var isPolling: Bool { timer != nil }

    func updateInterval(_ seconds: Double) {
        let clamped = max(1.0, min(10.0, seconds))
        hardwarePollInterval = clamped
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = clamped * 0.15
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
        updateBatteryPollingState()
    }

    // MARK: - Poll

    /// Serialises every SMC sensor sweep, off the main thread.
    ///
    /// Temps and fans are the expensive half of a poll: each SMC key costs two
    /// `IOConnectCallStructMethod` round trips into the kernel, and a sweep
    /// covers every live temperature sensor plus four keys per fan. Running
    /// that inline on main blocked the run loop — and therefore the menu bar
    /// animations — for the whole sweep, once per poll interval.
    private let sensorQueue = DispatchQueue(label: "msg.hardware.sensors", qos: .utility)
    /// Main-only. Drops a sweep if the previous one is still running rather
    /// than queueing them up behind a slow SMC (same guard as
    /// `SystemState.scanInFlight`).
    private var sensorSampleInFlight = false

    private func poll() {
        stats.cpuPercent = readCPU()
        stats.gpuPercent = readGPU()
        readMemory()
        // While charging, power/battery has its own 1-second timer. Avoid
        // duplicating that read on the slower general hardware poll.
        if batteryTimer == nil { readPower() }
        stats.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        updateBatteryPollingState()
        sampleSensors()
    }

    /// Sweeps temps + fans on `sensorQueue`, then applies them on main. The fan
    /// curve runs from here rather than from `poll()` because it needs the
    /// temperatures this sweep produced.
    private func sampleSensors() {
        guard !sensorSampleInFlight else {
            // A dropped sweep must not drop the fan curve with it: the curve is
            // a control loop, and skipping a cycle means the fans hold their
            // last RPM. Re-run it against the temperatures we already have.
            recordPowerSample()
            applyFanCurve()
            // Still publish the cheap readings poll() just took.
            notify()
            return
        }
        sensorSampleInFlight = true
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let temps = self.sampleTemps()
            let fans = self.sampleFans()
            DispatchQueue.main.async {
                self.sensorSampleInFlight = false
                self.stats.cpuTemp = temps.cpu
                self.stats.gpuTemp = temps.gpu
                self.stats.fans = fans
                self.recordPowerSample()
                self.applyFanCurve()
                self.notify()
            }
        }
    }

    /// Raw charge capacity changes quickly enough to make a decimal useful,
    /// so sample battery state once per second while actively charging. Other
    /// hardware sensors retain the interval selected in Settings.
    private func updateBatteryPollingState() {
        let needsDedicatedTimer = stats.isCharging == true && hardwarePollInterval > 1.0
        if needsDedicatedTimer, batteryTimer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.readPower()
                self.recordPowerSample()
                self.updateBatteryPollingState()
                self.notify()
            }
            t.tolerance = 0.15 // sampling - let kernel coalesce
            RunLoop.current.add(t, forMode: .common)
            batteryTimer = t
        } else if !needsDedicatedTimer, batteryTimer != nil {
            batteryTimer?.invalidate()
            batteryTimer = nil
        }
    }

    private func pollFPS() {
        stats.fps = readFPS()
        notify()
    }

    // MARK: - CPU (host_statistics with HOST_CPU_LOAD_INFO)

    private func readCPU() -> Double {
        guard let hostStat = _host_statistics else { return 0 }

        var cpu = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = hostStat(_mach_host_self?() ?? mach_port_t(0), HOST_CPU_LOAD_INFO,
                          &cpu, &count)
        guard kr == KERN_SUCCESS else { return 0 }

        // Convert ticks to UInt32 for overflow-safe subtraction
        let cur = host_cpu_load_info_to_ticks(cpu)
        defer { prevCPU = cur }

        guard let prev = prevCPU, prev.count == cur.count else { return 0 }

        let user   = UInt64(cur[CPU_STATE_USER])   &- UInt64(prev[CPU_STATE_USER])
        let system = UInt64(cur[CPU_STATE_SYSTEM]) &- UInt64(prev[CPU_STATE_SYSTEM])
        let nice   = UInt64(cur[CPU_STATE_NICE])   &- UInt64(prev[CPU_STATE_NICE])
        let idle   = UInt64(cur[CPU_STATE_IDLE])   &- UInt64(prev[CPU_STATE_IDLE])

        let active = user + system + nice
        let total  = active + idle
        guard total > 0 else { return 0 }
        return Double(active) / Double(total) * 100.0
    }

    /// Convert the host_cpu_load_info_data_t tuple into an array for easy indexing.
    private func host_cpu_load_info_to_ticks(_ info: host_cpu_load_info_data_t) -> [UInt32] {
        return [
            info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3,
        ]
    }

    // MARK: - GPU (IOAccelerator → PerformanceStatistics)

    private func readGPU() -> Double {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOAccelerator")
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
        guard kr == KERN_SUCCESS else { return 0 }

        var best: Double = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }

            guard let perf = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString,
                kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            // Try known utilization keys
            if let v = perf["Device Utilization %"] as? Int {
                best = max(best, Double(v))
            } else if let v = perf["Device Utilization %"] as? Double {
                best = max(best, v)
            } else if let v = perf["GPU Activity(%)"] as? Int {
                best = max(best, Double(v))
            } else if let v = perf["GPU Activity(%)"] as? Double {
                best = max(best, v)
            }
        }
        IOObjectRelease(iterator)
        return min(best, 100.0)
    }

    // MARK: - Memory (host_statistics64 + sysctl)

    private func readMemory() {
        guard let hostStat64 = _host_statistics64 else { return }

        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                          / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let kr = hostStat64(_mach_host_self?() ?? mach_port_t(0), HOST_VM_INFO64, &vm, &size)
        guard kr == KERN_SUCCESS else { return }

        let pageSize = Double(_vm_page_size_ptr?.pointee ?? 16384)

        let active      = Double(vm.active_count)      * pageSize
        let inactive    = Double(vm.inactive_count)    * pageSize
        let speculative = Double(vm.speculative_count) * pageSize
        let wired       = Double(vm.wire_count)        * pageSize
        let compressed  = Double(vm.compressor_page_count) * pageSize
        let purgeable   = Double(vm.purgeable_count)   * pageSize
        let external    = Double(vm.external_page_count) * pageSize

        let used = active + inactive + speculative + wired + compressed
                 - purgeable - external
        stats.memoryUsedGB = max(0, used / 1_073_741_824.0)

        // Memory pressure level
        var pressureLevel: Int32 = 0
        var intSize = MemoryLayout<Int32>.size
        if let sb = _sysctlbyname {
            _ = sb("kern.memorystatus_vm_pressure_level",
                   &pressureLevel, &intSize, nil, 0)
        }
        switch pressureLevel {
        case 2:  stats.memoryPressure = .warning
        case 4:  stats.memoryPressure = .critical
        default: stats.memoryPressure = .normal
        }
    }

    // MARK: - FPS (WindowServer presented frames)

    /// Snapshot of the WindowServer frame counter from the previous poll.
    private var prevFrameCount: UInt64?
    private var prevFrameTime: Double = 0

    private func readFPS() -> Int {
        guard let mainConn = _SLSMainConnectionID,
              let getCount = _SLSGetPerformanceTotalUpdateCount else { return 0 }

        var count: UInt64 = 0
        var time: Double = 0
        guard getCount(mainConn(), &count, &time) == 0 else { return 0 }
        defer { prevFrameCount = count; prevFrameTime = time }

        guard let prev = prevFrameCount, count >= prev, time > prevFrameTime else { return 0 }
        return Int((Double(count - prev) / (time - prevFrameTime)).rounded())
    }

    // MARK: - Temperature (SMC)

    /// CPU temperature sensors across all Apple Silicon generations + Intel.
    /// Non-existent keys simply return nil; we average whatever is valid, so
    /// one list covers M1/M2/M3/M4 and Intel without per-chip detection.
    private static let cpuSensorNames: [String] = [
        // Intel
        "TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCAD",
        // M1 (efficiency + performance cores)
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // M2
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
        // M3 (efficiency Te + performance Tf)
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        // M4
        "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e",
    ]

    private static let gpuSensorNames: [String] = [
        // Intel / AMD
        "TG0D", "TG0P", "TG0H", "TCGC", "TGDD",
        // M1
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        // M2
        "Tg0f", "Tg0j",
        // M3
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
        // M4
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k",
    ]

    private static let cpuSensorKeys: [UInt32] = cpuSensorNames.map(smcFourCC)
    private static let gpuSensorKeys: [UInt32] = gpuSensorNames.map(smcFourCC)

    private var liveCPUSensorKeys: [UInt32]?
    private var liveGPUSensorKeys: [UInt32]?
    private var lastSensorProbeAt: TimeInterval = 0

    /// Sensor-queue only — see `sampleSensors()`. Returns the temperatures
    /// instead of writing `stats` so the caller can apply them on main.
    private func sampleTemps() -> (cpu: Double?, gpu: Double?) {
        dispatchPrecondition(condition: .onQueue(sensorQueue))
        let now = ProcessInfo.processInfo.systemUptime
        let bothEmpty = (liveCPUSensorKeys?.isEmpty == true) && (liveGPUSensorKeys?.isEmpty == true)
        if liveCPUSensorKeys == nil || (bothEmpty && now - lastSensorProbeAt > 60) {
            lastSensorProbeAt = now
            liveCPUSensorKeys = Self.cpuSensorKeys.filter { k in
                if let v = SMCController.read(k), v > 0, v < 130 { return true }
                return false
            }
            liveGPUSensorKeys = Self.gpuSensorKeys.filter { k in
                if let v = SMCController.read(k), v > 0, v < 130 { return true }
                return false
            }
            if !tempLogOnce {
                logDiscoveredSensors()
                tempLogOnce = true
            }
        }
        return (averageTemp(liveCPUSensorKeys ?? []), averageTemp(liveGPUSensorKeys ?? []))
    }

    private func logDiscoveredSensors() {
        var found: [String] = []
        let liveSet = Set((liveCPUSensorKeys ?? []) + (liveGPUSensorKeys ?? []))
        for (name, key) in zip(Self.cpuSensorNames + Self.gpuSensorNames,
                                Self.cpuSensorKeys + Self.gpuSensorKeys) {
            if liveSet.contains(key), let v = SMCController.read(key), v > 0, v < 130 {
                found.append("\(name)=\(String(format: "%.1f", v))")
            }
        }
        NSLog("[HW] Valid temp sensors: %@", found.isEmpty ? "none" : found.joined(separator: ", "))
    }

    /// Average all valid readings (0 < v < 110°C). Mirrors how Stats reports a
    /// chip temperature: the mean of its per-core sensors.
    private func averageTemp(_ keys: [UInt32]) -> Double? {
        var sum = 0.0
        var n = 0
        for key in keys {
            if let v = SMCController.read(key), v > 0, v < 110 {
                sum += v
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    // MARK: - Power (AppleSmartBattery, with SMC fallback for battery-less Macs)

    /// SMC power keys tried only when there's no AppleSmartBattery service
    /// (desktop Macs). These are far less certain than the per-core temp
    /// sensors, so treat them as a last resort.
    private static let powerSensorNames: [String] = [
        "PSTR",  // System Total Power
        "PDTR",  // DC-In (AC adapter) Power
        "PPBR",  // Battery Power
    ]
    private static let powerSensorKeys: [UInt32] = powerSensorNames.map(smcFourCC)

    /// Live DC-in (adapter input) power sensor. Unlike the AppleSmartBattery
    /// telemetry — which the SMC only refreshes every ~10s — this key updates
    /// every SMC cycle, so it tracks an inline USB-C meter in real time.
    private static let dcInPowerKey = smcFourCC("PDTR")

    /// Live total-system power sensor, same freshness as PDTR. On battery the
    /// battery supplies the whole system, so this is the live discharge rate
    /// (verified against the PPBR battery rail while discharging).
    private static let systemPowerKey = smcFourCC("PSTR")

    /// The charge limit the user set in System Settings ▸ Battery, read from
    /// its (undocumented) preference. `CFPreferencesAppSynchronize` re-reads
    /// from disk so a slider change made while MSG runs is picked up. nil when
    /// the key is absent (no limit set, or a macOS that stores it elsewhere).
    private static func readChargeLimitPercent() -> Int? {
        let appID = "com.apple.batteryui.charging.mac" as CFString
        CFPreferencesAppSynchronize(appID)
        let value = CFPreferencesCopyAppValue(
            "com.apple.batteryui.charging.mac.prior.limit" as CFString, appID)
        guard let n = value as? NSNumber else { return nil }
        let pct = n.intValue
        return (pct > 0 && pct <= 100) ? pct : nil
    }

    private var lastChargeLimitReadAt: TimeInterval = 0
    private var cachedChargeLimit: Int?

    private func readPower() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastChargeLimitReadAt > 30 || lastChargeLimitReadAt == 0 {
            lastChargeLimitReadAt = now
            cachedChargeLimit = Self.readChargeLimitPercent()
        }
        stats.chargeLimitPercent = cachedChargeLimit
        if let (watts, charging, adapterWatts, percent, rawPercent, chargeRate) = readPowerFromBattery() {
            stats.powerWatts = watts
            stats.isCharging = charging
            stats.adapterWatts = adapterWatts
            stats.batteryPercent = percent
            stats.batteryRawPercent = chargingPercentEstimate(
                systemPercent: percent, rawPercent: rawPercent,
                chargeRatePerSecond: chargeRate, charging: charging)
            if !powerLogOnce {
                NSLog("[HW] Power via AppleSmartBattery: %.1fW (%@)%@",
                      watts, charging ? "charging" : "discharging",
                      adapterWatts.map { ", \($0)W adapter" } ?? "")
                powerLogOnce = true
            }
            return
        }
        for (name, key) in zip(Self.powerSensorNames, Self.powerSensorKeys) {
            if let v = SMCController.read(key), v > 0, v < 1000 {
                stats.powerWatts = v
                stats.isCharging = nil
                stats.adapterWatts = nil
                stats.batteryPercent = nil
                stats.batteryRawPercent = nil
                resetChargingPercentEstimate()
                if !powerLogOnce {
                    NSLog("[HW] Power sensor resolved via SMC fallback: %@=%.1fW", name, v)
                    powerLogOnce = true
                }
                return
            }
        }
        stats.powerWatts = nil
        stats.isCharging = nil
        stats.adapterWatts = nil
        stats.batteryPercent = nil
        stats.batteryRawPercent = nil
        resetChargingPercentEstimate()
        if !powerLogOnce {
            NSLog("[HW] No power source resolved (no AppleSmartBattery, no SMC power keys)")
            powerLogOnce = true
        }
    }

    /// Real-time power + charge direction from the AppleSmartBattery
    /// IORegistry entry — the same data source tools like coconutBattery
    /// read. `Amperage` × `Voltage` are the battery's live current/voltage
    /// sensor (signed mA / mV; positive amperage = charging, negative =
    /// discharging), so this tracks actual load. `AdapterDetails.Watts` is
    /// the charger's rated (nominal) capacity — purely informational, not
    /// used in the wattage calculation, which is why it's kept separate from
    /// the Current/AdapterVoltage fields (those describe the negotiated PD
    /// contract, not a live measurement).
    ///
    /// On AC, battery Amperage only sees the charge current — the system's
    /// own load is fed directly from the adapter and never crosses the battery
    /// sensor, so Amperage × Voltage under-reports total input (and reads ~0
    /// at the charge limit). With an adapter connected and delivering, we
    /// report the SMC's live DC-in sensor (`PDTR`) — the total power entering
    /// the Mac, the same figure an inline USB-C power meter shows — with
    /// `PowerTelemetryData.SystemPowerIn` as the fallback where PDTR is
    /// absent. Plugged in but not drawing (PD handshake, paused charger) and
    /// on-battery states show the battery figure, which IS the system draw.
    private func readPowerFromBattery() -> (watts: Double, charging: Bool, adapterWatts: Int?, percent: Int?, rawPercent: Double?, chargeRate: Double?)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = propsRef?.takeRetainedValue() as? [String: Any] else { return nil }

        // Amperage is signed mA but the IORegistry hands negative values back
        // as their unsigned 64-bit wrap (e.g. -1073 → 18446744073709550543).
        // int64Value reinterprets the bit pattern; doubleValue would turn it
        // into ~1.8e19 and wreck the math.
        guard let amperageNum = props["Amperage"] as? NSNumber,
              let voltage = (props["Voltage"] as? NSNumber)?.doubleValue, voltage > 0 else {
            return nil
        }
        let amperage = Double(amperageNum.int64Value)
        let charging = (props["IsCharging"] as? Bool) ?? (amperage > 0)
        var adapterWatts = (props["AdapterDetails"] as? [String: Any])
            .flatMap { ($0["Watts"] as? NSNumber)?.intValue }
        // AdapterDetails.Watts vanishes for a read or two during PD
        // renegotiation even though power never dropped. ExternalConnected is
        // the stable plugged-in signal, so gate on it and bridge Watts
        // dropouts with the last-known rating.
        let external = (props["ExternalConnected"] as? Bool) ?? (adapterWatts != nil)
        if external {
            if adapterWatts == nil { adapterWatts = lastAdapterWatts }
            else { lastAdapterWatts = adapterWatts }
        } else {
            lastAdapterWatts = nil
        }
        // CurrentCapacity is the charge percentage directly on modern macOS.
        let percent = ((props["CurrentCapacity"] as? NSNumber)?.intValue)
            .map { max(0, min(100, $0)) }
        // CurrentCapacity is intentionally rounded by macOS. The gas gauge's
        // raw charge units let us show meaningful tenths while charge is
        // actively increasing, without inventing precision when discharging.
        let batteryData = props["BatteryData"] as? [String: Any]
        let rawCurrent = (batteryData?["RemainingCapacity"] as? NSNumber)?.doubleValue
            ?? (batteryData?["AppleRawCurrentCapacity"] as? NSNumber)?.doubleValue
        let rawMax = (batteryData?["FullChargeCapacity"] as? NSNumber)?.doubleValue
            ?? (batteryData?["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
        let rawPercent: Double? = {
            guard let current = rawCurrent, let maximum = rawMax, maximum > 0 else { return nil }
            return max(0, min(100, current / maximum * 100))
        }()
        // Percent gained per second at the measured battery charge current:
        // mA / mAh = 1/hour, then ×100/3600 converts to percent/second.
        let chargeRate: Double? = {
            guard charging, amperage > 0, let maximum = rawMax, maximum > 0 else { return nil }
            return amperage / (maximum * 36.0)
        }()

        // Battery current × voltage only sees power flowing through the
        // battery. On AC the system's own load is fed straight from the
        // adapter and bypasses that sensor, so it under-reports by the Mac's
        // live draw (and reads ~0 when held at the charge limit). What an
        // inline USB-C meter shows is the total power entering the Mac, and
        // the live source for that is the SMC's DC-in sensor (PDTR) — it's
        // fresh every read, where the AppleSmartBattery figures (Amperage,
        // PowerTelemetryData) only refresh every ~10s and lag badly right
        // after plug-in.
        let batteryWatts = abs(amperage) * voltage / 1_000_000.0
        if external {
            let dcIn = SMCController.read(Self.dcInPowerKey)
            if let dcIn, dcIn > 1, dcIn < 1000 {
                return (dcIn, charging, adapterWatts, percent, rawPercent, chargeRate)
            }
            // No PDTR key on this machine: fall back to the slow-but-correct
            // telemetry average.
            if dcIn == nil,
               let telemetry = props["PowerTelemetryData"] as? [String: Any],
               let systemMilliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue,
               systemMilliwatts > 100 {
                return (systemMilliwatts / 1000.0, charging, adapterWatts, percent, rawPercent, chargeRate)
            }
            // PDTR ≈ 0 while plugged in: the adapter isn't delivering (PD
            // handshake in progress, or macOS paused the charger) — the
            // battery is powering the Mac, so fall through to its figure.
        }
        // Battery is the source (unplugged, or adapter idle): live total
        // system power IS the discharge rate, and it's fresh every read where
        // Amperage × Voltage goes ~10s stale.
        if let sysTotal = SMCController.read(Self.systemPowerKey),
           sysTotal > 0.5, sysTotal < 1000 {
            return (sysTotal, charging, adapterWatts, percent, rawPercent, chargeRate)
        }
        return (batteryWatts, charging, adapterWatts, percent, rawPercent, chargeRate)
    }

    /// The gas gauge publishes RemainingCapacity in batches, so polling it
    /// faster still produces jumps such as .0 → .7. Integrate the measured
    /// charge current between publications to expose intermediate decimals,
    /// anchored to the same whole percentage macOS displays.
    private func chargingPercentEstimate(systemPercent: Int?,
                                         rawPercent: Double?,
                                         chargeRatePerSecond: Double?,
                                         charging: Bool) -> Double? {
        guard charging else {
            resetChargingPercentEstimate()
            return rawPercent
        }

        // Apple's displayed CurrentCapacity includes reserve/smoothing and
        // can be a full point above the raw cell ratio. Anchor to that same
        // whole number so MSG never says 30.xx while macOS says 31%.
        guard let wholePercent = systemPercent else { return rawPercent }

        let now = ProcessInfo.processInfo.systemUptime
        if estimatedChargeWholePercent != wholePercent {
            let anchored = Double(wholePercent)
            estimatedChargePercent = anchored
            estimatedChargeTimestamp = now
            estimatedChargeWholePercent = wholePercent
            return anchored
        }
        guard let previous = estimatedChargePercent,
              let timestamp = estimatedChargeTimestamp else {
            let anchored = Double(wholePercent)
            estimatedChargePercent = anchored
            estimatedChargeTimestamp = now
            estimatedChargeWholePercent = wholePercent
            return anchored
        }

        // Cap elapsed time so wake-from-sleep cannot create a large invented
        // jump before the battery controller publishes a fresh raw value.
        let elapsed = max(0, min(5, now - timestamp))
        var estimate = previous + max(0, chargeRatePerSecond ?? 0) * elapsed
        estimate = max(Double(wholePercent), min(Double(wholePercent) + 0.999, estimate))
        estimate = min(100, estimate)
        estimatedChargePercent = estimate
        estimatedChargeTimestamp = now
        return estimate
    }

    private func resetChargingPercentEstimate() {
        estimatedChargePercent = nil
        estimatedChargeTimestamp = nil
        estimatedChargeWholePercent = nil
    }

    // MARK: - Model max charge wattage

    /// Highest charging wattage this Mac model supports, derived from the
    /// device tree product name (e.g. "MacBook Pro (14-inch, M5 Pro)").
    /// Fixed top of the power module's bar scale.
    static let modelMaxChargeWatts: Double = {
        let fallback = 100.0
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return fallback }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let data = prop as? Data,
              let raw = String(data: data, encoding: .utf8) else { return fallback }
        let name = raw.lowercased()

        if name.contains("macbook pro") {
            if name.contains("16-inch") { return 140 }
            if name.contains("14-inch") { return 96 }
            if name.contains("13-inch") { return 67 }
            return 96
        }
        if name.contains("macbook air") {
            // The M1 Air tops out at its 30W brick; later Airs fast-charge at 70W.
            if name.contains("m1,") || name.contains("m1)") { return 30 }
            return 70
        }
        return fallback
    }()

    // MARK: - Energy mode (pmset powermode: 0 = automatic, 1 = low, 2 = high)

    struct EnergyModes {
        var battery: Int?
        var ac: Int?
        var supported: Bool { battery != nil || ac != nil }
    }

    /// Parses `pmset -g custom` (no privileges needed). nil fields mean the
    /// powermode key is absent — energy modes unsupported on this Mac.
    static func readEnergyModes() -> EnergyModes {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "custom"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return EnergyModes() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return EnergyModes() }

        var modes = EnergyModes()
        var section = ""
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") { section = line; continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "powermode", let v = Int(parts[1]) else { continue }
            if section.hasPrefix("Battery") { modes.battery = v }
            else if section.hasPrefix("AC") { modes.ac = v }
        }
        return modes
    }

    /// Sets the energy mode for both power sources (`pmset -a powermode N`)
    /// via the privileged helper. May raise the one-time admin prompt if no
    /// helper session is live. Completion fires on the main queue.
    func setEnergyMode(_ mode: Int, completion: @escaping (Bool) -> Void) {
        guard (0...2).contains(mode) else {
            completion(false)
            return
        }
        Self.fanHelperQueue.async {
            let ok = Self.runFanHelper(arguments: ["powermode", String(mode)], allowPrompt: true)
            NSLog("[HW] set powermode %d via helper: %@", mode, ok ? "OK" : "FAIL")
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Fans

    /// Per-fan SMC keys, indexed by fan number (F0…, F1…).
    /// Ac = actual RPM, Mn = min, Mx = max, Tg = target, Md/md = control mode.
    private struct FanKeys {
        let act, min, max, target, mode, modeLower: UInt32
        init(_ i: Int) {
            func k(_ suffix: String) -> UInt32 {
                smcFourCC("F\(i)\(suffix)")
            }
            act = k("Ac"); min = k("Mn"); max = k("Mx")
            target = k("Tg"); mode = k("Md"); modeLower = k("md")
        }
    }
    private static let fnumKey = smcFourCC("FNum")
    private var fanLogOnce = false
    private var tempLogOnce = false
    private var powerLogOnce = false
    private var fansForced = false
    private var lastHelperFanPercent: Double?
    private var lastHelperFanWriteAt: Date?
    private var helperFanControlActive = false
    private var fanPresetApplyInFlight = false

    /// Re-read fan state after a control write, without blocking the caller.
    ///
    /// The fan-control paths call this to reflect a write they just made. It
    /// goes through `sensorQueue` like every other SMC read so it can't
    /// interleave with an in-flight sweep on the shared connection.
    private func refreshFansAsync() {
        sensorQueue.async { [weak self] in
            guard let self else { return }
            let fans = self.sampleFans()
            DispatchQueue.main.async {
                self.stats.fans = fans
                self.notify()
            }
        }
    }

    /// Sensor-queue only — see `sampleSensors()`.
    private func sampleFans() -> [FanInfo] {
        dispatchPrecondition(condition: .onQueue(sensorQueue))
        let fanCountRaw = SMCController.readUInt16(Self.fnumKey)
        if !fanLogOnce {
            NSLog("[HW] FNum raw: %d (SMC open: %@)",
                  Int(fanCountRaw ?? 65535), SMCController.isOpen ? "yes" : "no")
            for i in 0..<2 {
                let fk = FanKeys(i)
                let a = SMCController.readUInt16(fk.act)
                let mn = SMCController.readUInt16(fk.min)
                let mx = SMCController.readUInt16(fk.max)
                NSLog("[HW] Fan %d: Ac=%d Mn=%d Mx=%d",
                      i, Int(a ?? 0), Int(mn ?? 0), Int(mx ?? 0))
            }
            fanLogOnce = true
        }

        guard let fanCount = fanCountRaw, fanCount > 0, fanCount < 10 else {
            return []
        }
        var fans: [FanInfo] = []
        for i in 0..<Int(fanCount) {
            let fk = FanKeys(i)
            guard let mx  = SMCController.readUInt16(fk.max),  mx > 0 else { continue }
            let cur = SMCController.readUInt16(fk.act) ?? 0
            let mn = SMCController.readUInt16(fk.min) ?? 0
            let fanName: String = {
                switch i {
                case 0:  return "Left"
                case 1:  return "Right"
                default: return "Fan \(i + 1)"
                }
            }()
            fans.append(FanInfo(index: i, name: fanName,
                                current: Int(cur), min: Int(mn), max: Int(mx)))
        }
        return fans
    }

    /// Ftst key — diagnostic mode flag that suppresses thermalmonitord.
    /// Required on M3/M4+ to take manual fan control.
    private static let ftstKey = smcFourCC("Ftst")
    /// FS! key — fan status/manual force bitmask key. Used on Intel Macs.
    private static let fsKey = smcFourCC("FS! ")

    private static func shouldUseFSFanControl() -> Bool {
        SMCController.keyInfo(Self.fsKey) != nil && SMCController.keyInfo(Self.ftstKey) == nil
    }

    /// Force all fans to maximum speed. Uses the Ftst unlock sequence when
    /// direct writes are blocked by thermalmonitord (M3/M4+).
    func fanFullBlast() {
        guard !fanControlUnlocking else {
            NSLog("[HW] fanFullBlast ignored while another fan command is in flight")
            return
        }
        _ = SMCController.open()
        refreshFansAsync()
        guard !stats.fans.isEmpty else {
            NSLog("[HW] fanFullBlast: no fans to control")
            return
        }

        fansForced = true
        fanControlUnlocking = true
        if !Self.shouldUseFSFanControl() {
            Self.fanHelperQueue.async { [weak self] in
                guard let self else { return }
                let helperOK = Self.runFanHelper(arguments: ["full"], allowPrompt: true)
                NSLog("[HW] fanFullBlast privileged helper: %@", helperOK ? "OK" : "FAIL")
                self.helperFanControlActive = helperOK
                if helperOK {
                    self.lastHelperFanPercent = 100
                    self.lastHelperFanWriteAt = Date()
                }
                self.fanControlUnlocking = false
                self.refreshFansAsync()
            }
            return
        }
        Self.fanHelperQueue.async { [weak self] in
            guard let self else { return }

            let directOK: Bool
            if Self.shouldUseFSFanControl() {
                // Intel / FS! path
                var mask: UInt16 = 0
                for f in self.stats.fans {
                    mask |= (1 << f.index)
                }
                let fsOK = SMCController.write(Self.fsKey, u16: mask)
                NSLog("[HW] fanFullBlast FS! write mask %d: %@", mask, fsOK ? "OK" : "FAIL")
                var targetsOK = true
                for f in self.stats.fans {
                    let fk = FanKeys(f.index)
                    let tgOK = SMCController.write(fk.target, u16: UInt16(f.max))
                    targetsOK = targetsOK && tgOK
                    NSLog("[HW] fanFullBlast %@: Tg=%d max=%d", f.name, tgOK, f.max)
                }
                directOK = fsOK && targetsOK
            } else {
                // Apple Silicon / Ftst path
                // Step 1: Signal diagnostic mode — suppresses thermalmonitord.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 1)
                NSLog("[HW] fanFullBlast Ftst=1: %@", ftstOK ? "OK" : "FAIL")
                var targetsOK = ftstOK
                for f in self.stats.fans {
                    let fk = FanKeys(f.index)
                    // Step 2: Wait for mode to leave System (3) → Auto (0).
                    //          thermalmonitord needs ~3-4s to yield after Ftst.
                    self.waitForMode(key: fk.mode, keyLower: fk.modeLower,
                                      target: 0, fan: f.name, timeout: 6.0)
                    // Step 3: Set manual mode.
                    _ = SMCController.write(fk.mode, u16: 1)
                    _ = SMCController.write(fk.modeLower, u16: 1)
                    // Step 4: Set target to max RPM.
                    let tgOK = SMCController.write(fk.target, u16: UInt16(f.max))
                    targetsOK = targetsOK && tgOK
                    NSLog("[HW] fanFullBlast %@: Tg=%d max=%@", f.name, tgOK, String(f.max))
                }
                directOK = targetsOK
            }
            if !directOK {
                let helperOK = Self.runFanHelper(arguments: ["full"])
                NSLog("[HW] fanFullBlast privileged helper: %@", helperOK ? "OK" : "FAIL")
                if helperOK {
                    self.helperFanControlActive = true
                    self.lastHelperFanPercent = 100
                    self.lastHelperFanWriteAt = Date()
                }
            }
            self.fanControlUnlocking = false
            self.refreshFansAsync()
        }
    }

    /// Poll a fan mode key until it reads `target` or timeout expires.
    private func waitForMode(key: UInt32, keyLower: UInt32,
                              target: UInt16, fan: String, timeout: TimeInterval) {
        let deadline = Date().timeIntervalSinceReferenceDate + timeout
        while Date().timeIntervalSinceReferenceDate < deadline {
            let v = SMCController.readUInt16(key) ?? SMCController.readUInt16(keyLower)
            if v == target {
                NSLog("[HW] waitForMode %@ → %d (%.1fs)",
                      fan, target,
                      timeout - (deadline - Date().timeIntervalSinceReferenceDate))
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let v = SMCController.readUInt16(key) ?? SMCController.readUInt16(keyLower) ?? 999
        NSLog("[HW] waitForMode %@ timed out, mode=%d", fan, v)
    }

    /// Return all fans to automatic control and release Ftst.
    /// `allowPrompt: false` is for poll-driven retries — they must never
    /// raise the admin password dialog.
    func fanReset(allowPrompt: Bool = true) {
        guard !fanControlUnlocking else {
            NSLog("[HW] fanReset ignored while another fan command is in flight")
            return
        }
        _ = SMCController.open()
        refreshFansAsync()
        guard !stats.fans.isEmpty else {
            NSLog("[HW] fanReset: no fans to control")
            return
        }

        if !Self.shouldUseFSFanControl() {
            fanControlUnlocking = true
            Self.fanHelperQueue.async { [weak self] in
                guard let self else { return }
                let helperOK = Self.runFanHelper(arguments: ["auto"], allowPrompt: allowPrompt)
                NSLog("[HW] fanReset privileged helper: %@", helperOK ? "OK" : "FAIL")
                // Only forget ownership when the reset actually happened.
                // Clearing the flags on failure left the fans stuck in manual
                // mode with nothing ever retrying.
                if helperOK {
                    self.fansForced = false
                    self.helperFanControlActive = false
                    self.lastHelperFanPercent = nil
                    self.lastHelperFanWriteAt = nil
                }
                self.fanControlUnlocking = false
                self.refreshFansAsync()
            }
            return
        }

        fanControlUnlocking = true
        Self.fanHelperQueue.async { [weak self] in
            guard let self else { return }
            let directOK: Bool
            if Self.shouldUseFSFanControl() {
                // Intel / FS! path
                let fsOK = SMCController.write(Self.fsKey, u16: 0)
                NSLog("[HW] fanReset FS!=0: %@", fsOK ? "OK" : "FAIL")
                directOK = fsOK
            } else {
                // Apple Silicon / Ftst path
                var modesOK = true
                for f in self.stats.fans {
                    let fk = FanKeys(f.index)
                    let mdOK = SMCController.write(fk.mode, u16: 0)
                    let lowerOK = SMCController.write(fk.modeLower, u16: 0)
                    modesOK = modesOK && (mdOK || lowerOK)
                    NSLog("[HW] fanReset %@: mode→Auto", f.name)
                }
                // Release diagnostic mode so thermalmonitord resumes.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 0)
                NSLog("[HW] fanReset Ftst=0: %@", ftstOK ? "OK" : "FAIL")
                directOK = modesOK && ftstOK
            }
            var resetOK = directOK
            if !directOK {
                let helperOK = Self.runFanHelper(arguments: ["auto"], allowPrompt: allowPrompt)
                NSLog("[HW] fanReset privileged helper: %@", helperOK ? "OK" : "FAIL")
                resetOK = helperOK
            }
            if resetOK {
                self.fansForced = false
                self.helperFanControlActive = false
                self.lastHelperFanPercent = nil
                self.lastHelperFanWriteAt = nil
            }
            self.fanControlUnlocking = false
            self.refreshFansAsync()
        }
    }

    /// True while fans are being forced to full blast by us.
    var isFanFullBlast: Bool { fansForced }

    /// True if any fan's SMC mode key currently reports manual control.
    /// Readable without privileges — used to detect manual mode left over
    /// from a previous run (the SMC keeps it across app relaunches).
    private func anyFanManual() -> Bool {
        for f in stats.fans {
            let fk = FanKeys(f.index)
            let v = SMCController.readUInt16(fk.mode) ?? SMCController.readUInt16(fk.modeLower)
            if v == 1 { return true }
        }
        return false
    }

    /// Best-effort synchronous fan release at app termination. No prompt:
    /// only works while the helper session is alive (the common case — curve
    /// updates keep it warm). Startup reconciliation covers the rest.
    func fanQuitCleanup() {
        guard fansForced || helperFanControlActive || anyFanManual() else { return }
        if case .success = Self.sendFanHelperCommand(arguments: ["auto"]) {
            fansForced = false
            helperFanControlActive = false
            NSLog("[HW] fans released to auto at quit")
        } else {
            NSLog("[HW] could not release fans at quit (helper not running)")
        }
    }

    /// Guards against duplicate unlock attempts while the Ftst dance is in flight.
    private var fanControlUnlocking = false

    func applySelectedFanPresetFromUser() {
        guard !fanPresetApplyInFlight else {
            NSLog("[HW] fan preset request ignored while another fan command is in flight")
            return
        }
        _ = SMCController.open()
        refreshFansAsync()
        let preset = AppSettings.shared.hardwareStatsFanPreset
        guard preset != "default" else {
            fanReset()
            return
        }
        guard !stats.fans.isEmpty else { return }
        let curve = fanCurve(for: preset)
        let maxTemp = max(stats.cpuTemp ?? 30, stats.gpuTemp ?? 30)
        let rpmPct = curveRPMPercent(for: maxTemp, curve: curve)
        fanPresetApplyInFlight = true
        fanControlUnlocking = true
        fansForced = true
        Self.fanHelperQueue.async { [weak self] in
            guard let self else { return }
            let pct = String(format: "%.0f", max(0, min(100, rpmPct)))
            let helperOK = Self.runFanHelper(arguments: ["set", pct], allowPrompt: true)
            NSLog("[HW] fan preset privileged helper %@%%: %@", pct, helperOK ? "OK" : "FAIL")
            self.helperFanControlActive = helperOK
            if helperOK {
                self.lastHelperFanPercent = rpmPct
                self.lastHelperFanWriteAt = Date()
            } else {
                // Control was never taken — stay "forced" only if the fans
                // really are in manual mode (leftover from an earlier run).
                self.fansForced = self.anyFanManual()
            }
            self.fanPresetApplyInFlight = false
            self.fanControlUnlocking = false
            self.refreshFansAsync()
        }
    }

    // MARK: - Fan curve engine

    /// Returns the stored curve for a preset, or a sensible fallback.
    private func fanCurve(for preset: String) -> [(Double, Double)] {
        if let stored = AppSettings.shared.hardwareStatsFanCurves[preset] {
            return stored.map { ($0[0], $0[1]) }
        }
        switch preset {
        case "silent":
            return [(40, 0), (60, 20), (75, 40), (85, 60), (95, 80)]
        case "performance":
            return [(30, 30), (50, 50), (65, 70), (80, 85), (95, 100)]
        default:
            return [(30, 30), (50, 50), (65, 70), (80, 85), (95, 100)]
        }
    }

    /// Interpolate target RPM% for a given temperature from a curve.
    private func curveRPMPercent(for temp: Double, curve: [(Double, Double)]) -> Double {
        guard !curve.isEmpty else { return 30 }
        let temp = max(0, min(100, temp))
        if temp <= curve[0].0 { return curve[0].1 }
        if temp >= curve.last!.0 { return curve.last!.1 }
        for i in 0..<(curve.count - 1) {
            let (t0, r0) = curve[i]
            let (t1, r1) = curve[i + 1]
            if temp >= t0 && temp <= t1 {
                let frac = (temp - t0) / (t1 - t0)
                return r0 + (r1 - r0) * frac
            }
        }
        return curve[0].1
    }

    /// Called from poll(). When not in control: kicks off async Ftst unlock.
    /// When already in control: updates target RPM inline (fast).
    private func applyFanCurve() {
        let preset = AppSettings.shared.hardwareStatsFanPreset
        guard preset != "default" else {
            if fansForced { fanReset(allowPrompt: false) }
            return
        }
        guard !stats.fans.isEmpty else { return }

        let curve = fanCurve(for: preset)
        let maxTemp = max(stats.cpuTemp ?? 30, stats.gpuTemp ?? 30)
        let rpmPct = curveRPMPercent(for: maxTemp, curve: curve)

        if helperFanControlActive {
            setFanPercentWithHelperIfNeeded(rpmPct)
            return
        }

        // Polling must never launch a privileged prompt. The helper is started
        // only by explicit preset changes; otherwise the 2s poll timer can
        // repeatedly ask for an admin password.
        guard fansForced else { return }

        // Already in control — quick inline target update.
        var wroteAllTargets = true
        for f in stats.fans {
            let targetRPM = Int(Double(f.max) * rpmPct / 100.0)
            let clamped = max(f.min, min(f.max, targetRPM))
            let fk = FanKeys(f.index)
            wroteAllTargets = SMCController.write(fk.target, u16: UInt16(clamped)) && wroteAllTargets
        }
        if !wroteAllTargets {
            setFanPercentWithHelperIfNeeded(rpmPct)
        }
    }

    /// Full Ftst unlock sequence on a background queue.
    /// Per the macos-smc-fan research:
    ///   1. Ftst=1  (suppresses thermalmonitord)
    ///   2. Wait ~3-4s for mode 3→0
    ///   3. Mode=1  (manual)
    ///   4. Tg=<target RPM>
    private func takeFanControl(targetPct: Double) {
        fanControlUnlocking = true
        fansForced = true
        let rpmPct = targetPct
        let fans = stats.fans  // snapshot

        Self.fanHelperQueue.async { [weak self] in
            guard let self else { return }
            _ = SMCController.open()

            let directOK: Bool
            if Self.shouldUseFSFanControl() {
                // Intel / FS! path
                var mask: UInt16 = 0
                for f in fans {
                    mask |= (1 << f.index)
                }
                let fsOK = SMCController.write(Self.fsKey, u16: mask)
                NSLog("[HW] takeFanControl FS! write mask %d: %@", mask, fsOK ? "OK" : "FAIL")
                var targetsOK = true
                for f in fans {
                    let fk = FanKeys(f.index)
                    let targetRPM = Int(Double(f.max) * rpmPct / 100.0)
                    let clamped = max(f.min, min(f.max, targetRPM))
                    let tgOK = SMCController.write(fk.target, u16: UInt16(clamped))
                    targetsOK = targetsOK && tgOK
                    NSLog("[HW] takeFanControl %@: Tg=%d rpm=%d", f.name, tgOK, clamped)
                }
                directOK = fsOK && targetsOK
            } else {
                // Apple Silicon / Ftst path
                // Step 1 — diagnostic mode.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 1)
                NSLog("[HW] takeFanControl Ftst=1: %@", ftstOK ? "OK" : "FAIL")
                var targetsOK = ftstOK
                for f in fans {
                    let fk = FanKeys(f.index)
                    // Step 2 — wait for System(3)→Auto(0).
                    self.waitForMode(key: fk.mode, keyLower: fk.modeLower,
                                      target: 0, fan: f.name, timeout: 6.0)
                    // Step 3 — manual mode (try both casings).
                    let mdOK  = SMCController.write(fk.mode, u16: 1)
                    let mdOK2 = SMCController.write(fk.modeLower, u16: 1)
                    // Step 4 — target RPM.
                    let targetRPM = Int(Double(f.max) * rpmPct / 100.0)
                    let clamped = max(f.min, min(f.max, targetRPM))
                    let tgOK = SMCController.write(fk.target, u16: UInt16(clamped))
                    targetsOK = targetsOK && tgOK
                    NSLog("[HW] takeFanControl %@: Md=%d md=%d Tg=%d rpm=%@",
                          f.name, mdOK, mdOK2, tgOK, String(clamped))
                }
                directOK = targetsOK
            }
            if !directOK {
                let pct = String(format: "%.0f", max(0, min(100, rpmPct)))
                let helperOK = Self.runFanHelper(arguments: ["set", pct], allowPrompt: true)
                NSLog("[HW] takeFanControl privileged helper %@%%: %@", pct, helperOK ? "OK" : "FAIL")
                if helperOK {
                    self.helperFanControlActive = true
                    self.lastHelperFanPercent = rpmPct
                    self.lastHelperFanWriteAt = Date()
                }
            }
            self.fanControlUnlocking = false
            self.refreshFansAsync()
        }
    }

    private func setFanPercentWithHelperIfNeeded(_ rpmPct: Double) {
        let now = Date()
        if let last = lastHelperFanPercent,
           abs(last - rpmPct) < 2,
           let lastWrite = lastHelperFanWriteAt,
           now.timeIntervalSince(lastWrite) < 8 {
            return
        }
        lastHelperFanPercent = rpmPct
        lastHelperFanWriteAt = now
        Self.fanHelperQueue.async {
            let pct = String(format: "%.0f", max(0, min(100, rpmPct)))
            let helperOK = Self.runFanHelper(arguments: ["set", pct], allowPrompt: false)
            NSLog("[HW] fan curve privileged helper %@%%: %@", pct, helperOK ? "OK" : "FAIL")
            self.helperFanControlActive = helperOK
        }
    }

    private static func runFanHelper(arguments: [String], allowPrompt: Bool = true) -> Bool {
        switch sendFanHelperCommand(arguments: arguments) {
        case .success:
            return true
        case .commandFailed(let code):
            NSLog("[HW] fan helper command failed before restart attempt: %d", code)
            return false
        case .notRunning:
            break
        }
        guard allowPrompt else {
            return false
        }
        guard startFanHelperSession() else {
            return false
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            switch sendFanHelperCommand(arguments: arguments) {
            case .success:
                return true
            case .commandFailed(let code):
                NSLog("[HW] fan helper command failed: %d", code)
                return false
            case .notRunning:
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private enum FanHelperCommandResult {
        case notRunning
        case success
        case commandFailed(Int32)
    }

    /// Translates a legacy helper command line into an XPC call.
    ///
    /// Returns nil when the daemon can't answer, so the caller falls back to the
    /// socket rather than reporting a failure the user would see as "fan control
    /// is broken". Synchronous to keep the existing call sites unchanged; the
    /// timeout is short because `applyFanCurve()` reaches here from the main
    /// thread on every poll.
    @available(macOS 14.0, *)
    private static func sendViaDaemon(_ arguments: [String]) -> FanHelperCommandResult? {
        guard let command = arguments.first else { return nil }
        let client = FanControlClient.shared
        let semaphore = DispatchSemaphore(value: 0)
        var reply: FanHelperReply?
        let done: (FanHelperReply?) -> Void = { r in reply = r; semaphore.signal() }

        switch command {
        case "auto":
            client.restoreAutomatic(completion: done)
        case "full":
            client.setPercent(100, completion: done)
        case "set":
            guard let pct = arguments.dropFirst().first.flatMap(Double.init) else { return nil }
            client.setPercent(pct, completion: done)
        case "powermode":
            guard let mode = arguments.dropFirst().first.flatMap(Int.init) else { return nil }
            client.setPowerMode(mode, completion: done)
        default:
            return nil
        }

        guard semaphore.wait(timeout: .now() + 1.5) == .success else { return nil }
        guard let reply else { return nil }
        return reply.ok ? .success : .commandFailed(1)
    }

    /// All privileged fan helper work runs on this serial queue so a stale
    /// "set" can never land after a later "auto" and re-force the fans.
    private static let fanHelperQueue = DispatchQueue(label: "MSG.fanHelper", qos: .userInitiated)

    private static let fanHelperToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private static let fanHelperSocketPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("msg-fan-\(getuid()).sock")
        .path
    private static let fanHelperLock = NSLock()
    private static var fanHelperLastStartAttempt: Date?
    private static var fanHelperPromptInFlight = false

    private static func startFanHelperSession() -> Bool {
        fanHelperLock.lock()
        if fanHelperPromptInFlight {
            fanHelperLock.unlock()
            return false
        }
        if let last = fanHelperLastStartAttempt, Date().timeIntervalSince(last) < 15 {
            fanHelperLock.unlock()
            return false
        }
        fanHelperLastStartAttempt = Date()
        fanHelperPromptInFlight = true
        fanHelperLock.unlock()

        defer {
            fanHelperLock.lock()
            fanHelperPromptInFlight = false
            fanHelperLock.unlock()
        }

        guard let helperURL = Bundle.main.url(forResource: "MSGFanControlHelper", withExtension: nil) else {
            NSLog("[HW] fan helper missing from bundle")
            return false
        }

        _ = Darwin.unlink(fanHelperSocketPath)

        let command = [
            helperURL.path,
            "serve",
            fanHelperSocketPath,
            fanHelperToken,
            String(getuid()),
        ].map(shellQuote).joined(separator: " ") + " >/dev/null 2>&1 &"
        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[HW] fan helper session launch failed: %@", String(describing: error))
            return false
        }
    }

    /// Single choke point for every privileged fan command.
    ///
    /// Prefers the `SMAppService` daemon over the legacy socket helper whenever
    /// the user has approved it. Both are kept because approval is a manual step
    /// in System Settings that may never happen: until then the old
    /// osascript-launched helper is still the only thing that can move a fan,
    /// and silently losing fan control would be worse than the weaker auth.
    ///
    /// Once approved, the daemon is strictly better — the kernel checks the
    /// caller's code signature instead of a shared token, and its lease
    /// watchdog restores automatic control if this app dies while the fans are
    /// pinned. See FanControlClient.
    private static func sendFanHelperCommand(arguments: [String]) -> FanHelperCommandResult {
        if #available(macOS 14.0, *), FanControlClient.shared.access == .enabled,
           let viaDaemon = sendViaDaemon(arguments) {
            return viaDaemon
        }
        guard let fd = connectFanHelperSocket() else {
            return .notRunning
        }
        defer { Darwin.close(fd) }

        let line = ([fanHelperToken] + arguments).joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return .notRunning }

        let wroteAll = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        guard wroteAll else { return .notRunning }

        _ = shutdown(fd, SHUT_WR)

        var response = [UInt8](repeating: 0, count: 32)
        let count = Darwin.read(fd, &response, response.count - 1)
        guard count > 0,
              let text = String(bytes: response.prefix(count), encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .notRunning
        }
        return code == 0 ? .success : .commandFailed(code)
    }

    private static func connectFanHelperSocket() -> Int32? {
        guard fanHelperSocketPath.utf8.count < 104 else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        fanHelperSocketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyMemory(from: UnsafeRawBufferPointer(start: path, count: strlen(path) + 1))
            }
        }

        let length = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + fanHelperSocketPath.utf8.count + 1)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, length)
            }
        }
        if result == 0 {
            return fd
        }
        Darwin.close(fd)
        return nil
    }

    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - SMC Controller

/// Minimal SMC (System Management Controller) client used to read temperature
/// and fan keys via `IOConnectCallStructMethod`.
final class SMCController {

    private static var conn: io_connect_t = 0

    static var isOpen: Bool { conn != 0 }

    // MARK: - Connect / disconnect

    static func open() -> Bool {
        connLock.lock()
        defer { connLock.unlock() }
        guard conn == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == KERN_SUCCESS else { conn = 0; return false }
        return true
    }

    static func close() {
        connLock.lock()
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
        connLock.unlock()
        cacheLock.lock()
        keyInfoCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Data-type-aware read

    /// SMC data type four-char codes (as big-endian UInt32).
    private enum DType {
        static let flt:  UInt32 = 0x666C_7420  // "flt "
        static let fpe2: UInt32 = 0x6670_6532  // "fpe2"
        static let fp2e: UInt32 = 0x6670_3265  // "fp2e"
        static let sp78: UInt32 = 0x7370_3738  // "sp78"
        static let ui8:  UInt32 = 0x7569_3820  // "ui8 "
        static let ui16: UInt32 = 0x7569_3136  // "ui16"
        static let ui32: UInt32 = 0x7569_3332  // "ui32"
    }

    // SMC command codes (placed in the struct's data8 field).
    private static let cmdReadBytes:   UInt8 = 5
    private static let cmdWriteBytes:  UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9
    private static let kernelIndex: UInt32 = 2

    private static var keyInfoCache: [UInt32: (type: UInt32, size: UInt32)] = [:]
    private static let cacheLock = NSLock()
    /// Guards `conn` itself — see `callSMC`.
    private static let connLock = NSLock()

    /// Read a decoded value from any SMC key. Reads the key's metadata first
    /// (data type + size), then decodes the payload — works for `flt` (Apple
    /// Silicon temps/fans), `fpe2`/`sp78` (Intel), and integer keys.
    ///
    /// Mirrors exelban/Stats' proven two-call protocol.
    static func read(_ key: UInt32) -> Double? {
        guard conn != 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()

        var type: UInt32 = 0
        var size: UInt32 = 0

        cacheLock.lock()
        let cached = keyInfoCache[key]
        cacheLock.unlock()

        if let cached {
            type = cached.type
            size = cached.size
        } else {
            // 1. Get key info (dataType + dataSize)
            input.key = key
            input.data8 = cmdReadKeyInfo
            guard callSMC(&input, &output) == KERN_SUCCESS else { return nil }

            size = output.keyInfo.dataSize
            type = output.keyInfo.dataType
            guard size > 0 else { return nil }

            cacheLock.lock()
            keyInfoCache[key] = (type: type, size: size)
            cacheLock.unlock()
        }

        // 2. Read the bytes
        input.key = key
        input.keyInfo.dataSize = size
        input.data8 = cmdReadBytes
        guard callSMC(&input, &output) == KERN_SUCCESS else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { raw in
            Array(raw.prefix(min(Int(size), 32)))
        }
        // All-zero payload means "no value" (matches Stats).
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return decode(type: type, bytes: bytes)
    }

    /// Convenience: read a value and round to UInt16 (fan RPM, etc.).
    static func readUInt16(_ key: UInt32) -> UInt16? {
        guard let v = read(key) else { return nil }
        return UInt16(max(0, min(65535, v.rounded())))
    }

    // MARK: - Writes

    /// Write a 16-bit value to an SMC key, encoding it for the key's data type.
    static func write(_ key: UInt32, u16 value: UInt16) -> Bool {
        guard conn != 0, let info = keyInfo(key) else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        switch info.type {
        case DType.flt:
            let bits = Float(value).bitPattern
            bytes[0] = UInt8(bits & 0xFF)
            bytes[1] = UInt8((bits >> 8) & 0xFF)
            bytes[2] = UInt8((bits >> 16) & 0xFF)
            bytes[3] = UInt8((bits >> 24) & 0xFF)
        case DType.fpe2:
            let raw = UInt16(min(65535, Int(value) * 4))
            bytes[0] = UInt8(raw >> 8); bytes[1] = UInt8(raw & 0xFF)
        default:
            if info.size == 4 {
                bytes[0] = UInt8((value >> 24) & 0xFF)
                bytes[1] = UInt8((value >> 16) & 0xFF)
                bytes[2] = UInt8((value >> 8) & 0xFF)
                bytes[3] = UInt8(value & 0xFF)
            } else if info.size == 2 {
                bytes[0] = UInt8(value >> 8); bytes[1] = UInt8(value & 0xFF)
            } else {
                bytes[0] = UInt8(min(255, value))
            }
        }
        return writeBytes(key, bytes, size: info.size)
    }

    private static func writeBytes(_ key: UInt32, _ data: [UInt8], size: UInt32) -> Bool {
        guard conn != 0 else { return false }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key
        input.data8 = cmdWriteBytes
        input.keyInfo.dataSize = size
        input.keyInfo.dataType = 0
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<min(data.count, 32) { raw[i] = data[i] }
        }
        guard callSMC(&input, &output) == KERN_SUCCESS else {
            NSLog("[SMC] write call failed for key %08X", key)
            return false
        }
        if output.result != 0 {
            NSLog("[SMC] write rejected key %08X (result=%d)", key, output.result)
        }
        return output.result == 0
    }

    // MARK: - SMC plumbing

    /// Query a key's metadata (data size + type) via kSMCGetKeyInfo.
    static func keyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = key
        input.data8 = cmdReadKeyInfo
        guard callSMC(&input, &output) == KERN_SUCCESS else { return nil }
        return (output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    /// Invoke the AppleSMC user client. Index 2 = KERNEL_INDEX_SMC; the actual
    /// command (read/write/getKeyInfo) lives in the struct's data8 field.
    /// Uses `MemoryLayout.stride` so the kernel gets the exact struct size.
    private static func callSMC(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        // One `io_connect_t` is shared by every caller. Sensor sampling now runs
        // on a background queue (HardwareMonitor.sensorQueue) while fan control
        // still writes from main, so the connection has to be serialised or two
        // threads can interleave calls on the same kernel handle.
        connLock.lock()
        defer { connLock.unlock() }
        guard conn != 0 else { return KERN_FAILURE }
        return IOConnectCallStructMethod(conn, kernelIndex, &input, inputSize, &output, &outputSize)
    }

    private static func decode(type: UInt32, bytes b: [UInt8]) -> Double {
        guard b.count >= 1 else { return 0 }
        switch type {
        case DType.flt where b.count >= 4:
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8)
                     | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return Double(Float(bitPattern: bits))
        case DType.fpe2 where b.count >= 2:
            // (b0 << 6) + (b1 >> 2)  — matches Stats
            return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        case DType.fp2e where b.count >= 2:
            return Double((UInt16(b[0]) << 8) | UInt16(b[1])) / 16384.0
        case DType.sp78 where b.count >= 2:
            let raw16 = (UInt16(b[0]) << 8) | UInt16(b[1])
            return Double(Int16(bitPattern: raw16)) / 256.0
        case DType.ui8:
            return Double(b[0])
        case DType.ui16 where b.count >= 2:
            return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
        case DType.ui32 where b.count >= 4:
            return Double((UInt32(b[0]) << 24) | (UInt32(b[1]) << 16)
                        | (UInt32(b[2]) << 8) | UInt32(b[3]))
        default:
            var v: UInt64 = 0
            for i in 0..<min(b.count, 8) { v = (v << 8) | UInt64(b[i]) }
            return Double(v)
        }
    }
}

// ---------------------------------------------------------------------------
// SMCKeyData_t — Apple's AppleSMC parameter struct, mirrored from
// exelban/Stats (the explicit `padding` field makes the Swift layout match
// the C struct so `MemoryLayout.stride` is correct).
// ---------------------------------------------------------------------------

private struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
        var reserved: UInt8 = 0, release: UInt16 = 0
    }
    struct LimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
    )
}
