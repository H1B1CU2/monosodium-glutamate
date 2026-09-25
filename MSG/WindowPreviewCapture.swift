import AppKit
import ApplicationServices
import Darwin
import ScreenCaptureKit

// MARK: - Private AX / SkyLight bindings (shared capture + raise/close plumbing)

/// Private AX call mapping an `AXUIElement` window back to its `CGWindowID`.
/// Used to tell genuine top-level windows (including minimized ones, which stay
/// in the AX window list) apart from uncapturable phantom/helper windows.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Addresses an AX element by opaque token. Still needed to *raise* a window
/// living on another Space; enumeration no longer brute-forces these.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

private typealias AXUIElementID = UInt64

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowTags")
private func CGSGetWindowTags(_ cid: CGSConnectionID, _ wid: CGWindowID,
                              _ tags: UnsafeMutablePointer<UInt32>, _ tagSize: Int) -> CGError

/// Spaces a window belongs to. A window the user could actually switch to always
/// sits on one; helper and leftover surfaces sit on none. See `isPlausiblyReal`.
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int,
                                     _ windowIDs: CFArray) -> CFArray?

/// Renders windows straight from their WindowServer backing store. Unlike
/// ScreenCaptureKit and `CGWindowListCreateImage`, this still returns the
/// real contents of a *minimized* window (the Dock keeps its backing alive
/// for the genie animation). Returns a +1 `CFArray` of `CGImage`.
@_silgen_name("CGSHWCaptureWindowList")
private func CGSHWCaptureWindowList(_ cid: CGSConnectionID, _ windowList: UnsafeMutablePointer<CGWindowID>,
                                    _ count: UInt32, _ options: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?

/// Reassigns existing windows to a managed Space without switching the user's
/// active Space. This is the operation Mission Control uses for a dragged
/// window; changing AXPosition alone does not change Space membership.
@_silgen_name("SLSMoveWindowsToManagedSpace")
private func SLSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windowIDs: CFArray,
                                          _ spaceID: UInt64)

/// Brings a specific window (and its owning process) to the front, switching to
/// that window's Space if it lives on another one — the reliable cross-Space
/// focus path. `mode` 0x200 = `kCPSUserGenerated`.
@_silgen_name("_SLPSSetFrontProcessWithOptions")
private func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber,
                                             _ wid: CGWindowID, _ mode: UInt32) -> CGError

/// Posts a raw window event (used to make the raised window the key window so
/// keyboard focus follows it).
@_silgen_name("SLPSPostEventRecordTo")
private func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber,
                                   _ bytes: UnsafePointer<UInt8>) -> CGError

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

// MARK: - CapturedWindow

/// A single captured window: its thumbnail plus the identifiers needed to raise
/// that exact window later.
struct CapturedWindow: Identifiable {
    let id: CGWindowID
    let image: NSImage
    /// The window's own title, when the system exposes it (used as the card label).
    let title: String?
    /// Window bounds in Quartz/AX global coordinates (top-left origin). Used to
    /// match this thumbnail back to its `AXUIElement` for precise raising.
    let bounds: CGRect
}

// MARK: - NotchWindowItem

/// A window preview item for the Notch preview panel.
struct NotchWindowItem: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let appIcon: NSImage?
    let title: String?
    let bounds: CGRect
    /// Starts as the last-known picture (or an icon placeholder) so the panel
    /// can open at once, then is swapped for a live capture.
    var image: NSImage
    var isOtherSpace: Bool = false
    /// Its app is hidden (⌘H): listed where it lives, drawn greyed out.
    var isHidden: Bool = false

    /// Width/height of the card. From the window's own bounds when it has
    /// them, so a card keeps its size when a placeholder is swapped for the
    /// live capture; the image's shape otherwise.
    var previewAspect: CGFloat {
        if bounds.width > 0, bounds.height > 0 { return bounds.width / bounds.height }
        return image.size.height > 0 ? image.size.width / image.size.height : 1.4
    }

    /// Includes the image, or SwiftUI would treat a card whose thumbnail was
    /// just replaced as unchanged and keep drawing the old one.
    static func == (lhs: NotchWindowItem, rhs: NotchWindowItem) -> Bool {
        lhs.id == rhs.id && lhs.image === rhs.image && lhs.isHidden == rhs.isHidden
    }
}

// MARK: - WindowPreviewCapture

/// Shared window backend for the Tray HUD and the Dock hover previews:
/// enumerates an app's real windows (all Spaces, including minimized ones),
/// captures thumbnails, and raises/closes a specific window on request.
/// The authoritative window list comes from `CGWindowList` (which spans every
/// Space); each window is rendered with ScreenCaptureKit when it's on the
/// active Space (crisp, shadow-free) or the CGWindowList image API otherwise.
enum WindowPreviewCapture {

    private struct Entry {
        let id: CGWindowID
        let title: String?
        let bounds: CGRect
        /// From `kCGWindowIsOnscreen`. False both for windows on another Space
        /// and for never-shown helper windows — see `isPlausiblyReal`.
        var onScreen: Bool = false
    }

    // MARK: Shared cache state
    //
    // `capture` runs on the concurrency pool while the Dock controller hits the
    // sync helpers from the main thread, so every cache below is lock-guarded.

    private static let lock = NSLock()

    /// Last successful thumbnail per window id, so a window that later minimizes
    /// (and becomes uncapturable) can still show its real last-seen image.
    /// Bounded to `thumbnailCacheLimit`, evicting the oldest insertions.
    private static var thumbnailCache: [CGWindowID: NSImage] = [:]
    private static var thumbnailOrder: [CGWindowID] = []
    private static let thumbnailCacheLimit = 80

    /// Short-lived `hasPreviewableWindows` verdicts, keyed by pid.
    private static var previewableCache: [pid_t: (stamp: CFAbsoluteTime, value: Bool)] = [:]
    private static var browserTitlesCache: [pid_t: (stamp: CFAbsoluteTime, titles: [String: String])] = [:]

    /// An app's window elements by window id. `kAXWindows` is a round trip into
    /// that app's main thread — measured at 10-20 ms while it is busy, and over
    /// 100 ms across all apps from cold — and one tiling refresh used to ask
    /// each app again for every window it owns.
    private static var axWindowCache: [pid_t: (stamp: CFAbsoluteTime, windows: [CGWindowID: AXUIElement])] = [:]

    /// (stamp, `SCShareableContent`) — typed `Any` so the stored property needs
    /// no availability gate under the pre-14 deployment target.
    private static var shareableCache: (stamp: CFAbsoluteTime, content: Any)?

    private static let previewableTTL: CFAbsoluteTime = 2.0
    /// Long enough to serve one refresh pass, short enough that a window closed
    /// a moment ago is not handed out.
    private static let axWindowTTL: CFAbsoluteTime = 0.25
    private static let browserTitlesTTL: CFAbsoluteTime = 2.0
    private static let shareableTTL: CFAbsoluteTime = 1.5

    // MARK: Capture

