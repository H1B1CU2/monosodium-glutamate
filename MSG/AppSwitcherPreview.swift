import AppKit
import ApplicationServices
import Combine
import Darwin
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

// MARK: - NativeAppSwitcherPreviewController

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
final class NativeAppSwitcherPreviewController {

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

// MARK: - MSG replacement switcher
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Adapted from Vorssaint v3.3.2 AppSwitcher.swift, SwitcherSupport.swift and
// SwitcherView.swift. MSG modifications: independent native/replacement modes,
// fixed Cmd-Tab binding, asynchronous event routing and MSG thumbnail/focus APIs.
// See ThirdParty/Vorssaint for the source revision, attribution and license.

/// Only one controller may own Cmd-Tab. Native mode never installs an event tap.
@available(macOS 14.0, *)
final class AppSwitcherHoverController {
    private let settings: AppSettings
    private let native: NativeAppSwitcherPreviewController
    private let replacement: MSGWindowSwitcher
    init(settings: AppSettings) {
        self.settings = settings
        native = NativeAppSwitcherPreviewController(settings: settings)
        replacement = MSGWindowSwitcher(settings: settings)
    }
    func start() {
        stop()
        if settings.appSwitcherMode == "native" { native.start() }
        else { replacement.start() }
    }
    func stop() {
        native.stop()
        replacement.stop()
    }
}

/// Pure search/selection logic ported from Vorssaint's SwitcherSupport.
enum MSGSwitcherSearch {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func matches(title: String, app: String, query: String) -> Bool {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace)
        let haystack = normalized(title + " " + app)
        return tokens.allSatisfy { haystack.contains($0) }
    }
    static func sanitized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }))
    }
    static func next(_ index: Int, delta: Int, count: Int, wrapping: Bool = true) -> Int {
        guard count > 0 else { return 0 }
        if !wrapping { return min(max(0, index + delta), count - 1) }
        return ((index + delta) % count + count) % count
    }
}

/// One cell of the switcher grid: a window, or the padding that keeps the next
/// app's run from starting mid-row.
private enum MSGSwitcherSlot: Identifiable {
    case window(MSGSwitcherWindow)
    case blank(Int)

    var id: String {
        switch self {
        case .window(let w): return w.id
        case .blank(let n):  return "blank-\(n)"
        }
    }
}

// MARK: - Private CGS API Bindings

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: CGSConnectionID) -> Int

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ windowIDs: CFArray) -> CFArray?

private struct MSGSwitcherSpace: Identifiable {
    let id: Int
    let displayID: CGDirectDisplayID?
    let displayName: String?
    let type: Int
    let name: String
    let isCurrent: Bool
    let order: Int
}

private struct MSGSwitcherWindow: Identifiable {
    var id: String { "\(pid):\(window.id)" }
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    /// Display the window lives on, resolved once at enumeration from its
    /// bounds. `nil` for the icon-only placeholder an app with no enumerable
    /// windows gets, whose bounds are `.zero`.
    let displayID: CGDirectDisplayID?
    let spaceID: Int?
    let spaceName: String?
    var window: CapturedWindow
    var category: String = "Float"
}

/// How the switcher treats a multi-display setup.
private enum MSGSwitcherDisplayMode: String {
    /// Every window, in one list. The original behaviour.
    case unified = "all"
    /// Every window, but split into a labelled section per display.
    case grouped = "grouped"
    /// Only the windows on the display the panel is currently on.
    case currentOnly = "current"

    init(_ raw: String) { self = MSGSwitcherDisplayMode(rawValue: raw) ?? .unified }
}

/// Visual arrangement of windows in the switcher panel.
private enum MSGSwitcherLayout: String {
    case grid = "grid"
    case singleRow = "singleRow"
    case spacePerRow = "spacePerRow"

    init(_ raw: String) { self = MSGSwitcherLayout(rawValue: raw) ?? .grid }
}

/// A display, described in the coordinate space window bounds arrive in.
///
/// `CapturedWindow.bounds` is Quartz global: top-left origin, y growing
/// downwards, measured from the *primary* display's top-left. `NSScreen.frame`
/// is Cocoa global: bottom-left origin, y growing upwards. A screen below or
/// right of the primary one therefore has a negative Quartz origin in one
/// space and a positive Cocoa one in the other, so the two cannot be compared
/// without this conversion.
private struct MSGSwitcherDisplay {
    let id: CGDirectDisplayID
    let name: String
    let uuid: String?
    let quartzFrame: CGRect

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func displayUUID(for id: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// Snapshot of the current displays. Read on the main thread and passed by
    /// value into the enumeration task — `NSScreen` is not safe to touch from
    /// a background queue.
    static func table() -> [MSGSwitcherDisplay] {
        // `NSScreen.screens[0]` is the primary display by definition, and its
        // top edge is the Quartz origin.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let id = displayID(for: screen) else { return nil }
            let f = screen.frame
            return MSGSwitcherDisplay(id: id, name: screen.localizedName,
                                      uuid: displayUUID(for: id),
                                      quartzFrame: CGRect(x: f.minX, y: primaryTop - f.maxY,
                                                          width: f.width, height: f.height))
        }
    }

    /// Which display a window sits on: the one containing its centre, or
    /// failing that the one it overlaps most. A window straddling a boundary
    /// belongs to whichever display shows more of it, which is also the one
    /// macOS treats as its own.
    static func owner(of bounds: CGRect, in table: [MSGSwitcherDisplay]) -> CGDirectDisplayID? {
        guard !bounds.isEmpty else { return nil }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        if let hit = table.first(where: { $0.quartzFrame.contains(centre) }) { return hit.id }
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for display in table {
            let overlap = display.quartzFrame.intersection(bounds)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (display.id, area) }
        }
        return best?.id
    }
}

/// One run of rows under a single heading.
private struct MSGSwitcherSection: Identifiable {
    let id: String
    let title: String?
    let displaySubtitle: String?
    let isCurrent: Bool
    let isFullscreen: Bool
    let showDivider: Bool
    let count: Int
    let rows: [[MSGSwitcherWindow]]
}

private enum MSGSwitcherInput {
    case begin(Bool)
    case key(Int, String, Bool, Bool)
    case commit
    case cancel
}

/// A dedicated tap thread claims only Cmd-Tab and an active session's keys.
/// It never waits for the main queue, AX, screenshots, or window activation.
/// This retains Vorssaint's separation of input routing and presentation while
/// also keeping active-session UI work out of the callback's response path.
@available(macOS 14.0, *)
private final class MSGSwitcherEventTap {
    // Mouse input must never wait for the switcher's suppressing event tap.
    static let eventMask = [CGEventType.keyDown, .keyUp, .flagsChanged]
        .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var stopped = false
    private var owned = false
    private var finishing = false
    private var session = 0
    private var swallowedKeys = Set<Int>()
    private var shiftDown = false
    private var shiftPressTime: TimeInterval = 0
    private var shiftTimer: DispatchSourceTimer?
    private let handler: (Int, MSGSwitcherInput) -> Void
    private let didStart: () -> Void

