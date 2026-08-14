import AppKit
import ApplicationServices
import SwiftUI

// MARK: - SwitcherItem

/// One app tile inside the Cmd-Tab application switcher.
private struct SwitcherItem: Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// Tile frame in Cocoa (bottom-left origin) global coordinates.
    let frame: CGRect

    /// Identity is the app, not the tile rect — the switcher re-lays out its row
    /// as apps come and go, and a frame-sensitive equality would restart the
    /// dwell timer while the selection never actually moved.
    static func == (lhs: SwitcherItem, rhs: SwitcherItem) -> Bool {
        lhs.pid == rhs.pid
    }
}

// MARK: - AppSwitcherHoverController

/// Shows the same window-preview card as the Dock hover preview when the
/// selection in the native Cmd-Tab application switcher rests on one app for the
/// configured dwell.
///
/// It never touches the switcher: the card is a click-through panel layered over
/// it, and the switcher keeps every key and mouse event it would normally get.
///
/// Detection is entirely Accessibility-driven. The Dock exposes its persistent
/// strip as an `AXList`; while the switcher is up it publishes a *second* list
/// whose children are `AXApplicationDockItem`s. Which attribute marks the
/// highlighted item has moved around between macOS releases, so `selectedItem`
/// tries every known marker in turn rather than betting on one.
@available(macOS 14.0, *)
final class AppSwitcherHoverController {

    private let settings: AppSettings

    private var flagsMonitorGlobal: Any?
    private var flagsMonitorLocal: Any?
    /// Runs only while a modifier that can drive the switcher is held down.
    private var pollTimer: Timer?

    private var dockApp: AXUIElement?
    /// The Dock's own strip list, learned whenever the switcher is *not* up. The
    /// switcher is then simply "the list that isn't this one".
    private var dockStripList: AXUIElement?

    private var panel: DockPreviewPanel?

    /// Currently highlighted app, and when the highlight landed on it.
    private var selection: SwitcherItem?
    private var selectionStamp: CFAbsoluteTime = 0
    /// Set once the dwell for `selection` has been acted on, so a captureless app
    /// isn't re-captured on every tick.
    private var dwellConsumed = false
    private var isPanelVisible = false
    /// Generation counter so a slow async capture for an abandoned app is ignored.
    private var captureToken = 0
    private var switcherFrame: CGRect = .zero

    private let debug = UserDefaults.standard.bool(forKey: "appSwitcherPreviewDebug")

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Lifecycle

