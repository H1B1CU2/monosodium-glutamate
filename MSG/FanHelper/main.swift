import Foundation
import IOKit

// MARK: - SMC
//
// Ported from the previous C helper, which is the version that was proven to
// drive these fans. The protocol is the two-call AppleSMC one: read a key's
// type/size, then read or write its payload.

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (dataSize: UInt32, dataType: UInt32, dataAttributes: UInt8) = (0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMC {
    static var conn: io_connect_t = 0
    private static let kernelIndex: UInt32 = 2
    private static let cmdRead: UInt8 = 5
    private static let cmdWrite: UInt8 = 6
    private static let cmdKeyInfo: UInt8 = 9

    static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
        return v
    }

    static func open() -> Bool {
        guard conn == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        if kr != KERN_SUCCESS { conn = 0; return false }
        return true
    }

    private static func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let size = MemoryLayout<SMCKeyData>.stride
        var outSize = size
        return IOConnectCallStructMethod(conn, kernelIndex, &input, size, &output, &outSize)
    }

    static func keyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        var i = SMCKeyData(); var o = SMCKeyData()
        i.key = key; i.data8 = cmdKeyInfo
        guard call(&i, &o) == KERN_SUCCESS, o.keyInfo.dataSize > 0 else { return nil }
        return (o.keyInfo.dataSize, o.keyInfo.dataType)
    }

    /// Reads a key as UInt16, decoding the float/fpe2 encodings Apple uses for
    /// fan values on different generations.
    static func readUInt16(_ key: UInt32) -> UInt16? {
        guard let info = keyInfo(key) else { return nil }
        var i = SMCKeyData(); var o = SMCKeyData()
        i.key = key; i.keyInfo.dataSize = info.size; i.data8 = cmdRead
        guard call(&i, &o) == KERN_SUCCESS else { return nil }
        let b = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(min(info.size, 32)))) }
        guard b.contains(where: { $0 != 0 }) else { return nil }
        switch info.type {
        case fourCC("flt "):
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            return UInt16(max(0, min(65535, Float(bitPattern: bits).rounded())))
        case fourCC("fpe2"):
            guard b.count >= 2 else { return nil }
            return UInt16((UInt32(b[0]) << 6) | (UInt32(b[1]) >> 2))
        default:
            if b.count >= 2 { return UInt16(b[0]) << 8 | UInt16(b[1]) }
            return UInt16(b[0])
        }
    }

    static func write(_ key: UInt32, _ value: UInt16) -> Bool {
        guard let info = keyInfo(key) else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        switch info.type {
        case fourCC("flt "):
            let bits = Float(value).bitPattern
            bytes[0] = UInt8(bits & 0xFF); bytes[1] = UInt8((bits >> 8) & 0xFF)
            bytes[2] = UInt8((bits >> 16) & 0xFF); bytes[3] = UInt8((bits >> 24) & 0xFF)
        case fourCC("fpe2"):
            let raw = UInt16(min(65535, Int(value) * 4))
            bytes[0] = UInt8(raw >> 8); bytes[1] = UInt8(raw & 0xFF)
        default:
            if info.size == 4 {
                bytes[0] = UInt8((value >> 24) & 0xFF); bytes[1] = UInt8((value >> 16) & 0xFF)
                bytes[2] = UInt8((value >> 8) & 0xFF);  bytes[3] = UInt8(value & 0xFF)
            } else if info.size == 2 {
                bytes[0] = UInt8(value >> 8); bytes[1] = UInt8(value & 0xFF)
            } else {
                bytes[0] = UInt8(min(255, value))
            }
        }
        var i = SMCKeyData(); var o = SMCKeyData()
        i.key = key; i.data8 = cmdWrite
        i.keyInfo.dataSize = info.size; i.keyInfo.dataType = 0
        withUnsafeMutableBytes(of: &i.bytes) { raw in
            for n in 0..<min(bytes.count, 32) { raw[n] = bytes[n] }
        }
        guard call(&i, &o) == KERN_SUCCESS else { return false }
        return o.result == 0
    }
}

// MARK: - Fan control

private enum Fans {
    static func key(_ index: Int, _ suffix: String) -> UInt32 { SMC.fourCC("F\(index)\(suffix)") }

    static func count() -> Int {
        guard let c = SMC.readUInt16(SMC.fourCC("FNum")), c > 0, c < 10 else { return 0 }
        return Int(c)
    }

    /// Newer chips gate manual control behind `Ftst` (diagnostic mode) rather
    /// than the older `FS! ` bitmask. Matching the previous helper exactly.
    private static var useFSBitmask: Bool {
        let hasFS = SMC.keyInfo(SMC.fourCC("FS! ")) != nil
        let hasFtst = SMC.keyInfo(SMC.fourCC("Ftst")) != nil
        return hasFS && !hasFtst
    }

    static func setPercent(_ pct: Double) -> Bool {
        let n = count()
        guard n > 0 else { return false }
        if useFSBitmask {
            var mask: UInt16 = 0
            for i in 0..<n { mask |= UInt16(1 << i) }
            guard SMC.write(SMC.fourCC("FS! "), mask) else { return false }
        } else if SMC.keyInfo(SMC.fourCC("Ftst")) != nil {
            guard SMC.write(SMC.fourCC("Ftst"), 1) else { return false }
        }
        var failures = 0
        for i in 0..<n {
            let mn = SMC.readUInt16(key(i, "Mn")) ?? 0
            guard let mx = SMC.readUInt16(key(i, "Mx")), mx > 0 else { failures += 1; continue }
            if !useFSBitmask {
                _ = SMC.write(key(i, "Md"), 1)
                _ = SMC.write(key(i, "md"), 1)
            }
            let rpm = UInt16(max(Double(mn), min(Double(mx), Double(mx) * pct / 100.0)).rounded())
            if !SMC.write(key(i, "Tg"), rpm) { failures += 1 }
        }
        return failures == 0
    }

