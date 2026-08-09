import AppKit
import CoreGraphics

// MARK: - Private CGS API Bindings

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> Int

@_silgen_name("CGSManagedDisplayIsAnimating")
private func CGSManagedDisplayIsAnimating(_ cid: CGSConnectionID, _ display: CFString) -> Bool

// MARK: - Data

struct SpaceInfo: Equatable {
    struct DisplayInfo: Equatable {
        let current: Int   // 1-based
        let total: Int
        let uuid: String
    }
    let displays: [DisplayInfo]
    let activeDisplayIndex: Int
    let mainDisplayIndex: Int

    var focusedDisplay: DisplayInfo {
        guard activeDisplayIndex >= 0, activeDisplayIndex < displays.count else {
            return DisplayInfo(current: 1, total: 1, uuid: "")
        }
        return displays[activeDisplayIndex]
    }
}

// MARK: - SpaceWatcher

final class SpaceWatcher {

    private(set) var currentInfo = SpaceInfo(
        displays: [.init(current: 1, total: 1, uuid: "")],
        activeDisplayIndex: 0, mainDisplayIndex: 0
    )

    var onChange: (() -> Void)?

    var prioritizeMain: Bool = true {
        didSet { if oldValue != prioritizeMain { updateInfo() } }
    }
    var customOrder: [Int] = [] {
        didSet { if oldValue != customOrder { updateInfo() } }
    }
    var focusDetection: Bool = true {
        didSet { if oldValue != focusDetection { updateInfo(forceNotify: true) } }
    }
    var currentFocusedUUID: String? = nil {
        didSet { if oldValue != currentFocusedUUID { updateInfo() } }
    }

    /// Set by Indicator when SystemState detects MC entry/exit.
    /// When true, the activeSpaceDidChangeNotification handler skips
    /// CGSCopyManagedDisplaySpaces calls that would contend with WindowServer.
    var isInMissionControl = false

    private var spaceObs: NSObjectProtocol?
    private var screenObs: NSObjectProtocol?

    private var chaseWork: DispatchWorkItem?