    @available(macOS 14.0, *)
    static func capture(pid: pid_t, maxWindows: Int = 12) async -> [CapturedWindow] {
        guard pid > 0 else { return [] }

        // CGWindowList is the source of windows; `isPlausiblyReal` decides which
        // of them a person could actually switch to.
        //
        // This used to also require membership in a set built from `AXWindows`
        // plus a brute-force sweep of ~1000 AX remote tokens. That sweep existed
        // to find windows on other Spaces, and it silently found nothing for
        // plenty of real apps — Music and ChatGPT among them — so those apps
        // produced no tiles at all. Space membership answers the same question
        // directly, for one syscall instead of a thousand IPC round trips.
        let axWins = accessibilityWindows(pid: pid)
        let axIDs = Set(axWins.compactMap { $0.id != 0 ? $0.id : nil })
        let owner = NSRunningApplication(processIdentifier: pid)
        let ownerBundleID = owner?.bundleIdentifier
        let minimizedIDs = Set(axWins.filter(\.minimized).map(\.id))

        let rawEntries = dedupByRect(previewEntries(pid: pid, axWins: axWins,
                                                 axStandard: axStandardIDs(axWins))
            .filter { isPlausiblyReal($0, axIDs: axIDs, ownerBundleID: ownerBundleID,
                                      ownerIsHidden: owner?.isHidden ?? true,
                                      minimizedIDs: minimizedIDs) }, axIDs: axIDs)
        let entries = resolveFullTitles(pid: pid, bundleID: ownerBundleID,
                                        entries: Array(rawEntries.prefix(maxWindows)),
                                        axWins: axWins)

        // Map of on-screen SCWindows by id for high-quality capture.
        var sckByID: [CGWindowID: SCWindow] = [:]
        if let content = await shareableContent() {
            for w in content.windows where w.owningApplication?.processID == Int32(pid) {
                sckByID[w.windowID] = w
            }
        }

        var captured: [CapturedWindow] = []
        for e in entries {
            if let scw = sckByID[e.id], let img = await sckImage(of: scw) {
                cacheThumbnail(img, for: e.id)
                captured.append(CapturedWindow(id: e.id, image: img,
                                               title: e.title ?? title(of: scw), bounds: scw.frame))
            } else if let img = cgImage(of: e.id) {
                cacheThumbnail(img, for: e.id)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            } else if let cached = cachedThumbnail(for: e.id) {
                captured.append(CapturedWindow(id: e.id, image: cached, title: e.title, bounds: e.bounds))
            } else if minimizedIDs.contains(e.id), let img = minimizedImage(of: e.id) {
                cacheThumbnail(img, for: e.id)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            } else {
                // Uncapturable but a genuine top-level window (e.g. on another
                // Space) with no picture yet — an icon placeholder.
                let img = placeholderImage(pid: pid)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            }
        }

        if captured.isEmpty, let placeholder = appPlaceholderWindow(pid: pid) {
            return [placeholder]
        }
        return captured
    }

    /// One known window's thumbnail, for surfaces that show a single window
    /// rather than an app's whole list — the tiling control bar's hover card.
    ///
    /// Skips enumeration: the caller already holds the exact window id, and
    /// `capture(pid:)` would shoot every window the app owns to show one of
    /// them. Falls back the same way that path does — ScreenCaptureKit, then
    /// `CGWindowListCreateImage`, then the last thumbnail seen this session,
    /// then an icon placeholder — so a window on another Space or minimised
    /// still gets a card.
    @available(macOS 14.0, *)
    static func captureWindow(pid: pid_t, windowID: CGWindowID) async -> CapturedWindow {
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first
        let listedTitle = (info?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var listedBounds = CGRect.zero
        if let dict = info?[kCGWindowBounds as String] as? [String: Any] {
            listedBounds = CGRect(dictionaryRepresentation: dict as CFDictionary) ?? .zero
        }

        // A hidden or minimized window can't be captured, and trying only
        // fails after a delay; go straight to its last picture.
        if isWindowHidden(pid: pid, windowID: windowID) {
            // `minimizedImage` returns nil for ⌘H windows, so it's safe to try.
            let image = cachedThumbnail(for: windowID)
                ?? minimizedImage(of: windowID).map { cacheThumbnail($0, for: windowID); return $0 }
                ?? placeholderImage(pid: pid)
            return CapturedWindow(id: windowID, image: image,
                                  title: listedTitle, bounds: listedBounds)
        }
        if let content = await shareableContent(),
           let scw = content.windows.first(where: { $0.windowID == windowID }),
           let img = await sckImage(of: scw) {
            cacheThumbnail(img, for: windowID)
            return CapturedWindow(id: windowID, image: img,
                                  title: listedTitle ?? title(of: scw), bounds: scw.frame)
        }
        if let img = cgImage(of: windowID) {
            cacheThumbnail(img, for: windowID)
            return CapturedWindow(id: windowID, image: img, title: listedTitle, bounds: listedBounds)
        }
        return CapturedWindow(id: windowID,
                              image: cachedThumbnail(for: windowID) ?? placeholderImage(pid: pid),
                              title: listedTitle, bounds: listedBounds)
    }

    /// The last thumbnail captured for a window this session, without capturing
    /// anything. Lets a hover card appear with a real image on the first frame
    /// and refresh it once a live capture lands.
    static func lastThumbnail(for windowID: CGWindowID) -> NSImage? {
        cachedThumbnail(for: windowID)
    }

    /// Metadata-only switcher enumeration. Screenshots load after selection is
    /// available, so Cmd-Tab never waits for ScreenCaptureKit image rendering.
    ///
    /// `scriptBrowsers` allows the AppleScript title fetch. Background callers
    /// (the tiling poll, which runs on every click) must pass false: an Apple
    /// Event landing in Dia or Edge mid-interaction drops the new-tab field's
    /// keyboard focus and eats clicks on sidebar buttons and context menus.
    /// They still get whatever titles the last explicit fetch cached.
    static func switcherWindows(pid: pid_t, scriptBrowsers: Bool = true) -> [CapturedWindow] {
        let axWins = accessibilityWindows(pid: pid)
        let axIDs = Set(axWins.compactMap { $0.id != 0 ? $0.id : nil })
        let owner = NSRunningApplication(processIdentifier: pid)
        let ownerBundleID = owner?.bundleIdentifier
        let minimizedIDs = Set(axWins.filter(\.minimized).map(\.id))
        let rawEntries = dedupByRect(previewEntries(pid: pid, axWins: axWins,
                                                axStandard: axStandardIDs(axWins))
            .filter { isPlausiblyReal($0, axIDs: axIDs, ownerBundleID: ownerBundleID,
                                      ownerIsHidden: owner?.isHidden ?? true,
                                      minimizedIDs: minimizedIDs) }, axIDs: axIDs)
        let entries = resolveFullTitles(pid: pid, bundleID: ownerBundleID,
                                        entries: rawEntries,
                                        axWins: axWins,
                                        allowScript: scriptBrowsers)
        return entries.map { e in
            CapturedWindow(id: e.id, image: cachedThumbnail(for: e.id) ?? placeholderImage(pid: pid),
                           title: e.title, bounds: e.bounds)
        }
    }

    /// True when the app has at least one window worth previewing. Cheap by
    /// design — one CGWindowList sweep and at most one AX window-list fetch —
    /// because the Dock controller calls it from the mouse-move path. Verdicts
    /// are cached briefly per app.
    static func hasPreviewableWindows(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let c = previewableCache[pid], now - c.stamp < previewableTTL {
            lock.unlock()
            return c.value
        }
        lock.unlock()

        // Any plausibly real CGWindowList window (layer 0, sized, visible — the
        // list spans every Space) counts; the capture path still applies the
        // strict genuine-window filter before anything is shown.
        //
        // The helper-window test runs here too, or an app whose only listed
        // window is a hidden shell (Electron's 800x600) would advertise a
        // preview and then show nothing but an icon placeholder.
        let axWins = accessibilityWindows(pid: pid)
        let axIDs = Set(axWins.compactMap { $0.id != 0 ? $0.id : nil })
        let owner = NSRunningApplication(processIdentifier: pid)
        let ownerBundleID = owner?.bundleIdentifier
        let minimizedIDs = Set(axWins.filter(\.minimized).map(\.id))
        var value = windowEntries(pid: pid, axStandard: axStandardIDs(axWins)).contains {
            isPlausiblyReal($0, axIDs: axIDs, ownerBundleID: ownerBundleID,
                            ownerIsHidden: owner?.isHidden ?? true,
                            minimizedIDs: minimizedIDs)
        }
        if !value {
            // No listed windows — the app may still have minimized ones.
            value = axWins.contains { $0.minimized && $0.id != 0 }
        }

        lock.lock()
        previewableCache[pid] = (now, value)
        lock.unlock()
        return value
    }

    // MARK: Raising & closing

    @MainActor private static var activationGeneration = 0

    // MARK: Hidden windows

    private static var hiddenCache: [CGWindowID: (stamp: CFAbsoluteTime, hidden: Bool)] = [:]
    /// Previews ask per card on every re-render — Cmd-Tab re-renders a whole
    /// grid on each step — and the minimized check is an AX round trip into
    /// the app, so a verdict is reused for a moment.
    private static let hiddenTTL: CFAbsoluteTime = 2.0

    /// Whether a window is out of sight while still belonging to its Desktop:
    /// its app is hidden (⌘H), the window is minimized, or the app has
    /// ordered just that window out. Apps that "hide" from their own UI do
    /// either of the last two — Hermes minimizes — and never set the app's
    /// `isHidden`, which is why checking the app alone missed them.
    static func isWindowHidden(pid: pid_t, windowID: CGWindowID) -> Bool {
        if pid != 0, NSRunningApplication(processIdentifier: pid)?.isHidden == true { return true }
        guard windowID != 0 else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let cached = hiddenCache[windowID]
        lock.unlock()
        if let cached, now - cached.stamp < hiddenTTL { return cached.hidden }

        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first
        let hidden: Bool
        if (info?[kCGWindowIsOnscreen as String] as? Bool) == true {
            hidden = false
        } else if windowIsOnVisibleSpace(windowID) == true {
            // Off screen on a Desktop being shown: ordered out or minimized.
            hidden = true
        } else if pid != 0, let element = axWindow(pid: pid, windowID: windowID) {
            // On another Desktop every window is off screen; only AX can
            // still tell a minimized one apart.
            var value: CFTypeRef?
            hidden = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success
                && (value as? Bool) == true
        } else {
            hidden = false
        }
        lock.lock()
        hiddenCache[windowID] = (now, hidden)
        if hiddenCache.count > 200 { hiddenCache = hiddenCache.filter { now - $0.value.stamp < hiddenTTL } }
        lock.unlock()
        return hidden
    }

    /// Query only: Dock/WindowServer owns the transition and its animation.
    private static func windowIsOnVisibleSpace(_ windowID: CGWindowID) -> Bool? {
        let memberships = Set(spacesForWindow(windowID))
        guard !memberships.isEmpty,
              let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return nil }
        let current = Set(displays.compactMap { display -> Int? in
            guard let space = display["Current Space"] as? [String: Any] else { return nil }
            return space["ManagedSpaceID"] as? Int ?? space["id64"] as? Int
        })
        guard !current.isEmpty else { return nil }
        return !memberships.isDisjoint(with: current)
    }

