import AppKit
import ApplicationServices
import Darwin
import ScreenCaptureKit

/// Private AX call mapping an `AXUIElement` window back to its `CGWindowID`.
/// Used to tell genuine top-level windows (including minimized ones, which stay
/// in the AX window list) apart from uncapturable phantom/helper windows.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

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

/// Shared window-thumbnail capture used by both the Tray HUD and the Dock hover
/// previews. The authoritative window list comes from `CGWindowList` (which spans
/// every Space), and each window is rendered with ScreenCaptureKit when it's on
/// the active Space (crisp, shadow-free) or the CGWindowList image API otherwise.
enum WindowPreviewCapture {

    private struct Entry {
        let id: CGWindowID
        let title: String?
        let bounds: CGRect
    }

    @available(macOS 14.0, *)
    static func capture(pid: pid_t, maxWindows: Int = 12) async -> [CapturedWindow] {
        guard pid > 0 else { return [] }

        let genuineIDs = genuineWindowIDs(pid: pid)
        let axWins = accessibilityWindows(pid: pid)
        let entries = dedupByRect(previewEntries(pid: pid, axWins: axWins)
            .filter { genuineIDs.contains($0.id) })
            .prefix(maxWindows)

        // Map of on-screen SCWindows by id for high-quality capture.
        var sckByID: [CGWindowID: SCWindow] = [:]
        if let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) {
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
                let img = thumbnailCache[e.id] ?? placeholderImage(pid: pid)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            }
        }

        if captured.isEmpty {
            if let placeholder = appPlaceholderWindow(pid: pid) {
                return [placeholder]
            }
        }
        return captured
    }

    /// Synchronous CGWindowList-only capture (used where ScreenCaptureKit isn't
    /// available). Spans every Space.
    static func captureCG(pid: pid_t, maxWindows: Int = 12) -> [CapturedWindow] {
        guard pid > 0 else { return [] }
        let genuineIDs = genuineWindowIDs(pid: pid)
        let axWins = accessibilityWindows(pid: pid)
        let entries = dedupByRect(previewEntries(pid: pid, axWins: axWins)
            .filter { genuineIDs.contains($0.id) })
            .prefix(maxWindows)

        var captured: [CapturedWindow] = []
        for e in entries {
            if let img = cgImage(of: e.id) {
                cacheThumbnail(img, for: e.id)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            } else {
                let img = thumbnailCache[e.id] ?? placeholderImage(pid: pid)
                captured.append(CapturedWindow(id: e.id, image: img, title: e.title, bounds: e.bounds))
            }
        }

        if captured.isEmpty {
            if let placeholder = appPlaceholderWindow(pid: pid) {
                return [placeholder]
            }
        }
        return captured
    }



    /// True when the app has at least one window worth previewing — a genuine
    /// (AX-backed) visible/other-Space window, or any minimized window. Cheap:
    /// enumerates windows but captures no images. Lets the Dock controller hide
    /// the panel the instant the cursor glides onto a window-less tile.
    static func hasPreviewableWindows(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let genuineIDs = genuineWindowIDs(pid: pid)
        let entries = windowEntries(pid: pid)
        if entries.contains(where: { genuineIDs.contains($0.id) }) {
            return true
        }
        let axWins = accessibilityWindows(pid: pid)
        return axWins.contains { $0.minimized && $0.id != 0 && genuineIDs.contains($0.id) }
    }

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

    // MARK: Thumbnail cache (for minimized windows)

    /// Last successful thumbnail per window id, so a window that later minimizes
    /// (and becomes uncapturable) can still show its real last-seen image.
    /// Bounded to `thumbnailCacheLimit`, evicting the oldest insertions.
    private static var thumbnailCache: [CGWindowID: NSImage] = [:]
    private static var thumbnailOrder: [CGWindowID] = []
    private static let thumbnailCacheLimit = 80

    private static func cacheThumbnail(_ image: NSImage, for id: CGWindowID) {
        guard id != 0 else { return }
        if thumbnailCache[id] == nil { thumbnailOrder.append(id) }
        thumbnailCache[id] = image
        while thumbnailOrder.count > thumbnailCacheLimit {
            let old = thumbnailOrder.removeFirst()
            thumbnailCache[old] = nil
        }
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
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.map { w in
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

    private static func axFrame(of element: AXUIElement) -> CGRect? {
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

    private static func windowEntries(pid: pid_t) -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return [] }
        let entries = list.compactMap { info -> Entry? in
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
        .sorted { a, b in
            let areaA = a.bounds.width * a.bounds.height
            let areaB = b.bounds.width * b.bounds.height
            if areaA != areaB { return areaA > areaB }
            // Equal area — e.g. a window zoomed to fill the screen and a same-app
            // helper twin both snapped to the identical rect. Sort the titled one
            // first so the later rect-dedup keeps the genuine window, not the helper.
            return (a.title != nil ? 0 : 1) < (b.title != nil ? 0 : 1)
        }
        return entries
    }

    /// Drops duplicate tiles sharing the same on-screen rect (some apps report
    /// shadow/helper twins at identical bounds, which would render twice). Run
    /// *after* the genuine-window filter so a non-genuine twin can never evict
    /// the real window — when a window is zoomed to fill the screen, the real
    /// window and its helper collapse onto the identical screen rect, and the
    /// helper must not be the survivor.
    private static func dedupByRect<S: Sequence>(_ entries: S) -> [Entry] where S.Element == Entry {
        var seenRects = Set<String>()
        return entries.filter { e in
            let key = "\(Int(e.bounds.minX)),\(Int(e.bounds.minY)),\(Int(e.bounds.width)),\(Int(e.bounds.height))"
            return seenRects.insert(key).inserted
        }
    }

    // MARK: Per-window image

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

    private static func cgImage(of id: CGWindowID) -> NSImage? {
        typealias Creator = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
        let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage")
        let create = unsafeBitCast(sym, to: Creator.self)
        guard let cg = create(.null, .optionIncludingWindow, id,
                              [.boundsIgnoreFraming, .bestResolution]) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }

    private static func genuineWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        var genuine = Set<CGWindowID>()

        // 1. Add standard AX windows on the current space
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for w in windows {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(w, &wid) == .success && wid != 0 {
                    genuine.insert(wid)
                }
            }
        }

        // 2. Brute force remote tokens to find minimized or other space windows
        var token = Data(count: 20)
        token.replaceSubrange(0 ..< 4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4 ..< 8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8 ..< 12, with: withUnsafeBytes(of: Int32(0x636F_636F)) { Data($0) })

        for axId: AXUIElementID in 0 ..< 1000 {
            token.replaceSubrange(12 ..< 20, with: withUnsafeBytes(of: axId) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(el, &wid)
            guard wid != 0, !genuine.contains(wid) else { continue }

            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subrole)
            if let sub = subrole as? String, [kAXStandardWindowSubrole, kAXDialogSubrole].contains(sub) {
                genuine.insert(wid)
                continue
            }

            var closeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &closeButton) == .success {
                genuine.insert(wid)
                continue
            }

            var minimizeButton: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXMinimizeButtonAttribute as CFString, &minimizeButton) == .success {
                genuine.insert(wid)
                continue
            }
        }

        return genuine
    }
}
