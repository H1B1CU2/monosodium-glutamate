import AppKit
import IOKit

// MARK: - Private IOAVService bindings
//
// Switching a monitor's input means writing VCP 0x60 (Input Select) over the
// display's DDC/CI channel, which rides the panel's I2C bus. HDMI-CEC is not an
// option — macOS ships no CEC stack at all — and Apple publishes no publicI2C
// API on Apple Silicon. The private IOAVService family is the only route.
//
// Symbols are resolved with dlsym rather than declared with @_silgen_name so a
// removal in a future macOS degrades to "no monitors found" instead of failing
// to launch the app. They live in IOKit.framework (verified with dyld_info —
// not CoreDisplay and not DisplayServices, where other display privates sit).

private typealias IOAVServiceRef = CFTypeRef

private let iokitHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

private func avSymbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = iokitHandle, let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
}

private typealias AVCreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias AVCopyEDIDFn =
    @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
private typealias AVReadI2CFn =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
private typealias AVWriteI2CFn =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

private let avCreateWithService = avSymbol("IOAVServiceCreateWithService", as: AVCreateWithServiceFn.self)
private let avCopyEDID          = avSymbol("IOAVServiceCopyEDID",          as: AVCopyEDIDFn.self)
private let avReadI2C           = avSymbol("IOAVServiceReadI2C",           as: AVReadI2CFn.self)
private let avWriteI2C          = avSymbol("IOAVServiceWriteI2C",          as: AVWriteI2CFn.self)

// MARK: - DDC/CI wire constants

/// 7-bit I2C address of the display's DDC/CI endpoint (0x6E >> 1).
private let ddcChipAddress: UInt32 = 0x37
/// The "offset" the IOAVService I2C calls take is the DDC source-address byte.
private let ddcSubAddress: UInt32 = 0x51
/// Checksum seed for host→display frames: destination (0x6E) ^ source (0x51).
private let ddcChecksumSeed: UInt8 = 0x6E ^ 0x51
/// MCCS requires ≥40 ms before reading a reply and ≥50 ms between messages.
/// Panels that cut corners on the spec fail below this, so both use 60 ms.
private let ddcDelay: UInt32 = 60_000

// MARK: - Engine

/// Reads which inputs an external monitor advertises and switches between them.
///
/// Everything here is slow, blocking I2C: a capability-string read is a dozen
/// round trips at 60 ms each, so **nothing in this file may be called from the
/// main thread**. The public surface is a main-thread cache (`monitors`) that
/// `refresh()` repopulates in the background; UI reads the cache and never waits.
final class DisplayInputEngine {

    // MARK: Types

    struct Input: Equatable, Identifiable {
        let code: UInt16
        /// MCCS name for the code, or a vendor-specific placeholder.
        let standardName: String
        /// What the user renamed it to, if anything.
        var customName: String?
        /// True when the code came from the monitor's own capability string
        /// rather than from the fallback guess list.
        let advertised: Bool
        /// The input this Mac is plugged into, as marked by the user. Cannot be
        /// detected: the panels that need this feature are exactly the ones whose
        /// VCP 0x60 read is broken.
        var isMac: Bool

        var id: UInt16 { code }
        var label: String { customName?.isEmpty == false ? customName! : standardName }
    }

    struct Monitor: Equatable, Identifiable {
        /// Stable across replug and reboot: EDID product name + serial. The
        /// IOAVService node exposes no CGDisplay UUID, so this is the identity
        /// custom names are filed under.
        let key: String
        let name: String
        var inputs: [Input]
        /// The input the panel says it is showing, when it answers truthfully.
        /// Many panels (the MSI MP341CQ among them) reply 0xFF here forever, so
        /// this is nil far more often than you would expect — never build UI
        /// that *requires* it.
        let currentCode: UInt16?
        /// False when this entry is remembered rather than freshly measured: the
        /// panel is still physically linked but its DDC channel is not answering.
        /// That is what a monitor showing *another machine* looks like — the whole
        /// bus goes quiet — so the entry has to survive, or the UI that switches
        /// back would disappear exactly when it is needed.
        var reachable: Bool = true

        var id: String { key }
    }

    // MARK: Cache

