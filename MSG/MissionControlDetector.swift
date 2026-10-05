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
    /// Displays whose native menu-bar surface is actually on screen. Unlike
    /// NSMenu.menuBarVisible(), this changes when an auto-hidden bar slides in.
    let visibleMenuBarDisplayUUIDs: Set<String>
    /// A LocalAuthentication Touch ID sheet (`coreautha`) is on screen. Its
    /// agent doesn't reliably become the active app while the sheet is up —
    /// often only as it closes — so the window itself is the signal.
    var touchIDPromptVisible = false
}

enum WindowListScanner {
    private static let lock = NSLock()
    private static var cached: (stamp: CFTimeInterval, signals: WindowListSignals)?

    /// One pass shared by every caller. Mission Control checks run from many
    /// guards per tiling refresh, the control bar asks up to 15×/s and
    /// SystemState 30×/s — each used to pull the full on-screen window list
    /// from WindowServer on its own. A pass up to `maxAge` old is reused;
    /// pass 0 where a frame of latency matters (SystemState's slide detection).
    static func scan(maxAge: CFTimeInterval = 0.1) -> WindowListSignals {
        let now = CACurrentMediaTime()
        lock.lock()
        if let cached, now - cached.stamp <= maxAge {
            lock.unlock()
            return cached.signals
        }
        lock.unlock()
        let signals = freshScan()
        lock.lock()
        cached = (CACurrentMediaTime(), signals)
        lock.unlock()
        return signals
    }

    private static func freshScan() -> WindowListSignals {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return WindowListSignals(missionControlActive: false, menuBarWindowCount: 1,
                                     visibleMenuBarDisplayUUIDs: [])
        }
        var mc = false
        var touchIDPrompt = false
        var menuBars = 0
        var menuBarFrames: [CGRect] = []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if owner == "Window Server", layer == 24 {
                menuBars += 1
                if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
                    var frame = CGRect.zero
                    if CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) {
                        menuBarFrames.append(frame)
                    }
                }
                continue
            }
            if owner == "coreautha", layer > 0 { touchIDPrompt = true; continue }
            // The same panel hosted inside an app (System Settings asking for
            // Touch ID) has no coreautha window: it's the app's own, untitled
            // and exactly the standard 260 pt wide.
            if !touchIDPrompt, layer >= 0, owner != "MSG", owner != "Window Server",
               (w[kCGWindowName as String] as? String).map({ $0.isEmpty || $0 == "Untitled" }) ?? true,
               let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
               width == 260, height > 200, height < 420 {
                touchIDPrompt = true
                continue
            }
            guard !mc, owner == "WindowManager", layer > 0, layer < 1000 else { continue }
            // Name check preserved verbatim from MissionControlDetector — see the
            // rationale comment there about Screen Recording permission and Stage Manager.
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                if MissionControlDetector.overlayNames.contains(name) { mc = true }
            } else {
                mc = true
            }
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var visibleMenuBarDisplayUUIDs = Set<String>()
        for quartzFrame in menuBarFrames {
            let appKitFrame = CGRect(x: quartzFrame.minX,
                                     y: primaryTop - quartzFrame.maxY,
                                     width: quartzFrame.width,
                                     height: quartzFrame.height)
            if let screen = NSScreen.screens.max(by: {
                $0.frame.intersection(appKitFrame).width < $1.frame.intersection(appKitFrame).width
            }), screen.frame.intersects(appKitFrame), let uuid = screen.uuid {
                visibleMenuBarDisplayUUIDs.insert(uuid)
            }
        }
        return WindowListSignals(missionControlActive: mc,
                                 menuBarWindowCount: max(1, menuBars),
                                 visibleMenuBarDisplayUUIDs: visibleMenuBarDisplayUUIDs,
                                 touchIDPromptVisible: touchIDPrompt)
    }
}