    /// Resolves the current managed Space for the display receiving a drop.
    /// `CGSGetActiveSpace` is global and can point at whichever monitor most
    /// recently had focus, so it is not sufficient for cross-display drops.
    static func currentManagedSpaceID(for screen: NSScreen) -> UInt64? {
        guard let current = managedDisplay(for: screen)?["Current Space"] as? [String: Any] else { return nil }
        return managedSpaceID(of: current)
    }

    /// The managed Space at `spaceNumber` (1-based, in Mission Control order —
    /// the same numbering the tiling bar's space indicator uses) on `screen`.
    /// `isFullscreen` marks a fullscreen app's own Space, which accepts no
    /// other windows.
    static func managedSpace(for screen: NSScreen, number spaceNumber: Int) -> (id: UInt64, isFullscreen: Bool)? {
        let spaces = managedSpaces(for: screen)
        guard spaceNumber >= 1, spaceNumber <= spaces.count else { return nil }
        return spaces[spaceNumber - 1]
    }

    /// Every managed Space on `screen`, in Mission Control order, so index + 1
    /// is the Space's number. A Space whose id can't be read is dropped, which
    /// would shift the numbering — callers treat an empty result as unknown.
    static func managedSpaces(for screen: NSScreen) -> [(id: UInt64, isFullscreen: Bool)] {
        guard let spaces = managedDisplay(for: screen)?["Spaces"] as? [[String: Any]] else { return [] }
        let resolved = spaces.compactMap { space in
            managedSpaceID(of: space).map { (id: $0, isFullscreen: (space["type"] as? Int) == 4) }
        }
        return resolved.count == spaces.count ? resolved : []
    }

    private static func managedDisplay(for screen: NSScreen) -> [String: Any]? {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else {
            return nil
        }
        let screenUUID = screen.uuid
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let isMainDisplay = screenNumber == CGMainDisplayID()

        return displays.first { display in
            let identifier = display["Display Identifier"] as? String ?? ""
            return identifier == "Main"
                ? isMainDisplay
                : screenUUID.map { identifier.caseInsensitiveCompare($0) == .orderedSame } ?? false
        }
    }

    private static func managedSpaceID(of space: [String: Any]) -> UInt64? {
        // `id64` is the concrete CGSSpaceID accepted by the move APIs.
        // On newer macOS releases `ManagedSpaceID` may instead be a String.
        if let value = space["id64"] as? NSNumber { return value.uint64Value }
        if let value = space["id64"] as? UInt64 { return value }
        if let value = space["id64"] as? Int, value > 0 { return UInt64(value) }
        if let value = space["ManagedSpaceID"] as? NSNumber { return value.uint64Value }
        if let value = space["ManagedSpaceID"] as? UInt64 { return value }
        if let value = space["ManagedSpaceID"] as? Int, value > 0 { return UInt64(value) }
        if let value = space["ManagedSpaceID"] as? String,
           let parsed = UInt64(value), parsed > 0 { return parsed }
        return nil
    }

    /// macOS 26.4 and later route third-party Space writes through a bridged
    /// WindowServer operation. The older SLS function still links but silently
    /// ignores cross-Space moves on current systems.
    private static func submitBridgedSpaceMove(windowID: CGWindowID, spaceID: UInt64) -> Bool {
        guard let operationClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else {
            return false
        }

        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let allocated = (operationClass as AnyObject).perform(allocSelector)?.takeUnretainedValue(),
              allocated.responds(to: initSelector) else {
            return false
        }

        typealias InitFunction = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject
        let initFunction = unsafeBitCast(allocated.method(for: initSelector), to: InitFunction.self)
        let operation = initFunction(
            allocated,
            initSelector,
            [NSNumber(value: UInt32(windowID))] as NSArray,
            spaceID
        )
        guard operation.responds(to: performSelector) else { return false }

        typealias PerformFunction = @convention(c) (AnyObject, Selector) -> Void
        let performFunction = unsafeBitCast(operation.method(for: performSelector), to: PerformFunction.self)
        performFunction(operation, performSelector)
        return true
    }

    /// Moves one concrete window to `spaceID` and confirms WindowServer applied
    /// the reassignment before callers raise or reposition it. Raising first
    /// would navigate to the source Space, which is the opposite of a drop.
    static func moveWindow(_ windowID: CGWindowID, toManagedSpace spaceID: UInt64) async -> Bool {
        guard windowID != 0, spaceID > 0, spaceID <= UInt64(Int.max) else { return false }
        let target = Int(spaceID)
        if spacesForWindow(windowID).contains(target) { return true }

        let connection = CGSMainConnectionID()
        let windows = [NSNumber(value: UInt32(windowID))] as CFArray
        // A fullscreen exit or unminimise can still be settling when the first
        // request arrives. Re-submit after short verification windows instead
        // of raising the window on its old Space.
        for _ in 0..<3 {
            if !submitBridgedSpaceMove(windowID: windowID, spaceID: spaceID) {
                SLSMoveWindowsToManagedSpace(connection, windows, spaceID)
            }
            for _ in 0..<15 {
                if spacesForWindow(windowID).contains(target) { return true }
                do { try await Task.sleep(nanoseconds: 40_000_000) }
                catch { return false }
            }
        }
        return spacesForWindow(windowID).contains(target)
    }

    static func window(_ windowID: CGWindowID, isOnManagedSpace spaceID: UInt64) -> Bool {
        guard windowID != 0, spaceID > 0, spaceID <= UInt64(Int.max) else { return false }
        return spacesForWindow(windowID).contains(Int(spaceID))
    }

    @MainActor
    private static func activationIsCurrent(_ generation: Int, from originalPID: pid_t?, to pid: pid_t) -> Bool {
        guard generation == activationGeneration, !Task.isCancelled else { return false }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // A newer selection or the user activating another app cancels settling.
        return front == nil || front == originalPID || front == pid || front == getpid()
    }

