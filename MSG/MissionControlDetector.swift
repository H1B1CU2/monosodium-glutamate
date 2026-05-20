import AppKit

/// Detects whether Mission Control is currently active.
///
/// When the Dock is visible (not auto-hidden), the dock panel itself sits at
/// CGWindowLayer ~20 — within the elevated 1..<1000 range. So layer alone isn't
/// enough to distinguish "dock visible" from "MC active". We count Dock-owned
/// windows in that layer range instead: the dock panel contributes exactly 1
/// window; MC adds at least one more (space-preview thumbnails / MC chrome).
enum MissionControlDetector {

    static func isActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        var count = 0
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "Dock" else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer > 0 && layer < 1000 {
                count += 1
                if count >= 2 { return true }
            }
        }
        return false
    }
}
