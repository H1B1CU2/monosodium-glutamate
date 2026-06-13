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

    // All currently-online displays (does not include soft-disconnected ones).
    static func allOnlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.compactMap { makeInfo($0, enabled: true) }
    }

    // External displays, including any we soft-disconnected (shown as disabled rows).
    static func externalDisplays() -> [DisplayInfo] {
        loadIfNeeded()
        var result = allOnlineDisplays().filter { !$0.isBuiltin }
        let onlineUUIDs = Set(result.map { $0.uuid })

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
            if onlineUUIDs.contains(uuid) {
                disconnected[uuid] = nil
                cachedNames[uuid] = nil
                changed = true
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
            guard let id = disconnected[uuid] else {
                // Already online — nothing to re-enable.
                return
            }
            configureEnabled(id, true)
            disconnected[uuid] = nil
            cachedNames[uuid] = nil
            persist()
        } else {
            let online = allOnlineDisplays()
            guard let info = online.first(where: { $0.uuid == uuid }) else { return }
            if info.isBuiltin { return }
            if online.filter({ $0.enabled }).count <= 1 { return }
            cachedNames[uuid] = info.name
            configureEnabled(info.id, false)
            disconnected[uuid] = info.id
            persist()
        }
    }

    // Re-enable every soft-disconnected display and clear the cache. Called when the
    // app quits so ejected monitors don't stay dark with no running UI to restore them.
    static func reconnectAll() {
        loadIfNeeded()
        guard !disconnected.isEmpty else { return }
        for (_, id) in disconnected {
            configureEnabled(id, true)
        }
        disconnected.removeAll()
        cachedNames.removeAll()
        persist()
    }

    // MARK: - Helpers

    private static var cachedNames: [String: String] = [:]

    private static func configureEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        _ = CGSConfigureDisplayEnabled(config, id, enabled)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    private static func makeInfo(_ id: CGDirectDisplayID, enabled: Bool) -> DisplayInfo? {
        guard let uuidStr = DisplayID.uuid(id) else { return nil }
        let bounds = CGDisplayBounds(id)
        return DisplayInfo(id: id, uuid: uuidStr, name: displayName(for: id),
                           origin: bounds.origin, enabled: CGDisplayIsActive(id) != 0)
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