    init(didStart: @escaping () -> Void = {}, handler: @escaping (Int, MSGSwitcherInput) -> Void) {
        self.didStart = didStart; self.handler = handler
    }
    func start() {
        let thread = Thread { [self] in
            guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: Self.eventMask,
                callback: { _, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<MSGSwitcherEventTap>.fromOpaque(context)
                        .takeUnretainedValue().route(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                NSLog("[MSG Switcher] Cannot install Cmd-Tab event tap; check Accessibility access.")
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            lock.lock()
            if stopped {
                lock.unlock()
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
                CFMachPortInvalidate(created)
                return
            }
            tap = created; loop = runLoop
            lock.unlock()
            DispatchQueue.main.async { [didStart] in didStart() }
            CFRunLoopRun()
            CGEvent.tapEnable(tap: created, enable: false)
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(created)
            lock.lock(); tap = nil; loop = nil; lock.unlock()
        }
        thread.name = "MSG Cmd-Tab input"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    var isHealthy: Bool {
        lock.lock()
        let current = stopped ? nil : tap
        lock.unlock()
        // WindowServer calls must not hold the lock needed by its callback.
        return current.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } == true
    }
    func stop() {
        lock.lock()
        stopped = true; owned = false; finishing = false
        stopShiftTimer()
        shiftDown = false
        let loop = self.loop
        lock.unlock()
        if let loop {
            // Teardown runs on the tap thread after any in-flight callback.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }
    func endSession(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        if session == id {
            owned = false; finishing = false
            stopShiftTimer()
            shiftDown = false
        }
    }
    private func stopShiftTimer() {
        shiftTimer?.cancel()
        shiftTimer = nil
    }
    private func startShiftTimer() {
        stopShiftTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(120))
        let id = session
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.owned, self.shiftDown, !self.stopped, self.session == id else {
                self.lock.unlock()
                return
            }
            self.send(.key(48, "", true, true))
            self.lock.unlock()
        }
        shiftTimer = timer
        timer.resume()
    }
    private func send(_ input: MSGSwitcherInput) {
        let id = session
        DispatchQueue.main.async { [handler] in handler(id, input) }
    }
    /// The character a key would type with Command held aside, resolved without
    /// touching AppKit.
    ///
    /// This used to be `NSEvent(cgEvent:)?.charactersIgnoringModifiers`, which
    /// crashed the app outright: that path reaches HIToolbox's Text Input
    /// Services, which asserts it is on the main queue, and this tap runs on its
    /// own thread by design — an event tap serviced by the main run loop is
    /// disabled by the system the moment main blocks. The assertion is a
    /// `dispatch_assert_queue` failure, so it arrives as SIGTRAP rather than an
    /// exception: pressing ⌘-Tab killed MSG.
    ///
    /// `CGEvent.keyboardGetUnicodeString` does the same translation inside
    /// CoreGraphics, against the event's own keyboard layout, with no main-queue
    /// requirement. Command and Control are cleared on a copy first because they
    /// change what a layout produces; Shift stays so it still types uppercase.
    private static func charactersIgnoringModifiers(_ event: CGEvent) -> String {
        guard let copy = event.copy() else { return "" }
        copy.flags = event.flags.intersection(.maskShift)
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        copy.keyboardGetUnicodeString(maxStringLength: chars.count,
                                      actualStringLength: &length,
                                      unicodeString: &chars)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: min(length, chars.count))
    }

    private func route(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            guard !stopped else { lock.unlock(); return Unmanaged.passUnretained(event) }
            stopShiftTimer()
            shiftDown = false
            owned = false; finishing = false; swallowedKeys.removeAll(); send(.cancel)
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }
        // Ignore synthetic events generated by MSG itself (e.g. SpaceHop hotkeys)
        if event.getIntegerValueField(.eventSourceUserData) == 0x4D5347 {
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return Unmanaged.passUnretained(event) }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedKeys.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged {
            if owned {
                let physicalCmdDown = CGEventSource.keyState(.hidSystemState, key: 55) ||
                                      CGEventSource.keyState(.hidSystemState, key: 54)
                if !event.flags.contains(.maskCommand) && !physicalCmdDown {
                    stopShiftTimer()
                    shiftDown = false
                    owned = false; finishing = true; send(.commit)
                } else {
                    let shift = event.flags.contains(.maskShift)
                    if shift && !shiftDown {
                        shiftDown = true
                        shiftPressTime = ProcessInfo.processInfo.systemUptime
                        send(.key(48, "", true, false))
                        startShiftTimer()
                    } else if !shift && shiftDown {
                        shiftDown = false
                        stopShiftTimer()
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let shift = event.flags.contains(.maskShift)
        if !owned {
            guard code == 48, event.flags.contains(.maskCommand),
                  !event.flags.contains(.maskAlternate), !event.flags.contains(.maskControl)
            else {
                // Typing after a quick release cancels any slow pending focus.
                if finishing { finishing = false; send(.cancel) }
                return Unmanaged.passUnretained(event)
            }
            owned = true; finishing = false; session &+= 1; swallowedKeys.insert(code)
            shiftDown = shift
            shiftPressTime = ProcessInfo.processInfo.systemUptime
            send(.begin(shift)); return nil
        }
        swallowedKeys.insert(code)
        if code == 53 {
            stopShiftTimer()
            shiftDown = false
            owned = false; finishing = false; send(.cancel); return nil
        }
        if code == 36 || code == 76 {
            stopShiftTimer()
            shiftDown = false
            owned = false; finishing = true; send(.commit); return nil
        }
        if code == 48 && shift {
            let now = ProcessInfo.processInfo.systemUptime
            if now - shiftPressTime < 0.20 {
                return nil
            }
        }
        if code != 48 {
            stopShiftTimer()
        }
        // Printable letters are forwarded as .key: w (close window), q (quit app),
        // h (hide app) like macOS, with other characters routed to search.
        let text = Self.charactersIgnoringModifiers(event)
        send(.key(code, text, shift, event.getIntegerValueField(.keyboardEventAutorepeat) != 0))
        return nil
    }
}

/// Drive window movement at the refresh rate of the display hosting its view.
@available(macOS 14.0, *)
private final class MSGSwitcherDisplayAnimation: NSObject {
    private var link: CADisplayLink?
    private let update: (MSGSwitcherDisplayAnimation) -> Void

    init(view: NSView, update: @escaping (MSGSwitcherDisplayAnimation) -> Void) {
        self.update = update
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) { update(self) }

    func invalidate() {
        link?.invalidate()
        link = nil
    }
}

/// How window previews show which app a window belongs to, shared by the ⌘Tab
/// switcher and the notch preview so the two read alike: an app's windows sit
/// close together under one name, and a wider gap separates apps.
enum WindowGroupSpacing {
    /// Between two windows of the same app.
    static let sameApp: CGFloat = 10
    /// Between the last window of one app and the first of the next.
    static let betweenApps: CGFloat = 40
}

@available(macOS 14.0, *)
private final class MSGWindowSwitcher: ObservableObject {
    @Published private(set) var items: [MSGSwitcherWindow] = []
    @Published private(set) var selected = 0
    @Published private(set) var query = ""
    @Published private(set) var searchActive = false
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var canHover = false
    @Published private(set) var suppressInitialHover = false
    private var hasPresentedPanel = false
    private var beginUptime: TimeInterval = 0
    private var initialMouseLocation: NSPoint?
    private(set) var iconLayout = false
    private(set) var layoutMode: MSGSwitcherLayout = .grid
    /// Read once per invocation, so changing the setting never reshuffles a
    /// session that is already on screen.
    private(set) var displayMode: MSGSwitcherDisplayMode = .unified
    private(set) var displays: [MSGSwitcherDisplay] = []
    /// Display the panel is currently on; drives both `.currentOnly` filtering
    /// and which section comes first in `.grouped`.
    private(set) var anchorDisplayID: CGDirectDisplayID?
    private(set) var thumbHeight: CGFloat = 140
    private(set) var contentWidth: CGFloat = 800
    private(set) var contentHeight: CGFloat = 480
    private(set) var maxPerRow: Int = 5
    /// Widest a card can be: the thumbnail plus its own 6pt frame either side.
    var cellWidth: CGFloat { thumbHeight * 1.9 + 12 }
    static let cellSpacing: CGFloat = 12

    /// How many cells fit across the space the screen allows.
    private var maxColumns: Int { max(1, Int(contentWidth / (cellWidth + Self.cellSpacing))) }

    // MARK: Flow layout
    //
    // Not a grid. A grid forces every window into the same cell width, which
    // stretches narrow windows and pads wide ones, and it can only express
    // grouping by leaving whole cells empty. Here each card keeps the width its
    // own aspect ratio asks for, and grouping is carried by proximity: windows
    // of one app sit close together, a wider gap separates apps.

    /// Gap between two windows of the same app.
    static let intraGroupGap = WindowGroupSpacing.sameApp
    /// Gap between the last window of one app and the first of the next.
    static let interGroupGap = WindowGroupSpacing.betweenApps
    static let rowGap: CGFloat = 22

    /// Height of the app-name row above each card.
    static let labelHeight: CGFloat = 20
    /// Gap between that row and the card.
    static let labelGap: CGFloat = 8
    /// Slack kept around every card so the hover transform — 1.045 scale, a 3pt
    /// lift and a 12pt shadow — has somewhere to grow. Without it the card is
    /// framed to its exact size and the scroll view clips the moment it lifts.
    static let hoverSlack: CGFloat = 20
    /// Root padding either side plus the hover slack either side.
    static var chromeWidth: CGFloat { 28 + hoverSlack * 2 }

    /// Height of a display heading in grouped mode.
    static let sectionHeaderHeight: CGFloat = 18
    /// Height reserved for section divider between desktop spaces.
    static let dividerHeight: CGFloat = 11
    /// Gap between one display's block of rows and the next heading. Wider than
    /// `rowGap` so the split reads as a division, not just another row.
    static let sectionGap: CGFloat = 26

    /// Widest a card may get, as a multiple of its height.
    ///
    /// Was 1.9, which is narrower than plenty of ordinary windows — a Finder
    /// list window at 920x436 is 2.11 — so those were clamped and cropped. The
    /// cap still exists to stop one ultrawide window from taking a whole row.
    static let maxCardAspect: CGFloat = 2.6

    /// Width a card takes: its thumbnail's aspect at `thumbHeight`, plus the
    /// card's own 6pt frame either side. Mirrors `DockWindowCard`.
    func cardWidth(_ item: MSGSwitcherWindow) -> CGFloat {
        let size = item.window.image.size
        let aspect = size.height > 0 ? size.width / size.height : 1.4
        return min(thumbHeight * Self.maxCardAspect, max(80, thumbHeight * aspect)) + 12
    }

    static let categoryDividerWidth: CGFloat = 62

    /// Balance card counts within each section, retaining order and width limits.
    func pack(_ list: [MSGSwitcherWindow]) -> [[MSGSwitcherWindow]] {
        Self.balancedRowRanges(widths: list.map { cardWidth($0) },
                               appIDs: list.map(\.pid),
                               categories: list.map(\.category),
                               budget: contentWidth - Self.chromeWidth,
                               intraGap: Self.intraGroupGap,
                               interGap: Self.interGroupGap,
                               dividerWidth: Self.categoryDividerWidth,
                               maxPerRow: maxPerRow).map { Array(list[$0]) }
    }

    /// Minimise row count first, then uneven card counts, then app splits.
    /// Equal layouts put the fuller row first (five cards become 3 + 2).
    static func balancedRowRanges(widths: [CGFloat], appIDs: [pid_t],
                                  categories: [String]? = nil,
                                  budget: CGFloat,
                                  intraGap: CGFloat, interGap: CGFloat,
                                  dividerWidth: CGFloat = 62,
                                  maxPerRow: Int = 6) -> [Range<Int>] {
        let n = widths.count
        guard n > 0, appIDs.count == n else { return [] }
        var rowCounts = Array(repeating: Int.max, count: n + 1)
        var imbalance = Array(repeating: Int.max, count: n + 1)
        var splits = Array(repeating: Int.max, count: n + 1)
        var next = Array(repeating: n, count: n)
        rowCounts[n] = 0; imbalance[n] = 0; splits[n] = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            var width: CGFloat = 0
            for j in i..<n {
                if (j - i + 1) > maxPerRow { break }
                if j > i {
                    if let cats = categories, cats.indices.contains(j), cats.indices.contains(j - 1),
                       cats[j] != cats[j - 1], cats[j] != "Master" {
                        width += dividerWidth
                    } else {
                        width += appIDs[j] == appIDs[j - 1] ? intraGap : interGap
                    }
                }
                width += widths[j]
                // An individually oversized card still gets its own row.
                if j > i && width > budget { break }
                let end = j + 1
                let rows = rowCounts[end] + 1
                let cost = imbalance[end] + (end - i) * (end - i)
                let cuts = splits[end] + (end < n && appIDs[j] == appIDs[end] ? 1 : 0)
                if rows < rowCounts[i] ||
                    (rows == rowCounts[i] && cost < imbalance[i]) ||
                    (rows == rowCounts[i] && cost == imbalance[i] && cuts <= splits[i]) {
                    rowCounts[i] = rows; imbalance[i] = cost; splits[i] = cuts; next[i] = end
                }
            }
        }
        var result: [Range<Int>] = []
        var index = 0
        while index < n {
            result.append(index..<next[index])
            index = next[index]
        }
        return result
    }

    /// Moves the selection one row up or down, landing on the card whose centre
    /// is nearest horizontally.
    ///
    /// Rows used to be uniform, so this was `selected ± columns`. With cards
    /// sized to their own windows and gaps that vary by app, rows hold different
    /// numbers of cards at different positions, and only the geometry answers
    /// "the one below this".
    func moveRow(_ delta: Int) {
        let laidOut = rows
        guard !laidOut.isEmpty, let current = selectedItem else { return }
        guard let r = laidOut.firstIndex(where: { $0.contains { $0.id == current.id } })
        else { return }
        let target = r + delta
        guard laidOut.indices.contains(target) else { return }

        // Rows are centred, so measure each card's centre from its row's centre.
        func centres(_ row: [MSGSwitcherWindow]) -> [CGFloat] {
            let total = rowWidth(row)
            var x = -total / 2
            var out: [CGFloat] = []
            for (i, item) in row.enumerated() {
                if i > 0 {
                    if item.category != row[i - 1].category && item.category != "Master" {
                        x += Self.categoryDividerWidth
                    } else {
                        x += item.pid == row[i - 1].pid ? Self.intraGroupGap : Self.interGroupGap
                    }
                }
                let w = cardWidth(item)
                out.append(x + w / 2)
                x += w
            }
            return out
        }

        let here = centres(laidOut[r])
        guard let col = laidOut[r].firstIndex(where: { $0.id == current.id }) else { return }
        let x = here[col]
        let there = centres(laidOut[target])
        guard let nearest = there.indices.min(by: { abs(there[$0] - x) < abs(there[$1] - x) })
        else { return }
        if let index = items.firstIndex(where: { $0.id == laidOut[target][nearest].id }) {
            selected = index
        }
    }

    /// Rendered width of one laid-out row.
    func rowWidth(_ row: [MSGSwitcherWindow]) -> CGFloat {
        guard !row.isEmpty else { return 0 }
        var w = cardWidth(row[0])
        for i in 1 ..< row.count {
            if row[i].category != row[i - 1].category && row[i].category != "Master" {
                w += Self.categoryDividerWidth
            } else {
                w += (row[i].pid == row[i - 1].pid ? Self.intraGroupGap : Self.interGroupGap)
            }
            w += cardWidth(row[i])
        }
        return w
    }

    /// Sizes of each app's run of windows, in the order given.
    static func groupSizes(of list: [MSGSwitcherWindow]) -> [Int] {
        var sizes: [Int] = []
        var lastPID: pid_t?
        for item in list {
            if item.pid == lastPID { sizes[sizes.count - 1] += 1 }
            else { sizes.append(1); lastPID = item.pid }
        }
        return sizes
    }

    // MARK: Display sections

    /// Displays in the order their sections appear: the one the panel is on
    /// first — it is the one the user is looking at — then the rest left to
    /// right, so the layout matches the physical arrangement.
    var displayOrder: [CGDirectDisplayID] {
        var ids = displays.sorted { $0.quartzFrame.minX < $1.quartzFrame.minX }.map(\.id)
        if let anchor = anchorDisplayID, let i = ids.firstIndex(of: anchor) {
            ids.remove(at: i)
            ids.insert(anchor, at: 0)
        }
        return ids
    }

    /// True only when there is genuinely more than one display to separate.
    var separatesDisplays: Bool { displayMode != .unified && displays.count > 1 }

    /// Reorders a list so each display's windows are contiguous, preserving the
    /// existing app grouping and recency order inside each display. Windows
    /// whose display could not be resolved go last rather than being dropped.
    static func orderedByDisplay(_ list: [MSGSwitcherWindow],
                                 order: [CGDirectDisplayID]) -> [MSGSwitcherWindow] {
        var buckets: [CGDirectDisplayID: [MSGSwitcherWindow]] = [:]
        var unplaced: [MSGSwitcherWindow] = []
        for item in list {
            if let id = item.displayID, order.contains(id) { buckets[id, default: []].append(item) }
            else { unplaced.append(item) }
        }
        return order.flatMap { id in
            Self.sortWindowsByCategoryAndPosition(buckets[id] ?? [])
        } + Self.sortWindowsByCategoryAndPosition(unplaced)
    }

    /// Reorders a list so each space's windows are contiguous, preserving category
    /// grouping and on-screen position within each space.
    static func orderedBySpace(_ list: [MSGSwitcherWindow],
                                order: [Int]) -> [MSGSwitcherWindow] {
        var buckets: [Int: [MSGSwitcherWindow]] = [:]
        var unplaced: [MSGSwitcherWindow] = []
        for item in list {
            let targetID = item.spaceID ?? order.first
            if let id = targetID, order.contains(id) {
                buckets[id, default: []].append(item)
            } else {
                unplaced.append(item)
            }
        }
        return order.flatMap { id in
            Self.sortWindowsByCategoryAndPosition(buckets[id] ?? [])
        } + Self.sortWindowsByCategoryAndPosition(unplaced)
    }

    static func categoryPriority(_ cat: String) -> Int {
        switch cat {
        case "Master": return 0
        case "Tab", "Tabbed": return 1
        case "Stacked": return 2
        case "Split": return 3
        case "Float", "Floating": return 4
        case "Hidden": return 5
        case "Other": return 6
        default: return 7
        }
    }

    static func sortWindowsByCategoryAndPosition(_ list: [MSGSwitcherWindow]) -> [MSGSwitcherWindow] {
        return list.sorted { a, b in
            let pa = categoryPriority(a.category)
            let pb = categoryPriority(b.category)
            if pa != pb {
                return pa < pb
            }
            if abs(a.window.bounds.minX - b.window.bounds.minX) > 15 {
                return a.window.bounds.minX < b.window.bounds.minX
            }
            return a.window.bounds.minY < b.window.bounds.minY
        }
    }

    func isCurrentSpace(_ item: MSGSwitcherWindow) -> Bool {
        if item.spaceID == activeSpaceID { return true }
        if let sid = item.spaceID, currentSpaceIDs.contains(sid), displayMode != .currentOnly { return true }
        if item.spaceID == nil && activeSpaceID > 0 { return true }
        return false
    }

    var hasMultipleCategories: Bool {
        Set(items.map(\.category)).count > 1
    }


    var singleRowDividerIndex: Int? {
        guard layoutMode == .singleRow, settings.appSwitcherGroupBySpace else { return nil }
        let currentCount = items.filter { isCurrentSpace($0) }.count
        guard currentCount > 0 && currentCount < items.count else { return nil }
        return currentCount
    }

    var singleRowWidth: CGFloat {
        guard let firstRow = rows.first, !firstRow.isEmpty else { return 308 }
        return rowWidth(firstRow)
    }

    private func buildSingleRowSections() -> [MSGSwitcherSection] {
        return [MSGSwitcherSection(
            id: "singleRow",
            title: nil,
            displaySubtitle: nil,
            isCurrent: true,
            isFullscreen: false,
            showDivider: false,
            count: items.count,
            rows: [items]
        )]
    }

    private func buildSpacePerRowSections() -> [MSGSwitcherSection] {
        var out: [MSGSwitcherSection] = []

        let activeSpaces = spaces.filter { $0.id == activeSpaceID || currentSpaceIDs.contains($0.id) || $0.isCurrent }
        let otherSpaces = spaces.filter { s in !activeSpaces.contains(where: { $0.id == s.id }) }
        var orderedSpaces = activeSpaces + otherSpaces

        if separatesDisplays && displayMode == .currentOnly, let anchor = anchorDisplayID {
            orderedSpaces = orderedSpaces.filter { $0.displayID == anchor }
        }

        var placedItemIDs = Set<String>()

        for space in orderedSpaces {
            let spaceItems = items.filter { $0.spaceID == space.id }
            guard !spaceItems.isEmpty else { continue }
            for it in spaceItems { placedItemIDs.insert(it.id) }
            let showDiv = !out.isEmpty
            out.append(MSGSwitcherSection(
                id: "space-\(space.id)",
                title: space.name,
                displaySubtitle: (separatesDisplays ? space.displayName : nil),
                isCurrent: space.id == activeSpaceID || currentSpaceIDs.contains(space.id) || space.isCurrent,
                isFullscreen: space.type == 4,
                showDivider: showDiv,
                count: spaceItems.count,
                rows: [spaceItems]
            ))
        }

        let unplaced = items.filter { !placedItemIDs.contains($0.id) }
        if !unplaced.isEmpty {
            let showDiv = !out.isEmpty
            out.append(MSGSwitcherSection(
                id: "space-other",
                title: "Other",
                displaySubtitle: nil,
                isCurrent: false,
                isFullscreen: false,
                showDivider: showDiv,
                count: unplaced.count,
                rows: [unplaced]
            ))
        }

        return out.isEmpty
            ? [MSGSwitcherSection(id: "all", title: nil, displaySubtitle: nil,
                                  isCurrent: false, isFullscreen: false,
                                  showDivider: false, count: items.count, rows: [items])]
            : out
    }

    /// The grid, split into the sections it renders as.
    var sections: [MSGSwitcherSection] {
        if layoutMode == .spacePerRow {
            return buildSpacePerRowSections()
        }
        if layoutMode == .singleRow {
            return buildSingleRowSections()
        }
        if settings.appSwitcherGroupBySpace {
            let currentItems = items.filter { isCurrentSpace($0) }
            let otherItems = items.filter { !isCurrentSpace($0) }

            if !currentItems.isEmpty && !otherItems.isEmpty {
                let currentSection = MSGSwitcherSection(
                    id: "current-space",
                    title: "Current",
                    displaySubtitle: nil,
                    isCurrent: true,
                    isFullscreen: false,
                    showDivider: false,
                    count: currentItems.count,
                    rows: pack(currentItems)
                )

                let otherSection = MSGSwitcherSection(
                    id: "other-spaces",
                    title: "Other",
                    displaySubtitle: nil,
                    isCurrent: false,
                    isFullscreen: false,
                    showDivider: true,
                    count: otherItems.count,
                    rows: pack(otherItems)
                )

                return [currentSection, otherSection]
            } else if currentItems.isEmpty && !otherItems.isEmpty {
                let otherSection = MSGSwitcherSection(
                    id: "other-spaces",
                    title: "Other",
                    displaySubtitle: nil,
                    isCurrent: false,
                    isFullscreen: false,
                    showDivider: false,
                    count: otherItems.count,
                    rows: pack(otherItems)
                )
                return [otherSection]
            } else if !currentItems.isEmpty && otherItems.isEmpty {
                let currentSection = MSGSwitcherSection(
                    id: "current-space",
                    title: nil,
                    displaySubtitle: nil,
                    isCurrent: true,
                    isFullscreen: false,
                    showDivider: false,
                    count: currentItems.count,
                    rows: pack(currentItems)
                )
                return [currentSection]
            }
        }

        guard separatesDisplays, displayMode == .grouped else {
            return [MSGSwitcherSection(id: "all", title: nil, displaySubtitle: nil,
                                          isCurrent: false, isFullscreen: false,
                                          showDivider: false, count: items.count, rows: pack(items))]
        }
        var out: [MSGSwitcherSection] = []
        for id in displayOrder {
            let group = items.filter { $0.displayID == id }
            guard !group.isEmpty else { continue }
            let showDiv = !out.isEmpty
            out.append(MSGSwitcherSection(id: "d-\(id)",
                                          title: displays.first { $0.id == id }?.name ?? "Display",
                                          displaySubtitle: nil,
                                          isCurrent: id == anchorDisplayID,
                                          isFullscreen: false,
                                          showDivider: showDiv,
                                          count: group.count, rows: pack(group)))
        }
        let known = Set(displayOrder)
        let unplaced = items.filter { $0.displayID.map { !known.contains($0) } ?? true }
        if !unplaced.isEmpty {
            let showDiv = !out.isEmpty
            out.append(MSGSwitcherSection(id: "other", title: "Other",
                                          displaySubtitle: nil,
                                          isCurrent: false,
                                          isFullscreen: false,
                                          showDivider: showDiv,
                                          count: unplaced.count, rows: pack(unplaced)))
        }
        return out.isEmpty
            ? [MSGSwitcherSection(id: "all", title: nil, displaySubtitle: nil,
                                  isCurrent: false, isFullscreen: false,
                                  showDivider: false, count: items.count, rows: pack(items))]
            : out
    }

    /// Width of a section: its widest row. The heading is framed to this so a
    /// long display name can never make the panel wider than its content.
    func sectionWidth(_ section: MSGSwitcherSection) -> CGFloat {
        max(1, section.rows.map(rowWidth).max() ?? 0)
    }

    /// Every row in the panel, top to bottom, sections flattened. Row-wise
    /// navigation reads this, so Down from the last row of one display lands in
    /// the first row of the next.
    var rows: [[MSGSwitcherWindow]] { sections.flatMap(\.rows) }

    /// Panel content width: the widest row actually produced.
    var gridWidth: CGFloat {
        guard !loading, !items.isEmpty else { return 308 }
        let maxW = rows.map(rowWidth).max() ?? 308
        if layoutMode == .spacePerRow {
            return min(contentWidth - Self.chromeWidth, max(1, maxW))
        }
        return max(1, maxW)
    }

    /// Height needed for the caption of a switcher item.
    /// Single-line (or reserved) is 16pt; 2-line wraps expand to 38pt so text is never clipped.
    func captionHeight(for item: MSGSwitcherWindow) -> CGFloat {
        guard let caption = dockPreviewCaption(for: item.window, appName: item.appName) else {
            return 14
        }
        let font = NSFont.systemFont(ofSize: 10)
        let width = cardWidth(item)
        let attr = NSAttributedString(string: caption, attributes: [.font: font])
        let rect = attr.boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return rect.height > 15 ? 28 : 14
    }

    /// Rendered height of one laid-out row, sized to the tallest card in that row.
    func rowHeight(_ row: [MSGSwitcherWindow]) -> CGFloat {
        guard !row.isEmpty else { return cellHeight }
        let maxCaption = row.map { captionHeight(for: $0) }.max() ?? 14
        return thumbHeight + 12 + 10 + maxCaption + Self.labelHeight + Self.labelGap
    }

    /// Height of one row: the card (thumbnail + 6pt frame, VStack gap, reserved
    /// caption line) plus the app label above it.
    private var cellHeight: CGFloat {
        // card (thumbnail + 6pt frame either side) + the card's own VStack gap
        // + its reserved caption line + the app label row and its gap.
        thumbHeight + 12 + 10 + 16 + Self.labelHeight + Self.labelGap
    }

    /// Viewport for up to three rows, including only the headings and dividers
    /// before those rows. The full grid remains available inside its ScrollView.
    var gridHeight: CGFloat {
        guard !loading, !items.isEmpty else { return cellHeight + Self.hoverSlack * 2 }
        var height = Self.hoverSlack * 2
        var remaining = 3
        for (i, section) in sections.enumerated() {
            guard remaining > 0 else { break }
            if i > 0 { height += Self.sectionGap }
            if section.showDivider { height += Self.dividerHeight + Self.labelGap }
            if section.title != nil { height += Self.sectionHeaderHeight + Self.labelGap }
            let visibleRows = section.rows.prefix(remaining)
            if visibleRows.isEmpty {
                height += cellHeight
                remaining -= 1
            } else {
                height += visibleRows.reduce(CGFloat(0)) { $0 + rowHeight($1) }
                height += CGFloat(visibleRows.count - 1) * Self.rowGap
                remaining -= visibleRows.count
            }
        }
        return height
    }

    var selectedItem: MSGSwitcherWindow? { items.indices.contains(selected) ? items[selected] : nil }
    var appGroups: [MSGSwitcherWindow] {
        var seen = Set<pid_t>()
        return items.filter { seen.insert($0.pid).inserted }
    }
    var selectedAppItems: [MSGSwitcherWindow] {
        guard let pid = selectedItem?.pid else { return [] }
        return items.filter { $0.pid == pid }
    }
    private(set) var spaces: [MSGSwitcherSpace] = []
    private var activeSpaceID: Int = 0
    private var currentSpaceIDs: Set<Int> = []
    private var displayCurrentSpaces: [CGDirectDisplayID: Int] = [:]

    var spaceOrder: [Int] {
        var ids = spaces.map(\.id)
        if activeSpaceID > 0, let i = ids.firstIndex(of: activeSpaceID) {
            ids.remove(at: i)
            ids.insert(activeSpaceID, at: 0)
        }
        return ids
    }

    private let settings: AppSettings
    private var eventTap: MSGSwitcherEventTap?
    private var clickMonitorGlobal: Any?
    private var clickMonitorLocal: Any?
    private var healthTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var recentPIDs: [pid_t] = []
    private var panel: NSPanel?
    private var searchPanel: NSPanel?
    private var searchPanelObservers: [NSObjectProtocol] = []
    private var dockPanel: NotchDockPanel?
    /// Screen rect the panel centres itself in; kept for re-layout.
    private var panelAnchor: CGRect?
    private var allItems: [MSGSwitcherWindow] = []
    private var pending: [MSGSwitcherInput] = []
    private var sessionID = 0
    private var generation = 0
    private var tapEpoch = 0
    private var running = false
    private var active = false
    private var captureTask: Task<Void, Never>?
    private var enumerationTask: Task<Void, Never>?

    init(settings: AppSettings) { self.settings = settings }
    func start() {
        guard !running else { return }
        running = true
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { recentPIDs = [pid] }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.recentPIDs.removeAll { $0 == app.processIdentifier }
            self.recentPIDs.insert(app.processIdentifier, at: 0)
        }
        checkTap()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkTap() }
        RunLoop.main.add(timer, forMode: .common); healthTimer = timer
    }
    func stop() {
        running = false; tapEpoch &+= 1
        healthTimer?.invalidate(); healthTimer = nil
        eventTap?.stop(); eventTap = nil
        MSGNativeHotkeys.apply(desired: [])
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        dismiss()
    }
    private func checkTap() {
        guard running else { return }
        guard AXIsProcessTrusted(), PresentationState.shared.canPresent else {
            eventTap?.stop(); eventTap = nil; MSGNativeHotkeys.apply(desired: []); dismiss(); return
        }
        guard eventTap?.isHealthy != true else {
            MSGNativeHotkeys.apply(desired: MSGNativeHotkeys.commandTabIDs())
            return
        }
        eventTap?.stop(); MSGNativeHotkeys.apply(desired: []); dismiss()
        tapEpoch &+= 1
        let lifetime = tapEpoch
        let tap = MSGSwitcherEventTap(didStart: { [weak self] in
            guard let self, self.running, self.tapEpoch == lifetime, self.eventTap?.isHealthy == true else { return }
            MSGNativeHotkeys.apply(desired: MSGNativeHotkeys.commandTabIDs())
        }) { [weak self] id, input in
            guard let self, self.running, self.tapEpoch == lifetime else { return }
            self.receive(id, input)
        }
        eventTap = tap; tap.start()
    }
    private func receive(_ id: Int, _ input: MSGSwitcherInput) {
        if case .begin(let reverse) = input { begin(id: id, reverse: reverse); return }
        guard active, id == sessionID else { return }
        if case .cancel = input { dismiss(); return }
        if loading {
            pending.append(input)
            // A quick Cmd-Tab release commits the pending selection without
            // ever presenting a panel after the modifier is released.
            if case .commit = input { panel?.orderOut(nil) }
            return
        }
        apply(input)
    }
    private func begin(id: Int, reverse: Bool) {
        dismiss(endInput: false)
        active = true; sessionID = id
        canHover = false
        suppressInitialHover = settings.appSwitcherStartAtCurrent && !reverse
        hasPresentedPanel = false
        beginUptime = ProcessInfo.processInfo.systemUptime
        initialMouseLocation = NSEvent.mouseLocation
        startClickMonitoring()
        let token = generation
        query = ""; searchActive = false; selected = 0; items = []; allItems = []; total = 0; pending = []
        spaces = []; activeSpaceID = 0; currentSpaceIDs = []; displayCurrentSpaces = [:]
        loading = true
        iconLayout = settings.appSwitcherLayout == "icons"
        layoutMode = MSGSwitcherLayout(settings.appSwitcherLayout)
        displayMode = MSGSwitcherDisplayMode(settings.appSwitcherDisplayMode)
        displays = MSGSwitcherDisplay.table()
        thumbHeight = settings.dockPreviewThumbHeight
        maxPerRow = settings.appSwitcherMaxPerRow
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
        anchorDisplayID = screen.flatMap(MSGSwitcherDisplay.displayID(for:))
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        contentWidth = min(1400, max(280, frame.width - 100))
        contentHeight = min(820, max(220, frame.height - 120))
        let myPID = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            if app.processIdentifier == myPID {
                return NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.frame.width > 200 }
            }
            return app.activationPolicy == .regular && !app.isTerminated
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recents = recentPIDs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active, self.generation == token,
                  NSEvent.modifierFlags.contains(.command) else { return }
            self.hasPresentedPanel = true
            self.show(frame: frame)
        }
        let displayTable = displays
        let targetAnchorDisplay = anchorDisplayID
        enumerationTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> (items: [MSGSwitcherWindow], spaces: [MSGSwitcherSpace], activeSpaceID: Int, currentSpaceIDs: Set<Int>, displayCurrentSpaces: [CGDirectDisplayID: Int]) in
                let cid = CGSMainConnectionID()
                let globalActive = CGSGetActiveSpace(cid)

