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

    func start() {
        updateInfo()
        spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateInfo()
        }

        screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateInfo() }
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
            previous: currentInfo
        )
        guard newInfo != currentInfo else {
            if forceNotify { DispatchQueue.main.async { self.onChange?() } }
            return
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
        previous: SpaceInfo? = nil
    ) -> SpaceInfo {
        let cid = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(cid)
        let fallback = SpaceInfo(displays: [.init(current: 1, total: 1, uuid: "")], activeDisplayIndex: 0, mainDisplayIndex: 0)

        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displayDicts = raw as? [[String: Any]] else { return fallback }

        var prevByUUID: [String: Int] = [:]
        if let prev = previous { for d in prev.displays { prevByUUID[d.uuid] = d.current } }

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

        return displays.isEmpty ? fallback :
            SpaceInfo(displays: displays, activeDisplayIndex: activeIdx, mainDisplayIndex: mainIdx)
    }
}
