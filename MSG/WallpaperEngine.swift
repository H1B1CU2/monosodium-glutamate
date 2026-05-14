import AppKit

final class WallpaperEngine {

    enum Mode { case live, editing }

    static let shared = WallpaperEngine(settings: .shared)

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "msg.wallpaper", qos: .userInitiated)

    private(set) var mode: Mode = .live
    private var originalURLs: [String: URL] = [:]
    private var placementCache: [String: Placement] = [:]
    private var toggle: [String: Bool] = [:]
    private var pollTimer: Timer?
    private var idleTimer: DispatchSourceTimer?
    private var spaceObserver: NSObjectProtocol?
    private var generation = 0

    // MARK: - Lifecycle

    private init(settings: AppSettings) { self.settings = settings }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.bake(generation: 0)
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }

        // Space switches surface a different wallpaper per Space — react
        // immediately instead of waiting for the next 1s poll.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkForChanges()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
        cancelIdleTimer()
    }

    func restore() {
        stop()
        for (uuid, url) in originalURLs {
            if let screen = NSScreen.screens.first(where: { Self.screenUUID($0) == uuid }) {
                Self.setWallpaper(url: url, for: screen)
            }
        }
        let dir = Self.wallpaperDir()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        originalURLs.removeAll()
        placementCache.removeAll()
        toggle.removeAll()
        mode = .live
    }

    // MARK: - Editing lifecycle

    func beginEditing() {
        guard mode != .editing else { return }
        cancelIdleTimer()
        generation += 1
        mode = .editing
        let entryGen = generation

        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen) else { continue }
            revertOrSync(for: screen, uuid: uuid, entryGen: entryGen)
        }
    }

    /// Reverts the desktop on `screen` to the cached original (so the slider
    /// can preview clean), but defers if the current read looks like one of
    /// our files — `NSWorkspace.desktopImageURL(for:)` is briefly stale right
    /// after a user wallpaper change. The deferred re-check catches that.
    private func revertOrSync(for screen: NSScreen, uuid: String, entryGen: Int) {
        let cur = Self.wallpaperURL(for: screen)

        // Live read shows a user wallpaper — sync cache, don't touch the desktop.
        if let cur, !Self.isMSGFile(url: cur) {
            originalURLs[uuid] = cur
            placementCache[uuid] = Self.readPlacement(for: screen)
            return
        }

        // Live read shows one of ours. Could be genuine (we set it last bake) or
        // could be a stale API response masking an in-flight user change. Wait
        // for the system to settle, then decide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  self.mode == .editing,
                  entryGen == self.generation else { return }

            let curNow = Self.wallpaperURL(for: screen)
            if let curNow, !Self.isMSGFile(url: curNow) {
                // The user change came through after all — adopt it.
                self.originalURLs[uuid] = curNow
                self.placementCache[uuid] = Self.readPlacement(for: screen)
                return
            }

            // Truly our file. Safe to revert to cached original.
            guard self.ensureOriginal(for: screen, uuid: uuid),
                  let orig = self.originalURLs[uuid] else { return }
            Self.setWallpaper(url: orig, for: screen)
        }
    }

    func commit() {
        guard mode != .live else { return }
        cancelIdleTimer()
        mode = .live
        bake()
    }

    func noteUserInteraction() {
        if mode == .live { beginEditing() }
        cancelIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5)
        timer.setEventHandler { [weak self] in
            self?.commit()
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: - Bake

    private func bake(generation gen: Int = 0) {
        let gen = gen > 0 ? gen : { generation += 1; return generation }()
        let bottom = settings.bottomCornersEnabled
        var jobs: [(NSScreen, String, URL)] = []

        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen) else { continue }

            // Refresh cache from the live desktop in case the user changed
            // their wallpaper between the last 3s poll and this bake. Without
            // this, we'd bake the previous original on top of a stale path
            // and the desktop "reverts" to the old wallpaper.
            if let cur = Self.wallpaperURL(for: screen),
               !Self.isMSGFile(url: cur),
               cur != originalURLs[uuid] {
                originalURLs[uuid] = cur
                placementCache[uuid] = Self.readPlacement(for: screen)
            }

            if !ensureOriginal(for: screen, uuid: uuid) { continue }
            if let orig = originalURLs[uuid] {
                jobs.append((screen, uuid, orig))
            }
        }

        guard !jobs.isEmpty else { return }

        queue.async { [weak self] in
            for (screen, uuid, sourceURL) in jobs {
                guard let self else { return }
                if gen > 0, gen < self.generation { return }
                guard let cg = Self.loadImage(url: sourceURL) else { continue }
                guard let ctx = Self.createContext(for: screen) else { continue }

                let w = CGFloat(ctx.width)
                let h = CGFloat(ctx.height)
                let placement = self.placement(for: uuid, screen: screen)
                let drawRect = Self.wallpaperDrawRect(
                    imageSize: CGSize(width: cg.width, height: cg.height),
                    screenPixelSize: CGSize(width: w, height: h),
                    placement: placement
                )
                ctx.draw(cg, in: drawRect)

                if bottom {
                    ctx.setFillColor(CGColor.black)
                    // Per-display corner radius — matches overlay behaviour
                    let isBuiltin = screen.isBuiltin
                    let radius = isBuiltin
                        ? settings.cornerRadius
                        : settings.extCornerRadius(for: uuid)
                    let r = radius * screen.backingScaleFactor
                    Self.fillCorner(ctx: ctx, x: 0,          y: 0, r: r, dx:  1, dy:  1)
                    Self.fillCorner(ctx: ctx, x: CGFloat(w), y: 0, r: r, dx: -1, dy:  1)
                }

                guard let out = ctx.makeImage() else { continue }
                let (outURL, altURL) = Self.exportPNG(image: out, uuid: uuid, toggle: &self.toggle)
                guard let outURL else { continue }

                DispatchQueue.main.async {
                    // Final guard: if the user picked a new wallpaper while
                    // we were baking, the desktop already shows a non-MSG URL
                    // different from our source. Don't clobber their choice.
                    if let curNow = Self.wallpaperURL(for: screen),
                       !Self.isMSGFile(url: curNow),
                       curNow != sourceURL {
                        return
                    }
                    Self.setWallpaper(url: outURL, for: screen)
                    // Single-file cache: drop the previous alternate now that
                    // macOS has switched to the new file.
                    if let altURL {
                        try? FileManager.default.removeItem(at: altURL)
                    }
                }
            }
        }
    }

    // MARK: - Change detection

    private func checkForChanges() {
        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen) else { continue }
            let cur = Self.wallpaperURL(for: screen)

            switch mode {
            case .live:
                // Stuck? Try to capture clean wallpaper
                if originalURLs[uuid] == nil || Self.isMSGFile(url: originalURLs[uuid]!) {
                    if let cur, !Self.isMSGFile(url: cur) {
                        originalURLs[uuid] = cur
                        placementCache[uuid] = Self.readPlacement(for: screen)
                        bake()
                    }
                    continue
                }
                // External change — recapture and re-bake
                if let cur, cur != originalURLs[uuid], !Self.isMSGFile(url: cur) {
                    originalURLs[uuid] = cur
                    placementCache[uuid] = Self.readPlacement(for: screen)
                    bake()
                }

            case .editing:
                // While editing, show new wallpapers plain (no bake)
                if let cur, !Self.isMSGFile(url: cur), cur != originalURLs[uuid] {
                    originalURLs[uuid] = cur
                    placementCache[uuid] = Self.readPlacement(for: screen)
                    DispatchQueue.main.async {
                        Self.setWallpaper(url: cur, for: screen)
                    }
                }
            }
        }
    }

    // MARK: - Original tracking

    private func ensureOriginal(for screen: NSScreen, uuid: String) -> Bool {
        if let orig = originalURLs[uuid], !Self.isMSGFile(url: orig) { return true }
        if let cur = Self.wallpaperURL(for: screen), !Self.isMSGFile(url: cur) {
            originalURLs[uuid] = cur
            return true
        }
        return false
    }

    // MARK: - Placement

    enum Placement { case fill, fit, stretch, center, tile }

    private func placement(for uuid: String, screen: NSScreen) -> Placement {
        if let p = placementCache[uuid] { return p }
        let p = Self.readPlacement(for: screen)
        placementCache[uuid] = p
        return p
    }

    static func readPlacement(for screen: NSScreen) -> Placement {
        guard let uuid = screenUUID(screen) else { return .fill }
        let db = NSHomeDirectory() + "/Library/Application Support/Dock/desktoppicture.db"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [db, "SELECT value FROM data WHERE key LIKE '%\(uuid)%' LIMIT 1"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let i = Int(digits), i >= 2, i <= 5 {
            switch i {
            case 2: return .fit
            case 3: return .stretch
            case 4: return .center
            case 5: return .tile
            default: break
            }
        }
        return .fill
    }

    static func wallpaperDrawRect(imageSize: CGSize, screenPixelSize: CGSize, placement: Placement) -> CGRect {
        let iw = imageSize.width, ih = imageSize.height
        let sw = screenPixelSize.width, sh = screenPixelSize.height
        switch placement {
        case .stretch:
            return CGRect(origin: .zero, size: CGSize(width: sw, height: sh))
        case .center:
            return CGRect(x: (sw - iw) / 2, y: (sh - ih) / 2, width: iw, height: ih)
        case .fit:
            let s = min(sw / iw, sh / ih)
            return CGRect(x: (sw - iw * s) / 2, y: (sh - ih * s) / 2, width: iw * s, height: ih * s)
        default:
            let s = max(sw / iw, sh / ih)
            return CGRect(x: (sw - iw * s) / 2, y: (sh - ih * s) / 2, width: iw * s, height: ih * s)
        }
    }

    // MARK: - Image loading / export

    static func loadImage(url: URL) -> CGImage? {
        if let s = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(s, 0, nil) { return cg }
        if let ns = NSImage(contentsOf: url),
           let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        return nil
    }

    static func createContext(for screen: NSScreen) -> CGContext? {
        let frame = screen.frame
        let scale = screen.backingScaleFactor
        return CGContext(
            data: nil, width: Int(frame.width * scale), height: Int(frame.height * scale),
            bitsPerComponent: 8, bytesPerRow: Int(frame.width * scale) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }

    static let signature = "MSG-Wallpaper-Signature-v1"

    static func exportPNG(image: CGImage, uuid: String, toggle: inout [String: Bool]) -> (URL?, URL?) {
        let dir = wallpaperDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let useA = !(toggle[uuid] ?? false)
        toggle[uuid] = useA
        let outURL = dir.appendingPathComponent("\(uuid)_\(useA ? "a" : "b").png")
        let altURL = dir.appendingPathComponent("\(uuid)_\(useA ? "b" : "a").png")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)
        else { return (nil, nil) }
        // PNGComment is silently dropped by ImageIO's writer — use PNGSoftware,
        // which actually round-trips through a tEXt chunk.
        let props: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGSoftware as String: signature
            ]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return (nil, nil) }
        return (outURL, altURL)
    }

    /// True when the URL points at one of our baked wallpapers, either because
    /// it sits in our cache dir (fast path) or because the PNG carries our
    /// signature in its tEXt Software chunk (slow path — survives a move).
    static func isMSGFile(url: URL) -> Bool {
        if url.path.contains(wallpaperDir().path) { return true }
        guard url.pathExtension.lowercased() == "png",
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any],
              let software = png[kCGImagePropertyPNGSoftware as String] as? String
        else { return false }
        return software == signature
    }

    // MARK: - System wallpaper

    static func wallpaperURL(for screen: NSScreen) -> URL? {
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) { return url }
        let src = "tell application \"System Events\" to get picture of desktop 1"
        if let r = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !r.isEmpty, r != "missing value" {
            return URL(fileURLWithPath: r)
        }
        return nil
    }

    static func setWallpaper(url: URL, for screen: NSScreen) {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            let src = "tell application \"System Events\" to set picture of desktop 1 to \"\(url.path)\""
            _ = NSAppleScript(source: src)?.executeAndReturnError(nil)
        }
    }

    // MARK: - Drawing

    static func fillCorner(ctx: CGContext, x: CGFloat, y: CGFloat, r: CGFloat, dx: CGFloat, dy: CGFloat) {
        let sa: CGFloat = dy < 0 ? .pi / 2 : .pi * 1.5
        let ea: CGFloat = dx > 0 ? .pi : 0
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x + dx * r, y: y))
        ctx.addArc(center: CGPoint(x: x + dx * r, y: y + dy * r),
                   radius: r, startAngle: sa, endAngle: ea,
                   clockwise: dx * dy > 0)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Helpers

    private func cancelIdleTimer() {
        idleTimer?.cancel(); idleTimer = nil
    }

    static func wallpaperDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("MSG/Wallpapers")
    }

    static func screenUUID(_ screen: NSScreen) -> String? {
        guard let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let u = CGDisplayCreateUUIDFromDisplayID(dID),
              let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String? else { return nil }
        return s
    }
}