                var displayCurrentSpaces: [CGDirectDisplayID: Int] = [:]
                var allCurrentSpaces = Set<Int>()
                if globalActive > 0 { allCurrentSpaces.insert(globalActive) }

                var spacesList: [MSGSwitcherSpace] = []
                var spaceOrderMap: [Int: Int] = [:]
                var desktopCounter = 1

                var uuidToDisplay: [String: MSGSwitcherDisplay] = [:]
                for d in displayTable {
                    if let u = d.uuid { uuidToDisplay[u] = d }
                }

                if let rawDisplays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] {
                    for d in rawDisplays {
                        let ident = d["Display Identifier"] as? String ?? ""
                        let matchedDisplay = uuidToDisplay[ident] ?? (ident == "Main" ? displayTable.first : nil)
                        let curSpaceDict = d["Current Space"] as? [String: Any]
                        let displayCurSpace = curSpaceDict?["ManagedSpaceID"] as? Int
                        if let displayCurSpace {
                            allCurrentSpaces.insert(displayCurSpace)
                            if let dID = matchedDisplay?.id {
                                displayCurrentSpaces[dID] = displayCurSpace
                            }
                        }

                        if let rawSpaces = d["Spaces"] as? [[String: Any]] {
                            for s in rawSpaces {
                                guard let sid = s["ManagedSpaceID"] as? Int else { continue }
                                let type = s["type"] as? Int ?? 0
                                let isCurrent = (sid == displayCurSpace) || (displayCurSpace == nil && sid == globalActive)
                                let name: String
                                if type == 4 {
                                    if let tileLayout = s["TileLayoutManager"] as? [String: Any],
                                       let tileSpaces = tileLayout["TileSpaces"] as? [[String: Any]],
                                       let firstTile = tileSpaces.first,
                                       let app = firstTile["appName"] as? String, !app.isEmpty {
                                        name = app
                                    } else if let pid = s["pid"] as? pid_t,
                                              let app = NSRunningApplication(processIdentifier: pid),
                                              let appName = app.localizedName, !appName.isEmpty {
                                        name = appName
                                    } else {
                                        name = "Fullscreen"
                                    }
                                } else {
                                    name = "Desktop \(desktopCounter)"
                                    desktopCounter += 1
                                }
                                let space = MSGSwitcherSpace(
                                    id: sid,
                                    displayID: matchedDisplay?.id,
                                    displayName: matchedDisplay?.name,
                                    type: type,
                                    name: name,
                                    isCurrent: isCurrent,
                                    order: spacesList.count
                                )
                                spaceOrderMap[sid] = spacesList.count
                                spacesList.append(space)
                            }
                        }
                    }
                }

                let anchorActiveSpace = targetAnchorDisplay.flatMap { displayCurrentSpaces[$0] }
                    ?? (displayTable.first.flatMap { displayCurrentSpaces[$0.id] } ?? globalActive)

                let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                let zOrder = raw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
                let orderedApps = apps.sorted { a, b in
                    func rank(_ app: NSRunningApplication) -> Int {
                        if app.processIdentifier == front { return -1 }
                        return recents.firstIndex(of: app.processIdentifier) ?? (recents.count + (raw.firstIndex { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier } ?? 10000))
                    }
                    return rank(a) < rank(b)
                }
                var result: [MSGSwitcherWindow] = []
                for app in orderedApps {
                    if Task.isCancelled { break }
                    let pid = app.processIdentifier
                    let windows = WindowPreviewCapture.switcherWindows(pid: pid)
                    for win in windows {
                        var winSpaceID: Int? = nil
                        var winSpaceName: String? = nil
                        var winDisplayID = MSGSwitcherDisplay.owner(of: win.bounds, in: displayTable)
                        let winCurSpace = winDisplayID.flatMap { displayCurrentSpaces[$0] } ?? anchorActiveSpace
                        if win.id != 0 {
                            let wSpaces = CGSCopySpacesForWindows(cid, 7, [win.id] as CFArray) as? [Int] ?? []
                            if wSpaces.contains(winCurSpace) {
                                winSpaceID = winCurSpace
                            } else if wSpaces.contains(anchorActiveSpace) {
                                winSpaceID = anchorActiveSpace
                            } else if let first = wSpaces.first(where: { spaceOrderMap[$0] != nil }) {
                                winSpaceID = first
                            } else if let first = wSpaces.first {
                                winSpaceID = first
                            }
                        }
                        if winSpaceID == nil, anchorActiveSpace > 0 {
                            winSpaceID = anchorActiveSpace
                        }
                        if let sid = winSpaceID, let match = spacesList.first(where: { $0.id == sid }) {
                            winSpaceName = match.name
                            if let spaceDisplay = match.displayID {
                                winDisplayID = spaceDisplay
                            }
                        }
                        result.append(MSGSwitcherWindow(
                            pid: pid,
                            appName: app.localizedName ?? "Application",
                            icon: app.icon,
                            displayID: winDisplayID,
                            spaceID: winSpaceID,
                            spaceName: winSpaceName,
                            window: win
                        ))
                    }
                }
                // Windows retain window-server front-to-back order within each
                // app. Recent app activation determines the inter-app ordering.
                let sortedResult = result.sorted { a, b in
                    if a.pid == b.pid { return (zOrder.firstIndex(of: a.window.id) ?? Int.max) < (zOrder.firstIndex(of: b.window.id) ?? Int.max) }
                    return (orderedApps.firstIndex { $0.processIdentifier == a.pid } ?? Int.max) < (orderedApps.firstIndex { $0.processIdentifier == b.pid } ?? Int.max)
                }
                return (items: sortedResult, spaces: spacesList, activeSpaceID: anchorActiveSpace, currentSpaceIDs: allCurrentSpaces, displayCurrentSpaces: displayCurrentSpaces)
            }
            let workResult = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, self.active, self.generation == token else { return }
            self.spaces = workResult.spaces
            self.activeSpaceID = workResult.activeSpaceID
            self.currentSpaceIDs = workResult.currentSpaceIDs
            self.displayCurrentSpaces = workResult.displayCurrentSpaces
            self.allItems = workResult.items; self.total = workResult.items.count; self.loading = false
            // Through `filter` rather than straight onto `items`, so display
            // and space scoping and ordering apply to the first list too, not only to
            // lists that have been searched or re-anchored.
            self.filter(relayout: false)
            self.layoutPanel()
            let startAtCurrent = self.settings.appSwitcherStartAtCurrent && !reverse
            self.suppressInitialHover = startAtCurrent
            let initialDelta = reverse ? -1 : (startAtCurrent ? 0 : 1)
            if self.iconLayout { self.moveApp(initialDelta) }
            else { self.selected = MSGSwitcherSearch.next(0, delta: initialDelta, count: self.items.count) }
            let buffered = self.pending; self.pending = []
            for input in buffered { guard self.active else { break }; self.apply(input) }
            guard self.active else { return }
            if self.panel?.isVisible == true {
                self.show(frame: frame)
            }
            self.loadPreviews(token: token)
        }
    }
    private func apply(_ input: MSGSwitcherInput) {
        switch input {
        case .commit: commit()
        case .cancel: dismiss()
        case .key(let code, let text, let shift, _):
            suppressInitialHover = false
            if canHover {
                canHover = false
                initialMouseLocation = NSEvent.mouseLocation
            }
            if !searchActive && (code == 3 || text.lowercased() == "f") {
                searchActive = true
                layoutPanel(animated: true)
                return
            }
            if searchActive && ![48, 50, 123, 124, 125, 126, 51, 117].contains(code) {
                let clean = MSGSwitcherSearch.sanitized(text)
                if !clean.isEmpty {
                    query += String(clean.prefix(max(0, 64 - query.count)))
                    filter()
                }
                return
            }
            switch code {
            case 48, 50:
                let delta = (code == 50 || shift) ? -1 : 1
                if iconLayout { moveApp(delta, wrapping: true) }
                else { selected = MSGSwitcherSearch.next(selected, delta: delta, count: items.count, wrapping: true) }
            case 123: moveWindow(-1)
            case 124: moveWindow(1)
            case 125: if iconLayout { moveWindow(1) } else { moveRow(1) }
            case 126: if iconLayout { moveWindow(-1) } else { moveRow(-1) }
            case 51, 117:
                if !query.isEmpty { query.removeLast(); filter() }
            case 13:
                closeSelected()
            case 12:
                quitSelected()
            case 4:
                hideSelected()
            default:
                if text.caseInsensitiveCompare("w") == .orderedSame {
                    closeSelected()
                } else if text.caseInsensitiveCompare("q") == .orderedSame {
                    quitSelected()
                } else if text.caseInsensitiveCompare("h") == .orderedSame {
                    hideSelected()
                }
            }
        default: break
        }
    }
    /// Rebuilds `items` from `allItems` for the current query, display mode,
    /// desktop spaces, and anchor display.
    ///
    /// `relayout: false` is for callers that are about to lay the panel out
    /// themselves — crossing to another display re-filters *and* moves, and
    /// wants one animated layout, not a snap followed by a slide.
    private func filter(relayout: Bool = true) {
        let preferred = selectedItem?.id
        var next = allItems.filter { MSGSwitcherSearch.matches(title: $0.window.title ?? "", app: $0.appName, query: query) }

        next = next.map { item -> MSGSwitcherWindow in
            var it = item
            if PreviewHiddenStyle.isHidden(pid: it.pid, windowID: it.window.id) {
                it.category = "Hidden"
            } else if self.isCurrentSpace(it) {
                let cat = TilingController.shared.tilingCategory(for: it.window.id, spaceID: it.spaceID)
                switch cat {
                case "Tabbed": it.category = "Tab"
                case "Floating": it.category = "Float"
                default: it.category = cat
                }
            } else {
                it.category = "Other"
            }
            return it
        }

        if separatesDisplays {
            switch displayMode {
            case .currentOnly:
                // Scoped against the unfiltered list, not the search results: a
                // display with windows on it stays scoped even when the query
                // matches none of them, so the "no matching windows" state is
                // still reachable. A display with no windows at all falls back
                // to showing everything — an empty switcher can't switch.
                if let anchor = anchorDisplayID, allItems.contains(where: { $0.displayID == anchor }) {
                    next = next.filter { $0.displayID == anchor }
                }
            case .grouped:
                if !settings.appSwitcherGroupBySpace {
                    next = Self.orderedByDisplay(next, order: displayOrder)
                }
            case .unified:
                break
            }
        }

        if settings.appSwitcherGroupBySpace || layoutMode == .spacePerRow || layoutMode == .singleRow {
            next = Self.orderedBySpace(next, order: spaceOrder)
        } else {
            next = Self.sortWindowsByCategoryAndPosition(next)
        }

        items = next
        selected = preferred.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        // Captured thumbnails can change card widths and row wrapping without
        // changing the item count. Resize for the new geometry as well, or the
        // grid can extend beyond a panel sized for the placeholder images.
        if relayout { layoutPanel(animated: true) }
    }
    private func moveApp(_ delta: Int, wrapping: Bool = true) {
        let groups = appGroups
        let current = groups.firstIndex { $0.pid == selectedItem?.pid } ?? 0
        let next = MSGSwitcherSearch.next(current, delta: delta, count: groups.count, wrapping: wrapping)
        if groups.indices.contains(next), let i = items.firstIndex(where: { $0.pid == groups[next].pid }) { selected = i }
    }
    private func moveWindow(_ delta: Int) {
        if iconLayout {
            let windows = selectedAppItems
            let current = windows.firstIndex { $0.id == selectedItem?.id } ?? 0
            let next = MSGSwitcherSearch.next(current, delta: delta, count: windows.count)
            if windows.indices.contains(next), let i = items.firstIndex(where: { $0.id == windows[next].id }) { selected = i }
        } else { selected = MSGSwitcherSearch.next(selected, delta: delta, count: items.count) }
    }
    func select(_ item: MSGSwitcherWindow, commitNow: Bool = false) {
        suppressInitialHover = false
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        selected = i
        if commitNow { commit() }
    }
    func close(_ item: MSGSwitcherWindow, quitLastPreview: Bool = false) {
        guard item.window.id != 0, items.contains(where: { $0.id == item.id }) else { return }
        if quitLastPreview && items.filter({ $0.pid == item.pid }).count == 1 {
            quitApp(pid: item.pid)
            return
        }
        let oldIndex = items.firstIndex(where: { $0.id == item.id }) ?? selected
        allItems.removeAll { $0.id == item.id }
        total = allItems.count
        if allItems.isEmpty {
            dismiss()
        } else {
            filter(relayout: true)
            if !items.isEmpty {
                selected = min(oldIndex, items.count - 1)
            } else {
                dismiss()
            }
        }
        Task {
            await WindowPreviewCapture.closeWindow(pid: item.pid, windowID: item.window.id)
        }
    }
    func minimize(_ item: MSGSwitcherWindow) {
        dismiss()
        Task { await WindowPreviewCapture.minimizeWindow(pid: item.pid, windowID: item.window.id) }
    }
    func toggleFullscreen(_ item: MSGSwitcherWindow) {
        dismiss()
        Task {
            await WindowPreviewCapture.toggleFullscreen(pid: item.pid, windowID: item.window.id, bounds: item.window.bounds)
        }
    }
    private func closeSelected() {
        guard let target = selectedItem else { return }
        close(target)
    }
    private func quitSelected() {
        guard let target = selectedItem else { return }
        quitApp(pid: target.pid)
    }
    private func quitApp(pid: pid_t) {
        let oldIndex = selected
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        }
        allItems.removeAll { $0.pid == pid }
        total = allItems.count
        if allItems.isEmpty {
            dismiss()
        } else {
            filter(relayout: true)
            if !items.isEmpty {
                selected = min(oldIndex, items.count - 1)
            } else {
                dismiss()
            }
        }
    }
    private func hideSelected() {
        guard let target = selectedItem else { return }
        if let app = NSRunningApplication(processIdentifier: target.pid) {
            app.hide()
        }
        if iconLayout {
            moveApp(1, wrapping: true)
        } else {
            selected = MSGSwitcherSearch.next(selected, delta: 1, count: items.count, wrapping: true)
        }
    }
    private func commit() {
        var targetIndex = selected
        if settings.appSwitcherStartAtCurrent && suppressInitialHover {
            let elapsed = ProcessInfo.processInfo.systemUptime - beginUptime
            let isQuickSwitch = !hasPresentedPanel || (elapsed < 0.22)
            if isQuickSwitch {
                if iconLayout {
                    let groups = appGroups
                    let next = MSGSwitcherSearch.next(0, delta: 1, count: groups.count)
                    if groups.indices.contains(next), let i = items.firstIndex(where: { $0.pid == groups[next].pid }) {
                        targetIndex = i
                    }
                } else {
                    targetIndex = MSGSwitcherSearch.next(0, delta: 1, count: items.count)
                }
            }
        }
        let target = items.indices.contains(targetIndex) ? items[targetIndex] : selectedItem
        dismiss()
        guard let target else { return }
        Task {
            await WindowPreviewCapture.raiseWindow(pid: target.pid, windowID: target.window.id, fallbackBounds: target.window.bounds)
        }
    }
    private func dismiss(endInput: Bool = true) {
        if let clickMonitorGlobal { NSEvent.removeMonitor(clickMonitorGlobal) }
        if let clickMonitorLocal { NSEvent.removeMonitor(clickMonitorLocal) }
        clickMonitorGlobal = nil; clickMonitorLocal = nil
        if endInput { eventTap?.endSession(sessionID) }
        active = false; generation &+= 1; pending = []; loading = false
        suppressInitialHover = false
        hasPresentedPanel = false
        enumerationTask?.cancel(); enumerationTask = nil
        captureTask?.cancel(); captureTask = nil
        stopPointerFollow()
        finishDisplayMove()
        thumbnailsPending = false
        searchPanel?.orderOut(nil)
        dockPanel?.dismiss()
        panel?.orderOut(nil)
    }
    private func startClickMonitoring() {
        let handleClick: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.active else { return }
            let mouseLoc = NSEvent.mouseLocation
            let inPanel = self.panel?.frame.contains(mouseLoc) == true
            let inSearch = self.searchPanel?.frame.contains(mouseLoc) == true
            let inDock = (self.dockPanel?.isVisible == true) && (self.dockPanel?.frame.contains(mouseLoc) == true)
            if self.panel?.isVisible != true || (!inPanel && !inSearch && !inDock) {
                self.dismiss()
            }
        }
        // Global monitors observe delivered events; they cannot swallow clicks.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        clickMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handleClick)
        clickMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handleClick(event)
            return event
        }
    }
    private func show(frame: CGRect) {
        guard active else { return }
        hasPresentedPanel = true
        canHover = false
        initialMouseLocation = NSEvent.mouseLocation
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .popUpMenu; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel = p
        }
        let host = NSHostingController(rootView: MSGSwitcherView(model: self))
        // The panel's size is decided here, from the screen, not by the view.
        // Left at its default the hosting controller pushes its content's
        // fitting size back onto the window, and the content no longer has an
        // intrinsic width to give: the title row and the shortcut legend that
        // used to hold the panel open were removed, leaving a ScrollView, which
        // has no natural width. The window collapsed to about 116pt.
        host.sizingOptions = []
        panel?.contentViewController = host
        panelAnchor = frame
        anchorScreen = NSScreen.screens.first { $0.visibleFrame == frame }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        anchorDisplayID = anchorScreen.flatMap(MSGSwitcherDisplay.displayID(for:)) ?? anchorDisplayID
        layoutPanel()
        panel?.orderFrontRegardless()
        updateSearchPanel()
        updateDockPanel()
        startPointerFollow()
    }

    private func updateSearchPanel() {
        guard active, searchActive, let panel, panel.isVisible else {
            searchPanel?.orderOut(nil)
            return
        }
        if searchPanel == nil {
            let child = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            child.isOpaque = false
            child.backgroundColor = .clear
            child.hasShadow = true
            child.hidesOnDeactivate = false
            child.level = .popUpMenu
            child.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let host = NSHostingController(rootView: MSGSwitcherSearchPanel(model: self))
            host.sizingOptions = []
            child.contentViewController = host
            searchPanel = child
            panel.addChildWindow(child, ordered: .above)
            searchPanelObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                    self?.updateSearchPanel()
                }
            }
        }
        let width = min(340, max(240, panel.frame.width)) - 10
        searchPanel?.setFrame(CGRect(x: panel.frame.midX - width / 2,
                                     y: panel.frame.minY - 50, width: width, height: 40), display: true)
        if searchPanel?.isVisible != true {
            // A fresh view restarts the reveal for each search session.
            let host = NSHostingController(rootView: MSGSwitcherSearchPanel(model: self))
            host.sizingOptions = []
            searchPanel?.contentViewController = host
            searchPanel?.orderFrontRegardless()
        }
    }

    private func updateDockPanel() {
        guard active, let panel, panel.isVisible, settings.appSwitcherShowDock else {
            dockPanel?.orderOut()
            return
        }
        let dockItems = NotchDockReader.fetchDockItems()
        guard !dockItems.isEmpty, let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            dockPanel?.orderOut()
            return
        }
        if dockPanel == nil {
            dockPanel = NotchDockPanel()
        }
        let notchRect = NotchGeometry.notchRect(for: screen)
        if dockPanel?.isVisible == true {
            dockPanel?.updatePosition(screen: screen, notchRect: notchRect, previewFrame: panel.frame)
        } else {
            dockPanel?.present(
                items: dockItems,
                screen: screen,
                notchRect: notchRect,
                previewFrame: panel.frame,
                onSelect: { [weak self] item in
                    self?.selectDockItem(item)
                }
            )
        }
    }

    private func selectDockItem(_ item: NotchDockItem) {
        dismiss()
        NotchDockReader.launchDockItem(item)
    }

    /// Re-centres and re-sizes the panel for the current content.
    ///
    /// Called after enumeration, search, and thumbnail updates: image aspect
    /// ratios can change row packing even when the item count stays the same.
    private func layoutPanel(animated: Bool = false) {
        guard let panel, let frame = panelAnchor else { return }
        defer {
            updateSearchPanel()
            updateDockPanel()
        }
        guard moveTimer == nil else { thumbnailsPending = true; return }
        if layoutMode == .singleRow {
            thumbHeight = settings.dockPreviewThumbHeight
        } else {
            fitGridRows(in: frame)
        }
        let target = panelTarget(in: frame)
        guard animated, panel.isVisible, panel.frame != target else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak panel] in panel?.invalidateShadow() })
    }

    /// Fit complete rows instead of clipping them at the old fixed-height cap.
    /// Caption and section chrome remain full size; only thumbnails may shrink.
    private func fitGridRows(in frame: CGRect) {
        guard !iconLayout, !loading, !items.isEmpty else { return }
        let previous = thumbHeight
        let available = max(160, frame.height - (searchActive ? 120 : 40))
        thumbHeight = settings.dockPreviewThumbHeight
        while gridHeight + 20 > available && thumbHeight > 40 {
            thumbHeight = max(40, thumbHeight - 2)
        }
        if previous != thumbHeight { objectWillChange.send() }
    }

    private func panelTarget(in frame: CGRect) -> CGRect {
        let width: CGFloat
        let mainHeight: CGFloat
        if loading || items.isEmpty {
            width = 340
            mainHeight = 160
        } else if layoutMode == .singleRow {
            let rowH = rows.first.map(rowHeight) ?? (thumbHeight + 80)
            width = min(contentWidth + 28, max(320, singleRowWidth + Self.chromeWidth))
            mainHeight = rowH + Self.hoverSlack * 2 + 20
        } else {
            width = iconLayout ? contentWidth + 28
                               : min(contentWidth + 28, gridWidth + Self.chromeWidth)
            mainHeight = iconLayout ? min(contentHeight, thumbHeight + 350)
                                    : min(max(160, frame.height - (searchActive ? 120 : 40)), gridHeight + 20)
        }
        let height = mainHeight
        let topY = frame.midY + mainHeight / 2
        return NSRect(x: frame.midX - width / 2, y: topY - height,
                      width: width, height: height)
    }

    private var movingHost: NSViewController?

    private func finishDisplayMove() {
        moveTimer?.invalidate()
        moveTimer = nil
        moveGeneration &+= 1
        if let host = movingHost, let panel {
            host.view.removeFromSuperview()
            host.view.isHidden = false
            panel.contentViewController = host
            host.view.frame = NSRect(origin: .zero, size: panel.frame.size)
        }
        movingHost = nil
    }

    /// Start travelling without synchronous bitmap rendering. The live grid is
    /// laid out once at the border; Core Animation handles its fade and scaling.
    private func movePanel(to screen: NSScreen) {
        finishDisplayMove()
        guard let panel, let host = panel.contentViewController else { return }
        let from = panel.frame
        let visible = screen.visibleFrame
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: visible.midX, y: visible.midY)
        let canvas = NSView(frame: NSRect(origin: .zero, size: from.size))
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        let content = NSView(frame: canvas.bounds)
        content.wantsLayer = true
        content.autoresizingMask = []
        movingHost = host
        panel.contentViewController = nil
        panel.contentView = canvas
        canvas.addSubview(content)
        host.view.frame = content.bounds
        host.view.autoresizingMask = [.width, .height]
        content.addSubview(host.view)
        content.layer?.anchorPoint = .zero
        content.layer?.position = .zero
        let token = moveGeneration
        let began = CACurrentMediaTime()
        var crossedAt: CFTimeInterval?
        var destination = from
        let timer = MSGSwitcherDisplayAnimation(view: canvas) { [weak self, weak panel] timer in
            guard let self, let panel, self.active, panel.isVisible,
                  self.moveGeneration == token else { timer.invalidate(); return }
            let now = CACurrentMediaTime()
            let raw = min(1, (now - began) / Self.moveDuration)
            let progress = Self.travelProgress(CGFloat(raw))
            let centre = CGPoint(x: start.x + (end.x - start.x) * progress,
                                 y: start.y + (end.y - start.y) * progress)
            if crossedAt == nil && Self.hasCrossedDisplay(centre, destination: screen.frame) {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.12
                content.layer?.add(fade, forKey: "displayPreviewFade")
                self.contentWidth = min(1400, max(280, visible.width - 100))
                self.contentHeight = min(820, max(220, visible.height - 120))
                self.panelAnchor = visible
                self.anchorDisplayID = MSGSwitcherDisplay.displayID(for: screen)
                if let id = self.anchorDisplayID, let space = self.displayCurrentSpaces[id] {
                    self.activeSpaceID = space
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.filter(relayout: false) }
                self.fitGridRows(in: visible)
                destination = self.panelTarget(in: visible)
                content.frame = CGRect(origin: .zero, size: destination.size)
                crossedAt = now
            }
            let morph = crossedAt.map { Self.travelCurve(CGFloat(max(0, now - $0) / 0.12)) } ?? 0
            let size = CGSize(width: from.width + (destination.width - from.width) * morph,
                              height: from.height + (destination.height - from.height) * morph)
            let searchOffset = crossedAt == nil ? 0 : (destination.midY - visible.midY) * morph
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if crossedAt != nil {
                content.layer?.setAffineTransform(CGAffineTransform(scaleX: size.width / destination.width,
                                                                   y: size.height / destination.height))
            }
            panel.setFrame(CGRect(x: centre.x - size.width / 2,
                                  y: centre.y + searchOffset - size.height / 2,
                                  width: size.width, height: size.height), display: false)
            CATransaction.commit()
            if raw >= 1 && morph >= 1 {
                panel.setFrame(destination, display: true)
                self.finishDisplayMove()
                let refresh = self.thumbnailsPending
                self.thumbnailsPending = false
                if refresh { self.filter() }
                panel.invalidateShadow()
            }
        }
        moveTimer = timer
    }

    static let moveDuration: CFTimeInterval = 0.3

    /// Capture the current selection first, then visible apps, then apps on
    /// every other display. Display filtering must never remove capture work.
    static func previewCaptureOrder(selected: pid_t?, visible: [pid_t], all: [pid_t]) -> [pid_t] {
        var seen = Set<pid_t>()
        return ((selected.map { [$0] } ?? []) + visible + all).filter { seen.insert($0).inserted }
    }

    /// Immediate velocity on departure, smoothly slowing at the destination.
    static func travelProgress(_ t: CGFloat) -> CGFloat {
        let p = max(0, min(1, t))
        return 1 - pow(1 - p, 3)
    }

    static func hasCrossedDisplay(_ centre: CGPoint, destination: CGRect) -> Bool {
        destination.contains(centre)
    }

    /// Monotonic ease with no overshoot or discontinuity at the display border.
    static func travelCurve(_ t: CGFloat) -> CGFloat {
        let p = max(0, min(1, t))
        return p * p * (3 - 2 * p)
    }

    private var moveTimer: MSGSwitcherDisplayAnimation?
    /// A thumbnail batch arrived while the panel was travelling between
    /// displays; publish it once the move is over.
    private var thumbnailsPending = false

    private var moveGeneration = 0

    // MARK: Following the pointer across displays

    /// Screen the panel is currently centred on.
    private var anchorScreen: NSScreen?
    private var pointerMonitor: Any?
    private var pointerMonitorLocal: Any?

    /// The panel opens on whichever display holds the pointer, but that was a
    /// one-time decision — move the pointer to the other display while still
    /// holding Command and the switcher stayed behind on the first one. It now
    /// follows, reusing the pointer position MSG already tracks.
    private func startPointerFollow() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.pointerMoved()
        }
        // A global monitor never sees this app's own events, and the panel is a
        // large target sitting under the pointer's path — crossing it would
        // otherwise go unnoticed until the pointer left it again.
        pointerMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.pointerMoved()
            return e
        }
    }

    private func stopPointerFollow() {
        if let m = pointerMonitor { NSEvent.removeMonitor(m); pointerMonitor = nil }
        if let m = pointerMonitorLocal { NSEvent.removeMonitor(m); pointerMonitorLocal = nil }
        anchorScreen = nil
        canHover = false
        initialMouseLocation = nil
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if Thread.isMainThread {
            handlePointerMoved(at: point)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.handlePointerMoved(at: point)
            }
        }
    }

    private func handlePointerMoved(at point: NSPoint) {
        guard active, let panel, panel.isVisible else { return }

        // Ignore pointer hover / selection until pointer actually moves by at least 4pt
        if !canHover {
            if let initial = initialMouseLocation {
                let dx = point.x - initial.x
                let dy = point.y - initial.y
                if (dx * dx + dy * dy) >= 16 {
                    canHover = true
                    suppressInitialHover = false
                }
            } else {
                initialMouseLocation = point
            }
        }

        guard NSScreen.screens.count > 1 else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              screen !== anchorScreen
        else { return }

        let firstPlacement = anchorScreen == nil
        anchorScreen = screen

        // A trackpad detent at the boundary, the same feedback macOS gives for
        // window snapping. Skipped on the initial placement, which is not a
        // crossing, and silently absent on hardware without a haptic engine.
        if !firstPlacement {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        movePanel(to: screen)
    }
    private func loadPreviews(token: Int) {
        // Selected app first. Each update changes images only; the search result
        // ordering and selection never jump when a slow capture finishes.
        let pids = Self.previewCaptureOrder(selected: selectedItem?.pid,
                                            visible: appGroups.map(\.pid),
                                            all: allItems.map(\.pid))
        captureTask = Task { @MainActor [weak self] in
            for pid in pids {
                guard !Task.isCancelled else { return }
                let windows = await WindowPreviewCapture.capture(pid: pid, maxWindows: 100)
                guard let self, self.active, self.generation == token else { return }
                let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for i in self.allItems.indices where self.allItems[i].pid == pid {
                    if let image = byID[self.allItems[i].window.id] { self.allItems[i].window = image }
                }
                // Publishing a batch of thumbnails re-renders the whole grid on
                // the main thread, and captures land continuously for the first
                // second or so. Landing one in the middle of a display move
                // stalled the animation for ~105ms, after which the time-based
                // curve jumped over 500pt in a single frame to catch up. The
                // move is a third of a second; the images can wait for it.
                if self.moveTimer != nil {
                    self.thumbnailsPending = true
                } else {
                    self.filter()
                }
            }
        }
    }
}

