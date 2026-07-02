import IOKit
import AppKit

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

    enum MemoryPressure: String {
        case normal  = "N"
        case warning = "W"
        case critical = "C"
    }
}

// ---------------------------------------------------------------------------
// HardwareMonitor
// ---------------------------------------------------------------------------

final class HardwareMonitor {

    static let shared = HardwareMonitor()

    private var timer: Timer?
    private var observers: [() -> Void] = []

    private(set) var stats = HardwareStats()

    /// Previous CPU tick snapshot for delta computation.
    private var prevCPU: [UInt32]?

    /// Number of logical CPUs (including hyperthreading).
    private var cpuCount: Int32 = 0

    private init() {}

    // MARK: - Observer list

    func addObserver(_ cb: @escaping () -> Void) { observers.append(cb) }
    private func notify() { observers.forEach { $0() } }

    // MARK: - Lifecycle

    func start() {
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

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    func updateInterval(_ seconds: Double) {
        let clamped = max(1.0, min(10.0, seconds))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: clamped, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
    }

    // MARK: - Poll

    private func poll() {
        stats.cpuPercent = readCPU()
        stats.gpuPercent = readGPU()
        readMemory()
        readTemps()
        stats.fps = readFPS()
        readFans()
        applyFanCurve()
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

    /// Build a 4-char-code SMC key (UInt32) from a string, e.g. "TC0D".
    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

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

    private static let cpuSensorKeys: [UInt32] = cpuSensorNames.map(fourCC)
    private static let gpuSensorKeys: [UInt32] = gpuSensorNames.map(fourCC)

    private func readTemps() {
        stats.cpuTemp = averageTemp(Self.cpuSensorKeys)
        stats.gpuTemp = averageTemp(Self.gpuSensorKeys)
        if !tempLogOnce {
            var found: [String] = []
            for (name, key) in zip(Self.cpuSensorNames + Self.gpuSensorNames,
                                    Self.cpuSensorKeys + Self.gpuSensorKeys) {
                if let v = SMCController.read(key), v > 0, v < 130 {
                    found.append("\(name)=\(String(format: "%.1f", v))")
                }
            }
            NSLog("[HW] Valid temp sensors: %@", found.isEmpty ? "none" : found.joined(separator: ", "))
            tempLogOnce = true
        }
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

    // MARK: - Fans

    /// Per-fan SMC keys, indexed by fan number (F0…, F1…).
    /// Ac = actual RPM, Mn = min, Mx = max, Tg = target, Md/md = control mode.
    private struct FanKeys {
        let act, min, max, target, mode, modeLower: UInt32
        init(_ i: Int) {
            func k(_ suffix: String) -> UInt32 {
                HardwareMonitor.fourCC("F\(i)\(suffix)")
            }
            act = k("Ac"); min = k("Mn"); max = k("Mx")
            target = k("Tg"); mode = k("Md"); modeLower = k("md")
        }
    }
    private static let fnumKey = fourCC("FNum")
    private var fanLogOnce = false
    private var tempLogOnce = false
    private var fansForced = false

    private func readFans() {
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
            stats.fans = []
            return
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
        stats.fans = fans
    }

    /// Ftst key — diagnostic mode flag that suppresses thermalmonitord.
    /// Required on M3/M4+ to take manual fan control.
    private static let ftstKey = fourCC("Ftst")
    /// FS! key — fan status/manual force bitmask key. Used on Intel Macs.
    private static let fsKey = fourCC("FS! ")

    /// Force all fans to maximum speed. Uses the Ftst unlock sequence when
    /// direct writes are blocked by thermalmonitord (M3/M4+).
    func fanFullBlast() {
        _ = SMCController.open()
        readFans()
        guard !stats.fans.isEmpty else {
            NSLog("[HW] fanFullBlast: no fans to control")
            return
        }

        fansForced = true
        fanControlUnlocking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            if SMCController.keyInfo(Self.fsKey) != nil {
                // Intel / FS! path
                var mask: UInt16 = 0
                for f in self.stats.fans {
                    mask |= (1 << f.index)
                }
                let fsOK = SMCController.write(Self.fsKey, u16: mask)
                NSLog("[HW] fanFullBlast FS! write mask %d: %@", mask, fsOK ? "OK" : "FAIL")
                
                for f in self.stats.fans {
                    let fk = FanKeys(f.index)
                    let tgOK = SMCController.write(fk.target, u16: UInt16(f.max))
                    NSLog("[HW] fanFullBlast %@: Tg=%d max=%d", f.name, tgOK, f.max)
                }
            } else {
                // Apple Silicon / Ftst path
                // Step 1: Signal diagnostic mode — suppresses thermalmonitord.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 1)
                NSLog("[HW] fanFullBlast Ftst=1: %@", ftstOK ? "OK" : "FAIL")

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
                    NSLog("[HW] fanFullBlast %@: Tg=%d max=%@", f.name, tgOK, String(f.max))
                }
            }
            self.fanControlUnlocking = false
            DispatchQueue.main.async { self.readFans() }
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
    func fanReset() {
        _ = SMCController.open()
        readFans()
        guard !stats.fans.isEmpty else {
            NSLog("[HW] fanReset: no fans to control")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            if SMCController.keyInfo(Self.fsKey) != nil {
                // Intel / FS! path
                let fsOK = SMCController.write(Self.fsKey, u16: 0)
                NSLog("[HW] fanReset FS!=0: %@", fsOK ? "OK" : "FAIL")
            } else {
                // Apple Silicon / Ftst path
                for f in self.stats.fans {
                    let fk = FanKeys(f.index)
                    _ = SMCController.write(fk.mode, u16: 0)
                    _ = SMCController.write(fk.modeLower, u16: 0)
                    NSLog("[HW] fanReset %@: mode→Auto", f.name)
                }
                // Release diagnostic mode so thermalmonitord resumes.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 0)
                NSLog("[HW] fanReset Ftst=0: %@", ftstOK ? "OK" : "FAIL")
            }
            self.fansForced = false
            self.fanControlUnlocking = false
            DispatchQueue.main.async { self.readFans() }
        }
    }

    /// True while fans are being forced to full blast by us.
    var isFanFullBlast: Bool { fansForced }

    /// Guards against duplicate unlock attempts while the Ftst dance is in flight.
    private var fanControlUnlocking = false

    // MARK: - Fan curve engine

    /// Returns the stored curve for a preset, or a sensible fallback.
    private func fanCurve(for preset: String) -> [(Double, Double)] {
        if let stored = AppSettings.shared.hardwareStatsFanCurves[preset] {
            return stored.map { ($0[0], $0[1]) }
        }
        switch preset {
        case "silent":
            return [(30, 15), (50, 25), (65, 40), (80, 60), (95, 80)]
        case "performance":
            return [(30, 30), (50, 50), (65, 70), (80, 85), (95, 100)]
        case "fullBlast":
            return [(0, 100), (100, 100)]
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
            if fansForced { fanReset() }
            return
        }
        guard !stats.fans.isEmpty else { return }

        let curve = fanCurve(for: preset)
        let maxTemp = max(stats.cpuTemp ?? 30, stats.gpuTemp ?? 30)
        let rpmPct = curveRPMPercent(for: maxTemp, curve: curve)

        // Already in control — quick inline target update.
        if fansForced {
            for f in stats.fans {
                let targetRPM = Int(Double(f.max) * rpmPct / 100.0)
                let clamped = max(f.min, min(f.max, targetRPM))
                let fk = FanKeys(f.index)
                SMCController.write(fk.target, u16: UInt16(clamped))
            }
            return
        }

        // Not yet in control — do the full Ftst unlock asynchronously.
        guard !fanControlUnlocking else { return }
        takeFanControl(targetPct: rpmPct)
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = SMCController.open()

            if SMCController.keyInfo(Self.fsKey) != nil {
                // Intel / FS! path
                var mask: UInt16 = 0
                for f in fans {
                    mask |= (1 << f.index)
                }
                let fsOK = SMCController.write(Self.fsKey, u16: mask)
                NSLog("[HW] takeFanControl FS! write mask %d: %@", mask, fsOK ? "OK" : "FAIL")
                
                for f in fans {
                    let fk = FanKeys(f.index)
                    let targetRPM = Int(Double(f.max) * rpmPct / 100.0)
                    let clamped = max(f.min, min(f.max, targetRPM))
                    let tgOK = SMCController.write(fk.target, u16: UInt16(clamped))
                    NSLog("[HW] takeFanControl %@: Tg=%d rpm=%d", f.name, tgOK, clamped)
                }
            } else {
                // Apple Silicon / Ftst path
                // Step 1 — diagnostic mode.
                let ftstOK = SMCController.write(Self.ftstKey, u16: 1)
                NSLog("[HW] takeFanControl Ftst=1: %@", ftstOK ? "OK" : "FAIL")

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
                    NSLog("[HW] takeFanControl %@: Md=%d md=%d Tg=%d rpm=%@",
                          f.name, mdOK, mdOK2, tgOK, String(clamped))
                }
            }
            self.fanControlUnlocking = false
            DispatchQueue.main.async { self.readFans() }
        }
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
        guard conn != 0 else { return }
        IOServiceClose(conn)
        conn = 0
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

    /// Read a decoded value from any SMC key. Reads the key's metadata first
    /// (data type + size), then decodes the payload — works for `flt` (Apple
    /// Silicon temps/fans), `fpe2`/`sp78` (Intel), and integer keys.
    ///
    /// Mirrors exelban/Stats' proven two-call protocol.
    static func read(_ key: UInt32) -> Double? {
        guard conn != 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()

        // 1. Get key info (dataType + dataSize)
        input.key = key
        input.data8 = cmdReadKeyInfo
        guard callSMC(&input, &output) == KERN_SUCCESS else { return nil }

        let size = output.keyInfo.dataSize
        let type = output.keyInfo.dataType
        guard size > 0 else { return nil }

        // 2. Read the bytes
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
