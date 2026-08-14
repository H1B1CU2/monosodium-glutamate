// ddcprobe — DDC/CI probe for external displays on Apple Silicon.
//
// Purpose: find out which VCP 0x60 (Input Select) values a monitor actually
// accepts, so MSG can offer a "switch input" action. Vendors deviate from the
// MCCS standard constantly (MSI especially), so the values must be measured on
// the real panel rather than assumed.
//
// This is a standalone CLI, deliberately outside the MSG target — it is not in
// build.sh's file list and not in project.pbxproj.
//
//   Build:  xcrun swiftc -O tools/ddcprobe/main.swift -o /tmp/ddcprobe -framework IOKit -framework CoreFoundation
//   Run:    /tmp/ddcprobe               # read-only: list displays, caps, current input
//           /tmp/ddcprobe --watch       # poll input every second while you flip inputs on the OSD
//           /tmp/ddcprobe --raw         # add raw DDC frame hex dumps
//           /tmp/ddcprobe --set 0x11    # WRITE: switch input (only VCP 0x60 is ever written)
//
// Everything except --set is read-only.
//
// Transport: DDC/CI rides the display's I2C bus. On Apple Silicon there is no
// public API for that; the private IOAVService family in IOKit.framework is the
// only route (same one m1ddc and BetterDisplay use). Symbols are resolved with
// dlsym rather than declared, so a missing symbol on a future macOS degrades to
// a clear error instead of a link failure.

import Foundation
import IOKit

// MARK: - Private IOAVService bindings

typealias IOAVServiceRef = CFTypeRef

private let iokitHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

private func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = iokitHandle, let sym = dlsym(handle, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private typealias CreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias CopyEDIDFn =
    @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
private typealias ReadI2CFn =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias WriteI2CFn =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

private let avCreateWithService = loadSymbol("IOAVServiceCreateWithService", as: CreateWithServiceFn.self)
private let avCopyEDID          = loadSymbol("IOAVServiceCopyEDID",          as: CopyEDIDFn.self)
private let avReadI2C           = loadSymbol("IOAVServiceReadI2C",           as: ReadI2CFn.self)
private let avWriteI2C          = loadSymbol("IOAVServiceWriteI2C",          as: WriteI2CFn.self)

// MARK: - DDC/CI constants

/// 7-bit I2C address of the display's DDC/CI endpoint (0x6E >> 1).
private let ddcChipAddress: UInt32 = 0x37
/// The "offset" IOAVServiceRead/WriteI2C takes is the DDC source address byte.
private let ddcSubAddress: UInt32 = 0x51
/// Checksum seed for host→display frames: destination (0x6E) ^ source (0x51).
private let hostChecksumSeed: UInt8 = 0x6E ^ 0x51

/// MCCS wants ≥40 ms between a Get request and its reply, and ≥50 ms between
/// consecutive messages. Panels that violate the spec fail with less.
private let ddcReplyDelay: UInt32 = 60_000    // µs
private let ddcInterMessageDelay: UInt32 = 60_000

// MARK: - Options

struct Options {
    var watch = false
    var raw = false
    var setValue: UInt16?
    var displayIndex: Int?
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let arg = args.first {
        args.removeFirst()
        switch arg {
        case "--watch": o.watch = true
        case "--raw":   o.raw = true
        case "--set":
            guard let v = args.first, let parsed = parseNumber(v) else {
                fail("--set needs a value, e.g. --set 0x11")
            }
            args.removeFirst()
            o.setValue = parsed
        case "--display":
            guard let v = args.first, let parsed = parseNumber(v) else {
                fail("--display needs an index, e.g. --display 0")
            }
            args.removeFirst()
            o.displayIndex = Int(parsed)
        case "-h", "--help":
            print("""
            ddcprobe — read a display's DDC/CI input-select capabilities.

              (no args)        list external displays, capabilities, current input
              --watch          poll input select every second (flip inputs on the OSD to map codes)
              --raw            include raw DDC frame hex
              --display N      target only display N (default: all)
              --set 0xNN       WRITE VCP 0x60 to 0xNN (switches input — you may lose the Mac's picture)
            """)
            exit(0)
        default:
            fail("unknown argument: \(arg)")
        }
    }
    return o
}

func parseNumber(_ s: String) -> UInt16? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt16(s.dropFirst(2), radix: 16) }
    return UInt16(s)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("error: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Display discovery

struct ExternalDisplay {
    let index: Int
    let service: IOAVServiceRef
    let name: String
    let serial: String?
}

/// Every external panel exposes a DCPAVServiceProxy node with Location=External.
/// The built-in display has one too (Location=Embedded) but no DDC bus behind it.
func findExternalDisplays() -> [ExternalDisplay] {
    guard let create = avCreateWithService else {
        fail("IOAVServiceCreateWithService is unavailable on this macOS build")
    }
    var displays: [ExternalDisplay] = []
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("DCPAVServiceProxy"),
                                       &iterator) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iterator) }

    var index = 0
    while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                       kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        guard location == "External" else { continue }
        guard let svc = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }

        let edid = readEDID(svc)
        displays.append(ExternalDisplay(index: index,
                                        service: svc,
                                        name: edid?.name ?? "External display \(index)",
                                        serial: edid?.serial))
        index += 1
    }
    return displays
}