@available(macOS 14.0, *)
private struct MSGSwitcherSearchPanel: View {
    @ObservedObject var model: MSGWindowSwitcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold))
            Text(model.query.isEmpty ? "Type to search…" : model.query)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
            Text("\(model.items.count)/\(model.total)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            }
        }
        .scaleEffect(x: revealed || reduceMotion ? 1 : 0.72,
                     y: revealed || reduceMotion ? 1 : 0.12, anchor: .top)
        .opacity(revealed ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12)
                          : .spring(response: 0.32, dampingFraction: 0.82)) {
                revealed = true
            }
        }
    }
}

@available(macOS 14.0, *)
private struct MSGSwitcherView: View {
    @ObservedObject var model: MSGWindowSwitcher
    @State private var appeared = false
    /// A short taper is enough to signal that more switcher rows are available
    /// without visibly dimming the first or last preview.
    private let overflowFadeHeight: CGFloat = 18

    /// Ids of the first window of each app's run.
    ///
    /// `model.items` already sorts every app's windows adjacently, so grouping
    /// needs no restructuring of the list — only a label on the card that opens
    /// each run. An earlier version gave every app its own section with its own
    /// grid, which read as grouped but cost a full row per app: an app with one
    /// window took a whole row of a three-column grid, so the panel showed one
    /// or two windows per row instead of filling it.
    private var runStarts: Set<String> {
        var starts = Set<String>()
        for section in model.sections {
            var lastPID: pid_t?
            for row in section.rows {
                for item in row {
                    if item.pid != lastPID {
                        starts.insert(item.id)
                        lastPID = item.pid
                    }
                }
            }
        }
        return starts
    }

