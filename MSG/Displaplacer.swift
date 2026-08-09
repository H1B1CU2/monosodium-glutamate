import AppKit
import CoreGraphics

// MARK: - Private CGS display API
//
// CGSConfigureDisplayEnabled is the real soft-disconnect: it removes a display
// from the desktop as if the cable were pulled (windows migrate to remaining
// displays, the panel goes dark). Resolved the same way as the CGS space
// bindings in SpaceWatcher — these symbols are exported via CoreGraphics.
// Used inside a CGBeginDisplayConfiguration / CGCompleteDisplayConfiguration block.

@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

// MARK: - Display log
//
// A monitor that goes dark can't be debugged live — by the time it happens the
// screen is black and any UI we'd print to is on the wrong display. So every
// display reconfiguration is appended to a file instead, tagged with whether MSG
// itself opened the transaction. That single bit ("ours" vs not) is what tells
// us whether the app is causing a blackout or just witnessing one.
//
//   tail -f ~/Library/Logs/MSG/displays.log

enum DisplayLog {

    private static let queue = DispatchQueue(label: "H1D3S1GN.MSG.displaylog")
    private static let maxBytes = 512 * 1024

    private static let url: URL? = {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/MSG", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("displays.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    // True while MSG owns an open display-configuration transaction. Read by the
    // reconfiguration callback so the log can attribute the change.
    private(set) static var inOurTransaction = false

    static func markTransaction(_ active: Bool) { inOurTransaction = active }

    static func write(_ message: @autoclosure () -> String) {
        let line = "\(stamp.string(from: Date())) \(message())\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Start over rather than grow without bound; these are breadcrumbs,
                // not an audit trail, and the interesting window is the last few minutes.
                if (try? handle.seekToEnd()) ?? 0 > UInt64(maxBytes) {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Full state of every display CoreGraphics can see, one line each.
    static func snapshot(_ tag: String) {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { CGGetOnlineDisplayList(count, &ids, &count) }
        write("── snapshot [\(tag)] \(count) display(s)")
        for id in ids {
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let modeText = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshRate))" } ?? "nil"
            write(String(format: "   id=%u %@ active=%d asleep=%d main=%d mirrors=%u origin=(%.0f,%.0f) size=%.0fx%.0f mode=%@",
                         id,
                         CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external",
                         CGDisplayIsActive(id) != 0 ? 1 : 0,
                         CGDisplayIsAsleep(id) != 0 ? 1 : 0,
                         CGDisplayIsMain(id) != 0 ? 1 : 0,
                         CGDisplayMirrorsDisplay(id),
                         b.origin.x, b.origin.y, b.width, b.height,
                         modeText))
        }
    }

    /// Human-readable form of the flags CoreGraphics hands the reconfiguration callback.
    static func describe(_ flags: CGDisplayChangeSummaryFlags) -> String {
        var parts: [String] = []
        let map: [(CGDisplayChangeSummaryFlags, String)] = [
            (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "setMain"),
            (.setModeFlag, "setMode"), (.addFlag, "add"), (.removeFlag, "remove"),
            (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
            (.mirrorFlag, "mirror"), (.unMirrorFlag, "unMirror"),
            (.desktopShapeChangedFlag, "desktopShape")
        ]
        for (flag, name) in map where flags.contains(flag) { parts.append(name) }
        return parts.isEmpty ? "none(\(flags.rawValue))" : parts.joined(separator: "+")
    }
}

// MARK: - Data model

struct DisplaplacerDisplayLayout: Codable, Equatable {
    var uuid: String
    var originX: Int
    var originY: Int
}

struct DisplaplacerPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var layouts: [DisplaplacerDisplayLayout]
}

// MARK: - Engine

final class DisplaplacerEngine {

    struct DisplayInfo {
        let id: CGDirectDisplayID
        let uuid: String
        let name: String
        let origin: CGPoint
        let enabled: Bool          // false = soft-disconnected
        var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }
    }