// MARK: - EDID

/// Only the descriptor blocks are parsed — enough to label which panel we are
/// talking to when more than one is attached.
func readEDID(_ service: IOAVServiceRef) -> (name: String?, serial: String?)? {
    guard let copyEDID = avCopyEDID else { return nil }
    var out: Unmanaged<CFData>?
    guard copyEDID(service, &out) == KERN_SUCCESS, let data = out?.takeRetainedValue() as Data? else {
        return nil
    }
    guard data.count >= 128 else { return nil }

    var name: String?
    var serial: String?
    // Four 18-byte descriptors start at offset 54. A descriptor whose first two
    // bytes are zero is a text block; byte 3 is its type tag.
    for block in 0..<4 {
        let base = 54 + block * 18
        guard base + 18 <= data.count else { break }
        guard data[base] == 0, data[base + 1] == 0 else { continue }
        let tag = data[base + 3]
        let text = String(decoding: data[(base + 5)..<(base + 18)], as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n ").union(.controlCharacters))
        if tag == 0xFC { name = text }
        if tag == 0xFF { serial = text }
    }
    return (name, serial)
}

// MARK: - DDC primitives

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

@discardableResult
func ddcWrite(_ service: IOAVServiceRef, _ payload: [UInt8], raw: Bool) -> Bool {
    guard let write = avWriteI2C else { return false }
    var frame = payload
    // Checksum covers destination + source + everything in the payload.
    frame.append(frame.reduce(hostChecksumSeed) { $0 ^ $1 })
    if raw { print("      → \(hex(frame))") }
    let result = frame.withUnsafeBytes { buf -> IOReturn in
        write(service, ddcChipAddress, ddcSubAddress, buf.baseAddress!, UInt32(buf.count))
    }
    if result != KERN_SUCCESS {
        if raw { print("      write failed: \(String(format: "0x%08X", result))") }
        return false
    }
    return true
}

func ddcRead(_ service: IOAVServiceRef, count: Int, raw: Bool) -> [UInt8]? {
    guard let read = avReadI2C else { return nil }
    var buffer = [UInt8](repeating: 0, count: count)
    let result = buffer.withUnsafeMutableBytes { buf -> IOReturn in
        read(service, ddcChipAddress, ddcSubAddress, buf.baseAddress!, UInt32(count))
    }
    guard result == KERN_SUCCESS else {
        if raw { print("      read failed: \(String(format: "0x%08X", result))") }
        return nil
    }
    if raw { print("      ← \(hex(buffer))") }
    return buffer
}

struct VCPReading {
    let current: UInt16
    let maximum: UInt16
}

/// Get VCP Feature (opcode 0x01). Reply frame:
///   6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <checksum>
/// Some driver versions hand back the buffer without the leading source-address
/// byte, so the reply opcode is located rather than assumed.
func getVCP(_ service: IOAVServiceRef, code: UInt8, raw: Bool) -> VCPReading? {
    guard ddcWrite(service, [0x82, 0x01, code], raw: raw) else { return nil }
    usleep(ddcReplyDelay)
    guard let reply = ddcRead(service, count: 12, raw: raw) else { return nil }

    // Locate the 0x02 (feature reply) opcode: offset 2 in a well-formed frame.
    for start in [2, 1, 0, 3] where start + 7 < reply.count {
        guard reply[start] == 0x02 else { continue }
        let resultCode = reply[start + 1]
        let vcp = reply[start + 2]
        guard vcp == code else { continue }
        guard resultCode == 0x00 else {
            if raw { print("      VCP \(String(format: "0x%02X", code)) unsupported (result \(resultCode))") }
            return nil
        }
        let maximum = UInt16(reply[start + 4]) << 8 | UInt16(reply[start + 5])
        let current = UInt16(reply[start + 6]) << 8 | UInt16(reply[start + 7])
        return VCPReading(current: current, maximum: maximum)
    }
    return nil
}

/// Set VCP Feature (opcode 0x03). No reply is defined by MCCS.
func setVCP(_ service: IOAVServiceRef, code: UInt8, value: UInt16, raw: Bool) -> Bool {
    ddcWrite(service, [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)], raw: raw)
}

