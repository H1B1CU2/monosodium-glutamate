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
    }
    let displays: [DisplayInfo]
    let activeDisplayIndex: Int
    let mainDisplayIndex: Int       // index of the main (menu bar) display

    var focusedDisplay: DisplayInfo {
        guard activeDisplayIndex >= 0, activeDisplayIndex < displays.count else {
            return DisplayInfo(current: 1, total: 1)
        }
        return displays[activeDisplayIndex]
    }
}

// MARK: - SpaceWatcher

final class SpaceWatcher {

    private(set) var currentInfo = SpaceInfo(
        displays: [.init(current: 1, total: 1)], activeDisplayIndex: 0, mainDisplayIndex: 0
    )
    private let onChange: () -> Void
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    func start() {
        updateInfo()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateInfo() }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateInfo() }
    }

    func stop() {
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
    }

    deinit { stop() }

    func updateInfo() {
        let newInfo = Self.readSpaceInfo(prioritizeMain: prioritizeMain)
        guard newInfo != currentInfo else { return }
        currentInfo = newInfo
        DispatchQueue.main.async { self.onChange() }
    }

    var prioritizeMain = true {
        didSet { if oldValue != prioritizeMain { updateInfo() } }
    }

    static func readSpaceInfo(prioritizeMain: Bool = true) -> SpaceInfo {
        let cid = CGSMainConnectionID()
        let activeID = CGSGetActiveSpace(cid)
        let fallback = SpaceInfo(displays: [.init(current: 1, total: 1)], activeDisplayIndex: 0, mainDisplayIndex: 0)

        guard let raw = CGSCopyManagedDisplaySpaces(cid),
              let displayDicts = raw as? [[String: Any]] else { return fallback }

        // Map UUIDs to X-origins for sorting, and identify the primary UUID
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

        struct TempDisplay {
            let info: SpaceInfo.DisplayInfo
            let isMain: Bool
            let xOrigin: CGFloat
            let containsActive: Bool
        }

        var tempDisplays: [TempDisplay] = []

        for dict in displayDicts {
            guard let spaces = dict["Spaces"] as? [[String: Any]] else { continue }
            var ids: [Int] = []
            for s in spaces {
                if let v = s["id64"] as? Int { ids.append(v) }
                else if let v = s["id"] as? Int { ids.append(v) }
            }
            guard !ids.isEmpty else { continue }

            var cur = 1
            if let cs = dict["Current Space"] as? [String: Any],
               let csid = cs["id64"] as? Int ?? cs["id"] as? Int,
               let idx = ids.firstIndex(of: csid) { cur = idx + 1 }

            let ident = dict["Display Identifier"] as? String ?? ""
            let isMainIdent = ident == "Main" || (primaryUUID != nil && ident == primaryUUID)
            let x = isMainIdent ? 0 : (uuidToX[ident] ?? 99999)
            let isMain = isMainIdent || x == 0

            tempDisplays.append(TempDisplay(
                info: .init(current: cur, total: ids.count),
                isMain: isMain,
                xOrigin: x,
                containsActive: ids.contains(activeID)
            ))
        }

        // Sort: (Main vs Non-Main) based on flag, then by X coordinate
        tempDisplays.sort { a, b in
            if a.isMain != b.isMain {
                return prioritizeMain ? a.isMain : b.isMain
            }
            return a.xOrigin < b.xOrigin
        }

        let displays = tempDisplays.map { $0.info }
        let activeIdx = tempDisplays.firstIndex(where: { $0.containsActive }) ?? 0
        let mainIdx = tempDisplays.firstIndex(where: { $0.isMain }) ?? 0

        return displays.isEmpty ? fallback :
            SpaceInfo(displays: displays, activeDisplayIndex: activeIdx, mainDisplayIndex: mainIdx)
    }
}