    // UUID -> displayID for displays we've soft-disconnected. A disabled display
    // drops out of the online list, so we keep its ID around to re-enable it later.
    // The soft-disable is applied .forSession, so it outlives an app quit/rebuild;
    // this cache is persisted to UserDefaults so the "Ejected" row survives too.
    // Stale entries are pruned in externalDisplays() once the display is back
    // online (e.g. after logout/reboot) or its ID stops resolving (cable pulled).
    private static var disconnected: [String: CGDirectDisplayID] = [:]

    private struct EjectedRecord: Codable {
        let uuid: String
        let displayID: CGDirectDisplayID
        let name: String
    }
    private static let ejectedDefaultsKey = "displaplacer.ejectedDisplays"
    private static var didLoad = false

    private static func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = UserDefaults.standard.data(forKey: ejectedDefaultsKey),
              let records = try? JSONDecoder().decode([EjectedRecord].self, from: data) else { return }
        for r in records {
            disconnected[r.uuid] = r.displayID
            cachedNames[r.uuid] = r.name
        }
    }

    private static func persist() {
        let records = disconnected.map {
            EjectedRecord(uuid: $0.key, displayID: $0.value, name: cachedNames[$0.key] ?? "Display")
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: ejectedDefaultsKey)
        }
    }

    // Every display Core Graphics still sees. Depending on the macOS version a
    // soft-disabled display either drops out of this list entirely or stays in it
    // as an *inactive* entry — both are handled, see `isSoftDisabled`.
    static func allOnlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.compactMap { makeInfo($0) }
    }

    // A display we (or a previous run of the app) soft-disabled: still enumerable,
    // but not drawable. `CGDisplayIsActive` is also false for a mirroring slave and
    // for a sleeping panel — neither is an eject, so both are excluded. Getting this
    // wrong in the permissive direction would make us "heal" a mirrored display by
    // force-enabling it; in the strict direction it leaves the panel dark forever.
    private static func isSoftDisabled(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(id) == 0
            && CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay
            && CGDisplayIsAsleep(id) == 0
    }

    // External displays, including any we soft-disconnected (shown as disabled rows).
    static func externalDisplays() -> [DisplayInfo] {
        loadIfNeeded()
        var result = allOnlineDisplays().filter { !$0.isBuiltin }
        // Only displays that are actually *drawable* count as "back". An ejected
        // display can still be enumerated (it just isn't active), and treating that
        // as a return used to delete the record while the panel stayed dark — after
        // which nothing could re-enable it: the toggle bailed on the missing record
        // and quit-time reconnectAll() had nothing to restore. The panel then only
        // came back via a cable replug or logout (which ends the .forSession config).
        let liveUUIDs = Set(result.filter { $0.enabled }.map { $0.uuid })

        // Snapshot before mutating: iterating a dictionary while editing it is unsafe.
        var changed = false
        for (uuid, id) in Array(disconnected) {
            // Came back online on its own — replugged, or the session ended so the
            // .forSession soft-disable was cleared. Either way it's no longer ejected.
            //
            // We deliberately do NOT try to auto-detect "cable pulled while ejected":
            // a soft-disabled display vanishes from Core Graphics entirely (its ID
            // stops resolving) and IOKit display enumeration is empty on Apple
            // Silicon, so there's no reliable presence signal. A liveness check here
            // would wrongly delete still-ejected displays after a relaunch. Instead
            // we always show the row; reconnecting it clears the entry regardless of
            // whether the panel is still physically attached.
            if liveUUIDs.contains(uuid) {
                disconnected[uuid] = nil
                cachedNames[uuid] = nil
                changed = true
                continue
            }
            // Still enumerable but not drawable: the row is already in `result`, so
            // don't add a second one (duplicate uuids break the SwiftUI ForEach id).
            // Refresh the cached ID from the live entry while we're here — display IDs
            // are not stable across replug/reboot and a stale one re-enables nothing.
            if let live = result.first(where: { $0.uuid == uuid }) {
                if live.id != id {
                    disconnected[uuid] = live.id
                    changed = true
                }
                continue
            }
            result.append(DisplayInfo(
                id: id, uuid: uuid,
                name: cachedNames[uuid] ?? "Display",
                origin: .zero, enabled: false
            ))
        }
        if changed { persist() }
        return result
    }

    static func captureCurrentLayout() -> [DisplaplacerDisplayLayout] {
        allOnlineDisplays().filter { $0.enabled }.map {
            DisplaplacerDisplayLayout(
                uuid: $0.uuid,
                originX: Int($0.origin.x),
                originY: Int($0.origin.y)
            )
        }
    }

    // Apply a preset's arrangement. Displays not connected are skipped gracefully.
    static func apply(_ preset: DisplaplacerPreset) {
        let online = allOnlineDisplays()
        var uuidToID: [String: CGDirectDisplayID] = [:]
        for d in online { uuidToID[d.uuid] = d.id }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }

        var changed = false
        for layout in preset.layouts {
            guard let id = uuidToID[layout.uuid], CGDisplayIsActive(id) != 0 else { continue }
            CGConfigureDisplayOrigin(config, id, Int32(layout.originX), Int32(layout.originY))
            changed = true
        }

        if changed {
            CGCompleteDisplayConfiguration(config, .forSession)
        } else {
            CGCancelDisplayConfiguration(config)
        }
    }

    // Disconnect = soft-disable the display (panel goes dark, windows migrate off).
    // Reconnect  = re-enable it. Built-in and last-active display are protected.
    static func setEnabled(_ uuid: String, enabled: Bool) {
        loadIfNeeded()
        if enabled {
            // Prefer the ID Core Graphics reports right now: the cached one comes from
            // UserDefaults and can be stale (IDs are reassigned across replug/reboot),
            // in which case re-enabling it would silently target nothing. Fall back to
            // the cache for the case where a disabled display leaves the online list.
            let liveID = allOnlineDisplays().first(where: { $0.uuid == uuid })?.id
            guard let id = liveID ?? disconnected[uuid] else { return }
            configureEnabled([id], true)
            disconnected[uuid] = nil
            cachedNames[uuid] = nil
            persist()
        } else {
            let online = allOnlineDisplays()
            guard let info = online.first(where: { $0.uuid == uuid }) else { return }
            if info.isBuiltin { return }
            if online.filter({ $0.enabled }).count <= 1 { return }
            // Record before disabling: the resulting screen-parameter change can run
            // healStuckDisplays(), which would undo an eject it doesn't know about.
            cachedNames[uuid] = info.name
            disconnected[uuid] = info.id
            persist()
            configureEnabled([info.id], false)
        }
    }

    // External displays that are dark with no record of us ejecting them. This is
    // the state that used to be terminal: soft-disabled, no record saying we did it,
    // and the config applied .forSession — so it stays black until the cable is
    // pulled or the user logs out, however many times the app is relaunched.
    private static func unexplainedDarkDisplays() -> [CGDirectDisplayID] {
        allOnlineDisplays()
            .filter { !$0.isBuiltin && !$0.enabled && disconnected[$0.uuid] == nil }
            .map { $0.id }
    }

    // Re-enable those, but only after confirming the state holds.
    //
    // Confirmation matters more than speed here: a display reads as inactive for a
    // moment during hotplug, wake, and mode changes, and re-enabling it right then
    // forces a link renegotiation on a display that was already coming up fine —
    // which is a good way to *cause* the blank screen we're trying to repair. So
    // sample twice a few seconds apart and act only on displays dark in both.
    // Anything in `disconnected` is a deliberate eject and is never touched.
    static func healStuckDisplays() {
        loadIfNeeded()
        let candidates = Set(unexplainedDarkDisplays())
        guard !candidates.isEmpty else { return }
        DisplayLog.write("heal: \(candidates.count) dark display(s) \(Array(candidates)) — confirming")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let confirmed = Set(unexplainedDarkDisplays()).intersection(candidates)
            guard !confirmed.isEmpty else {
                DisplayLog.write("heal: cleared on its own, no action")
                return
            }
            DisplayLog.write("heal: re-enabling \(Array(confirmed))")
            configureEnabled(Array(confirmed), true)
        }
    }

    /// Force a display to renegotiate its link: soft-disconnect, pause, reconnect.
    ///
    /// This is the programmatic version of pulling the cable, and the fix for a
    /// monitor that is enumerated and nominally active but showing no picture —
    /// nothing in software can see that state, so it can't be detected, only
    /// re-triggered on demand. The temporary disable is recorded like a real eject
    /// so a crash mid-cycle still leaves a display the next launch will restore.
    static func relink(_ uuid: String, completion: (() -> Void)? = nil) {
        loadIfNeeded()
        let online = allOnlineDisplays()
        guard let info = online.first(where: { $0.uuid == uuid }), !info.isBuiltin else {
            completion?()
            return
        }
        // Same protection as an eject: never black out the only display left.
        guard online.filter({ $0.enabled }).count > 1 else {
            DisplayLog.write("relink \(info.name): refused, it is the only active display")
            completion?()
            return
        }

        DisplayLog.write("relink \(info.name) (id=\(info.id)): disabling")
        cachedNames[uuid] = info.name
        disconnected[uuid] = info.id
        persist()
        configureEnabled([info.id], false)

        // Long enough for the panel to actually drop the link — a quick off/on gets
        // coalesced and the display comes back in the same wedged state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let liveID = allOnlineDisplays().first(where: { $0.uuid == uuid })?.id ?? info.id
            DisplayLog.write("relink \(info.name) (id=\(liveID)): re-enabling")
            configureEnabled([liveID], true)
            disconnected[uuid] = nil
            cachedNames[uuid] = nil
            persist()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                DisplayLog.snapshot("after relink")
                completion?()
            }
        }
    }

    /// Re-link every connected external display, one after another.
    static func relinkAllExternals(completion: (() -> Void)? = nil) {
        let targets = externalDisplays().filter { $0.enabled }.map { $0.uuid }
        DisplayLog.snapshot("before relink")
        func next(_ remaining: ArraySlice<String>) {
            guard let uuid = remaining.first else { completion?(); return }
            relink(uuid) { next(remaining.dropFirst()) }
        }
        next(targets[...])
    }

    // Re-enable every soft-disconnected display and clear the cache. Called when the
    // app quits so ejected monitors don't stay dark with no running UI to restore them.
    static func reconnectAll() {
        loadIfNeeded()
        // Cached IDs plus anything currently dark, so a display whose record was lost
        // still gets restored instead of being left black after the app is gone.
        var ids = Set(disconnected.values)
        for d in allOnlineDisplays() where !d.isBuiltin && !d.enabled {
            ids.insert(d.id)
        }
        if !disconnected.isEmpty {
            disconnected.removeAll()
            cachedNames.removeAll()
            persist()
        }
        guard !ids.isEmpty else { return }
        configureEnabled(Array(ids), true)
    }

    // MARK: - Helpers

    private static var cachedNames: [String: String] = [:]

    // One transaction for the whole batch — at quit time we only get a single runloop
    // turn before terminate, so restoring several displays must not be several configs.
    private static func configureEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool) {
        guard !ids.isEmpty else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            DisplayLog.write("configureEnabled(\(enabled)) \(ids): CGBeginDisplayConfiguration failed")
            return
        }
        for id in ids {
            _ = CGSConfigureDisplayEnabled(config, id, enabled)
        }
        // The reconfiguration callback fires from inside CGCompleteDisplayConfiguration,
        // so the marker has to bracket the completion call for the log to attribute it.
        DisplayLog.markTransaction(true)
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        DisplayLog.markTransaction(false)
        DisplayLog.write("configureEnabled(\(enabled)) \(ids) -> \(err == .success ? "ok" : "error \(err.rawValue)")")
    }

    private static func makeInfo(_ id: CGDirectDisplayID) -> DisplayInfo? {
        guard let uuidStr = DisplayID.uuid(id) else { return nil }
        let bounds = CGDisplayBounds(id)
        return DisplayInfo(id: id, uuid: uuidStr, name: displayName(for: id),
                           origin: bounds.origin, enabled: !isSoftDisabled(id))
    }

    private static func displayName(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               dID == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display"
    }
}