/// Capabilities Request (opcode 0xF3) returns the capability string in ≤32-byte
/// fragments. Reply frame:
///   6E <0x80|len> E3 <offHi> <offLo> <data…> <checksum>
/// A reply carrying zero data bytes ends the string.
func readCapabilities(_ service: IOAVServiceRef, raw: Bool) -> String? {
    var out = [UInt8]()
    var offset: UInt16 = 0
    // 32 bytes per fragment; 128 iterations is ~4KB, far past any real string.
    for _ in 0..<128 {
        guard ddcWrite(service, [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)], raw: raw) else {
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }
        usleep(ddcReplyDelay)
        guard let reply = ddcRead(service, count: 40, raw: raw) else {
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }

        // Same tolerance as getVCP: find the 0xE3 reply opcode near the front.
        var start = -1
        for candidate in [2, 1, 0, 3] where candidate < reply.count {
            if reply[candidate] == 0xE3 { start = candidate; break }
        }
        // >= 1, not >= 0: the length byte read below sits *before* the opcode.
        guard start >= 1 else { break }

        // The length byte sits immediately before the opcode; low 7 bits are the
        // byte count of opcode + 2 offset bytes + payload.
        let lengthByte = reply[start - 1] & 0x7F
        guard lengthByte >= 3 else { break }          // 3 = header only → string complete
        let payloadCount = Int(lengthByte) - 3
        guard payloadCount > 0 else { break }
        let payloadStart = start + 3
        guard payloadStart + payloadCount <= reply.count else { break }

        out.append(contentsOf: reply[payloadStart..<(payloadStart + payloadCount)])
        offset += UInt16(payloadCount)
        usleep(ddcInterMessageDelay)
    }
    return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
}

// MARK: - Input-select decoding

/// MCCS-standard VCP 0x60 values. Vendors add their own — anything not listed
/// here is reported as unknown rather than guessed at.
let standardInputNames: [UInt16: String] = [
    0x01: "VGA-1", 0x02: "VGA-2",
    0x03: "DVI-1", 0x04: "DVI-2",
    0x05: "Composite-1", 0x06: "Composite-2",
    0x07: "S-Video-1", 0x08: "S-Video-2",
    0x09: "Tuner-1", 0x0A: "Tuner-2", 0x0B: "Tuner-3",
    0x0C: "Component-1", 0x0D: "Component-2", 0x0E: "Component-3",
    0x0F: "DisplayPort-1", 0x10: "DisplayPort-2",
    0x11: "HDMI-1", 0x12: "HDMI-2",
    0x1B: "USB-C (common vendor extension)",
]

func describeInput(_ value: UInt16) -> String {
    standardInputNames[value].map { "\($0)" } ?? "unknown/vendor-specific"
}

