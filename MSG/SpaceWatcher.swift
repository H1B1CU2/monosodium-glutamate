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

    private var spaceObs: NSObjectProtocol?
    private var screenObs: NSObjectProtocol?
    private var debounceWork: DispatchWorkItem?

    /// CGS can return transient values during and shortly after Mission Control.
    /// Debouncing coalesces rapid-fire change notifications into a single read
    /// after the system settles. Screen parameter changes skip the debounce.
    private let debounceInterval: TimeInterval = 0.25

    /// Toggle to dump raw CGS data to stdout for debugging MC transitions.
    var diagnosticsEnabled = false
    private var lastDiagTime: TimeInterval = 0

    func start() {
        updateInfo()
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleDebouncedUpdate() }

        screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateInfo() }
    }

    func stop() {
        if let o = spaceObs  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = screenObs { NotificationCenter.default.removeObserver(o) }
        spaceObs = nil; screenObs = nil
        debounceWork?.cancel(); debounceWork = nil
    }

    deinit { stop() }

    private func scheduleDebouncedUpdate() {
        if diagnosticsEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            let since = lastDiagTime > 0 ? String(format: "%.3f", now - lastDiagTime) : "—"
            print("[SW] 🔔 notification fired  (+\(since)s since last read)")
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.debounceWork = nil
            self?.updateInfo()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func updateInfo(forceNotify: Bool = false) {
        if diagnosticsEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            let since = lastDiagTime > 0 ? String(format: "%.3f", now - lastDiagTime) : "—"
            lastDiagTime = now
            print("[SW] updateInfo() called  (+\(since)s since last read)  force=\(forceNotify)  debounced=\(debounceWork != nil)")
        }

        let newInfo = Self.readSpaceInfo(
            prioritizeMain: prioritizeMain,
            customOrder: customOrder,
            focusDetection: focusDetection,
            focusedUUID: currentFocusedUUID,
            previous: currentInfo,
            diagnostics: diagnosticsEnabled
        )
        guard newInfo != currentInfo else {
            if diagnosticsEnabled { print("[SW] no change, skipping onChange") }
            if forceNotify { DispatchQueue.main.async { self.onChange?() } }
            return
        }
        if diagnosticsEnabled {
            print("[SW] CHANGED — firing onChange")
            print("[SW]   old: \(currentInfo)")
            print("[SW]   new: \(newInfo)")
            print("")
        }
        currentInfo = newInfo
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: - CGS read

    static func readSpaceInfo(
        prioritizeMain: Bool = true,
        customOrder: [Int] = [],
        focusDetection: Bool = true,
        focusedUUID: String? = nil,
        previous: SpaceInfo? = nil,
        diagnostics: Bool = false
    ) -> SpaceInfo {
        let cid = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(cid)
        let fallback = SpaceInfo(displays: [.init(current: 1, total: 1, uuid: "")], activeDisplayIndex: 0, mainDisplayIndex: 0)

        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displayDicts = raw as? [[String: Any]] else { return fallback }

        if diagnostics {
            let mc = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock"
            let fs = !NSMenu.menuBarVisible()
            print("[SW] ── CGS Read ───────────────────────")
            print("[SW]   CGSGetActiveSpace = \(activeID)")
            print("[SW]   Dock frontmost = \(mc)   menuBarHidden = \(fs)")
            print("[SW]   display count = \(displayDicts.count)")
            print("[SW]   --------------------------------")
            for (di, dict) in displayDicts.enumerated() {
                let ident = dict["Display Identifier"] as? String ?? "?"
                let spaces = dict["Spaces"] as? [[String: Any]] ?? []
                let cs = dict["Current Space"] as? [String: Any]
                let csManaged = cs?["ManagedSpaceID"] as? Int
                let csID64 = cs?["id64"] as? Int

                var spaceList: [String] = []
                for s in spaces {
                    let msid = s["ManagedSpaceID"] as? Int ?? -1
                    let i64 = s["id64"] as? Int ?? -1
                    let isFS = s["TileLayoutManager"] is [String: Any]
                    spaceList.append("msid=\(msid) i64=\(i64)\(isFS ? " FS" : "")")
                }
                print("[SW]   Display[\(di)] \(ident)")
                print("[SW]     CurrentSpace: ManagedSpaceID=\(csManaged ?? -1)  id64=\(csID64 ?? -1)")
                print("[SW]     Spaces: \(spaceList.joined(separator: " | "))")
            }
        }

        // Map UUIDs → previous current-space. Used as a fallback when CGS
        // hasn't settled and "Current Space" is missing or stale (common
        // during Mission Control transitions).
        var prevByUUID: [String: Int] = [:]
        if let prev = previous { for d in prev.displays { prevByUUID[d.uuid] = d.current } }

        // Map UUIDs to x-origin and find primary display UUID
        var uuidToX: [String: CGFloat] = [:]
        var primaryUUID: String? = nil
        for (idx, screen) in NSScreen.screens.enumerated() {
            if let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               dID != 0,
               let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(dID) {
                let uuid = uuidUnmanaged.takeRetainedValue()
                if let uuidString = CFUUIDCreateString(nil, uuid) as String? {
                    uuidToX[uuidString] = screen.frame.origin.x
                    if idx == 0 { primaryUUID = uuidString }
                }
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

            // Use ManagedSpaceID like Spaceman — more stable than id64/id
            // during Mission Control transitions.
            var managedIDs: [Int] = []
            for s in spaces {
                if let v = s["ManagedSpaceID"] as? Int { managedIDs.append(v) }
            }
            guard !managedIDs.isEmpty else { continue }

            let ident = dict["Display Identifier"] as? String ?? ""

            // Resolve current space via ManagedSpaceID from the Current Space dict.
            // This matches Spaceman's approach and avoids CGSGetActiveSpace
            // which can be transient during MC.
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

            // Determine if this display contains the globally active space.
            // Use Current Space → ManagedSpaceID match against global active,
            // or fall back to CGSGetActiveSpace only when needed.
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

        // Sort: custom order > main-first > x position
        if !customOrder.isEmpty {
            var indexToUUID: [Int: String] = [:]
            for (idx, screen) in NSScreen.screens.enumerated() {
                if let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                   let uuidUnmanaged = CGDisplayCreateUUIDFromDisplayID(dID),
                   let uuidString = CFUUIDCreateString(nil, uuidUnmanaged.takeRetainedValue()) as String? {
                    indexToUUID[idx] = uuidString
                }
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

        let displays = temps.map { $0.info }
        var activeIdx: Int = 0
        if focusDetection, let fUUID = focusedUUID,
           let idx = temps.firstIndex(where: { $0.identifier == fUUID }) {
            activeIdx = idx
        } else {
            activeIdx = temps.firstIndex(where: { $0.containsActive }) ?? 0
        }
        let mainIdx = temps.firstIndex(where: { $0.isMain }) ?? 0

        let result = displays.isEmpty ? fallback :
            SpaceInfo(displays: displays, activeDisplayIndex: activeIdx, mainDisplayIndex: mainIdx)

        if diagnostics {
            print("[SW]   ── Computed ──")
            for (i, d) in displays.enumerated() {
                let tag = i == activeIdx ? "★" : " "
                print("[SW]   \(tag) display[\(i)]: current=\(d.current) total=\(d.total) uuid=\(d.uuid.prefix(8))...")
            }
            if let prev = previous {
                let prevSpaces = prev.displays.map { $0.current }
                let curSpaces = result.displays.map { $0.current }
                let prevActive = prev.activeDisplayIndex
                let curActive = result.activeDisplayIndex
                print("[SW]   diffs: spaces \(prevSpaces)→\(curSpaces)  activeIdx \(prevActive)→\(curActive)")
            }
            print("[SW] ── End ──\n")
        }

        return result
    }
}