    var body: some View {
        // The chrome is gone: no title bar naming the mode, no shortcut legend
        // along the bottom. Both were fixed furniture that said the same thing
        // on every invocation, and the switcher is on screen for a second at a
        // time. What replaces them appears only when it has something to say —
        // the search field below, once the user actually types.
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Self.scroll, value: model.items.map(\.id))

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .scaleEffect(appeared ? 1.0 : 0.94)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.76)) {
                appeared = true
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.searchActive)
    }

    @ViewBuilder private var content: some View {
        if model.loading {
            centred { ProgressView("Loading windows…") }
        } else if model.items.isEmpty {
            centred {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "No windows" : "No matching windows")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        } else if model.iconLayout {
            VStack(spacing: 12) { icons; thumbnails }
        } else if model.layoutMode == .singleRow {
            singleRowView
        } else {
            grid
        }
    }

    private func centred<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 8) { Spacer(); c(); Spacer() }
    }

    private var singleRowView: some View {
        let displayItems = model.rows.first ?? model.items
        let naturalW = model.singleRowWidth
        let availableW = model.contentWidth - MSGWindowSwitcher.chromeWidth
        let rowH = model.rowHeight(displayItems)
        let needsScroll = naturalW > availableW
        return ScrollViewReader { proxy in
            Group {
                if needsScroll {
                    ScrollView(.horizontal, showsIndicators: false) {
                        rowCards(row: displayItems, maxRowH: rowH)
                            .padding(.horizontal, MSGWindowSwitcher.hoverSlack)
                            .padding(.vertical, MSGWindowSwitcher.hoverSlack)
                    }
                    .frame(width: availableW, height: rowH + MSGWindowSwitcher.hoverSlack * 2)
                } else {
                    rowCards(row: displayItems, maxRowH: rowH)
                        .padding(.horizontal, MSGWindowSwitcher.hoverSlack)
                        .padding(.vertical, MSGWindowSwitcher.hoverSlack)
                }
            }
            .onChange(of: model.selectedItem?.id) { _, id in
                guard let id else { return }
                withAnimation(Self.scroll) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func rowCards(row: [MSGSwitcherWindow], maxRowH: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.element.id) { index, item in
                if index > 0 && item.category != row[index - 1].category && item.category != "Master" {
                    categoryDivider(title: item.category)
                }
                if index > 0 && (item.category == row[index - 1].category || item.category == "Master") {
                    Spacer()
                        .frame(width: item.pid == row[index - 1].pid
                               ? MSGWindowSwitcher.intraGroupGap
                               : MSGWindowSwitcher.interGroupGap)
                }
                let isSelected = !model.suppressInitialHover && (model.selectedItem?.id == item.id)
                cell(item, rowHeight: maxRowH)
                    .zIndex(isSelected ? 10 : 0)
            }
        }
    }

    @ViewBuilder private func categoryDivider(title: String) -> some View {
        let displayTitle = (title == "Tabbed") ? "Tab" : ((title == "Floating") ? "Float" : title)
        VStack(spacing: 8) {
            Text(displayTitle)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .frame(height: 20)

            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: model.thumbHeight + 12)
        }
        .padding(.horizontal, 8)
        .transition(.opacity)
    }

    private var icons: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.appGroups) { item in
                        Button { model.select(item) } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: item.icon ?? item.window.image).resizable().scaledToFit().frame(width: 48, height: 48)
                                Text(item.appName).font(.system(size: 11)).lineLimit(1)
                            }
                            .frame(width: 80).padding(8)
                            .background(RoundedRectangle(cornerRadius: 16).fill((!model.suppressInitialHover && model.selectedItem?.pid == item.pid) ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.045)))
                        }.buttonStyle(.plain).id(item.pid)
                    }
                }
            }
            .onAppear { if let pid = model.selectedItem?.pid { proxy.scrollTo(pid, anchor: .center) } }
            .onChange(of: model.selectedItem?.pid) { _, pid in
                guard let pid else { return }
                withAnimation(Self.scroll) { proxy.scrollTo(pid, anchor: .center) }
            }
        }
        .frame(height: 92)
    }

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(model.selectedAppItems) { item in
                        let isSelected = !model.suppressInitialHover && (model.selectedItem?.id == item.id)
                        card(item)
                            .id(item.id)
                            .zIndex(isSelected ? 10 : 0)
                    }
                }
                .padding(MSGWindowSwitcher.hoverSlack)
                .animation(Self.scroll, value: model.selectedAppItems.map(\.id))
            }
            .onAppear { if let id = model.selectedItem?.id { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: model.selectedItem?.id) { _, id in
                guard let id else { return }
                withAnimation(Self.scroll) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Tab steps through windows in order, so crossing a row boundary is the one
    /// moment the view has to move under the user. Animating it is what makes
    /// that read as the grid scrolling rather than the selection teleporting.
    private static let scroll = Animation.easeInOut(duration: 0.24)

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Fixed, not flexible: cards vary in width with their window's
                // aspect ratio, and flexible columns let that variation move the
                // column edges, so nothing lined up down the grid.
                VStack(alignment: .center, spacing: MSGWindowSwitcher.sectionGap) {
                    ForEach(model.sections) { section in
                        VStack(alignment: .center, spacing: MSGWindowSwitcher.labelGap) {
                            if section.showDivider {
                                sectionDivider(width: model.gridWidth)
                            }
                            if section.title != nil {
                                sectionHeader(for: section, width: model.gridWidth)
                            }
                            VStack(alignment: .center, spacing: MSGWindowSwitcher.rowGap) {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    let naturalW = model.rowWidth(row)
                                    let availableW = model.contentWidth - MSGWindowSwitcher.chromeWidth
                                    let hasSelected = row.contains(where: { $0.id == model.selectedItem?.id })
                                    if model.layoutMode == .spacePerRow && naturalW > availableW {
                                        ScrollViewReader { rowProxy in
                                            ScrollView(.horizontal, showsIndicators: false) {
                                                rowCards(row: row, maxRowH: model.rowHeight(row))
                                                    .padding(.horizontal, MSGWindowSwitcher.hoverSlack)
                                                    .padding(.vertical, MSGWindowSwitcher.hoverSlack)
                                            }
                                            .frame(width: availableW, height: model.rowHeight(row) + MSGWindowSwitcher.hoverSlack * 2)
                                            .onChange(of: model.selectedItem?.id) { _, id in
                                                guard let id, row.contains(where: { $0.id == id }) else { return }
                                                withAnimation(Self.scroll) { rowProxy.scrollTo(id, anchor: .center) }
                                            }
                                        }
                                        .zIndex(hasSelected ? 10 : 0)
                                    } else {
                                        rowCards(row: row, maxRowH: model.rowHeight(row))
                                            .zIndex(hasSelected ? 10 : 0)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                // Horizontal slack for the same reason as the vertical: a card
                // at the end of a row grows sideways when hovered.
                .padding(.horizontal, MSGWindowSwitcher.hoverSlack)
                // The first row carries app labels too; without this they sit
                // against the panel's top edge and get clipped.
                .padding(.top, MSGWindowSwitcher.hoverSlack)
                .padding(.bottom, MSGWindowSwitcher.hoverSlack)
                .animation(Self.scroll, value: model.items.map(\.id))
            }
            .mask {
                if model.rows.count > 3 {
                    verticalOverflowMask
                } else {
                    Rectangle().fill(.black)
                }
            }
            // No scroll on appear: the grid already starts at the top, and the
            // opening selection is in the first row. Scrolling here ran before
            // layout had settled and left the first row's app labels clipped
            // under the panel's top edge.
            //
            // No anchor on change either — move only far enough to bring the
            // selection into view, which is exactly "scroll when Tab crosses
            // into the next row" and nothing when it doesn't.
            .onChange(of: model.selectedItem?.id) { _, id in
                guard let id else { return }
                withAnimation(Self.scroll) { proxy.scrollTo(id) }
            }
        }
    }

    /// Match the notch preview's soft overflow treatment on the vertical
    /// switcher. The mask affects only scrolling cards; the material panel and
    /// its rounded border remain fully opaque.
    private var verticalOverflowMask: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: overflowFadeHeight)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: overflowFadeHeight)
        }
    }

    /// Visual divider line rendered between sections.
    private func sectionDivider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: width, height: 1)
            .frame(height: MSGWindowSwitcher.dividerHeight)
    }

    /// Section heading in space-grouped or display-grouped mode.
    private func sectionHeader(for section: MSGSwitcherSection, width: CGFloat) -> some View {
        guard section.title != nil else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 6) {
                if section.id == "current-space" {
                    Text("Current")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                } else if section.id == "other-spaces" {
                    Text("Other")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.09)))
                } else if section.id.hasPrefix("space-") {
                    Image(systemName: section.isFullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow")
                        .font(.system(size: 10, weight: .semibold))
                    Text(section.title ?? "Desktop")
                        .font(.system(size: 11.5, weight: .semibold))
                    if section.isCurrent {
                        Text("Current")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                    }
                    if let subtitle = section.displaySubtitle {
                        Text("•  \(subtitle)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    Text("\(section.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else if let title = section.title {
                    Image(systemName: "display")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("\(section.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .frame(width: width, height: MSGWindowSwitcher.sectionHeaderHeight, alignment: .leading)
        )
    }

    @ViewBuilder private func cell(_ item: MSGSwitcherWindow, rowHeight: CGFloat) -> some View {
        let isAppActive = !model.suppressInitialHover && (model.selectedItem?.pid == item.pid)
        VStack(alignment: .leading, spacing: MSGWindowSwitcher.labelGap) {
            // Flush with the card below it, which is now exactly as wide as its
            // own thumbnail — so the app name sits over the left corner of the
            // first window of its run, not over a grid cell that was wider.
            HStack(spacing: 6) {
                if runStarts.contains(item.id) {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                            .scaleEffect(isAppActive ? 1.08 : 1.0)
                            .shadow(color: .black.opacity(isAppActive ? 0.35 : 0.0), radius: isAppActive ? 3 : 0, y: isAppActive ? 1 : 0)
                    }
                    Text(item.appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isAppActive ? .primary : .secondary)
                        .opacity(isAppActive ? 1.0 : 0.72)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: MSGWindowSwitcher.labelHeight, alignment: .top)
            .padding(.leading, 2)
            .contentShape(Rectangle())
            .onHover { isHovered in
                if isHovered && model.canHover {
                    model.select(item)
                }
            }
            .onTapGesture {
                model.select(item, commitNow: true)
            }
            .animation(.easeOut(duration: 0.16), value: isAppActive)

            card(item)
        }
        .frame(width: model.cardWidth(item), height: rowHeight, alignment: .top)
        .id(item.id)
    }

    private func card(_ item: MSGSwitcherWindow) -> some View {
        let isSelected = !model.suppressInitialHover && (model.selectedItem?.id == item.id)
        return DockWindowCard(window: item.window, appName: item.appName,
                       height: model.thumbHeight,
                       maxWidth: model.thumbHeight * MSGWindowSwitcher.maxCardAspect,
                       action: { model.select(item, commitNow: true) },
                       onClose: { model.close(item, quitLastPreview: true) },
                       onMinimize: { model.minimize(item) },
                       onFullscreen: { model.toggleFullscreen(item) },
                       closeQuitsApp: model.items.filter { $0.pid == item.pid }.count == 1,
                       selected: isSelected,
                       reservesCaption: true,
                       captionHeight: model.captionHeight(for: item),
                       canHover: model.canHover,
                       onHoverChanged: { isHovered in
                           if isHovered && model.canHover {
                               model.select(item)
                           }
                       },
                       isHidden: PreviewHiddenStyle.isHidden(pid: item.pid, windowID: item.window.id))
            .accessibilityLabel("\(item.appName), \(item.window.title ?? "No open window")")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct MSGSystemShortcutTransition: Equatable {
    let suppress: Set<Int32>
    let restore: Set<Int32>
}

/// Pure rules behind `SystemShortcutTakeover`, kept apart so the unit tests
/// can exercise them without a WindowServer.
enum MSGSystemShortcutTakeoverSupport {
    /// SkyLight returns Carbon modifiers on some releases and CGEvent flags
    /// on others. Match both representations of Cmd-Tab / Cmd-Shift-Tab.
    static func matchesCommandTab(code: UInt32, modifiers: UInt32) -> Bool {
        code == 48 && [UInt32(0x100), 0x300, 0x100000, 0x120000].contains(modifiers)
    }
    /// Recovery runs before a replacement handler exists, so it must never
    /// disable a key, including an owned key the system has re-enabled.
    static func recoveryTransition(from current: Set<Int32>, keeping desired: Set<Int32>)
        -> MSGSystemShortcutTransition {
        MSGSystemShortcutTransition(suppress: [], restore: current.subtracting(desired))
    }

    static func transition(from current: Set<Int32>, to desired: Set<Int32>,
                           currentlyEnabled: Set<Int32>) -> MSGSystemShortcutTransition {
        MSGSystemShortcutTransition(suppress: desired.intersection(currentlyEnabled),
                                 restore: current.subtracting(desired))
    }

    /// One pass over a transition. The marker is written before each disable
    /// and again after each change, so a crash between the two still leaves a
    /// record of the key. A disable the WindowServer refuses takes its id back
    /// out of the marker; an enable it refuses keeps its id in, so the next
    /// pass or the next launch retries instead of dropping the key with
    /// nothing left to restore it.
    static func apply(_ transition: MSGSystemShortcutTransition, owned: Set<Int32>,
                      setEnabled: (Int32, Bool) -> Bool,
                      persist: (Set<Int32>) -> Void) -> Set<Int32> {
        var next = owned
        for id in transition.suppress {
            let newlyOwned = next.insert(id).inserted
            if newlyOwned { persist(next) }
            if !setEnabled(id, false), newlyOwned {
                next.remove(id)
                persist(next)
            }
        }
        for id in transition.restore where setEnabled(id, true) {
            next.remove(id)
            persist(next)
        }
        return next
    }

    /// The switcher kept its own marker before the take-over was shared. Fold
    /// it into the shared one on first launch so a crash marker from an older
    /// build still restores; ids that do not fit Int32 are noise, not keys.
    static func migratedMarker(old: [Int]?, new: [Int]?) -> Set<Int32> {
        Set(((old ?? []) + (new ?? [])).compactMap { Int32(exactly: $0) })
    }
}

/// Vorssaint's write-ahead ownership model, restricted to MSG's two shortcuts.
/// Changes are made only after the replacement tap is live. Native mode, quit,
/// loss of Accessibility, and next-launch crash recovery give the keys back.
enum MSGNativeHotkeys {
    private static let lock = NSLock()
    private static let marker = "msgSwitcherSuppressedNativeHotkeys"
    private static var suppressed = Set((UserDefaults.standard.array(forKey: marker) as? [Int] ?? [])
        .compactMap { Int32(exactly: $0) }.filter { $0 == 1 || $0 == 2 })
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> CGError
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> CGError
    private static let setEnabled: SetEnabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetEnabled.self)
    }()
    private static let isEnabled: IsEnabled? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: IsEnabled.self)
    }()
    private static let getValue: GetValue? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSGetSymbolicHotKeyValue") else { return nil }
        return unsafeBitCast(symbol, to: GetValue.self)
    }()
    static func commandTabIDs() -> Set<Int32> {
        guard let getValue else { return [] }
        return Set([Int32(1), Int32(2)].filter { id in
            var character: UInt32 = 0, code: UInt32 = 0, modifiers: UInt32 = 0
            guard getValue(id, &character, &code, &modifiers) == .success else { return false }
            return MSGSystemShortcutTakeoverSupport.matchesCommandTab(code: code, modifiers: modifiers)
        })
    }
    static func apply(desired: Set<Int32>) {
        lock.lock(); defer { lock.unlock() }
        guard let setEnabled, let isEnabled else { return }
        let enabled = desired.union(suppressed).filter { isEnabled($0) }
        let transition = MSGSystemShortcutTakeoverSupport.transition(from: suppressed, to: desired, currentlyEnabled: enabled)
        suppressed = MSGSystemShortcutTakeoverSupport.apply(transition, owned: suppressed,
            setEnabled: { setEnabled($0, $1) == .success }, persist: { ids in
                if ids.isEmpty { UserDefaults.standard.removeObject(forKey: marker) }
                else { UserDefaults.standard.set(ids.map(Int.init).sorted(), forKey: marker) }
            })
    }
}