    /// Main-thread snapshot. Empty until the first `refresh()` completes.
    private(set) static var monitors: [Monitor] = []
    /// True once a refresh has finished, so UI can tell "none found" from "not looked yet".
    private(set) static var hasScanned = false

    private static let queue = DispatchQueue(label: "H1D3S1GN.MSG.displayinput")
    /// IOAVService handles, keyed like `Monitor.key`. Touched only on `queue`.
    private static var services: [String: IOAVServiceRef] = [:]
    private static var refreshInFlight = false
    private static var refreshAgain = false
    private static var refreshCompletions: [() -> Void] = []

    // MARK: Custom names / "This Mac" marking

    private static let namesKey = "displayInput.customNames"
    private static let macInputKey = "displayInput.macInputs"

    private static func nameStorageKey(_ monitorKey: String, _ code: UInt16) -> String {
        "\(monitorKey)#\(String(format: "%02X", code))"
    }

    private static func loadCustomNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    static func setCustomName(_ name: String?, monitorKey: String, code: UInt16) {
        var names = loadCustomNames()
        let key = nameStorageKey(monitorKey, code)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { names[key] = trimmed } else { names.removeValue(forKey: key) }
        UserDefaults.standard.set(names, forKey: namesKey)

        // Patch the cache in place so the UI updates without a 2 s rescan.
        guard let m = monitors.firstIndex(where: { $0.key == monitorKey }),
              let i = monitors[m].inputs.firstIndex(where: { $0.code == code }) else { return }
        monitors[m].inputs[i].customName = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func loadMacInputs() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: macInputKey) as? [String: Int] ?? [:]
    }

    static func macInputCode(for monitorKey: String) -> UInt16? {
        loadMacInputs()[monitorKey].map { UInt16($0) }
    }

    /// Marks (or with nil, unmarks) the input this Mac is plugged into. At most
    /// one per monitor — a second mark replaces the first.
    static func setMacInput(_ code: UInt16?, monitorKey: String) {
        var stored = loadMacInputs()
        if let code { stored[monitorKey] = Int(code) } else { stored.removeValue(forKey: monitorKey) }
        UserDefaults.standard.set(stored, forKey: macInputKey)

        guard let m = monitors.firstIndex(where: { $0.key == monitorKey }) else { return }
        for i in monitors[m].inputs.indices {
            monitors[m].inputs[i].isMac = (monitors[m].inputs[i].code == code)
        }
    }

    // MARK: Persistence

    /// The in-memory cache is not enough. DDC can only be read while the panel is
    /// showing this Mac, so a relaunch that happens while the monitor is away
    /// starts empty at exactly the moment it can never refill — and the UI then
    /// claims no monitor supports input switching at all, hiding the Reconnect
    /// action that is the user's way out. Remember the last good scan on disk.
    private static let lastKnownKey = "displayInput.lastKnown"
    private static var didLoadPersisted = false

    private struct PersistedInput: Codable {
        let code: UInt16
        let standardName: String
        let advertised: Bool
    }

    private struct PersistedMonitor: Codable {
        let key: String
        let name: String
        let inputs: [PersistedInput]
    }

    /// Custom names and the "This Mac" mark are deliberately not stored here —
    /// they have their own keys and are re-applied on load, so renaming a monitor
    /// never depends on the scan cache being intact.
    private static func loadPersistedIfNeeded() {
        guard !didLoadPersisted else { return }
        didLoadPersisted = true
        guard monitors.isEmpty,
              let data = UserDefaults.standard.data(forKey: lastKnownKey),
              let stored = try? JSONDecoder().decode([PersistedMonitor].self, from: data)
        else { return }

        let names = loadCustomNames()
        let macInputs = loadMacInputs()
        monitors = stored.map { m in
            let macCode = macInputs[m.key].map { UInt16($0) }
            return Monitor(
                key: m.key,
                name: m.name,
                inputs: m.inputs.map { i in
                    Input(code: i.code,
                          standardName: i.standardName,
                          customName: names[nameStorageKey(m.key, i.code)],
                          advertised: i.advertised,
                          isMac: i.code == macCode)
                },
                currentCode: nil,
                reachable: false      // remembered, not measured
            )
        }
    }

    private static func persist(_ list: [Monitor]) {
        let stored = list.map { m in
            PersistedMonitor(key: m.key, name: m.name,
                             inputs: m.inputs.map {
                                 PersistedInput(code: $0.code,
                                                standardName: $0.standardName,
                                                advertised: $0.advertised)
                             })
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: lastKnownKey)
    }

    // MARK: Discovery

    /// Rescans every external panel. Cheap to over-call — concurrent requests
    /// collapse into the one in flight.
    static func refresh(completion: (() -> Void)? = nil) {
        if let completion { refreshCompletions.append(completion) }
        guard avReadI2C != nil, avWriteI2C != nil else {
            hasScanned = true
            let callbacks = refreshCompletions
            refreshCompletions.removeAll()
            callbacks.forEach { $0() }
            return
        }
        // A return from another input often produces several display-change
        // notifications while the link is still negotiating. Do not pretend a
        // refresh requested during the scan has completed: run one final scan
        // against the settled IORegistry and complete every waiter after that.
        guard !refreshInFlight else {
            refreshAgain = true
            return
        }
        refreshInFlight = true

        // Seed from disk first, so the merge below has something to preserve even
        // on the first scan after a relaunch.
        loadPersistedIfNeeded()

        // Read on main, where the cache lives, before handing off to the scan queue.
        let previous = monitors

        queue.async {
            let (found, attachedPanels) = scanDisplays(knownMonitors: previous)
            // UserDefaults is thread-safe; reading it here avoids a sync hop to
            // main from a queue main could later be waiting on.
            let names = loadCustomNames()
            let macInputs = loadMacInputs()
            var labelled = found.map { monitor -> Monitor in
                var m = monitor
                let macCode = macInputs[m.key].map { UInt16($0) }
                m.inputs = m.inputs.map { input in
                    var i = input
                    i.customName = names[nameStorageKey(m.key, i.code)]
                    i.isMac = (i.code == macCode)
                    return i
                }
                return m
            }

            // A scan that answered for nobody while a panel is still physically
            // linked is a temporary DDC outage, not a disconnection — that is
            // exactly the state a monitor is in while it displays another machine.
            // Keep what we knew, flagged unreachable, so the way back survives.
            // Any successful read means the scan is trustworthy and replaces the
            // cache outright (otherwise swapping monitors would leave a phantom).
            let keptFromCache = labelled.isEmpty && attachedPanels > 0 && !previous.isEmpty
            if keptFromCache {
                labelled = previous.map { var m = $0; m.reachable = false; return m }
            } else {
                services = servicesFromLastScan
            }

            DispatchQueue.main.async {
                monitors = labelled
                hasScanned = true
                // Only record measured results. Writing back the remembered set
                // would be a no-op at best; more importantly, a genuine unplug
                // (nothing attached, nothing found) must clear the store so a
                // monitor that is really gone stops being offered.
                if !keptFromCache { persist(labelled) }

                if refreshAgain {
                    refreshAgain = false
                    refreshInFlight = false
                    refresh()
                } else {
                    refreshInFlight = false
                    let callbacks = refreshCompletions
                    refreshCompletions.removeAll()
                    callbacks.forEach { $0() }
                }
            }
        }
    }

    /// Set by `scanDisplays()`; consumed by `refresh()` so a scan that found
    /// nothing does not throw away still-valid handles. Touched only on `queue`.
    private static var servicesFromLastScan: [String: IOAVServiceRef] = [:]

    /// Walks the IORegistry for external panels and interrogates each one.
    /// Runs on `queue`.
    ///
    /// Returns the monitors that answered, plus how many external panels were
    /// *present* whether they answered or not — the two differ precisely when a
    /// panel is linked but showing another machine, which is the case the cache
    /// merge in `refresh()` has to recognise.
    private static func scanDisplays(knownMonitors: [Monitor]) -> (monitors: [Monitor], attachedPanels: Int) {
        guard let create = avCreateWithService else { return ([], 0) }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return ([], 0) }
        defer { IOObjectRelease(iterator) }

        var results: [Monitor] = []
        var discovered: [String: IOAVServiceRef] = [:]
        var attached = 0

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // The built-in panel publishes a node too (Location = "Embedded")
            // but has no DDC bus behind it.
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            attached += 1
            guard let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }

            let edid = readEDID(service)
            let name = edid?.name ?? "External display"
            let key = [name, edid?.serial ?? ""].joined(separator: "|")

            // Brightness is the most universally implemented code; if it does not
            // answer, this link carries no usable DDC and there is nothing to offer.
            guard getVCP(service, code: 0x10) != nil else { continue }
            usleep(ddcDelay)

            let reading = getVCP(service, code: 0x60)
            usleep(ddcDelay)
            let knownInputs = knownMonitors.first(where: { $0.key == key })?.inputs
            let inputs = discoverInputs(service,
                                        inputVCPResponds: reading != nil,
                                        knownInputs: knownInputs)
            guard !inputs.isEmpty else { continue }

            // A panel that reports a code outside its own advertised list is
            // reporting garbage (0xFF is the common one) — treat it as unknown
            // rather than surfacing a phantom "current input".
            let current = reading.map(\.current).flatMap { value in
                inputs.contains(where: { $0.code == value }) ? value : nil
            }

            discovered[key] = service
            results.append(Monitor(key: key, name: name, inputs: inputs, currentCode: current))
        }

        servicesFromLastScan = discovered
        return (results, attached)
    }

    /// Recreates the IOAVService wrapper for a known monitor without requiring a
    /// successful DDC read. The DCP service can be replaced when an HDMI link
    /// disappears and returns; keeping the pre-switch wrapper then leaves every
    /// later write pointed at a dead user client until logout or reboot.
    ///
    /// EDID is used only for identity and is normally available from the link
    /// cache even while DDC/CI itself is recovering. Runs on `queue`.
    private static func freshService(forMonitorKey monitorKey: String) -> IOAVServiceRef? {
        guard let create = avCreateWithService else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var onlyExternalService: IOAVServiceRef?
        var externalServiceCount = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
            else { continue }

            externalServiceCount += 1
            onlyExternalService = service
            guard let edid = readEDID(service) else { continue }

            let key = [edid.name ?? "External display", edid.serial ?? ""]
                .joined(separator: "|")
            if key == monitorKey { return service }
        }
        // A single external panel is unambiguous even if EDID is briefly missing
        // during link recovery. Never use this shortcut with multiple monitors.
        return externalServiceCount == 1 ? onlyExternalService : nil
    }

    /// Prefers the panel's own `60(...)` capability group. If that read is
    /// temporarily unavailable, preserves a previously advertised list instead
    /// of inventing DP2/HDMI2 entries. An invalid input-select code is not harmless
    /// on every panel; the MP341CQ has shown that a bad/degraded transaction can
    /// leave its DDC channel unavailable for the rest of the boot.
    private static func discoverInputs(_ service: IOAVServiceRef,
                                       inputVCPResponds: Bool,
                                       knownInputs: [Input]?) -> [Input] {
        if let caps = readCapabilities(service), let codes = inputCodes(fromCapabilities: caps) {
            return codes.map { Input(code: $0, standardName: standardInputName($0),
                                     customName: nil, advertised: true, isMac: false) }
        }
        guard inputVCPResponds else { return [] }
        guard let knownInputs,
              !knownInputs.isEmpty,
              knownInputs.allSatisfy(\.advertised)
        else { return [] }
        return knownInputs
    }

    // MARK: Switching

    /// The switch users actually invoke. Wraps the raw VCP write with the
    /// workspace side of the handover:
    ///
    /// - **To this Mac's input** — reconnect the display *first*. Ejecting is a
    ///   soft disconnect that outlives the app, so a display parked that way would
    ///   otherwise stay missing even once the panel is showing us again.
    /// - **To any other input** — switch, then eject once the panel has had time
    ///   to relink, so windows land on the built-in display instead of stranding
    ///   on a panel that is now showing another machine.
    ///
    /// Both eject paths are gated on the user having marked which input is this
    /// Mac. Without that mark there is no way to tell a handover from a switch
    /// back — the panels this feature exists for are exactly the ones that refuse
    /// to report their live input — so the switch happens and nothing is ejected.
    static func selectInput(monitorKey: String, code: UInt16, autoEject: Bool) {
        let macCode = macInputCode(for: monitorKey)
        let switchingToMac = (macCode == code)
        let shouldEject = autoEject && macCode != nil && !switchingToMac

        if switchingToMac, let uuid = displayUUID(forMonitorKey: monitorKey) {
            DisplaplacerEngine.setEnabled(uuid, enabled: true)
            clearHandoverEject(uuid)
        }

        switchTo(monitorKey: monitorKey, code: code) { _ in
            guard shouldEject else { return }
            // The panel drops and re-establishes its link on an input change;
            // ejecting into the middle of that races the WindowServer's own
            // teardown. Let it settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let uuid = displayUUID(forMonitorKey: monitorKey) else { return }
                noteHandoverEject(uuid)
                DisplaplacerEngine.setEnabled(uuid, enabled: false)
            }
        }
    }

    // MARK: Handover ejects

    /// Displays MSG ejected as part of an input handover, as opposed to ones the
    /// user ejected by hand in Displaplacer. Only these are auto-reconnected when
    /// the panel comes back — auto-reconnecting a deliberate eject would fight the
    /// user. Persisted because the soft-disable is `.forSession` and outlives the
    /// app, so the obligation to undo it does too.
    private static let handoverKey = "displayInput.handoverEjected"

    private static var handoverEjected: [String] {
        get { UserDefaults.standard.stringArray(forKey: handoverKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: handoverKey) }
    }

    static func isHandoverEjected(monitorKey: String) -> Bool {
        guard let uuid = displayUUID(forMonitorKey: monitorKey) else {
            // No resolvable display and a pending obligation means the panel we
            // ejected is the one that has gone dark.
            return !handoverEjected.isEmpty
        }
        return handoverEjected.contains(uuid)
    }

    private static func noteHandoverEject(_ uuid: String) {
        var pending = handoverEjected
        guard !pending.contains(uuid) else { return }
        pending.append(uuid)
        handoverEjected = pending
    }

    private static func clearHandoverEject(_ uuid: String) {
        handoverEjected = handoverEjected.filter { $0 != uuid }
    }

    /// Undoes a handover eject once the panel is showing this Mac again.
    ///
    /// This is the *only* path back. While the monitor displays another machine
    /// its whole DDC bus goes quiet — measured, not assumed — so MSG cannot switch
    /// the input back and the user has to press the monitor's own input button.
    /// What MSG can still do is notice the panel's return and undo the eject, so
    /// that button is the single action required rather than the first of two.
    ///
    /// Call from display-reconfiguration paths.
    static func reconnectReturnedHandoverDisplays() {
        let pending = handoverEjected
        guard !pending.isEmpty else { return }

        let online = DisplaplacerEngine.allOnlineDisplays()
        for uuid in pending {
            guard let info = online.first(where: { $0.uuid == uuid }) else { continue }
            // Enumerable again. Either macOS already re-enabled it (session ended,
            // replug) — nothing to undo — or it is back but still soft-disabled,
            // which is ours to fix.
            if !info.enabled { DisplaplacerEngine.setEnabled(uuid, enabled: true) }
            clearHandoverEject(uuid)
            // Re-read on the off chance DDC came back with the panel. Measured on
            // the MP341CQ it does not: after a handover the I2C writes stay refused
            // (0xE0114101, the monitor NACKing at 0x37) through the panel's return,
            // a monitor power cycle and an OSD DDC/CI check — only a reboot cleared
            // it. So expect this to find nothing and the entry to stay unreachable;
            // that is why the cache is persisted rather than rebuilt from here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refresh() }
        }
    }

    /// Un-ejects on demand, for the UI to offer when a monitor is unreachable.
    /// Unlike switching, this needs no DDC at all — it is a pure CoreGraphics
    /// operation — so it still works while the panel is showing another machine.
    static func reconnectDisplay(monitorKey: String) {
        if let uuid = displayUUID(forMonitorKey: monitorKey) {
            DisplaplacerEngine.setEnabled(uuid, enabled: true)
            clearHandoverEject(uuid)
        } else {
            // The display resolves to nothing right now; undo every outstanding
            // handover eject we have a record of rather than stranding the user.
            for uuid in handoverEjected {
                DisplaplacerEngine.setEnabled(uuid, enabled: true)
                clearHandoverEject(uuid)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { refresh() }
    }

    /// Bridges this engine's EDID-based identity to Displaplacer's CGDisplay UUID.
    /// Matched on the display name both sides expose; when there is exactly one
    /// external display, that is the answer regardless — the names come from
    /// different sources (EDID descriptor vs NSScreen.localizedName) and are not
    /// guaranteed to agree.
    private static func displayUUID(forMonitorKey key: String) -> String? {
        let externals = DisplaplacerEngine.externalDisplays()
        if externals.count == 1 { return externals[0].uuid }
        let name = monitors.first(where: { $0.key == key })?.name
        return externals.first { $0.name.caseInsensitiveCompare(name ?? "") == .orderedSame }?.uuid
    }

    /// Writes VCP 0x60. The panel may take a second to relink, and if it switches
    /// away from this Mac the picture goes with it — that is the whole point of
    /// the feature, but it means the completion only reports that the I2C write
    /// was accepted, never that the panel acted on it.
    static func switchTo(monitorKey: String, code: UInt16, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            // Always prefer a newly-created wrapper. An input change tears down
            // and recreates the HDMI link on some Apple-silicon Macs, making the
            // handle captured by the discovery scan permanently stale.
            guard var service = freshService(forMonitorKey: monitorKey) ?? services[monitorKey] else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            services[monitorKey] = service

            // Slow links can NACK the first command just after reappearing. Retry
            // with a newly resolved service each time instead of hammering the
            // same dead handle. A successful input-select write is never repeated.
            var ok = false
            for attempt in 0..<4 {
                if setVCP(service, code: 0x60, value: code) {
                    ok = true
                    break
                }
                guard attempt < 3 else { break }
                usleep(UInt32(100_000 * (attempt + 1)))
                if let refreshed = freshService(forMonitorKey: monitorKey) {
                    service = refreshed
                    services[monitorKey] = refreshed
                }
            }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    // MARK: - DDC primitives (all on `queue`)

    @discardableResult
    private static func ddcWrite(_ service: IOAVServiceRef, _ payload: [UInt8]) -> Bool {
        guard let write = avWriteI2C else { return false }
        var frame = payload
        frame.append(frame.reduce(ddcChecksumSeed) { $0 ^ $1 })
        return frame.withUnsafeBytes { buffer -> Bool in
            write(service, ddcChipAddress, ddcSubAddress,
                  buffer.baseAddress!, UInt32(buffer.count)) == KERN_SUCCESS
        }
    }

    private static func ddcRead(_ service: IOAVServiceRef, count: Int) -> [UInt8]? {
        guard let read = avReadI2C else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            read(service, ddcChipAddress, ddcSubAddress,
                 raw.baseAddress!, UInt32(count)) == KERN_SUCCESS
        }
        return ok ? buffer : nil
    }

    /// Get VCP Feature. Well-formed reply:
    ///   6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <cksum>
    /// The leading source-address byte is not guaranteed to be present in every
    /// driver revision, so the reply opcode is located rather than assumed.
    private static func getVCP(_ service: IOAVServiceRef, code: UInt8) -> (current: UInt16, maximum: UInt16)? {
        // Mature Apple-silicon DDC implementations retry reads because the link
        // commonly NACKs while waking or immediately after reconfiguration.
        for attempt in 0..<4 {
            if ddcWrite(service, [0x82, 0x01, code]) {
                usleep(ddcDelay)
                if let reply = ddcRead(service, count: 12) {
                    for start in [2, 1, 0, 3] where start + 7 < reply.count {
                        guard reply[start] == 0x02, reply[start + 2] == code else { continue }
                        guard reply[start + 1] == 0x00 else { return nil }   // 0x01 = unsupported
                        let maximum = UInt16(reply[start + 4]) << 8 | UInt16(reply[start + 5])
                        let current = UInt16(reply[start + 6]) << 8 | UInt16(reply[start + 7])
                        return (current, maximum)
                    }
                }
            }
            if attempt < 3 { usleep(UInt32(50_000 * (attempt + 1))) }
        }
        return nil
    }

    private static func setVCP(_ service: IOAVServiceRef, code: UInt8, value: UInt16) -> Bool {
        ddcWrite(service, [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Capabilities Request (0xF3). The string arrives in ≤32-byte fragments:
    ///   6E <0x80|len> E3 <offHi> <offLo> <data…> <cksum>
    /// The read buffer comes back larger than the frame and with the frame's head
    /// repeated in the tail, so the payload length must come from the length byte,
    /// never from the buffer size.
    private static func readCapabilities(_ service: IOAVServiceRef) -> String? {
        var out = [UInt8]()
        var offset: UInt16 = 0
        // 32 bytes a fragment; 128 iterations is ~4 KB, far past any real string.
        for _ in 0..<128 {
            guard ddcWrite(service, [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]) else { break }
            usleep(ddcDelay)
            guard let reply = ddcRead(service, count: 40) else { break }

            var start = -1
            for candidate in [2, 1, 0, 3] where candidate < reply.count {
                if reply[candidate] == 0xE3 { start = candidate; break }
            }
            guard start >= 1 else { break }

            // Length byte sits immediately before the opcode; its low 7 bits count
            // the opcode + 2 offset bytes + payload.
            let declared = reply[start - 1] & 0x7F
            guard declared > 3 else { break }              // 3 = header only → end of string
            let payloadCount = Int(declared) - 3
            let payloadStart = start + 3
            guard payloadStart + payloadCount <= reply.count else { break }

            out.append(contentsOf: reply[payloadStart..<(payloadStart + payloadCount)])
            offset += UInt16(payloadCount)
            usleep(ddcDelay)
        }
        return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
    }

    // MARK: - EDID

    /// Only the text descriptors are parsed — enough to name the panel and build
    /// a stable identity for it.
    private static func readEDID(_ service: IOAVServiceRef) -> (name: String?, serial: String?)? {
        guard let copyEDID = avCopyEDID else { return nil }
        var out: Unmanaged<CFData>?
        guard copyEDID(service, &out) == KERN_SUCCESS,
              let data = out?.takeRetainedValue() as Data?, data.count >= 128 else { return nil }

        var name: String?
        var serial: String?
        // Four 18-byte descriptors from offset 54. Two leading zero bytes mark a
        // text block; byte 3 is the tag (0xFC product name, 0xFF serial).
        for block in 0..<4 {
            let base = 54 + block * 18
            guard base + 18 <= data.count, data[base] == 0, data[base + 1] == 0 else { continue }
            let text = String(decoding: data[(base + 5)..<(base + 18)], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n ").union(.controlCharacters))
            if data[base + 3] == 0xFC { name = text }
            if data[base + 3] == 0xFF { serial = text }
        }
        return (name, serial)
    }

    // MARK: - Input names

    /// MCCS-standard VCP 0x60 values. Vendors add their own; anything unlisted is
    /// labelled by its code rather than guessed at.
    private static let standardInputNames: [UInt16: String] = [
        0x01: "VGA 1",        0x02: "VGA 2",
        0x03: "DVI 1",        0x04: "DVI 2",
        0x05: "Composite 1",  0x06: "Composite 2",
        0x07: "S-Video 1",    0x08: "S-Video 2",
        0x09: "Tuner 1",      0x0A: "Tuner 2",     0x0B: "Tuner 3",
        0x0C: "Component 1",  0x0D: "Component 2", 0x0E: "Component 3",
        0x0F: "DisplayPort",  0x10: "DisplayPort 2",
        0x11: "HDMI",         0x12: "HDMI 2",
        0x1B: "USB-C",
    ]

    private static func standardInputName(_ code: UInt16) -> String {
        standardInputNames[code] ?? String(format: "Input 0x%02X", code)
    }

    /// Pulls the `60(...)` group out of a capability string, e.g.
    /// "…vcp(02 10 60(0F 11) AC…)…".
    private static func inputCodes(fromCapabilities caps: String) -> [UInt16]? {
        guard let marker = caps.range(of: "60("),
              let close = caps[marker.upperBound...].firstIndex(of: ")") else { return nil }
        let codes = caps[marker.upperBound..<close]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .compactMap { UInt16($0, radix: 16) }
        return codes.isEmpty ? nil : codes
    }
}