/// Pulls the `60(...)` group out of a capability string, e.g. "…vcp(02 10 60(0F 11 12) …)…".
func inputValuesFromCapabilities(_ caps: String) -> [UInt16]? {
    guard let marker = caps.range(of: "60(") else { return nil }
    guard let close = caps[marker.upperBound...].firstIndex(of: ")") else { return nil }
    let body = caps[marker.upperBound..<close]
    let values = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
        .compactMap { UInt16($0, radix: 16) }
    return values.isEmpty ? nil : values
}

// MARK: - Report

func probe(_ display: ExternalDisplay, options: Options) {
    print("")
    print("── Display \(display.index): \(display.name)"
          + (display.serial.map { "  (serial \($0))" } ?? ""))

    // Brightness first: it is the most widely implemented VCP code, so it
    // separates "DDC does not work on this link" from "this panel ignores 0x60".
    if let brightness = getVCP(display.service, code: 0x10, raw: options.raw) {
        print("   DDC/CI:        responding (brightness \(brightness.current)/\(brightness.maximum))")
    } else {
        print("   DDC/CI:        no valid reply for brightness (0x10)")
        print("                  → this link may not carry DDC; try the other cable/port")
    }
    usleep(ddcInterMessageDelay)

    if let input = getVCP(display.service, code: 0x60, raw: options.raw) {
        print(String(format: "   Input select:  0x%02X  (%@)", input.current, describeInput(input.current)))
    } else {
        print("   Input select:  VCP 0x60 did not answer")
    }
    usleep(ddcInterMessageDelay)

    if let caps = readCapabilities(display.service, raw: options.raw) {
        print("   Capabilities:  \(caps)")
        if let values = inputValuesFromCapabilities(caps) {
            print("   Declared inputs:")
            for v in values {
                print(String(format: "     0x%02X  %@", v, describeInput(v)))
            }
        } else {
            print("   Declared inputs: capability string has no 60(...) group")
            print("                    → use --watch and switch inputs on the OSD instead")
        }
    } else {
        print("   Capabilities:  not returned")
        print("                  → use --watch and switch inputs on the OSD instead")
    }
}

func watch(_ displays: [ExternalDisplay], options: Options) {
    print("")
    print("Watching VCP 0x60 once per second. Switch inputs on the monitor's own")
    print("OSD and note the value that appears for each one. Ctrl-C to stop.")
    print("")
    var last: [Int: UInt16] = [:]
    while true {
        for display in displays {
            guard let reading = getVCP(display.service, code: 0x60, raw: options.raw) else { continue }
            if last[display.index] != reading.current {
                last[display.index] = reading.current
                let stamp = ISO8601DateFormatter().string(from: Date())
                print(String(format: "%@  display %d  input = 0x%02X  (%@)",
                             stamp, display.index, reading.current, describeInput(reading.current)))
            }
            usleep(ddcInterMessageDelay)
        }
        sleep(1)
    }
}

// MARK: - Entry point

let options = parseOptions()

guard avReadI2C != nil, avWriteI2C != nil else {
    fail("IOAVServiceReadI2C/WriteI2C unavailable — DDC/CI cannot be reached on this system")
}

var displays = findExternalDisplays()
if let wanted = options.displayIndex {
    displays = displays.filter { $0.index == wanted }
    if displays.isEmpty { fail("no external display with index \(wanted)") }
}

guard !displays.isEmpty else {
    print("No external displays found (built-in panels have no DDC bus).")
    exit(0)
}

print("Found \(displays.count) external display(s).")

if let value = options.setValue {
    for display in displays {
        print(String(format: "Setting display %d input select to 0x%02X (%@)…",
                     display.index, value, describeInput(value)))
        let ok = setVCP(display.service, code: 0x60, value: value, raw: options.raw)
        print(ok ? "  write accepted by the I2C layer (the panel decides what to do with it)"
                 : "  write failed")
    }
    exit(0)
}

for display in displays { probe(display, options: options) }

if options.watch { watch(displays, options: options) }
