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
    private static let overlayNames: Set<String> = [
        "Spaces Bar",
        "Expose Overlay",
        "ExposeShieldWindow",
        "Mission Control",
    ]

    static func isActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "WindowManager" else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer > 0 && layer < 1000 else { continue }

            // When window names are readable (requires Screen Recording permission),
            // require a known overlay name so Stage Manager's positive-layer windows
            // can't trigger a false positive. Without that permission the name is
            // nil/empty — and a positive-layer WindowManager window is, by itself,
            // already a strong Mission Control signal — so accept it.
            if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                if overlayNames.contains(name) { return true }
            } else {
                return true
            }
        }
        return false
    }
}