    static func restoreAutomatic() -> Bool {
        let n = count()
        guard n > 0 else { return false }
        if useFSBitmask { return SMC.write(SMC.fourCC("FS! "), 0) }
        for i in 0..<n {
            _ = SMC.write(key(i, "Md"), 0)
            _ = SMC.write(key(i, "md"), 0)
        }
        if SMC.keyInfo(SMC.fourCC("Ftst")) != nil { _ = SMC.write(SMC.fourCC("Ftst"), 0) }
        return true
    }
}

// MARK: - Controller

/// Holds manual fan control only for as long as the app keeps renewing a lease.
///
/// This is the safety property the socket helper never had: manual mode
/// survives in the SMC across a crash, so an app that died with the fans pinned
/// left them pinned. Here the watchdog notices the missing heartbeats and puts
/// the fans back on automatic itself.
private final class Controller {
    /// How long a single heartbeat buys. The app sends one well inside this.
    static let leaseSeconds: Double = 20
    private let queue = DispatchQueue(label: "msg.fanhelper.control")
    private var state = FanHelperSnapshot()
    private var leaseExpiry: Date?
    private var watchdog: DispatchSourceTimer?

    init() {
        _ = SMC.open()
        state.fanCount = Fans.count()
        // Anything left in manual mode by a previous run (crash, force quit,
        // reboot with the SMC flag still set) is not ours to keep holding.
        _ = Fans.restoreAutomatic()
        startWatchdog()
    }

    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func tick() {
        guard let expiry = leaseExpiry else { return }
        let remaining = expiry.timeIntervalSinceNow
        state.secondsUntilRestore = max(0, remaining)
        guard remaining <= 0 else { return }
        NSLog("[fan-helper] lease expired — restoring automatic control")
        _ = Fans.restoreAutomatic()
        leaseExpiry = nil
        state.mode = "auto"
        state.percent = nil
        state.secondsUntilRestore = nil
    }

    private func renew() {
        leaseExpiry = Date().addingTimeInterval(Self.leaseSeconds)
        state.secondsUntilRestore = Self.leaseSeconds
    }

    func setPercent(_ pct: Double) -> FanHelperReply {
        queue.sync {
            let clamped = max(0, min(100, pct))
            guard Fans.setPercent(clamped) else {
                return FanHelperReply(ok: false, snapshot: state, error: "smcWriteFailed")
            }
            state.mode = "manual"
            state.percent = clamped
            state.fanCount = Fans.count()
            renew()
            return FanHelperReply(ok: true, snapshot: state)
        }
    }

    func restoreAutomatic() -> FanHelperReply {
        queue.sync {
            let ok = Fans.restoreAutomatic()
            leaseExpiry = nil
            state.mode = "auto"
            state.percent = nil
            state.secondsUntilRestore = nil
            return FanHelperReply(ok: ok, snapshot: state, error: ok ? nil : "smcWriteFailed")
        }
    }

    func setPowerMode(_ mode: Int) -> FanHelperReply {
        queue.sync {
            guard (0...2).contains(mode) else {
                return FanHelperReply(ok: false, snapshot: state, error: "badArgument")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["-a", "powermode", String(mode)]
            do { try p.run(); p.waitUntilExit() } catch {
                return FanHelperReply(ok: false, snapshot: state, error: "pmsetFailed")
            }
            let ok = p.terminationStatus == 0
            return FanHelperReply(ok: ok, snapshot: state, error: ok ? nil : "pmsetFailed")
        }
    }

    func heartbeat() -> FanHelperReply {
        queue.sync {
            if state.mode == "manual" { renew() }
            return FanHelperReply(ok: true, snapshot: state)
        }
    }

    func status() -> FanHelperReply {
        queue.sync { FanHelperReply(ok: true, snapshot: state) }
    }
}

// MARK: - XPC

private final class Service: NSObject, FanHelperProtocol {
    private let controller: Controller
    init(controller: Controller) { self.controller = controller }

    func setPercent(_ percent: Double, withReply reply: @escaping (Data) -> Void) {
        reply(FanHelperCodec.encode(controller.setPercent(percent)))
    }
    func restoreAutomatic(withReply reply: @escaping (Data) -> Void) {
        reply(FanHelperCodec.encode(controller.restoreAutomatic()))
    }
    func setPowerMode(_ mode: Int, withReply reply: @escaping (Data) -> Void) {
        reply(FanHelperCodec.encode(controller.setPowerMode(mode)))
    }
    func heartbeat(withReply reply: @escaping (Data) -> Void) {
        reply(FanHelperCodec.encode(controller.heartbeat()))
    }
    func status(withReply reply: @escaping (Data) -> Void) {
        reply(FanHelperCodec.encode(controller.status()))
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let controller: Controller
    init(controller: Controller) { self.controller = controller }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = Service(controller: controller)
        connection.resume()
        return true
    }
}

guard geteuid() == 0 else {
    NSLog("[fan-helper] must run as root")
    exit(EXIT_FAILURE)
}

private let controller = Controller()
private let delegate = ListenerDelegate(controller: controller)
private let listener = NSXPCListener(machServiceName: FanHelperID.helperID)
// The kernel refuses any peer that isn't the signed MSG binary, so being the
// same user is no longer enough to command the fans.
listener.setConnectionCodeSigningRequirement(FanHelperID.appRequirement)
listener.delegate = delegate
listener.resume()
NSLog("[fan-helper] listening on %@", FanHelperID.helperID)
RunLoop.main.run()
