import AppKit

/// Detects whether Mission Control / App Exposé is currently on screen.
///
/// macOS 26 (Tahoe) changed the signal. The old heuristic — counting `Dock`-owned
/// windows — is dead: the Dock now keeps a persistent window (layer 20) on screen
/// even when Mission Control is closed, so its presence proves nothing.
///
/// The reliable signal moved to the `WindowManager` process. On the idle desktop,
/// WindowManager only owns the wallpaper/backdrop/shield windows, all at hugely
/// negative CGWindowLayers. When Mission Control or App Exposé opens, WindowManager
/// adds overlay windows at small *positive* layers (~14–19):
///   • "Spaces Bar"          (layer 14) — Mission Control's top spaces strip
///   • "Expose Overlay"      (layer 17) — window-thumbnail overlay
///   • "ExposeShieldWindow"  (layer 19) — background shield
/// A positive-layer WindowManager window is therefore the tell.
enum MissionControlDetector {

    /// Named WindowManager overlays that exist only during Mission Control / Exposé.
    static let overlayNames: Set<String> = [
        "Spaces Bar",
        "Expose Overlay",
        "ExposeShieldWindow",
        "Mission Control",
    ]

    static func isActive() -> Bool {
        return WindowListScanner.scan().missionControlActive
    }
}

/// One on-screen window-list pass, yielding every signal MSG derives from it.
/// Both consumers (Mission Control detection and menu-bar-pair slide detection)
/// used to run their own full `CGWindowListCopyWindowInfo` dump; this collapses
/// them into a single WindowServer round trip.
struct WindowListSignals {
    /// Mission Control / App Exposé is on screen.
    let missionControlActive: Bool
    /// Onscreen Window Server menu bar windows (layer 24). ≥2 means a space
    /// slide is in flight — see the doc on `menuBarWindowCount` for why.
    let menuBarWindowCount: Int
}

enum WindowListScanner {
    static func scan() -> WindowListSignals {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return WindowListSignals(missionControlActive: false, menuBarWindowCount: 1)
        }
        var mc = false
        var menuBars = 0
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if owner == "Window Server", layer == 24 { menuBars += 1; continue }
            guard !mc, owner == "WindowManager", layer > 0, layer < 1000 else { continue }
            // Name check preserved verbatim from MissionControlDetector — see the
            // rationale comment there about Screen Recording permission and Stage Manager.
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                if MissionControlDetector.overlayNames.contains(name) { mc = true }
            } else {
                mc = true
            }
        }
        return WindowListSignals(missionControlActive: mc,
                                 menuBarWindowCount: max(1, menuBars))
    }
}
