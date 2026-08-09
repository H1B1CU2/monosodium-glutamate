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

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

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

private typealias AXUIElementID = UInt64

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

    /// Cached remote-token sweeps (the only expensive enumeration), keyed by pid.
    private static var remoteIDsCache: [pid_t: (stamp: CFAbsoluteTime, ids: Set<CGWindowID>)] = [:]

    /// (stamp, `SCShareableContent`) — typed `Any` so the stored property needs
    /// no availability gate under the pre-14 deployment target.
    private static var shareableCache: (stamp: CFAbsoluteTime, content: Any)?

    private static let previewableTTL: CFAbsoluteTime = 2.0
    private static let remoteIDsTTL: CFAbsoluteTime = 4.0
    private static let shareableTTL: CFAbsoluteTime = 1.5

    // MARK: Capture

    @available(macOS 14.0, *)
    static func capture(pid: pid_t, maxWindows: Int = 12) async -> [CapturedWindow] {
        guard pid > 0 else { return [] }

        // Genuine = fresh standard AX windows (current Space + minimized) plus
        // the cached remote-token sweep (windows living on other Spaces).
        let axWins = accessibilityWindows(pid: pid)
        var genuineIDs = remoteTokenWindowIDs(pid: pid)
        for w in axWins where w.id != 0 { genuineIDs.insert(w.id) }

        let entries = dedupByRect(previewEntries(pid: pid, axWins: axWins)
            .filter { genuineIDs.contains($0.id) })
            .prefix(maxWindows)

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
            } else {
                // Uncapturable but a genuine top-level window (e.g. minimized or on
                // another Space) — reuse the last thumbnail captured this session,
                // else an icon placeholder.
                let img = cachedThumbnail(for: e.id) ?? placeholderImage(pid: pid)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            }
        }

        if captured.isEmpty, let placeholder = appPlaceholderWindow(pid: pid) {
            return [placeholder]
        }
        return captured
    }

    /// True when the app has at least one window worth previewing. Cheap by
    /// design — one CGWindowList sweep and at most one AX window-list fetch, no
    /// remote-token brute force — because the Dock controller calls it from the
    /// mouse-move path. Verdicts are cached briefly per app.
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
        var value = !windowEntries(pid: pid).isEmpty
        if !value {
            // No listed windows — the app may still have minimized ones.
            value = accessibilityWindows(pid: pid).contains { $0.minimized && $0.id != 0 }
        }

        lock.lock()
        previewableCache[pid] = (now, value)
        lock.unlock()
        return value
    }

    // MARK: Raising & closing

    /// Brings the given window to the front: activates the app, un-minimizes the
    /// window, switches to its Space, and raises it topmost with keyboard focus.
    /// The slow AX lookup runs on the caller's (non-main) executor; only the app
    /// activation hops to the main actor.
    @available(macOS 14.0, *)
    static func raiseWindow(pid: pid_t, windowID: CGWindowID, fallbackBounds: CGRect) async {
        await MainActor.run {
            _ = NSRunningApplication(processIdentifier: pid)?.activate(from: .current, options: [])
        }

        var target = axWindow(pid: pid, windowID: windowID)

        // Placeholder card (id 0): fall back to the standard AX window closest
        // to the captured bounds, else the first one.
        if target == nil && windowID == 0 {
            let windows = standardAXWindows(pid: pid)
            var bestDist = CGFloat.greatestFiniteMagnitude
            for win in windows {
                guard let frame = axFrame(of: win) else { continue }
                let dx = frame.midX - fallbackBounds.midX
                let dy = frame.midY - fallbackBounds.midY
                let dist = dx * dx + dy * dy
                if dist < bestDist { bestDist = dist; target = win }
            }
            if target == nil { target = windows.first }
        }

        // Un-minimize if needed.
        if let win = target {
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &mini)
            if (mini as? Bool) == true {
                AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }

        // Bring this exact window's process+window to the front via SkyLight.
        if windowID != 0 {
            var psn = ProcessSerialNumber()
            if GetProcessForPID(pid, &psn) == noErr {
                _ = _SLPSSetFrontProcessWithOptions(&psn, windowID, 0x200) // kCPSUserGenerated
                makeKeyWindow(psn: &psn, windowID: windowID)
            }
        }

        // Raise the window and make it the main window topmost.
        if let win = target {
            AXUIElementSetAttributeValue(win, kAXMainWindowAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
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

    /// Finds the `AXUIElement` for a specific window id: the app's standard AX
    /// list first (cheap; covers the current Space and minimized windows), then
    /// the remote-token brute force (windows on other Spaces).
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard windowID != 0 else { return nil }

        for w in standardAXWindows(pid: pid) {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success, wid == windowID { return w }
        }

        var token = remoteToken(pid: pid)
        for axId: AXUIElementID in 0 ..< 1000 {
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            if wid == windowID { return el }
        }
        return nil
    }

    /// Posts the two raw window events that make `windowID` the key window so
    /// keyboard focus follows it across the Space switch (AltTab's technique).
    private static func makeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
        var wid = windowID
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<CGWindowID>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x02
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x01
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
    }

    /// The app's real top-level windows via AX. Empty when AX is unavailable
    /// (callers then trust the CGWindowList result as-is). Used both to drop
    /// uncapturable phantom/helper windows and to surface minimized ones.
    private static func accessibilityWindows(pid: pid_t) -> [AXWindowInfo] {
        standardAXWindows(pid: pid).map { w in
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(w, &wid)

            var miniRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &miniRef)

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String).flatMap { $0.isEmpty ? nil : $0 }

            return AXWindowInfo(id: wid, title: title,
                                frame: axFrame(of: w) ?? .zero,
                                minimized: (miniRef as? Bool) == true)
        }
    }

    /// The app's standard AX window list — one IPC round-trip. Covers windows on
    /// the current Space plus minimized ones; other-Space windows need the
    /// remote-token sweep.
    private static func standardAXWindows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Window ids discovered by brute-forcing AX remote tokens — the only way to
    /// see windows living on other Spaces. Up to ~1000 sync IPC round-trips, so
    /// sweeps are cached per app and must stay off the main thread's hot paths.
    private static func remoteTokenWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if let c = remoteIDsCache[pid], now - c.stamp < remoteIDsTTL {
            lock.unlock()
            return c.ids
        }
        lock.unlock()

        var found = Set<CGWindowID>()
        var token = remoteToken(pid: pid)
        for axId: AXUIElementID in 0 ..< 1000 {
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            guard wid != 0, !found.contains(wid) else { continue }

            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
            if let sub = subrole as? String, [kAXStandardWindowSubrole, kAXDialogSubrole].contains(sub) {
                found.insert(wid)
                continue
            }

            var closeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &closeButton) == .success {
                found.insert(wid)
                continue
            }

            var minimizeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXMinimizeButtonAttribute as CFString, &minimizeButton) == .success {
                found.insert(wid)
                continue
            }
        }

        lock.lock()
        remoteIDsCache[pid] = (CFAbsoluteTimeGetCurrent(), found)
        lock.unlock()
        return found
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
    private static func previewEntries(pid: pid_t, axWins: [AXWindowInfo]) -> [Entry] {
        var entries = windowEntries(pid: pid)
        let seen = Set(entries.map(\.id))
        for w in axWins where w.minimized && w.id != 0 && !seen.contains(w.id) {
            entries.append(Entry(id: w.id, title: w.title, bounds: w.frame))
        }
        return entries
    }

    /// The app's plausibly-real windows from `CGWindowList` (spans every Space),
    /// kept in the list's natural front-to-back z-order so the frontmost window
    /// leads the preview row.
    private static func windowEntries(pid: pid_t) -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info -> Entry? in
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t, wPid == pid,
                  let wID = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width  = bounds["Width"]  as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width >= 200, height >= 100,
                  // Skip invisible windows (alpha ~0) — hidden Electron helpers etc.
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { return nil }
            let name = info[kCGWindowName as String] as? String
            return Entry(id: wID, title: (name?.isEmpty == false) ? name : nil,
                         bounds: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    /// Drops duplicate tiles sharing the same on-screen rect (some apps report
    /// shadow/helper twins at identical bounds, which would render twice),
    /// preferring the titled entry so a helper twin can never evict the genuine
    /// window it shadows — e.g. a window zoomed to fill the screen and a same-app
    /// helper both snapped to the identical rect. Preserves z-order.
    private static func dedupByRect(_ entries: [Entry]) -> [Entry] {
        var kept: [Entry] = []
        var indexForRect: [String: Int] = [:]
        for e in entries {
            let key = "\(Int(e.bounds.minX)),\(Int(e.bounds.minY)),\(Int(e.bounds.width)),\(Int(e.bounds.height))"
            if let i = indexForRect[key] {
                if kept[i].title == nil, e.title != nil { kept[i] = e }
            } else {
                indexForRect[key] = kept.count
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
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
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
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        guard let cg = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg) else { return nil }
        return NSImage(cgImage: cg, size: filter.contentRect.size)
    }

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
}