    private static func waitForNativeSpace(_ windowID: CGWindowID, generation: Int,
                                           originalPID: pid_t?, pid: pid_t) async -> Bool {
        for _ in 0..<16 {
            guard await activationIsCurrent(generation, from: originalPID, to: pid) else { return false }
            if windowIsOnVisibleSpace(windowID) == true { return true }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return false }
        }
        return windowIsOnVisibleSpace(windowID) == true
    }

    private static func raiseAXWindow(_ window: AXUIElement) {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if (minimized as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        AXUIElementSetAttributeValue(window, kAXMainWindowAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// Requests normal macOS activation. No direct Space assignment, simulated
    /// desktop shortcuts, cursor warping, or independent delayed focus pulses.
    @available(macOS 14.0, *)
    static func raiseWindow(pid: pid_t, windowID: CGWindowID, fallbackBounds: CGRect) async {
        if pid == ProcessInfo.processInfo.processIdentifier {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where !w.isExcludedFromWindowsMenu && !(w is NSPanel) {
                    w.makeKeyAndOrderFront(nil)
                }
            }
            return
        }

        let (generation, originalPID) = await MainActor.run {
            activationGeneration &+= 1
            return (activationGeneration, NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        // A minimized window sits on no Space and can't be focused until it is
        // back on screen. Restore it first, directly, so no activation check
        // below can skip it — clicking a Dock-minimized window's card did
        // nothing when the later guard bailed before `raiseAXWindow`.
        if windowID != 0, let element = axWindow(pid: pid, windowID: windowID) {
            AXUIElementSetMessagingTimeout(element, 0.2)
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                NSLog("[MSG Window Preview] Unminimize window %u for pid %d: %d", windowID, pid, result.rawValue)
            }
        } else if windowID != 0 {
            NSLog("[MSG Window Preview] No AX element for window %u pid %d", windowID, pid)
        }
        let wasOffSpace = windowID != 0 && windowIsOnVisibleSpace(windowID) == false

        // Begin the native exact-window request before any slow AX discovery.
        if windowID != 0 { _ = requestWindowFocus(pid: pid, windowID: windowID) }
        await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            app.unhide()
            _ = app.activate(options: [])
        }

        var target = axWindow(pid: pid, windowID: windowID)
        if windowID == 0 {
            target = standardAXWindows(pid: pid).min { a, b in
                func distance(_ window: AXUIElement) -> CGFloat {
                    guard let frame = axFrame(of: window) else { return .greatestFiniteMagnitude }
                    return hypot(frame.midX - fallbackBounds.midX, frame.midY - fallbackBounds.midY)
                }
                return distance(a) < distance(b)
            }
        }
        guard await activationIsCurrent(generation, from: originalPID, to: pid) else { return }
        if let target { raiseAXWindow(target) }
        guard wasOffSpace else { return }

        if await waitForNativeSpace(windowID, generation: generation, originalPID: originalPID, pid: pid) { return }
        guard await activationIsCurrent(generation, from: originalPID, to: pid) else { return }

        // These apps may activate their process while leaving their main window
        // on another Space. Ask the existing app to open through Launch Services
        // so it can present its window normally, just as when opened from Dock.
        let reopenURL: URL? = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  ["com.openai.codex", "com.google.GeminiMacOS"].contains(app.bundleIdentifier ?? "") else { return nil }
            return app.bundleURL
        }
        if let reopenURL {
            do {
                try await reopenForNativeActivation(reopenURL)
            } catch {
                NSLog("[MSG Window Preview] Native app activation failed for pid %d: %@", pid, error.localizedDescription)
                return
            }
            guard await activationIsCurrent(generation, from: originalPID, to: pid) else { return }
            target = axWindow(pid: pid, windowID: windowID)
            if let target { raiseAXWindow(target) }
            if await waitForNativeSpace(windowID, generation: generation, originalPID: originalPID, pid: pid) { return }
        }
        if await activationIsCurrent(generation, from: originalPID, to: pid) {
            NSLog("[MSG Window Preview] Native activation did not reach window %u's Space for pid %d", windowID, pid)
        }
    }

    @MainActor
    private static func reopenForNativeActivation(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @discardableResult
    private static func requestWindowFocus(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0 else { return false }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        let result = _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200)
        guard result == .success else {
            NSLog("[MSG Window Preview] Cannot focus window %u for pid %d: %d", windowID, pid, result.rawValue)
            return false
        }
        makeKeyWindow(psn: &psn, windowID: windowID)
        return true
    }

    /// Presses the AX close button of the given window. Involves the slow AX
    /// lookup — call from off the main thread.
    static func closeWindow(pid: pid_t, windowID: CGWindowID) async {
        guard let el = axWindow(pid: pid, windowID: windowID) else { return }
        var closeButton: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &closeButton) == .success {
            AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Toggle the window's native fullscreen state, never its zoom/maximise state.
    @available(macOS 14.0, *)
    static func toggleFullscreen(pid: pid_t, windowID: CGWindowID, bounds: CGRect) async {
        guard let window = axWindow(pid: pid, windowID: windowID) else { return }
        let attribute = "AXFullScreen" as CFString
        var settable = DarwinBoolean(false)
        var value: CFTypeRef?
        guard AXUIElementIsAttributeSettable(window, attribute, &settable) == .success,
              settable.boolValue,
              AXUIElementCopyAttributeValue(window, attribute, &value) == .success,
              let fullscreen = value as? Bool else { return }
        await raiseWindow(pid: pid, windowID: windowID, fallbackBounds: bounds)
        let result = AXUIElementSetAttributeValue(window, attribute, (!fullscreen) as CFBoolean)
        if result != .success {
            NSLog("[MSG Window Preview] Fullscreen request failed for window %u: %d", windowID, result.rawValue)
        }
    }

    /// Finds the `AXUIElement` for a specific window id: the app's standard AX
    /// list first (cheap; covers the current Space and minimized windows), then
    /// the remote-token brute force (windows on other Spaces).
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard windowID != 0 else { return nil }

        // A hit costs nothing; a miss re-asks the app before the brute force,
        // so a window opened since the last pass is still found at once.
        if let element = axWindowsByID(pid: pid, allowCached: true)[windowID] { return element }
        if let element = axWindowsByID(pid: pid, allowCached: false)[windowID] { return element }

        var token = remoteToken(pid: pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        for axId: AXUIElementID in 0 ..< 1000 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            AXUIElementSetMessagingTimeout(el, 0.05)
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            if wid == windowID {
                // Windows on other Spaces are only ever found this way, and a
                // Space is laid out more than once. Remember it.
                lock.lock()
                let now = CFAbsoluteTimeGetCurrent()
                var entry = axWindowCache[pid] ?? (stamp: now, windows: [:])
                entry.windows[windowID] = el
                axWindowCache[pid] = entry
                lock.unlock()
                return el
            }
        }
        return nil
    }

    /// The app's standard windows keyed by window id, from the cache when it is
    /// fresh enough.
    private static func axWindowsByID(pid: pid_t, allowCached: Bool) -> [CGWindowID: AXUIElement] {
        let now = CFAbsoluteTimeGetCurrent()
        if allowCached {
            lock.lock()
            if let cached = axWindowCache[pid], now - cached.stamp < axWindowTTL {
                let windows = cached.windows
                lock.unlock()
                return windows
            }
            lock.unlock()
        }
        var byID: [CGWindowID: AXUIElement] = [:]
        for w in standardAXWindows(pid: pid) {
            AXUIElementSetMessagingTimeout(w, 0.1)
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid != 0 { byID[wid] = w }
        }
        lock.lock()
        axWindowCache[pid] = (stamp: now, windows: byID)
        lock.unlock()
        return byID
    }

    /// Posts the two raw window events that make `windowID` the key window so
    /// keyboard focus follows it across the Space switch (AltTab's technique).
    private static func makeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        // Keep the synthetic pair in press/release order. Reversing it ends
        // with a press and can leave the target's content tracking input.
        // Reference: yabai/src/window_manager.c, window_manager_make_key_window.
        bytes[0x08] = 0x01
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(&psn, &bytes)
    }

    // MARK: Placeholder & thumbnail cache

    private static func appPlaceholderWindow(pid: pid_t) -> CapturedWindow? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let appName = app.localizedName ?? "Application"
        let image = placeholderImage(pid: pid)
        return CapturedWindow(id: 0, image: image, title: appName, bounds: .zero)
    }

    private static func placeholderImage(pid: pid_t) -> NSImage {
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
        return createPlaceholderImage(icon: icon)
    }

    private static func cacheThumbnail(_ image: NSImage, for id: CGWindowID) {
        guard id != 0 else { return }
        lock.lock()
        if thumbnailCache[id] == nil { thumbnailOrder.append(id) }
        thumbnailCache[id] = image
        while thumbnailOrder.count > thumbnailCacheLimit {
            let old = thumbnailOrder.removeFirst()
            thumbnailCache[old] = nil
        }
        lock.unlock()
    }

    private static func cachedThumbnail(for id: CGWindowID) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return thumbnailCache[id]
    }

    private static func createPlaceholderImage(icon: NSImage) -> NSImage {
        let size = NSSize(width: 200, height: 140)
        let img = NSImage(size: size)
        img.lockFocus()

        // 1. Draw smooth charcoal gradient
        let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.22, alpha: 1.0),
                                  ending: NSColor(calibratedWhite: 0.12, alpha: 1.0))
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)

        // 2. Draw subtle inner border
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        path.lineWidth = 1
        path.stroke()

        // 3. Draw the icon in the center
        let iconSize = NSSize(width: 48, height: 48)
        let iconRect = NSRect(
            x: (size.width - iconSize.width) / 2,
            y: (size.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.95)

        img.unlockFocus()
        return img
    }

    // MARK: Genuine-window enumeration (via Accessibility)

    /// A real top-level window as reported by Accessibility, including minimized
    /// ones (which `CGWindowList` drops because they report zero/off-screen bounds).
    private struct AXWindowInfo {
        let id: CGWindowID        // 0 when `_AXUIElementGetWindow` can't resolve it
        let title: String?
        let frame: CGRect         // restored frame in Quartz/AX global (top-left) coords
        let minimized: Bool
        /// `kAXSubroleAttribute` — `AXStandardWindow` is what lets a window above
        /// the normal level still count as previewable. See `windowEntries`.
        let subrole: String?
        let identifier: String?
    }

    /// The app's real top-level windows via AX. Empty when AX is unavailable
    /// (callers then trust the CGWindowList result as-is). Used both to drop
    /// uncapturable phantom/helper windows and to surface minimized ones.
    private static func accessibilityWindows(pid: pid_t) -> [AXWindowInfo] {
        standardAXWindows(pid: pid).map { w in
            AXUIElementSetMessagingTimeout(w, 0.2)
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(w, &wid)

            var miniRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &miniRef)

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 }

            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subroleRef)

            var idRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, "AXIdentifier" as CFString, &idRef)
            let identifier = idRef as? String

            return AXWindowInfo(id: wid, title: title,
                                frame: axFrame(of: w) ?? .zero,
                                minimized: (miniRef as? Bool) == true,
                                subrole: subroleRef as? String,
                                identifier: identifier)
        }
    }

    private static func isScriptableBrowser(_ bid: String) -> Bool {
        let browsers: Set<String> = [
            "company.thebrowser.dia",
            "company.thebrowser.Arc",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.browser"
        ]
        return browsers.contains(bid)
    }

    private static func fetchBrowserWindowTitles(bundleID: String, pid: pid_t, allowScript: Bool) -> [String: String] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let cached = browserTitlesCache[pid], !allowScript || now - cached.stamp < browserTitlesTTL {
            let titles = cached.titles
            lock.unlock()
            return titles
        }
        lock.unlock()
        guard allowScript else { return [:] }

        let script: String
        if bundleID == "company.thebrowser.dia" || bundleID == "company.thebrowser.browser" {
            script = """
            tell application id "\(bundleID)"
                set res to ""
                repeat with w in windows
                    set res to res & (id of w as text) & "|||" & (name of w as text) & "///"
                end repeat
                return res
            end tell
            """
        } else if bundleID == "company.thebrowser.Arc" {
            script = """
            tell application id "company.thebrowser.Arc"
                set res to ""
                repeat with w in windows
                    set res to res & (id of w as text) & "|||" & (title of active tab of w as text) & "///"
                end repeat
                return res
            end tell
            """
        } else if bundleID == "com.apple.Safari" {
            script = """
            tell application id "com.apple.Safari"
                set res to ""
                repeat with w in windows
                    set res to res & (id of w as text) & "|||" & (name of current tab of w as text) & "///"
                end repeat
                return res
            end tell
            """
        } else if ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"].contains(bundleID) {
            script = """
            tell application id "\(bundleID)"
                set res to ""
                repeat with w in windows
                    set res to res & (id of w as text) & "|||" & (title of active tab of w as text) & "///"
                end repeat
                return res
            end tell
            """
        } else {
            return [:]
        }

        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue,
              !out.isEmpty else { return [:] }

        var map: [String: String] = [:]
        for entry in out.components(separatedBy: "///") {
            let parts = entry.components(separatedBy: "|||")
            if parts.count >= 2 {
                let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty && !title.isEmpty {
                    map[id] = title
                }
            }
        }

        lock.lock()
        browserTitlesCache[pid] = (stamp: now, titles: map)
        lock.unlock()
        return map
    }

    private static func resolveFullTitles(pid: pid_t, bundleID: String?, entries: [Entry], axWins: [AXWindowInfo],
                                          allowScript: Bool = true) -> [Entry] {
        guard let bundleID, isScriptableBrowser(bundleID) else { return entries }
        let scriptTitles = fetchBrowserWindowTitles(bundleID: bundleID, pid: pid, allowScript: allowScript)
        guard !scriptTitles.isEmpty else { return entries }

        return entries.map { e in
            // 1. Try matching by AXIdentifier UUID
            if let ax = axWins.first(where: { $0.id == e.id }), let axID = ax.identifier {
                for (asID, fullTitle) in scriptTitles {
                    if axID.contains(asID) {
                        return Entry(id: e.id, title: fullTitle, bounds: e.bounds, onScreen: e.onScreen)
                    }
                }
            }
            // 2. Try matching by title prefix (stripping ellipsis … or ...)
            let curTitle = e.title ?? axWins.first(where: { $0.id == e.id })?.title
            if let curTitle {
                let clean = curTitle.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespacesAndNewlines))
                if !clean.isEmpty, let match = scriptTitles.values.first(where: { $0.hasPrefix(clean) }) {
                    return Entry(id: e.id, title: match, bounds: e.bounds, onScreen: e.onScreen)
                }
            }
            // 3. Fallback: if only 1 window is present
            if entries.count == 1, let onlyTitle = scriptTitles.values.first {
                return Entry(id: e.id, title: onlyTitle, bounds: e.bounds, onScreen: e.onScreen)
            }
            return e
        }
    }

    /// Ids of windows AX calls `AXStandardWindow` — the app's own document/main
    /// windows, as opposed to dialogs, panels and HUDs.
    private static func axStandardIDs(_ wins: [AXWindowInfo]) -> Set<CGWindowID> {
        Set(wins.compactMap { $0.id != 0 && $0.subrole == kAXStandardWindowSubrole ? $0.id : nil })
    }

    /// The app's standard AX window list — one IPC round-trip. Covers windows on
    /// the current Space plus minimized ones; other-Space windows need the
    /// remote-token sweep.
    private static func standardAXWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement], !windows.isEmpty {
            return windows
        }
        // Chromium (Edge, Chrome, Brave) builds its accessibility tree lazily:
        // the first query after a quiet spell answers with no windows, the next
        // with all of them. Without AX ids, `dedupByRect` took Edge's windows —
        // stacked by tiling at one identical frame — for shadow twins and kept
        // only the first, so the bar previewed and tiled a single window.
        guard NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { return [] }
        value = nil
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// The 20-byte remote-token prefix for `pid` (element id filled in per probe).
    private static func remoteToken(pid: pid_t) -> Data {
        var token = Data(count: 20)
        token.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })
        return token
    }

    /// Frame of an AX element in Quartz/AX global (top-left origin) coordinates.
    static func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    // MARK: Window enumeration (all Spaces)

    /// Combined, ordered preview list: visible/other-Space windows from
    /// `windowEntries`, plus minimized windows discovered via AX that the
    /// CGWindowList size filter drops.
    private static func previewEntries(pid: pid_t, axWins: [AXWindowInfo],
                                       axStandard: Set<CGWindowID> = []) -> [Entry] {
        var entries = windowEntries(pid: pid, axStandard: axStandard)
        let seen = Set(entries.map(\.id))
        for w in axWins where w.minimized && w.id != 0 && !seen.contains(w.id) {
            entries.append(Entry(id: w.id, title: w.title, bounds: w.frame))
        }
        return entries
    }

    /// The app's plausibly-real windows from `CGWindowList` (spans every Space),
    /// kept in the list's natural front-to-back z-order so the frontmost window
    /// leads the preview row.
    /// `axStandard` are ids AX calls `AXStandardWindow`. They are accepted even
    /// above the normal window level: an app is free to put its real main window
    /// on a floating level, and Claude does exactly that in its compact mode
    /// (`layer 3`, subrole `AXStandardWindow`). Requiring `layer == 0` meant such
    /// an app got no Dock preview at all. Everything else still has to be layer 0,
    /// which is what keeps panels, HUDs, tooltips and menus out.
    private static func windowEntries(pid: pid_t,
                                      axStandard: Set<CGWindowID> = []) -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info -> Entry? in
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t, wPid == pid,
                  let wID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 || axStandard.contains(wID),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width  = bounds["Width"]  as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width >= 200, height >= 100,
                  // Skip invisible windows (alpha ~0) — hidden Electron helpers etc.
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { return nil }
            let name = info[kCGWindowName as String] as? String
            if pid == ProcessInfo.processInfo.processIdentifier {
                guard let name, !name.isEmpty else { return nil }
            }
            return Entry(id: wID, title: (name?.isEmpty == false) ? name : nil,
                         bounds: CGRect(x: x, y: y, width: width, height: height),
                         onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    /// Rejects helper and leftover surfaces while keeping genuine windows that
    /// also report off-screen — parked on another Space, minimized, or belonging
    /// to an app hidden with ⌘H.
    ///
    /// Accessibility alone cannot separate them: Electron's hidden background
    /// window reports role `AXWindow`, subrole `AXStandardWindow`, and both a
    /// close and a minimize button — identical to the real one. Titles cannot
    /// either: ChatGPT's leftover surface is titled "ChatGPT", and Gemini's
    /// dismissed onboarding window is titled "Gemini Onboarding".
    ///
    /// What does separate them is Space membership. Every window the user could
    /// switch to sits on some Space; a helper that was never shown, and a
    /// surface the window server kept after its window closed, sit on none. The
    /// remaining case is a leftover parked on the *current* Space (Gemini's
    /// onboarding window), which AX settles: if AppKit describes windows for
    /// this app and this is not among them, it is stale.
    ///
    /// Order matters — each test below is the reason the next one is reachable:
    ///   on screen            → visible, done
    ///   listed by AX         → AppKit vouches for it
    ///   AX described others  → AppKit enumerated this app and left this out: stale
    ///   on no Space          → never shown, or a surface outliving its window
    ///   otherwise            → AX said nothing at all; trust CGWindowList
    ///
    /// The AX veto deliberately outranks the Space test. An earlier version
    /// asked "is it on a Space other than the current one?" first and treated
    /// that as proof the window was real — which made the verdict depend on
    /// where the user happened to be standing: Gemini's dismissed onboarding
    /// window was dropped while viewing its Space and reappeared as a duplicate
    /// from any other. AX's window list spans Spaces, so its opinion doesn't
    /// move; the Space test is only the fallback for apps it says nothing about.
    private static func windowTags(_ id: CGWindowID) -> (low: UInt32, high: UInt32)? {
        guard id != 0 else { return nil }
        var tags = [UInt32](repeating: 0, count: 2)
        guard CGSGetWindowTags(CGSMainConnectionID(), id, &tags, 64) == .success else { return nil }
        return (tags[0], tags[1])
    }

    private static func isPlausiblyReal(_ e: Entry, axIDs: Set<CGWindowID>,
                                        ownerBundleID: String?, ownerIsHidden: Bool = false,
                                        minimizedIDs: Set<CGWindowID> = []) -> Bool {
        // CoreGraphics / SkyLight low-level window tags (adapted from Vorssaint / AltTab).
        // bit 18 (1 << 18) is the window cycle exclusion flag.
        if let tags = windowTags(e.id) {
            // Excluded from window cycle (e.g. system overlays, floating toolbars, backdrop canvases)
            if (tags.low & (1 << 18)) != 0 {
                return false
            }
        }

        // ChatGPT's computer-use controls are utility surfaces, not chat
        // windows. They can remain registered after the control session ends.
        if ownerBundleID == "com.openai.codex",
           e.title == "Computer Use" || e.title == "Computer Use Controls" {
            return false
        }
        if ownerBundleID == "com.google.GeminiMacOS", e.title == "Gemini Onboarding" {
            return false
        }

        if e.onScreen || axIDs.contains(e.id) { return true }

        // TV can omit its library window from AXWindows while its separate
        // fullscreen player is active. Keep that window only when WindowServer
        // still marks it ordered-in and assigns it to a Space. Other apps keep
        // the strict AX veto to avoid resurrecting background helper windows.
        if ownerBundleID == "com.apple.TV",
           let tags = windowTags(e.id),
           (tags.low & 0x402000) == 0x402000,
           !spacesForWindow(e.id).isEmpty {
            return true
        }
        if ownerBundleID == "com.apple.TV", isManagedFullscreenWindow(e.id) {
            return true
        }
        if !axIDs.isEmpty { return false }

        // Gemini can stop exposing its real chat window through AX as soon as
        // the user leaves its Space. WindowServer also clears the generic
        // AppKit ordered-in tag in that state, even though the window remains
        // attached to its native Space. Treat that concrete membership as the
        // authority for Gemini. Its dismissed onboarding surface is excluded
        // above by title, and its helper surfaces have no Space membership.
        if ownerBundleID == "com.google.GeminiMacOS" {
            return !spacesForWindow(e.id).isEmpty
        }

        // Fallback when AX cannot enumerate windows (e.g. app on another space):
        // AppKit / Cocoa windows with tag bit 22 (0x400000) use bit 13 (0x2000) to signify
        // ordered-in status. If 0x400000 is set but 0x2000 is clear, it is an ordered-out
        // ghost/helper surface (e.g. LINE's backing twin 91 vs real window 1483, Bambu Studio ghost settings).
        if let tags = windowTags(e.id) {
            if (tags.low & 0x400000) != 0 && (tags.low & 0x2000) == 0 {
                return false
            }
        }

        return !spacesForWindow(e.id).isEmpty
    }

    /// TV's fullscreen player may be absent from AXWindows and does not carry
    /// the library's AppKit ordered-in tag. Match the actual fullscreen owner,
    /// not every surface assigned to the fullscreen Space (controls/backdrops).
    private static func isManagedFullscreenWindow(_ id: CGWindowID) -> Bool {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return false }
        return displays.contains { display in
            (display["Spaces"] as? [[String: Any]] ?? []).contains { space in
                (space["type"] as? Int) == 4 && (space["fs_wid"] as? CGWindowID) == id
            }
        }
    }

    private static func spacesForWindow(_ id: CGWindowID) -> [Int] {
        // mask 7 = every Space, not just the visible ones.
        (CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [id] as CFArray) as? [Int]) ?? []
    }

    /// Drops duplicate tiles sharing virtually the same on-screen rect (some apps report
    /// shadow/helper twins at identical or slightly offset bounds, e.g. 2-6pt margin),
    /// preferring the titled entry so a helper twin can never evict the genuine
    /// window it shadows. Preserves z-order.
    ///
    /// Two windows AX lists (`axIDs`), or two with different titles, are both genuine and never twins: tiling
    /// stacks an app's windows in one tile at exactly the same frame, and
    /// collapsing them hid the second one from tiling, the bar and the switcher.
    private static func dedupByRect(_ entries: [Entry], axIDs: Set<CGWindowID>) -> [Entry] {
        var kept: [Entry] = []
        for e in entries {
            if let i = kept.firstIndex(where: {
                !(axIDs.contains($0.id) && axIDs.contains(e.id)) &&
                // Differently titled windows are distinct documents (browser
                // windows stacked in one tile); a helper twin has no title.
                !($0.title != nil && e.title != nil && $0.title != e.title) &&
                abs($0.bounds.minX - e.bounds.minX) <= 6 &&
                abs($0.bounds.minY - e.bounds.minY) <= 6 &&
                abs($0.bounds.width - e.bounds.width) <= 6 &&
                abs($0.bounds.height - e.bounds.height) <= 6
            }) {
                if kept[i].title == nil, e.title != nil { kept[i] = e }
            } else {
                kept.append(e)
            }
        }
        return kept
    }

    // MARK: Per-window image

    /// Briefly cached `SCShareableContent` so glide-switching between Dock tiles
    /// doesn't re-enumerate every shareable window each time.
    @available(macOS 14.0, *)
    private static func shareableContent() async -> SCShareableContent? {
        if let cached = cachedShareableContent() { return cached }
        // `onScreenWindowsOnly: true` hid exactly the windows that need this
        // path most. A window that is occluded, minimised, or parked on another
        // Space reports `kCGWindowIsOnscreen == false`, so ScreenCaptureKit left
        // it out and capture fell through to `CGWindowListCreateImage` — which
        // returns nil for GPU-composited windows (Gemini's among them), leaving
        // an app icon where the thumbnail should be. ScreenCaptureKit can shoot
        // those windows perfectly well when it is allowed to see them.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ) else { return nil }
        storeShareableContent(content)
        return content
    }

    @available(macOS 14.0, *)
    private static func cachedShareableContent() -> SCShareableContent? {
        lock.lock(); defer { lock.unlock() }
        guard let c = shareableCache,
              CFAbsoluteTimeGetCurrent() - c.stamp < shareableTTL else { return nil }
        return c.content as? SCShareableContent
    }

    @available(macOS 14.0, *)
    private static func storeShareableContent(_ content: SCShareableContent) {
        lock.lock(); defer { lock.unlock() }
        shareableCache = (CFAbsoluteTimeGetCurrent(), content)
    }

    @available(macOS 14.0, *)
    private static func sckImage(of win: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width  = max(1, Int(filter.contentRect.width  * scale))
        cfg.height = max(1, Int(filter.contentRect.height * scale))
        cfg.ignoreShadowsSingleWindow = true
        // Capture the whole window even when its placement crosses a display edge.
        cfg.ignoreGlobalClipSingleWindow = true
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg) else { return nil }
        return NSImage(cgImage: cg, size: filter.contentRect.size)
    }

    /// Refreshes the last-seen thumbnails of one app's on-screen windows, at a
    /// modest size. What previews fall back to once those windows are hidden
    /// or minimized — macOS captures nothing of a window off screen.
    @available(macOS 14.0, *)
    static func refreshThumbnails(pid: pid_t) async {
        guard let content = await shareableContent() else { return }
        for win in content.windows where win.owningApplication?.processID == pid
            && win.isOnScreen && win.windowLayer == 0
            && win.frame.width >= 100 && win.frame.height >= 80 {
            guard let img = await sckThumbnail(of: win) else { continue }
            cacheThumbnail(img, for: win.windowID)
        }
    }

    /// `sckImage` capped at `keptThumbnailPixels` on the long edge. A preview
    /// card is a few hundred points wide; a full Retina frame is wasted work
    /// and is most of what made the Notch slow to fill in.
    @available(macOS 14.0, *)
    private static func sckThumbnail(of win: SCWindow) async -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        let fit = min(1, Self.keptThumbnailPixels / max(pixels.width, pixels.height, 1))
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(pixels.width * fit))
        cfg.height = max(1, Int(pixels.height * fit))
        cfg.ignoreShadowsSingleWindow = true
        cfg.ignoreGlobalClipSingleWindow = true
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        else { return nil }
        return NSImage(cgImage: cg, size: filter.contentRect.size)
    }

    /// Longest edge of a kept thumbnail, in pixels.
    private static let keptThumbnailPixels: CGFloat = 900

    @available(macOS 14.0, *)
    private static func title(of win: SCWindow) -> String? {
        win.title?.isEmpty == false ? win.title : nil
    }

    private typealias WindowImageCreator = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?

    /// `CGWindowListCreateImage`, resolved once (it's gone from headers but still
    /// exported; the SCK path handles on-screen windows, this covers the rest).
    private static let windowImageCreator: WindowImageCreator? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageCreator.self)
    }()

    private static func cgImage(of id: CGWindowID) -> NSImage? {
        guard let create = windowImageCreator,
              let cg = create(.null, .optionIncludingWindow, id,
                              [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    /// A minimized window's real contents, from its WindowServer backing store.
    /// The only capture path that works once a window is in the Dock — both
    /// ScreenCaptureKit and `CGWindowListCreateImage` give up on it — so a
    /// window minimized before anything cached it (e.g. before MSG launched)
    /// shows itself instead of an icon placeholder. Synchronous, ~0.1s.
    /// Does not help ⌘H-hidden apps: their windows are ordered out entirely.
    private static func minimizedImage(of id: CGWindowID) -> NSImage? {
        guard id != 0 else { return nil }
        var wid = id
        // 1<<11 ignore global clip shape, 1<<9 nominal resolution.
        let options: UInt32 = (1 << 11) | (1 << 9)
        guard let images = CGSHWCaptureWindowList(CGSMainConnectionID(), &wid, 1, options)?
                .takeRetainedValue() as? [CGImage],
              let cg = images.first, cg.width > 1, cg.height > 1 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    /// Captures thumbnails and metadata for on-screen windows on the given screen,
    /// ordered front-to-back by z-index. Used by the Notch preview panel.
    ///
    /// `spaceID` narrows the result to the windows living on that one managed
    /// Space — visible, hidden or minimized (those come back flagged
    /// `isHidden`, drawn greyed out) — in true z-order. The
    /// tiling bar's Desktop preview draws them back to front at their real
    /// frames, so it needs exactly what that Desktop would show.
    @available(macOS 14.0, *)
    static func captureScreenWindows(screen: NSScreen, includeOtherSpaces: Bool = false,
                                     onSpace spaceID: UInt64? = nil,
                                     maxWindows: Int = 24) async -> [NotchWindowItem] {
        var scan = scanScreenWindows(screen: screen, includeOtherSpaces: includeOtherSpaces,
                                     onSpace: spaceID, maxWindows: maxWindows)
        let live = await liveThumbnails(for: scan)
        for i in scan.items.indices {
            if let img = live[scan.items[i].id] { scan.items[i].image = img }
        }
        return scan.items
    }

    /// The result of `scanScreenWindows`: items carrying placeholder or
    /// last-known images, plus what `liveThumbnails` needs to replace them.
    struct ScreenWindowScan {
        var items: [NotchWindowItem]
        /// Minimized windows — renderable via SkyLight, unlike ⌘H-hidden ones.
        let minimized: Set<CGWindowID>
        /// Items still showing an icon placeholder.
        let uncached: Set<CGWindowID>
    }

    /// The window list for `captureScreenWindows`, without capturing any
    /// pixels: each item holds its last thumbnail, else an icon placeholder.
    /// Fast enough to open a preview on, which is the point — the live shots
    /// follow from `liveThumbnails`. Synchronous; call off the main thread.
    static func scanScreenWindows(screen: NSScreen, includeOtherSpaces: Bool = false,
                                  onSpace spaceID: UInt64? = nil,
                                  maxWindows: Int = 24) -> ScreenWindowScan {
        let empty = ScreenWindowScan(items: [], minimized: [], uncached: [])
        // Every window, not just on-screen ones: a hidden app's windows are
        // ordered out but still belong to their Desktop, and previews show
        // them there, greyed out. The Desktop filter below does the narrowing.
        let options: CGWindowListOption = [.excludeDesktopElements]
        let spaceMember = spaceID.flatMap { $0 <= UInt64(Int.max) ? Int($0) : nil }
        let currentSpace = currentManagedSpaceID(for: screen).flatMap { $0 <= UInt64(Int.max) ? Int($0) : nil }
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return empty
        }
        let myPID = ProcessInfo.processInfo.processIdentifier

        // Convert screen frame to Quartz coordinate space (top-left is (0,0) of primary display)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenQuartzRect = CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        struct RawCandidate {
            let id: CGWindowID
            let pid: pid_t
            let appName: String
            let appIcon: NSImage?
            let title: String?
            let bounds: CGRect
            let isOnCurrentSpace: Bool
            let isOnScreen: Bool
            let appHidden: Bool
        }

        var candidates: [RawCandidate] = []
        var pids = Set<pid_t>()
        /// Minimized windows, gathered by the per-app AX pass below — which
        /// already reads that attribute — rather than asked again per window.
        var minimizedAll = Set<CGWindowID>()

        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 80,
                  (includeOtherSpaces || bounds.intersects(screenQuartzRect)),
                  let app = NSRunningApplication(processIdentifier: pid)
            else { continue }
            // Membership before any AX work, so apps with nothing on the
            // Space are never enumerated.
            if let spaceMember, !spacesForWindow(id).contains(spaceMember) { continue }

            if pid == myPID {
                let winName = w[kCGWindowName as String] as? String
                guard let name = winName, !name.isEmpty else { continue }
            } else {
                guard app.activationPolicy == .regular else { continue }
            }

            let appName = app.localizedName ?? (w[kCGWindowOwnerName as String] as? String ?? "App")
            let rawTitle = w[kCGWindowName as String] as? String
            // By Desktop membership, as the control bar decides it. "On screen"
            // is false for a hidden app's windows, which put them under Other
            // while they were still on this Desktop. A window macOS reports no
            // membership for falls back to the on-screen flag.
            let memberships = spacesForWindow(id)
            let isOnCurrentSpace = bounds.intersects(screenQuartzRect) && (memberships.isEmpty
                ? ((w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
                : currentSpace.map { memberships.contains($0) } ?? false)
            guard includeOtherSpaces || spaceMember != nil || isOnCurrentSpace else { continue }
            candidates.append(RawCandidate(
                id: id,
                pid: pid,
                appName: appName,
                appIcon: app.icon,
                title: rawTitle,
                bounds: bounds,
                isOnCurrentSpace: isOnCurrentSpace,
                isOnScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                appHidden: pid != myPID && app.isHidden
            ))
            pids.insert(pid)
        }

        // Filter through isPlausiblyReal per PID so utility/ghost windows are dropped
        var validIDs = Set<CGWindowID>()
        var fullTitlesByID: [CGWindowID: String] = [:]

        // One AX round trip per app, and an app that's slow to answer costs
        // up to its messaging timeout — so the apps are asked side by side
        // rather than one after another.
        struct PIDScan {
            let pid: pid_t
            let bundleID: String?
            let axWins: [AXWindowInfo]
            let entries: [Entry]
            let minimized: Set<CGWindowID>
        }
        let pidList = Array(pids)
        var scans = [PIDScan?](repeating: nil, count: pidList.count)
        let scansLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pidList.count) { i in
            let pid = pidList[i]
            let axWins = accessibilityWindows(pid: pid)
            let axIDs = Set(axWins.compactMap { $0.id != 0 ? $0.id : nil })
            let owner = NSRunningApplication(processIdentifier: pid)
            let ownerBundleID = owner?.bundleIdentifier
            let minimizedIDs = Set(axWins.filter(\.minimized).map(\.id))
            let pEntries = previewEntries(pid: pid, axWins: axWins, axStandard: axStandardIDs(axWins))
                .filter { isPlausiblyReal($0, axIDs: axIDs, ownerBundleID: ownerBundleID,
                                          ownerIsHidden: owner?.isHidden ?? true,
                                          minimizedIDs: minimizedIDs) }
            let scan = PIDScan(pid: pid, bundleID: ownerBundleID, axWins: axWins,
                               entries: pEntries, minimized: minimizedIDs)
            scansLock.lock()
            scans[i] = scan
            scansLock.unlock()
        }

        // Title resolution stays serial: it runs AppleScript for browsers.
        for scan in scans.compactMap({ $0 }) {
            minimizedAll.formUnion(scan.minimized)
            let resolved = resolveFullTitles(pid: scan.pid, bundleID: scan.bundleID,
                                             entries: scan.entries, axWins: scan.axWins)
            for e in resolved {
                validIDs.insert(e.id)
                if let t = e.title {
                    fullTitlesByID[e.id] = t
                }
            }
        }

        // A title is not evidence of a usable window: dismissed onboarding and
        // utility surfaces can retain both a title and full-sized bounds.
        let filteredCandidates = candidates.filter { c in
            validIDs.contains(c.id)
        }

        // Out of sight the same way `isWindowHidden` judges it, from what this
        // pass already knows — no extra round trip per window.
        func isHidden(_ c: RawCandidate) -> Bool {
            c.pid != myPID && (c.appHidden || minimizedAll.contains(c.id) || (c.isOnCurrentSpace && !c.isOnScreen))
        }

        // Current Space is pulled forward; within each space group, visible
        // windows are on the left and hidden windows are sorted to the right.
        let sortedCandidates = spaceID != nil
            ? filteredCandidates.sorted { a, b in
                if isHidden(a) != isHidden(b) { return !isHidden(a) && isHidden(b) }
                return false
            }
            : filteredCandidates.sorted { a, b in
                if a.isOnCurrentSpace != b.isOnCurrentSpace {
                    return a.isOnCurrentSpace && !b.isOnCurrentSpace
                }
                if isHidden(a) != isHidden(b) {
                    return !isHidden(a) && isHidden(b)
                }
                return false
            }

        let finalCandidates = Array(sortedCandidates.prefix(maxWindows))
        guard !finalCandidates.isEmpty else { return empty }

        var results: [NotchWindowItem] = []
        var uncached = Set<CGWindowID>()
        var placeholders: [pid_t: NSImage] = [:]
        for c in finalCandidates {
            let img: NSImage
            if let cached = cachedThumbnail(for: c.id) {
                img = cached
            } else {
                uncached.insert(c.id)
                if let p = placeholders[c.pid] {
                    img = p
                } else {
                    img = placeholderImage(pid: c.pid)
                    placeholders[c.pid] = img
                }
            }
            results.append(NotchWindowItem(
                id: c.id,
                pid: c.pid,
                appName: c.appName,
                appIcon: c.appIcon,
                title: fullTitlesByID[c.id] ?? c.title,
                bounds: c.bounds,
                image: img,
                isOtherSpace: !c.isOnCurrentSpace,
                isHidden: isHidden(c)
            ))
        }

        return ScreenWindowScan(items: results, minimized: minimizedAll, uncached: uncached)
    }

    /// Live pictures for a scan's items, keyed by window id, all captured
    /// side by side at thumbnail size. Items with nothing newer are left out.
    ///
    /// Visible windows are shot through ScreenCaptureKit. A hidden window
    /// keeps its last picture — macOS captures nothing of a window off screen,
    /// and each attempt only fails after a delay — unless it has none and is
    /// minimized, which SkyLight can still render.
    @available(macOS 14.0, *)
    static func liveThumbnails(for scan: ScreenWindowScan) async -> [CGWindowID: NSImage] {
        let visible = scan.items.filter { !$0.isHidden }
        let minimizedUncached = scan.items.filter {
            $0.isHidden && scan.uncached.contains($0.id) && scan.minimized.contains($0.id)
        }
        guard !visible.isEmpty || !minimizedUncached.isEmpty else { return [:] }

        var sckByID: [CGWindowID: SCWindow] = [:]
        if !visible.isEmpty, let content = await shareableContent() {
            for w in content.windows { sckByID[w.windowID] = w }
        }

        return await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for item in visible {
                let id = item.id
                let scw = sckByID[id]
                group.addTask {
                    if let scw, let img = await sckThumbnail(of: scw) { return (id, img) }
                    return (id, cgImage(of: id))
                }
            }
            for item in minimizedUncached {
                let id = item.id
                group.addTask { (id, minimizedImage(of: id)) }
            }
            var out: [CGWindowID: NSImage] = [:]
            for await (id, img) in group {
                guard let img else { continue }
                cacheThumbnail(img, for: id)
                out[id] = img
            }
            return out
        }
    }
}

