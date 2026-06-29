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

// MARK: - Menu bar item spacing

/// Adjusts the global macOS menu bar item spacing/padding, mirroring the
/// `beyondthecode-bc/MenuBarSpacing` tool. These two undocumented keys live in
/// the per-host global domain (`~/Library/Preferences/ByHost/.GlobalPreferences…`).
/// macOS reads them when a status-item owner launches, so a full effect requires
/// a logout/restart — `refreshMenuBar()` is only a best-effort live nudge.
enum MenuBarSpacingManager {
    static let spacingKey = "NSStatusItemSpacing"
    static let paddingKey = "NSStatusItemSelectionPadding"

    /// macOS default for both keys when unset.
    static let systemDefault = 16
    static let spacingRange: ClosedRange<Int> = 0...30
    static let paddingRange: ClosedRange<Int> = 0...20

    /// Writes both keys to the per-host global domain.
    static func apply(spacing: Int, padding: Int) {
        write(spacingKey, spacing)
        write(paddingKey, padding)
    }

    /// Removes both keys, restoring macOS defaults.
    static func reset() {
        delete(spacingKey)
        delete(paddingKey)
    }

    /// Writes the values, restarts the system menu bar so its own items pick up
    /// the change immediately, then offers a logout for any third-party items
    /// that only read the value when their owning app launches.
    static func applyAndOfferLogout(spacing: Int, padding: Int) {
        apply(spacing: spacing, padding: padding)
        restartMenuBar()
        promptLogout()
    }

    /// Restarts the system menu bar processes. launchd relaunches both
    /// immediately, so the system icons re-read the new spacing.
    static func restartMenuBar() {
        killall("ControlCenter")
        killall("SystemUIServer")
    }

    /// Triggers a standard macOS logout (shows the system confirmation dialog).
    static func logOut() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to log out"])
    }

    private static func promptLogout() {
        let alert = NSAlert()
        alert.messageText = "Menu bar spacing applied"
        alert.informativeText = "The system menu bar was restarted, so its icons update now. Third-party menu bar icons only pick up the new spacing after you log out.\n\nLog out now to apply everywhere?"
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            logOut()
        }
    }

    // MARK: Private

    private static func write(_ key: String, _ value: Int) {
        defaults(["-currentHost", "write", "-globalDomain", key, "-int", String(value)])
    }

    private static func delete(_ key: String) {
        defaults(["-currentHost", "delete", "-globalDomain", key])
    }

    private static func defaults(_ args: [String]) {
        run("/usr/bin/defaults", args)
    }

    private static func killall(_ name: String) {
        run("/usr/bin/killall", [name])
    }

    private static func run(_ launchPath: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("MenuBarSpacingManager: \(launchPath) \(args) failed: \(error)")
        }
    }
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
