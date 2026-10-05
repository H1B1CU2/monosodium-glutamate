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
        /// that *requires* it. Updated by MSG's own switches, never polled.
        var currentCode: UInt16?
        /// False while MSG has handed this panel to another machine (a handover
        /// eject is pending). Its DDC bus is silent then, so switching back has to
        /// happen on the monitor — but the entry must survive, or the UI offering
        /// Reconnect would disappear exactly when it is needed. Derived from
        /// MSG's own state rather than probed: probing is what wedges fragile links.
        var reachable: Bool = true

        var id: String { key }
    }

    // MARK: Cache

    /// Main-thread snapshot of the attached panels. Empty until the first
    /// `refresh()` completes.
    private(set) static var monitors: [Monitor] = []
    /// True once a refresh has finished, so UI can tell "none found" from "not looked yet".
    private(set) static var hasScanned = false

    /// Every DDC transaction in the process runs here, one at a time.
    private static let queue = DispatchQueue(label: "H1D3S1GN.MSG.displayinput")
    /// IOAVService handles, keyed like `Monitor.key`. Touched only on `queue`.
    private static var services: [String: IOAVServiceRef] = [:]

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
        rebuildMonitors()
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
        rebuildMonitors()
    }

    // MARK: Persistence

    /// Every panel MSG has ever probed, remembered on disk. DDC can only be read
    /// while the panel is showing this Mac, so a relaunch while the monitor is
    /// away would otherwise start empty at exactly the moment it can never
    /// refill. It also means a known panel never needs probing again — every
    /// probe is a burst of I2C, and on fragile links the probing itself is what
    /// broke DDC (see Discovery).
    private static let lastKnownKey = "displayInput.lastKnown"
    private static var didLoadPersisted = false
    /// Keyed like `Monitor.key`, without custom names or the "This Mac" mark —
    /// those have their own keys and are applied in `rebuildMonitors()`, so
    /// renaming never depends on this cache being intact. Main thread.
    private static var catalog: [String: Monitor] = [:]

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

    private static func loadPersistedIfNeeded() {
        guard !didLoadPersisted else { return }
        didLoadPersisted = true
        guard let data = UserDefaults.standard.data(forKey: lastKnownKey),
              let stored = try? JSONDecoder().decode([PersistedMonitor].self, from: data)
        else { return }
        for m in stored where catalog[m.key] == nil {
            catalog[m.key] = Monitor(
                key: m.key,
                name: m.name,
                inputs: m.inputs.map {
                    Input(code: $0.code, standardName: $0.standardName, customName: nil,
                          advertised: $0.advertised, isMac: false)
                },
                currentCode: nil)
        }
    }

    private static func persistCatalog() {
        let stored = catalog.values.sorted { $0.key < $1.key }.map { m in
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
    //
    // On a fragile link, scanning is what breaks DDC. The MP341CQ behind a
    // USB-C→HDMI adapter wedged (an I2C call that never returns, with every later
    // one queued behind it, until the adapter is replugged) under MSG's old
    // automatic rescans. Each was dozens of transactions, most of them the
    // capability string, and they fired 2.5 s after every display change while
    // the link was still renegotiating. With MSG quit, the same panel took reads
    // and writes on the first try. So discovery is split:
    //
    // - `refresh()` runs on launch and display changes. It lists the attached
    //   panels from the IORegistry with their EDID (served from the link cache,
    //   no I2C) and takes their inputs from `catalog`. No DDC at all, except a
    //   one-time probe of a panel never seen before.
    // - `rescan()` re-probes every attached panel over DDC. Only on explicit
    //   request (the settings pane's Rescan button).

    private struct Panel {
        let key: String
        let name: String
        let service: IOAVServiceRef
    }

    /// Attached panels' keys from the last refresh. Main thread.
    private static var attachedKeys: [String] = []
    /// Panels probed this launch, answered or not, so one without DDC isn't
    /// probed again on every display change. Main thread.
    private static var probedThisLaunch: Set<String> = []
    /// EDID reads happen here rather than on `queue`, so a wedged DDC call can't
    /// stop the menu from listing monitors.
    private static let discoveryQueue = DispatchQueue(label: "H1D3S1GN.MSG.displayinput.discovery")

    /// Lists attached panels without DDC. Cheap to over-call.
    static func refresh(completion: (() -> Void)? = nil) {
        discover(probeAll: false, completion: completion)
    }

    /// Re-reads every attached panel's inputs over DDC. User-initiated only.
    static func rescan(completion: (() -> Void)? = nil) {
        discover(probeAll: true, completion: completion)
    }

    private static func discover(probeAll: Bool, completion: (() -> Void)?) {
        loadPersistedIfNeeded()
        guard avCreateWithService != nil, avReadI2C != nil, avWriteI2C != nil else {
            hasScanned = true
            completion?()
            return
        }
        discoveryQueue.async {
            let panels = attachedPanels()
            DispatchQueue.main.async {
                // While a handover eject is pending the panel may drop out of the
                // registry entirely; keep it listed (unreachable) so Reconnect
                // stays on offer.
                if !panels.isEmpty || handoverEjected.isEmpty {
                    attachedKeys = panels.map(\.key)
                }
                let handles = panels.map { ($0.key, $0.service) }
                queue.async {
                    for (key, service) in handles { services[key] = service }
                }
                rebuildMonitors()

                let toProbe = probeAll
                    ? panels
                    : panels.filter { catalog[$0.key] == nil && !probedThisLaunch.contains($0.key) }
                guard !toProbe.isEmpty, !isStalled else {
                    hasScanned = true
                    completion?()
                    return
                }
                probe(toProbe) {
                    hasScanned = true
                    completion?()
                }
            }
        }
    }

    /// External panels in the IORegistry, identified by EDID. Runs on
    /// `discoveryQueue`. A panel whose EDID can't be read yet is still
    /// negotiating and is left for the next display change.
    private static func attachedPanels() -> [Panel] {
        guard let create = avCreateWithService else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var panels: [Panel] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            // The built-in panel publishes a node too (Location = "Embedded")
            // but has no DDC bus behind it.
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                           kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue(),
                  let edid = readEDID(service)
            else { continue }
            let name = edid.name ?? "External display"
            panels.append(Panel(key: [name, edid.serial ?? ""].joined(separator: "|"),
                                name: name, service: service))
        }
        return panels
    }

    /// Reads which inputs `panels` offer and files them in `catalog`. Main thread.
    private static func probe(_ panels: [Panel], completion: @escaping () -> Void) {
        probedThisLaunch.formUnion(panels.map(\.key))
        let known = catalog
        runDDC({ () -> [Monitor] in
            var found: [Monitor] = []
            for panel in panels {
                let service = panel.service
                // Brightness is the most universally implemented code; if it does
                // not answer, this link carries no usable DDC.
                guard getVCP(service, code: 0x10) != nil else { continue }
                usleep(ddcDelay)
                let reading = getVCP(service, code: 0x60)
                usleep(ddcDelay)
                let inputs = discoverInputs(service,
                                            inputVCPResponds: reading != nil,
                                            knownInputs: known[panel.key]?.inputs)
                guard !inputs.isEmpty else { continue }
                // A panel that reports a code outside its own advertised list is
                // reporting garbage (0xFF is the common one) — treat it as unknown
                // rather than surfacing a phantom "current input".
                let current = reading.map(\.current).flatMap { value in
                    inputs.contains(where: { $0.code == value }) ? value : nil
                }
                found.append(Monitor(key: panel.key, name: panel.name, inputs: inputs, currentCode: current))
            }
            return found
        }, done: { found in
            DisplayLog.write("ddc: probed \(panels.count) panel(s), \(found.count) answered")
            for monitor in found { catalog[monitor.key] = monitor }
            if !found.isEmpty { persistCatalog() }
            rebuildMonitors()
            completion()
        })
    }

    /// `monitors` = the attached panels' catalog entries, with custom names, the
    /// "This Mac" mark and handover state applied. Main thread.
    private static func rebuildMonitors() {
        let names = loadCustomNames()
        let macInputs = loadMacInputs()
        monitors = attachedKeys.compactMap { key in
            guard var m = catalog[key] else { return nil }
            let macCode = macInputs[key].map { UInt16($0) }
            m.inputs = m.inputs.map { input in
                var i = input
                i.customName = names[nameStorageKey(key, i.code)]
                i.isMac = (i.code == macCode)
                return i
            }
            m.reachable = !isHandoverEjected(monitorKey: key)
            return m
        }
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

    // MARK: Link health

    /// DDC waits this long after any display change. A plug, wake, mode change
    /// or one of MSG's own enable/disable transactions renegotiates the link, and
    /// I2C sent into that window is the likeliest thing to wedge a fragile one.
    private static let settleInterval: TimeInterval = 6
    private static var quietUntil = Date.distantPast
    /// DDC operations handed to `queue` and not finished yet, and when the one
    /// now running started. Main thread.
    private static var opsPending = 0
    private static var runningSince: Date?

    /// Call on every display reconfiguration, plug and wake. Main thread.
    static func noteDisplayChange() {
        quietUntil = Date().addingTimeInterval(settleInterval)
    }

    /// True while a DDC call has been stuck for seconds: the wedged-link state,
    /// where the call only returns once the adapter is replugged. New work is
    /// refused rather than piled up behind it. Main thread.
    static var isStalled: Bool {
        guard opsPending > 0, let since = runningSince else { return false }
        return Date().timeIntervalSince(since) > 3
    }

    /// Runs `work` on `queue` once the link has settled, then `done` on main with
    /// its result. Every DDC transaction goes through here. Main thread.
    private static func runDDC<T>(_ work: @escaping () -> T, done: @escaping (T) -> Void) {
        let wait = quietUntil.timeIntervalSinceNow
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { runDDC(work, done: done) }
            return
        }
        if opsPending == 0 { runningSince = Date() }
        opsPending += 1
        queue.async {
            let started = Date()
            let result = work()
            let took = Date().timeIntervalSince(started)
            if took > 2 {
                DisplayLog.write(String(format: "ddc: a transaction took %.1f s (link wedged, then released)", took))
            }
            DispatchQueue.main.async {
                opsPending -= 1
                // `queue` is serial, so the next pending operation starts now.
                runningSince = opsPending == 0 ? nil : Date()
                done(result)
            }
        }
    }

    /// Lets an in-flight transaction finish before the process exits: dying
    /// mid-transaction is another way to leave a fragile link wedged. Bounded,
    /// so a link that is already wedged can't hold up quitting.
    static func drainBeforeExit() {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + 1.5)
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
            // Relist so the entry shows as reachable again. Note DDC itself may not
            // be back: measured on the MP341CQ, after a handover the I2C writes were
            // refused (0xE0114101, the monitor NACKing at 0x37) until the USB-C
            // adapter was replugged — a monitor power cycle didn't clear it.
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
        guard !isStalled else { completion?(false); return }
        runDDC({ () -> Bool in
            // Always prefer a newly-created wrapper. An input change tears down
            // and recreates the HDMI link on some Apple-silicon Macs, making the
            // handle captured by the discovery scan permanently stale.
            guard var service = freshService(forMonitorKey: monitorKey) ?? services[monitorKey] else {
                return false
            }
            services[monitorKey] = service

            // Slow links can NACK the first command just after reappearing. Retry
            // with a newly resolved service each time instead of hammering the
            // same dead handle. A successful input-select write is never repeated.
            for attempt in 0..<4 {
                if setVCP(service, code: 0x60, value: code) {
                    usleep(ddcDelay)
                    return true
                }
                guard attempt < 3 else { break }
                usleep(UInt32(100_000 * (attempt + 1)))
                if let refreshed = freshService(forMonitorKey: monitorKey) {
                    service = refreshed
                    services[monitorKey] = refreshed
                }
            }
            return false
        }, done: { ok in
            if ok, catalog[monitorKey] != nil {
                catalog[monitorKey]?.currentCode = code
                rebuildMonitors()
            }
            completion?(ok)
        })
    }

    // MARK: - Levels (brightness 0x10, speaker volume 0x62)
    //
    // The brightness and volume keys drive these when the target is an external
    // panel: HDMI/DisplayPort audio has no CoreAudio volume, and macOS has no
    // brightness control for third-party monitors. Like everything else here,
    // they go through `runDDC`: one transaction at a time, never inside the
    // settle window after a display change.

    /// The continuous VCP controls the keys drive.
    enum Level: UInt8 {
        case brightness = 0x10
        case volume = 0x62
    }

    /// Latest requested value (0…1) per monitor and control, waiting for its
    /// write, and each panel's own maximum for that control from its last read
    /// (100 on the MP341CQ, but MCCS lets a panel pick any). Keyed by
    /// `levelKey`. Guarded by `levelLock`: the writes read them on `queue`.
    private static var levelTargets: [String: Double] = [:]
    private static var levelMaximum: [String: UInt16] = [:]
    private static let levelLock = NSLock()

    private static func levelKey(_ level: Level, _ monitorKey: String) -> String {
        "\(monitorKey)#\(level.rawValue)"
    }

    /// The DDC monitor called `name` — an NSScreen's name, or a CoreAudio
    /// output's, which macOS takes from the EDID product name just like
    /// `Monitor.name`. A lone external monitor is used when names differ.
    /// Main thread.
    static func monitorKey(named name: String) -> String? {
        loadPersistedIfNeeded()
        if monitors.isEmpty && !hasScanned { refresh() }
        let reachable = monitors.filter(\.reachable)
        if let match = reachable.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) { return match.key }
        return reachable.count == 1 ? reachable[0].key : nil
    }

    /// Reads a control as a 0…1 fraction of the panel's own maximum.
    /// Completion on main; nil when the panel does not answer.
    static func readLevel(_ level: Level, monitorKey: String, completion: @escaping (Double?) -> Void) {
        guard !isStalled else { completion(nil); return }
        runDDC({ () -> Double? in
            guard let service = services[monitorKey] ?? freshService(forMonitorKey: monitorKey) else { return nil }
            services[monitorKey] = service
            defer { usleep(ddcDelay) }
            guard let reading = getVCP(service, code: level.rawValue), reading.maximum > 0 else { return nil }
            levelLock.lock()
            levelMaximum[levelKey(level, monitorKey)] = reading.maximum
            levelLock.unlock()
            return Double(reading.current) / Double(reading.maximum)
        }, done: completion)
    }

    /// Sets a control to a 0…1 fraction of the panel's own maximum, the scale
    /// `readLevel` reports. Held keys fire faster than DDC takes writes, so
    /// requests collapse: the write sends whatever value is latest when it runs,
    /// and presses arriving while one is queued just update that value.
    /// Main thread.
    static func setLevel(_ level: Level, monitorKey: String, to value: Double) {
        guard !isStalled else { return }
        let key = levelKey(level, monitorKey)
        levelLock.lock()
        let writeQueued = levelTargets[key] != nil
        levelTargets[key] = max(0, min(1, value))
        levelLock.unlock()
        guard !writeQueued else { return }

        runDDC({ () -> Void in
            levelLock.lock()
            let target = levelTargets.removeValue(forKey: key)
            let maximum = levelMaximum[key] ?? 100
            levelLock.unlock()
            guard let target,
                  let service = services[monitorKey] ?? freshService(forMonitorKey: monitorKey)
            else { return }
            services[monitorKey] = service
            _ = setVCP(service, code: level.rawValue, value: UInt16((target * Double(maximum)).rounded()))
            usleep(ddcDelay)
        }, done: { _ in })
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
