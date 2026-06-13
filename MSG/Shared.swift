import AppKit
import CoreGraphics

// Shared, single-source-of-truth helpers used across the app. Previously these
// were copy-pasted into Indicator, WallpaperEngine, SettingsMenu, SettingsWindow,
// CornerWindow, SpaceWatcher and Displaplacer.

// MARK: - Display identity

enum DisplayID {
    /// Stable UUID string for a CoreGraphics display ID, or nil if unresolved.
    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String?
    }
}

extension NSScreen {
    /// Stable UUID string for this screen, or nil if it can't be resolved.
    var uuid: String? {
        guard let dID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return DisplayID.uuid(dID)
    }

    /// True if this is the built-in display (laptop screen).
    var isBuiltin: Bool {
        guard let dID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return self == NSScreen.screens.first
        }
        return CGDisplayIsBuiltin(dID) != 0
    }
}

// MARK: - Display geometry

/// Human-readable position of `screen` relative to `other` (e.g. "Above & Left").
func displayPosition(for screen: NSScreen, relativeTo other: NSScreen) -> String {
    let e = screen.frame, m = other.frame
    var h = "", v = ""
    if e.maxX <= m.minX { h = "Left" } else if e.minX >= m.maxX { h = "Right" }
    if e.minY >= m.maxY { v = "Above" } else if e.maxY <= m.minY { v = "Below" }
    if h.isEmpty && v.isEmpty { return "Overlapping" }
    if h.isEmpty { return v }
    if v.isEmpty { return h }
    return "\(v) & \(h)"
}

// MARK: - Hardware

enum MacModel {
    /// Marketing model name (e.g. "MacBook Pro"), resolved once via system_profiler.
    static let name: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let out = String(data: data, encoding: .utf8),
               let line = out.components(separatedBy: "\n").first(where: { $0.contains("Model Name") }),
               let name = line.split(separator: ":").last {
                return name.trimmingCharacters(in: .whitespaces)
            }
        } catch {}
        return "Mac"
    }()
}
