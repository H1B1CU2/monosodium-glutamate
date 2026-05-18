import AppKit

final class WallpaperEngine {

    // MARK: - Types

    enum Placement: Int, Codable { case fill = 1, fit = 2, stretch = 3, center = 4, tile = 5 }

    private struct ScreenState {
        var baselineURL: URL
        var placement: Placement
        var toggle: Bool = false
    }

    // MARK: - Singleton

    static let shared = WallpaperEngine(settings: AppSettings.shared)

    // MARK: - Properties

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "msg.wallpaper", qos: .utility)

    private var screens: [String: ScreenState] = [:]
    private var pollTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var bakeItem: DispatchWorkItem?
    private var lastBakedURLs: [String: URL] = [:]

    var isFetched: Bool { !screens.isEmpty }

    func baselineImage(for screen: NSScreen) -> NSImage? {
        guard let uuid = Self.screenUUID(screen),
              let url = screens[uuid]?.baselineURL else { return nil }
        guard let cg = Self.loadImage(url: url) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Fires when an external wallpaper change is detected (user changed wallpaper in System Settings).
    var onExternalChange: (() -> Void)?
    /// Stays true from the moment an external change is detected until fetch() is called.
    /// Survives settings-pane navigation so auto-apply stays suppressed until resolved.
    private(set) var externalChangePending: Bool = false

    // MARK: - Init

    private init(settings: AppSettings) { self.settings = settings }

    // MARK: - Start / Stop

    func start() {
        loadPersistedBaselines()
        if screens.isEmpty {
            recoverBrokenDesktopIfNeeded()
            fetch()
        }
        bake()
        beginPolling()

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reapplyToAllSpaces()
            // Chase reads: the macOS transition animation may complete slightly after
            // the notification fires, so re-apply a couple of times to close the gap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)  { self?.reapplyToAllSpaces() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)  { self?.reapplyToAllSpaces() }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            spaceObserver = nil
        }
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
            screenObserver = nil
        }
        bakeItem?.cancel(); bakeItem = nil
    }

    func restore() {
        stop()
        for (uuid, state) in screens {
            if let screen = NSScreen.screens.first(where: { Self.screenUUID($0) == uuid }) {
                Self.setWallpaper(url: state.baselineURL, for: screen)
            }
        }
        let dir = Self.wallpaperDir()
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        clearPersistedBaselines()
        screens.removeAll()
    }

    // MARK: - Editing mode

    /// Reverts the desktop to the baseline (uncornered) so the user sees a clean
    /// preview in the Cornermization pane. The CornerWindow overlay still shows
    /// the current corner settings as a live preview.
    func showBaseline() {
        for (uuid, state) in screens {
            if let screen = NSScreen.screens.first(where: { Self.screenUUID($0) == uuid }) {
                Self.setWallpaper(url: state.baselineURL, for: screen)
            }
        }
    }

    /// Re-applies the last baked PNG to all screens (undoes showBaseline).
    /// Call when leaving the Cornermization pane without pending changes.
    func restoreBakedWallpaper() {
        guard !externalChangePending else { return }
        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen),
                  let url = lastBakedURLs[uuid] else { continue }
            Self.setWallpaper(url: url, for: screen)
        }
    }

    // MARK: - Screen change

    /// Fetches baseline for any newly connected display and re-bakes.
    private func handleScreenChange() {
        var changed = false
        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen) else { continue }
            if screens[uuid] != nil { continue }
            guard let url = Self.wallpaperURL(for: screen),
                  !Self.isMSGFile(url: url) else { continue }
            screens[uuid] = ScreenState(baselineURL: url, placement: Self.readPlacement(for: screen))
            changed = true
        }
        if changed { persistBaselines(); bake() }
    }

    // MARK: - Fetch

    /// Captures the current desktop wallpaper as the baking baseline.
    /// Only call when corner radius is 0 (to avoid capturing an already-cornered image).
    func fetch() {
        var captured: [String: ScreenState] = [:]

        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen) else { continue }
            guard let url = Self.wallpaperURL(for: screen),
                  FileManager.default.fileExists(atPath: url.path),
                  !Self.isMSGFile(url: url) else { continue }
            let placement = Self.readPlacement(for: screen)
            captured[uuid] = ScreenState(baselineURL: url, placement: placement)
        }

        guard !captured.isEmpty else { return }
        externalChangePending = false  // user acknowledged the change by re-snapshotting
        screens = captured
        persistBaselines()
    }

    /// When the desktop URL points to a non-existent file (e.g. a stale MSG-baked PNG
    /// left over from a crash), the engine can't capture a baseline. Reset to a system
    /// thumbnail so fetch() has a valid file to work with.
    private func recoverBrokenDesktopIfNeeded() {
        let thumbDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        let solidDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors")

        for screen in NSScreen.screens {
            guard let url = Self.wallpaperURL(for: screen),
                  !FileManager.default.fileExists(atPath: url.path) else { continue }

            if let files = try? FileManager.default.contentsOfDirectory(
                at: thumbDir, includingPropertiesForKeys: [.isRegularFileKey]
            ).filter({ $0.pathExtension.lowercased() == "heic" }),
            let fallback = files.first {
                Self.setWallpaper(url: fallback, for: screen)
            } else if let files = try? FileManager.default.contentsOfDirectory(
                at: solidDir, includingPropertiesForKeys: nil
            ), let fallback = files.first {
                Self.setWallpaper(url: fallback, for: screen)
            }
        }
    }

    // MARK: - Bake

    /// Applies corner masks to the cached baseline wallpapers and sets them as the desktop.
    func bake() {
        guard !externalChangePending else { return }
        bakeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performBake()
        }
        bakeItem = item
        queue.async(execute: item)
    }

    private func performBake() {
        var jobs: [(NSScreen, String, URL, Placement)] = []

        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen),
                  let state = screens[uuid] else { continue }
            jobs.append((screen, uuid, state.baselineURL, state.placement))
        }

        guard !jobs.isEmpty else { return }

        for (screen, uuid, sourceURL, placement) in jobs {
            guard !(bakeItem?.isCancelled ?? true) else { return }
            guard let cg = Self.loadImage(url: sourceURL) else { continue }
            guard let ctx = Self.createContext(for: screen) else { continue }

            let w = CGFloat(ctx.width)
            let h = CGFloat(ctx.height)
            let drawRect = Self.wallpaperDrawRect(
                imageSize: CGSize(width: cg.width, height: cg.height),
                screenPixelSize: CGSize(width: w, height: h),
                placement: placement
            )
            ctx.draw(cg, in: drawRect)

            let isBuiltin = screen.isBuiltin
            let bottomEnabled = isBuiltin ? settings.bottomCornersEnabled : settings.extBottomCornersEnabled(for: uuid)
            if bottomEnabled {
                let radius = isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
                let r = radius * screen.backingScaleFactor
                ctx.setFillColor(CGColor.black)
                Self.fillCorner(ctx: ctx, x: 0,          y: 0, r: r, dx:  1, dy:  1)
                Self.fillCorner(ctx: ctx, x: CGFloat(w), y: 0, r: r, dx: -1, dy:  1)
            }

            guard let out = ctx.makeImage() else { continue }
            let (outURL, _) = Self.exportPNG(image: out, uuid: uuid, toggle: &screens[uuid]!.toggle)
            guard let outURL else { continue }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.screens[uuid]?.baselineURL == sourceURL else { return }
                Self.setWallpaper(url: outURL, for: screen)
                self.lastBakedURLs[uuid] = outURL
            }
        }
    }

    /// Re-applies the last baked PNG on space switch so the cornered wallpaper
    /// persists across all Spaces without re-rendering.
    private func reapplyToAllSpaces() {
        guard !externalChangePending else { return }
        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen),
                  let url = lastBakedURLs[uuid] else { continue }
            Self.setWallpaper(url: url, for: screen)
        }
    }

    // MARK: - Polling

    private func beginPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForExternalChange()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func checkForExternalChange() {
        guard !externalChangePending else { return }  // already flagged, wait for user to resolve
        for screen in NSScreen.screens {
            guard let uuid = Self.screenUUID(screen),
                  let state = screens[uuid] else { continue }
            guard let cur = Self.wallpaperURL(for: screen) else { continue }

            if !Self.isMSGFile(url: cur), cur != state.baselineURL {
                externalChangePending = true
                onExternalChange?()
                return
            }
        }
    }

    // MARK: - Persistence

    private var baselinesPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("MSG")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baselines.json").path
    }

    private struct PersistedEntry: Codable {
        let uuid: String
        let path: String
        let placement: Int
    }

    private func persistBaselines() {
        let entries: [PersistedEntry] = screens.compactMap { uuid, state in
            PersistedEntry(uuid: uuid, path: state.baselineURL.path, placement: state.placement.rawValue)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: baselinesPath))
    }

    private func loadPersistedBaselines() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: baselinesPath)),
              let entries = try? JSONDecoder().decode([PersistedEntry].self, from: data)
        else { return }

        var loaded: [String: ScreenState] = [:]
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: entry.path) else { continue }
            guard !Self.isMSGFile(url: url) else { continue }

            // If the current desktop shows a different wallpaper than what we
            // persisted, the baseline is stale (user changed wallpaper while
            // MSG wasn't running). Discard it so we fall through to fetch().
            var stale = false
            for screen in NSScreen.screens {
                if Self.screenUUID(screen) == entry.uuid,
                   let curURL = Self.wallpaperURL(for: screen),
                   !Self.isMSGFile(url: curURL),
                   curURL.path != entry.path {
                    stale = true; break
                }
            }
            if stale { continue }

            loaded[entry.uuid] = ScreenState(
                baselineURL: url,
                placement: Placement(rawValue: entry.placement) ?? .fill
            )
        }
        if !loaded.isEmpty { screens = loaded }
    }

    private func clearPersistedBaselines() {
        try? FileManager.default.removeItem(atPath: baselinesPath)
    }

    // MARK: - System Wallpaper

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
        // Best-effort: propagate to all spaces in the Dock DB so other spaces pick up
        // the baked wallpaper without needing the user to visit them first.
        if let uuid = screenUUID(screen) {
            DispatchQueue.global(qos: .background).async {
                propagateToAllSpacesInDB(url: url, displayUUID: uuid)
            }
        }
    }

    /// Writes the wallpaper URL to every space row for this display in the Dock
    /// database. The same `data` table that `readPlacement` reads from stores
    /// per-space file-path entries as plain text. Updating all text-valued rows
    /// whose key contains this display's UUID covers all spaces without needing
    /// to visit each one individually.
    private static func propagateToAllSpacesInDB(url: URL, displayUUID: String) {
        let db = NSHomeDirectory() + "/Library/Application Support/Dock/desktoppicture.db"
        guard FileManager.default.fileExists(atPath: db) else { return }
        let p = url.path.replacingOccurrences(of: "'", with: "''")
        let u = displayUUID.replacingOccurrences(of: "'", with: "''")
        // Cover both known schema patterns:
        //  - macOS 12-13: key contains display UUID, value is text path
        //  - macOS 14-15: separate display_uuid column
        let sql = """
        UPDATE data SET value='\(p)'
         WHERE typeof(value)='text' AND value LIKE '/%'
         AND (key GLOB '*\(u)*' OR display_uuid='\(u)');
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [db, sql]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        try? task.run(); task.waitUntilExit()
    }

    // MARK: - Placement

    static func readPlacement(for screen: NSScreen) -> Placement {
        guard let uuid = screenUUID(screen) else { return .fill }
        let db = NSHomeDirectory() + "/Library/Application Support/Dock/desktoppicture.db"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [db, "SELECT value FROM data WHERE key GLOB '*\(uuid)*' ORDER BY LENGTH(key) DESC LIMIT 1"]
        let pipe = Pipe(); task.standardOutput = pipe
        try? task.run(); task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let digits = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if let i = Int(digits), let p = Placement(rawValue: i) { return p }
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

    // MARK: - Image Loading / Export

    static func loadImage(url: URL) -> CGImage? {
        // .madesktop is a plist that points to a pre-rendered HEIC thumbnail
        if url.pathExtension.lowercased() == "madesktop",
           let plist = NSDictionary(contentsOf: url),
           let thumbPath = plist["thumbnailPath"] as? String {
            return loadImage(url: URL(fileURLWithPath: thumbPath))
        }
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

    static func exportPNG(image: CGImage, uuid: String, toggle: inout Bool) -> (URL?, URL?) {
        let dir = wallpaperDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        toggle.toggle()
        let outURL = dir.appendingPathComponent("\(uuid)_\(toggle ? "a" : "b").png")
        let altURL = dir.appendingPathComponent("\(uuid)_\(toggle ? "b" : "a").png")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil)
        else { return (nil, nil) }
        let props: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGSoftware as String: signature
            ]
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return (nil, nil) }
        return (outURL, altURL)
    }

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