    func start() {
        updateInfo()
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // During Mission Control, CGS data is transient and WindowServer is
            // under heavy load — skip the read to avoid main-thread stutter.
            guard !self.isInMissionControl else { return }
            self.updateInfo()
            self.chaseWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isInMissionControl else { return }
                self.chaseWork = nil
                self.updateInfo()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, !self.isInMissionControl else { return }
                    self.updateInfo()
                }
            }
            self.chaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016, execute: work)
        }

        screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateInfo() }
    }

    func cancelChaseReads() {
        chaseWork?.cancel()
        chaseWork = nil
    }

    func stop() {
        if let o = spaceObs  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = screenObs { NotificationCenter.default.removeObserver(o) }
        spaceObs = nil; screenObs = nil
    }

    deinit { stop() }

    func updateInfo(forceNotify: Bool = false) {
        let newInfo = Self.readSpaceInfo(
            prioritizeMain: prioritizeMain,
            customOrder: customOrder,
            focusDetection: focusDetection,
            focusedUUID: currentFocusedUUID,
            previous: currentInfo,
            fakeDisplays: AppSettings.shared.fakeDisplays
        )
        guard newInfo != currentInfo else {
            if forceNotify { onChange?() }
            return
        }
        currentInfo = newInfo
        onChange?()
    }

    /// Whether WindowServer is currently running a space-switch slide on the
    /// given display. Flips true at the start of the slide — measured ~500ms
    /// before CGSGetActiveSpace / activeSpaceDidChangeNotification, which only
    /// fire at landing. Caveat (measured): only desktop↔desktop slides set
    /// this; transitions to/from fullscreen-app spaces (type 4) never do.
    static func isDisplayAnimating(uuid: String) -> Bool {
        CGSManagedDisplayIsAnimating(CGSMainConnectionID(), uuid as CFString)
    }

    /// Current active space ID (cheap scalar read; safe to poll).
    static func activeSpaceID() -> Int {
        CGSGetActiveSpace(CGSMainConnectionID())
    }

    /// CGS space type for a fullscreen / tiled (Split View) space. A plain
    /// desktop space is type 0. Verified on macOS 26 against a live fullscreen
    /// space: `Current Space` = `{type = 4, fs_wid, pid, TileLayoutManager, …}`.
    private static let fullscreenSpaceType = 4

    /// Display UUIDs whose **current** space is a fullscreen space.
    ///
    /// Per-display and free of Accessibility: every display dict from
    /// `CGSCopyManagedDisplaySpaces` carries its own `Current Space` with a
    /// `type`. Measured at 0.086 ms/call, so it is fine on a space change or a
    /// 2 s watchdog pass — but it is ~2000× a `CGSGetActiveSpace` read, so do
    /// not put it on a per-frame path.
    ///
    /// Returns **nil** when CGS can't be read. Callers must treat nil as
    /// "unknown", never as "no display is fullscreen" — otherwise a failed read
    /// would silently hide every fullscreen-only top corner.
    static func fullscreenDisplayUUIDs() -> Set<String>? {
        guard let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()),
              let displayDicts = raw as? [[String: Any]] else { return nil }

        var out: Set<String> = []
        for dict in displayDicts {
            guard let cs = dict["Current Space"] as? [String: Any],
                  (cs["type"] as? Int) == fullscreenSpaceType else { continue }
            var ident = dict["Display Identifier"] as? String ?? ""
            // CGS reports "Main" rather than a UUID for the primary display in
            // some configurations — readSpaceInfo() handles the same case.
            if ident == "Main", let primary = NSScreen.screens.first?.uuid { ident = primary }
            guard !ident.isEmpty else { continue }
            out.insert(ident)
        }
        return out
    }

    // MARK: - CGS read

    static func readSpaceInfo(
        prioritizeMain: Bool = true,
        customOrder: [Int] = [],
        focusDetection: Bool = true,
        focusedUUID: String? = nil,
        previous: SpaceInfo? = nil,
        fakeDisplays: [FakeDisplay] = []
    ) -> SpaceInfo {
        let cid = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(cid)
        let fallback = SpaceInfo(displays: [.init(current: 1, total: 1, uuid: "")], activeDisplayIndex: 0, mainDisplayIndex: 0)

        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displayDicts = raw as? [[String: Any]] else { return fallback }

        var prevByUUID: [String: Int] = [:]
        if let prev = previous { for d in prev.displays { prevByUUID[d.uuid] = d.current } }

        var uuidToX: [String: CGFloat] = [:]
        var uuidToMidX: [String: CGFloat] = [:]
        var primaryUUID: String? = nil
        for (idx, screen) in NSScreen.screens.enumerated() {
            if let uuidString = screen.uuid {
                uuidToX[uuidString] = screen.frame.origin.x
                uuidToMidX[uuidString] = screen.frame.midX
                if idx == 0 { primaryUUID = uuidString }
            }
        }

        struct Temp {
            let info: SpaceInfo.DisplayInfo
            let isMain: Bool
            let xOrigin: CGFloat
            let containsActive: Bool
            let identifier: String
        }

        var temps: [Temp] = []
        for dict in displayDicts {
            guard let spaces = dict["Spaces"] as? [[String: Any]] else { continue }

            var managedIDs: [Int] = []
            for s in spaces {
                if let v = s["ManagedSpaceID"] as? Int { managedIDs.append(v) }
            }
            guard !managedIDs.isEmpty else { continue }

            let ident = dict["Display Identifier"] as? String ?? ""

            var cur: Int
            if let cs = dict["Current Space"] as? [String: Any],
               let csid = cs["ManagedSpaceID"] as? Int,
               let idx = managedIDs.firstIndex(of: csid) {
                cur = idx + 1
            } else if let prev = prevByUUID[ident], prev >= 1 && prev <= managedIDs.count {
                cur = prev
            } else {
                cur = 1
            }

            let containsActive: Bool
            if let cs = dict["Current Space"] as? [String: Any],
               let csid = cs["ManagedSpaceID"] as? Int {
                containsActive = csid == activeID || managedIDs.contains(activeID)
            } else {
                containsActive = managedIDs.contains(activeID)
            }

            let isMainIdent = ident == "Main" || (primaryUUID != nil && ident == primaryUUID)
            let x = isMainIdent ? 0 : (uuidToX[ident] ?? 99999)
            let isMain = isMainIdent || x == 0

            temps.append(Temp(
                info: .init(current: cur, total: managedIDs.count, uuid: ident),
                isMain: isMain, xOrigin: x,
                containsActive: containsActive,
                identifier: ident
            ))
        }

        // Sort
        if !customOrder.isEmpty {
            var indexToUUID: [Int: String] = [:]
            for (idx, screen) in NSScreen.screens.enumerated() {
                if let uuidString = screen.uuid { indexToUUID[idx] = uuidString }
            }
            let orderedUUIDs: [String] = customOrder.compactMap { indexToUUID[$0] }
            if !orderedUUIDs.isEmpty {
                temps.sort {
                    let ai = orderedUUIDs.firstIndex(of: $0.identifier) ?? 99
                    let bi = orderedUUIDs.firstIndex(of: $1.identifier) ?? 99
                    return ai < bi
                }
            }
        } else {
            temps.sort { a, b in
                if prioritizeMain && a.isMain != b.isMain { return a.isMain }
                return a.xOrigin < b.xOrigin
            }
        }

        var displays = temps.map { $0.info }
        var activeIdx: Int = 0
        if focusDetection, let fUUID = focusedUUID,
           let idx = temps.firstIndex(where: { $0.identifier.caseInsensitiveCompare(fUUID) == .orderedSame }) {
            activeIdx = idx
        } else {
            activeIdx = temps.firstIndex(where: { $0.containsActive }) ?? 0
        }
        let mainIdx = temps.firstIndex(where: { $0.isMain }) ?? 0

        // Physical detection: interleave fake displays with real displays by their canvas X position.
        // fd.arrangeX is a canvas-space offset from center, using the same scale as ArrangeDisplaysView:
        //   scale = (canvasH - padY*2) / screenHeight = 120 / screenHeight
        // Real display sort key = (screen.midX - screenCX) * scale, directly comparable to arrangeX.
        if !fakeDisplays.isEmpty && !prioritizeMain {
            let screens = NSScreen.screens
            let allX = screens.flatMap { [$0.frame.minX, $0.frame.maxX] }
            let allY = screens.flatMap { [$0.frame.minY, $0.frame.maxY] }
            if let sMinX = allX.min(), let sMaxX = allX.max(),
               let sMinY = allY.min(), let sMaxY = allY.max() {
                let screenCX = (sMinX + sMaxX) / 2
                let scale = 120.0 / max(1, sMaxY - sMinY)
                func realSortX(_ t: Temp) -> CGFloat {
                    let key = t.identifier == "Main" ? (primaryUUID ?? "") : t.identifier
                    let midX = uuidToMidX[key] ?? (t.xOrigin == 0 ? screenCX : t.xOrigin)
                    return (midX - screenCX) * scale
                }
                var merged: [(SpaceInfo.DisplayInfo, CGFloat, String)] =
                    temps.map { ($0.info, realSortX($0), $0.identifier) }
                for fd in fakeDisplays {
                    merged.append((.init(current: 1, total: fd.spaceCount, uuid: fd.id.uuidString),
                                   fd.arrangeX, fd.id.uuidString))
                }
                merged.sort { $0.1 < $1.1 }
                let activeUUID = activeIdx < temps.count ? temps[activeIdx].identifier : ""
                let mainUUID   = mainIdx   < temps.count ? temps[mainIdx].identifier   : ""
                let mergedDisplays = merged.map { $0.0 }
                let newAct  = merged.firstIndex(where: { $0.2 == activeUUID }) ?? 0
                let newMain = merged.firstIndex(where: { $0.2 == mainUUID   }) ?? 0
                return mergedDisplays.isEmpty ? fallback :
                    SpaceInfo(displays: mergedDisplays, activeDisplayIndex: newAct, mainDisplayIndex: newMain)
            }
        }

        // Prioritize-main mode or no screens: append fake displays after real displays
        for fd in fakeDisplays {
            displays.append(SpaceInfo.DisplayInfo(current: 1, total: fd.spaceCount, uuid: fd.id.uuidString))
        }

        return displays.isEmpty ? fallback :
            SpaceInfo(displays: displays, activeDisplayIndex: activeIdx, mainDisplayIndex: mainIdx)
    }
}