    func start() {
        guard flagsMonitorGlobal == nil else { return }
        resolveDockElement()
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handleFlags(e.modifierFlags) }
        flagsMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { handler($0) }
        flagsMonitorLocal  = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in handler(e); return e }
    }

    func stop() {
        if let m = flagsMonitorGlobal { NSEvent.removeMonitor(m); flagsMonitorGlobal = nil }
        if let m = flagsMonitorLocal  { NSEvent.removeMonitor(m); flagsMonitorLocal = nil }
        stopPolling()
        hide()
        panel?.orderOut()
    }

    // MARK: Modifier tracking

    /// The switcher lives as long as Command is held (Shift/Option only change the
    /// direction), so Command down arms the poll and Command up tears it down.
    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            startPolling()
        } else {
            stopPolling()
            hide()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // One AX round trip per tick, and only while Command is physically down —
        // fast enough to catch a quick Tab-and-rest, cheap enough to ignore.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Poll

    private func poll() {
        // Self-heal: a missed key-up (screen lock, permission blip) would other-
        // wise leave the poll running forever.
        guard NSEvent.modifierFlags.contains(.command) else {
            stopPolling()
            hide()
            return
        }

        guard let list = switcherList(),
              let element = selectedItem(in: list),
              let item = resolveItem(element) else {
            // Switcher gone (or nothing highlighted) — drop the card.
            if selection != nil || isPanelVisible { hide() }
            return
        }

        // Place against the whole switcher panel; if it won't report a frame, the
        // selected tile alone is a good enough anchor.
        let listFrame = WindowPreviewCapture.axFrame(of: list).map { axRectToCocoa($0) } ?? .zero
        switcherFrame = listFrame.isEmpty ? item.frame : listFrame

        if item != selection {
            selection = item
            selectionStamp = CFAbsoluteTimeGetCurrent()
            dwellConsumed = false
            // Once a card is up it follows the selection immediately: the dwell is
            // the cost of *opening* the preview, not of every step after it.
            if isPanelVisible { beginCapture(for: item) }
            return
        }

        guard !isPanelVisible, !dwellConsumed else { return }
        let delay = max(0.05, settings.appSwitcherPreviewDelay)
        if CFAbsoluteTimeGetCurrent() - selectionStamp >= delay {
            dwellConsumed = true
            beginCapture(for: item)
        }
    }

    // MARK: Presentation

    private func beginCapture(for item: SwitcherItem) {
        guard WindowPreviewCapture.hasPreviewableWindows(pid: item.pid) else {
            if isPanelVisible { hidePanelOnly() }
            return
        }
        captureToken &+= 1
        let token = captureToken
        let pid = item.pid
        Task { @MainActor [weak self] in
            let windows = await WindowPreviewCapture.capture(pid: pid)
            guard let self, self.captureToken == token, self.selection == item else { return }

            // A single id-0 entry is the app-icon placeholder, not a real window.
            let isWindowed = !windows.isEmpty && !(windows.count == 1 && windows[0].id == 0)
            if isWindowed {
                self.present(item: item, windows: windows)
            } else {
                self.hidePanelOnly()
            }
        }
    }

    private func present(item: SwitcherItem, windows: [CapturedWindow]) {
        isPanelVisible = true
        if panel == nil {
            // Click-through, and above the switcher's own window level so the card
            // is never drawn behind it.
            panel = DockPreviewPanel(interactive: false, level: .popUpMenu)
        }
        let icon = item.bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.icon }

        let screen = NSScreen.screens.first { $0.frame.intersects(switcherFrame) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let maxContentWidth = max(320, screen.visibleFrame.width - 100)

        panel?.present(
            appName: item.name,
            appIcon: icon,
            windows: windows,
            thumbHeight: settings.dockPreviewThumbHeight,
            maxContentWidth: maxContentWidth,
            placement: .appSwitcher(switcher: switcherFrame,
                                    selected: item.frame,
                                    offset: settings.appSwitcherPreviewOffset)
        )
    }

    /// Drops the card but keeps the current selection/dwell bookkeeping — used
    /// when the highlighted app simply has nothing to preview.
    private func hidePanelOnly() {
        isPanelVisible = false
        captureToken &+= 1
        panel?.dismiss()
    }

    private func hide() {
        selection = nil
        dwellConsumed = false
        hidePanelOnly()
    }

    // MARK: Switcher Accessibility

    private func resolveDockElement() {
        if let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        }
    }

    /// The switcher's list element, or nil when the switcher isn't on screen.
    private func switcherList() -> AXUIElement? {
        if dockApp == nil { resolveDockElement() }
        guard let dockApp else { return nil }

        let lists = axChildren(dockApp).filter { axString($0, kAXRoleAttribute) == (kAXListRole as String) }
        guard lists.count > 1 else {
            // Only the persistent strip is up: remember it, so the extra list that
            // appears next is unambiguously the switcher.
            if let strip = lists.first { dockStripList = strip }
            return nil
        }

        let candidates = lists.filter { list in
            guard let strip = dockStripList else { return true }
            return !CFEqual(strip, list)
        }
        // The switcher is published after the strip, so the last non-strip list is
        // the right pick even if the strip was never learned.
        guard let list = candidates.last ?? lists.last else { return nil }
        guard !axChildren(list).isEmpty else { return nil }
        if debug { NSLog("[AppSwitcher] lists=\(lists.count) items=\(axChildren(list).count)") }
        return list
    }

    /// The highlighted tile. macOS has marked this several different ways across
    /// releases, so every known marker is tried before giving up.
    private func selectedItem(in list: AXUIElement) -> AXUIElement? {
        if let selected = axElements(list, kAXSelectedChildrenAttribute)?.first {
            if debug { NSLog("[AppSwitcher] selection via AXSelectedChildren") }
            return selected
        }

        let items = axChildren(list)
        for attr in [kAXSelectedAttribute as String, kAXFocusedAttribute as String, "AXHighlighted"] {
            if let hit = items.first(where: { axBool($0, attr) == true }) {
                if debug { NSLog("[AppSwitcher] selection via \(attr)") }
                return hit
            }
        }

        // Last resort: the Dock's focused element is the switcher's selection
        // while the switcher owns the keyboard.
        if let dockApp,
           let focused = axElement(dockApp, kAXFocusedUIElementAttribute as String),
           items.contains(where: { CFEqual($0, focused) }) {
            if debug { NSLog("[AppSwitcher] selection via AXFocusedUIElement") }
            return focused
        }

        if debug { NSLog("[AppSwitcher] no selection marker found on \(items.count) items") }
        return nil
    }

    /// Resolves a switcher tile to the running app behind it.
    private func resolveItem(_ element: AXUIElement) -> SwitcherItem? {
        let title = axString(element, kAXTitleAttribute) ?? ""
        var urlRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef)
        let bundleID: String? = (urlRef as? URL).flatMap { Bundle(url: $0)?.bundleIdentifier }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID ?? "").first
            ?? NSWorkspace.shared.runningApplications.first {
                $0.activationPolicy == .regular && $0.localizedName == title
            }
        guard let app = running,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let frame = WindowPreviewCapture.axFrame(of: element).map { axRectToCocoa($0) } ?? .zero
        return SwitcherItem(pid: app.processIdentifier,
                            bundleID: app.bundleIdentifier ?? bundleID,
                            name: app.localizedName ?? title,
                            frame: frame)
    }

    // MARK: AX helpers

    private func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        axElements(element, kAXChildrenAttribute as String) ?? []
    }

    private func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    // MARK: Coordinate conversion (AX/Quartz top-left → Cocoa bottom-left)

    private var primaryHeight: CGFloat {
        (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    private func axRectToCocoa(_ r: CGRect) -> CGRect {
        guard r != .zero else { return .zero }
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
