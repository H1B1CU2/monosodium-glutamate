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

// Write diagnostics to a file so we don't depend on stdout buffering.
private let diagPath = "/tmp/msg_diagnostics.log"
private func diag(_ msg: String) {
    let line = msg + "\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: diagPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: diagPath, contents: data)
        }
    }
}

// MARK: - SpaceWatcher

final class SpaceWatcher {

    private(set) var currentInfo = SpaceInfo(
        displays: [.init(current: 1, total: 1, uuid: "")],
        activeDisplayIndex: 0, mainDisplayIndex: 0
    )

    var onChange: (() -> Void)?

    // Stabilisation: when a display's current value changes, we hold the old
    // value for `stabiliseInterval` seconds. Only if the new value persists
    // for the full interval do we accept it. This filters the CGS oscillation
    // seen during MC exit (see diagnostics log).
    private let stabiliseInterval: TimeInterval = 0.5
    private var stabiliseWork: DispatchWorkItem?
    private var stabilisePending: SpaceInfo?

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
            diag("[SW] 🔔 notification fired  (+\(since)s since last read)")
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
            diag("[SW] updateInfo() called  (+\(since)s since last read)  force=\(forceNotify)  debounced=\(debounceWork != nil)")
        }

        let newInfo = Self.readSpaceInfo(
            prioritizeMain: prioritizeMain,
            customOrder: customOrder,
            focusDetection: focusDetection,
            focusedUUID: currentFocusedUUID,
            previous: currentInfo,
            diagnostics: diagnosticsEnabled
        )

        // Screen parameter changes or force-notify: accept immediately
        if forceNotify {
            if newInfo != currentInfo {
                if diagnosticsEnabled {
                    diag("[SW] force/notify — accepting immediately")
                    diag("[SW]   old: \(currentInfo)")
                    diag("[SW]   new: \(newInfo)")
                    print("")
                }
                currentInfo = newInfo
                DispatchQueue.main.async { self.onChange?() }
            }
            return
        }

        guard newInfo != currentInfo else {
            if diagnosticsEnabled { diag("[SW] no change") }
            return
        }

        // A change was detected. Start/restart the stabilisation timer.
        // During the stabilisation window we keep the OLD value visible.
        // Only when the new value has been stable for stabiliseInterval
        // do we commit it.
        stabilisePending = newInfo
        stabiliseWork?.cancel()

        if diagnosticsEnabled {
            let oldCur = currentInfo.displays.map { $0.current }
            let newCur = newInfo.displays.map { $0.current }
            diag("[SW] pending stabilisation: \(oldCur)→\(newCur)")
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.stabilisePending else { return }
            self.stabiliseWork = nil
            self.stabilisePending = nil

            // Read CGS one more time to confirm the change is real
            let confirm = Self.readSpaceInfo(
                prioritizeMain: self.prioritizeMain,
                customOrder: self.customOrder,
                focusDetection: self.focusDetection,
                focusedUUID: self.currentFocusedUUID,
                previous: self.currentInfo,
                diagnostics: self.diagnosticsEnabled
            )

            let pendingCur = pending.displays.map { $0.current }
            let confirmCur = confirm.displays.map { $0.current }

            if pendingCur == confirmCur && pendingCur != self.currentInfo.displays.map({ $0.current }) {
                // The new values persisted — this is a real change.
                if self.diagnosticsEnabled {
                    diag("[SW] stabilised — accepting \(pendingCur)")
                    print("")
                }
                self.currentInfo = confirm
                DispatchQueue.main.async { self.onChange?() }
            } else if pendingCur != confirmCur {
                // Values changed again during the window — restart stabilisation
                if self.diagnosticsEnabled {
                    diag("[SW] oscillation detected: \(pendingCur)→\(confirmCur) — restarting")
                }
                self.stabilisePending = confirm
                let rework = DispatchWorkItem { [weak self] in
                    guard let self, let p = self.stabilisePending else { return }
                    self.stabiliseWork = nil
                    self.stabilisePending = nil
                    let final = Self.readSpaceInfo(
                        prioritizeMain: self.prioritizeMain,
                        customOrder: self.customOrder,
                        focusDetection: self.focusDetection,
                        focusedUUID: self.currentFocusedUUID,
                        previous: self.currentInfo,
                        diagnostics: self.diagnosticsEnabled
                    )
                    if final.displays.map({ $0.current }) == p.displays.map({ $0.current }),
                       final != self.currentInfo {
                        if self.diagnosticsEnabled {
                            diag("[SW] stabilised on retry — accepting")
                            print("")
                        }
                        self.currentInfo = final
                        DispatchQueue.main.async { self.onChange?() }
                    } else if self.diagnosticsEnabled {
                        diag("[SW] giving up — still oscillating, keeping current")
                        print("")
                    }
                }
                self.stabiliseWork = rework
                DispatchQueue.main.asyncAfter(deadline: .now() + self.stabiliseInterval, execute: rework)
            } else {
                if self.diagnosticsEnabled { diag("[SW] no real change after stabilise") }
            }
        }
        stabiliseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stabiliseInterval, execute: work)
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
            diag("[SW] ── CGS Read ───────────────────────")
            diag("[SW]   CGSGetActiveSpace = \(activeID)")
            diag("[SW]   Dock frontmost = \(mc)   menuBarHidden = \(fs)")
            diag("[SW]   display count = \(displayDicts.count)")
            diag("[SW]   --------------------------------")
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
                diag("[SW]   Display[\(di)] \(ident)")
                diag("[SW]     CurrentSpace: ManagedSpaceID=\(csManaged ?? -1)  id64=\(csID64 ?? -1)")
                diag("[SW]     Spaces: \(spaceList.joined(separator: " | "))")
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
            diag("[SW]   ── Computed ──")
            for (i, d) in displays.enumerated() {
                let tag = i == activeIdx ? "★" : " "
                diag("[SW]   \(tag) display[\(i)]: current=\(d.current) total=\(d.total) uuid=\(d.uuid.prefix(8))...")
            }
            if let prev = previous {
                let prevSpaces = prev.displays.map { $0.current }
                let curSpaces = result.displays.map { $0.current }
                let prevActive = prev.activeDisplayIndex
                let curActive = result.activeDisplayIndex
                diag("[SW]   diffs: spaces \(prevSpaces)→\(curSpaces)  activeIdx \(prevActive)→\(curActive)")
            }
            diag("[SW] ── End ──\n")
        }

        return result
    }
}
