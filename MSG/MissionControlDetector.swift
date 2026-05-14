import AppKit

/// Detects whether Mission Control is currently active.
///
/// During MC, Dock spawns on-screen windows at positive CGWindowLevel (< 1000)
/// for space-preview thumbnails. These exist only while MC is open and are the
/// most reliable signal — frontmost-app and activation callbacks lie during
/// the MC animation.
enum MissionControlDetector {

    static func isActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "Dock" else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer > 0 && layer < 1000 {
                return true
            }
        }
        return false
    }
}