// MARK: - WindowThumbnailKeeper

/// Keeps a recent picture of the windows most likely to vanish next, so a
/// preview can still show them — greyed out — once they're hidden or
/// minimized. macOS captures nothing of a window that's off screen; the only
/// picture a hidden window can have is one taken before it went.
///
/// ⌘H and minimize act on the frontmost app, so that is the app kept fresh:
/// when it comes forward, when the Desktop changes, and on a slow timer while
/// it stays in front. The timer runs only while the screen can be seen.
@available(macOS 14.0, *)
final class WindowThumbnailKeeper {
    static let shared = WindowThumbnailKeeper()

    /// How stale the frontmost app's pictures may get.
    private static let refreshInterval: TimeInterval = 20
    /// Lets a newly frontmost app draw before it's captured.
    private static let settleDelay: TimeInterval = 0.6

    private var running = false
    private var inFlight = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSoon()
            })
        }
        PresentationState.shared.addObserver { [weak self] in self?.updateTimer() }
        updateTimer()
        refreshSoon()
    }

    private func updateTimer() {
        guard running, PresentationState.shared.canPresent else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = Self.refreshInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard running, !inFlight, PresentationState.shared.canPresent, CGPreflightScreenCaptureAccess(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular, !app.isHidden,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        inFlight = true
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            await WindowPreviewCapture.refreshThumbnails(pid: pid)
            self?.inFlight = false
        }
    }
}
