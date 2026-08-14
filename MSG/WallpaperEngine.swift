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

    // MARK: - Debug logging

    /// Off unless `defaults write H1D3S1GN.MSG MSGWallpaperDebug -bool YES`.
    /// Same pattern as the slide log in AppDelegate (see F6): a shipping build
    /// with the key unset never creates the file and never formats a string.
    private static let debugEnabled =
        UserDefaults.standard.bool(forKey: "MSGWallpaperDebug")

    /// Appends to /tmp/msg_wallpaper_debug.log, rotating at 512 KB.
    /// `@autoclosure` so the message isn't built when logging is off.
    static func wpLog(_ s: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let url = URL(fileURLWithPath: "/tmp/msg_wallpaper_debug.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attrs[.size] as? Int ?? 0) > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(Date()) \(s())\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Short name for a wallpaper URL — "BAKE:uuid_a.png" or "user:Foo.heic".
    static func wpName(_ u: URL?) -> String {
        guard let u else { return "nil" }
        return isMSGFile(url: u) ? "BAKE:\(u.lastPathComponent)" : "user:\(u.lastPathComponent)"
    }

    private var screens: [String: ScreenState] = [:]
    private var pollTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var bakeItem: DispatchWorkItem?
    private var settingsSyncItem: DispatchWorkItem?
    private var lastBakedURLs: [String: URL] = [:]
    /// Per-display fingerprint of what was last baked (baseline + geometry +
    /// corner settings). Lets sync() skip redundant re-bakes.
    private var bakedSignature: [String: String] = [:]

    var isFetched: Bool { !screens.isEmpty }

    func baselineImage(for screen: NSScreen) -> NSImage? {
        guard let uuid = screen.uuid,
              let url = screens[uuid]?.baselineURL else { return nil }
        guard let cg = Self.loadImage(url: url) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Decoded full-res wallpaper images, memoized by source URL so settings
    /// panes don't re-decode on every appearance (was a visible hitch when
    /// switching panes). The app never rewrites a wallpaper file in place, so
    /// a given URL always maps to the same pixels.
    private var previewImageCache: [URL: NSImage] = [:]

    /// Resolves the preview wallpaper for `screen` — the baked baseline if we
    /// have one, otherwise the live desktop image. A cache hit calls back
    /// synchronously on the main thread; a miss decodes off the main thread and
    /// delivers the result on the main queue, so the pane never blocks.
    func previewWallpaper(for screen: NSScreen, completion: @escaping (NSImage?) -> Void) {
        var candidates: [URL] = []
        if let uuid = screen.uuid, let url = screens[uuid]?.baselineURL { candidates.append(url) }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) { candidates.append(url) }

        for url in candidates where previewImageCache[url] != nil {
            completion(previewImageCache[url]); return
        }
        guard !candidates.isEmpty else { completion(nil); return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var decoded: (URL, NSImage)?
            for url in candidates {
                if let cg = Self.loadImage(url: url) {
                    decoded = (url, NSImage(cgImage: cg, size: .zero)); break
                }
            }
            DispatchQueue.main.async {
                if let (url, image) = decoded { self?.previewImageCache[url] = image }
                completion(decoded?.1)
            }
        }
    }

    /// Fires when an external wallpaper change is detected (user changed wallpaper in System Settings).
    var onExternalChange: (() -> Void)?
    /// Stays true from the moment an external change is detected until fetch() is called.
    /// Survives settings-pane navigation so auto-apply stays suppressed until resolved.
    private(set) var externalChangePending: Bool = false
    private var pendingSince: TimeInterval = 0

    /// Set by Indicator when SystemState detects MC entry/exit.
    /// Suppresses the polling IPC check so we don't contend with WindowServer during MC animations.
    /// Read `mcSuppressionActive`, never this — a latched true takes the engine down for good.
    var isMissionControlActive = false {
        didSet {
            guard isMissionControlActive != oldValue else { return }
            mcActiveSince = isMissionControlActive ? ProcessInfo.processInfo.systemUptime : 0
        }
    }
    private var mcActiveSince: TimeInterval = 0
    /// No real Mission Control session justifies suppressing the engine this long.
    private static let mcSuppressionCeilingSec: TimeInterval = 30

    /// `isMissionControlActive` is edge-driven (cleared only by SystemState's
    /// didStabilize) and the MC reading itself can latch true — an unnamed
    /// positive-layer WindowManager window is indistinguishable from Mission
    /// Control without Screen Recording. It gates the external-change poll *and*
    /// the space-switch re-apply, so a latch strands the baked corners until
    /// relaunch. Time-bound it: past the ceiling the reading is not trusted.
    /// Worst case we re-render the desktop during a genuinely long MC session,
    /// which is a cosmetic hitch and self-correcting on exit.
    private var mcSuppressionActive: Bool {
        isMissionControlActive
            && ProcessInfo.processInfo.systemUptime - mcActiveSince <= Self.mcSuppressionCeilingSec
    }

    /// True while the Cornermizer pane is open. Suppresses automatic
    /// resolution of external wallpaper changes (the pane shows a confirmation
    /// card instead) and automatic re-bakes from settings changes (the pane
    /// has its own Apply flow).
    ///
    /// Never trust this flag on its own: the pane sets it in `onAppear` and
    /// clears it in `onDisappear`, and `onDisappear` does NOT fire when the
    /// settings window is closed or minimised — the controller keeps the window
    /// and its hosting view alive, so the view never leaves the hierarchy. A
    /// latched true leaves the desktop on the uncornered preview baseline with
    /// `sync()` disabled, which reads as "Cornermizer stopped working and the
    /// toggle won't fix it". `editingWindowIsOpen` makes it self-clearing.
    private(set) var isEditing = false

    /// Liveness for `isEditing`: whether the settings window is actually on
    /// screen. Wired at launch; nil (pre-macOS 14, where no pane exists to set
    /// isEditing) means "no opinion".
    var editingWindowIsOpen: (() -> Bool)?

    func beginEditing() {
        isEditing = true
    }

    /// Leaves editing mode and puts the corners back. Idempotent — called from
    /// the pane's onDisappear, from the window's close/minimise paths, and from
    /// the poll when the window went away without either firing.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        onExternalChange = nil
        // An unresolved external change is left alone — the poll adopts it now
        // that editing has ended.
        if !externalChangePending { sync() }
    }

    private func reconcileEditingState() {
        guard isEditing, editingWindowIsOpen?() == false else { return }
        Self.wpLog("editing latched with no settings window — releasing")
        endEditing()
    }

    // MARK: - Init

    private init(settings: AppSettings) { self.settings = settings }

    // MARK: - Start / Stop

    func start() {
        loadPersistedBaselines()
        recoverBrokenDesktopIfNeeded()
        // Capture baselines for any display that doesn't have one — covers
        // first launch, and displays whose persisted baseline was discarded
        // as stale (wallpaper changed while MSG wasn't running).
        fetchMissingDisplays()
        sync()
        beginPolling()

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // During Mission Control the desktop is the blurred MC background
            // — calling setDesktopImageURL forces WindowServer to re-render it,
            // causing a visible hitch in the MC animation.
            guard !self.mcSuppressionActive else { return }
            self.checkForExternalChange()
            self.reapplyToAllSpaces()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)  { [weak self] in
                guard let self, !self.mcSuppressionActive else { return }
                self.reapplyToAllSpaces()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)  { [weak self] in
                guard let self, !self.mcSuppressionActive else { return }
                self.reapplyToAllSpaces()
            }
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
        settingsSyncItem?.cancel(); settingsSyncItem = nil
    }

    /// Puts the original wallpaper back on every display (including the Dock-DB
    /// rows of disconnected displays) and deletes the baked PNGs. Everything runs
    /// synchronously: this is called on the way out of the process, so async
    /// propagation would be killed mid-flight and leave Spaces pointing at
    /// deleted files.
    func restore() {
        stop()
        for (uuid, state) in screens {
            if let screen = NSScreen.screens.first(where: { $0.uuid == uuid }) {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(state.baselineURL, for: screen, options: [:])
                } catch {
                    if screen == NSScreen.screens.first {
                        let src = "tell application \"System Events\" to set picture of desktop 1 to \"\(state.baselineURL.path)\""
                        _ = NSAppleScript(source: src)?.executeAndReturnError(nil)
                    }
                }
            }
            Self.propagateToAllSpacesInDB(url: state.baselineURL, displayUUID: uuid)
        }
        // On legacy macOS the Dock-DB propagation above pointed every Space back
        // at the baseline, so the baked PNGs can go. On macOS 14+ that DB no
        // longer exists and Spaces we aren't currently showing may still
        // reference the baked files — deleting them would leave those Spaces
        // with a missing wallpaper, and there is no post-exit way to fix it.
        // Keep the files and baselines.json; the launch reconciliation handles
        // every resulting state.
        let dockDB = NSHomeDirectory() + "/Library/Application Support/Dock/desktoppicture.db"
        if FileManager.default.fileExists(atPath: dockDB) {
            let dir = Self.wallpaperDir()
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: f)
            }
            clearPersistedBaselines()
        }
        screens.removeAll()
        lastBakedURLs.removeAll()
        bakedSignature.removeAll()
    }

    // MARK: - Editing mode

    /// Reverts the desktop to the baseline (uncornered) so the user sees a clean
    /// preview in the Cornermizer pane. The CornerWindow overlay still shows
    /// the current corner settings as a live preview.
    func showBaseline() {
        for (uuid, state) in screens {
            if let screen = NSScreen.screens.first(where: { $0.uuid == uuid }) {
                // Never put the old baseline back over a wallpaper the user has
                // just changed to and we haven't adopted yet — that reads as MSG
                // undoing their choice.
                guard isSafeToOverwrite(screen: screen, state: state) else { continue }
                Self.setWallpaper(url: state.baselineURL, for: screen)
            }
        }
    }

    /// Whether it is safe for us to write a wallpaper to `screen`.
    ///
    /// True only when the desktop currently shows something we already own: one
    /// of our baked PNGs, or the exact baseline we captured. Anything else means
    /// the user picked a new wallpaper that we have not adopted yet, and writing
    /// would silently revert them. `checkForExternalChange()` adopts it within
    /// one poll and normal baking resumes.
    private func isSafeToOverwrite(screen: NSScreen, state: ScreenState) -> Bool {
        guard let cur = Self.wallpaperURL(for: screen) else { return false }
        return Self.isMSGFile(url: cur) || cur == state.baselineURL
    }

    // MARK: - Sync

    /// Reconciles the desktop with the current settings. Per display:
    /// corners enabled → bake (unless the correct bake is already showing);
    /// corners disabled → put the clean baseline back if our baked PNG is up.
    /// Idempotent and state-driven, so it's safe to call from any situation:
    /// launch, settings change, pane close, screen change, external change.
    func sync() {
        guard !externalChangePending else { return }
        var staleDisplays: Set<String> = []
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid,
                  let state = screens[uuid] else { continue }
            let current = Self.wallpaperURL(for: screen)
            let showsBake = current.map { Self.isMSGFile(url: $0) } ?? false
            if bottomCornersWanted(for: screen, uuid: uuid) {
                if !showsBake || bakedSignature[uuid] != signature(for: screen, uuid: uuid, state: state) {
                    Self.wpLog("sync: stale -> rebake (cur=\(Self.wpName(current)) showsBake=\(showsBake) sigMatch=\(bakedSignature[uuid] == signature(for: screen, uuid: uuid, state: state)))")
                    staleDisplays.insert(uuid)
                }
            } else if showsBake {
                Self.setWallpaper(url: state.baselineURL, for: screen)
                lastBakedURLs[uuid] = nil
                bakedSignature[uuid] = nil
            }
        }
        if !staleDisplays.isEmpty { bake(displays: staleDisplays) }
    }

    /// Debounced sync for settings changes (menu toggles fire one change per
    /// click; the pane suppresses this entirely via isEditing and bakes through
    /// its own Apply flow).
    func settingsChanged() {
        settingsSyncItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isEditing else { return }
            self.sync()
        }
        settingsSyncItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    private func bottomCornersWanted(for screen: NSScreen, uuid: String) -> Bool {
        guard settings.cornersEnabled else { return false }
        return screen.isBuiltin ? settings.bottomCornersEnabled : settings.extBottomCornersEnabled(for: uuid)
    }

    private func signature(for screen: NSScreen, uuid: String, state: ScreenState) -> String {
        let radius = screen.isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
        return [
            state.baselineURL.path,
            String(state.placement.rawValue),
            String(describing: radius),
            String(describing: screen.frame.size),
            String(describing: screen.backingScaleFactor),
        ].joined(separator: "|")
    }

    // MARK: - Screen change

    /// Fetches baseline for any newly connected display and reconciles.
    private func handleScreenChange() {
        fetchMissingDisplays()
        sync()
    }

    // MARK: - Fetch

    /// Captures the current desktop wallpaper as the baking baseline.
    /// Merges per display: a display whose desktop currently shows an MSG-baked
    /// PNG can't be captured and keeps its existing baseline instead of being
    /// dropped from monitoring.
    func fetch() {
        var changed = false
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid else { continue }
            guard let url = Self.wallpaperURL(for: screen),
                  FileManager.default.fileExists(atPath: url.path),
                  !Self.isMSGFile(url: url) else { continue }
            let placement = Self.readPlacement(for: screen)
            screens[uuid] = ScreenState(baselineURL: url, placement: placement)
            changed = true
        }

        guard changed else { return }
        externalChangePending = false  // user acknowledged the change by re-snapshotting
        pendingSince = 0
        persistBaselines()
    }

    /// Captures a baseline only for displays that don't have one yet.
    /// Unlike fetch(), never overwrites an existing baseline.
    private func fetchMissingDisplays() {
        var changed = false
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid, screens[uuid] == nil else { continue }
            guard let url = Self.wallpaperURL(for: screen),
                  FileManager.default.fileExists(atPath: url.path),
                  !Self.isMSGFile(url: url) else { continue }
            screens[uuid] = ScreenState(baselineURL: url, placement: Self.readPlacement(for: screen))
            changed = true
        }
        if changed { persistBaselines() }
    }

    /// When a display has no usable baseline and its desktop URL is either a
    /// non-existent file or a leftover MSG-baked PNG (crash, deleted baseline),
    /// the engine has nothing clean to capture. Reset to a system picture so
    /// fetchMissingDisplays() has a valid file to work with.
    private func recoverBrokenDesktopIfNeeded() {
        let thumbDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        let solidDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Solid Colors")

        for screen in NSScreen.screens {
            guard let uuid = screen.uuid, let url = Self.wallpaperURL(for: screen) else { continue }
            let missing = !FileManager.default.fileExists(atPath: url.path)
            let orphanedBake = screens[uuid] == nil && Self.isMSGFile(url: url)
            guard missing || orphanedBake else { continue }

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

    private struct BakeJob {
        let screen: NSScreen
        let uuid: String
        let sourceURL: URL
        let placement: Placement
        let radius: CGFloat
        let signature: String
        let toggle: Bool
    }

    /// Applies corner masks to the cached baseline wallpapers and sets them as
    /// the desktop. Only bakes displays whose bottom corners are enabled —
    /// restricted further to `displays` when given, so reconciling one display
    /// doesn't churn the others. Jobs are snapshotted on the main thread so the
    /// render queue never touches shared state.
    func bake(displays: Set<String>? = nil) {
        guard !externalChangePending else { return }

        var jobs: [BakeJob] = []
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid,
                  displays?.contains(uuid) ?? true,
                  var state = screens[uuid],
                  bottomCornersWanted(for: screen, uuid: uuid) else { continue }
            // Choose the a/b slot from what is actually on the desktop, never from
            // a counter. Rewriting the file the desktop is currently showing makes
            // macOS reload it in place and the wallpaper visibly flickers — and a
            // plain toggle resets to its default on every launch, so a relaunch
            // wrote the displayed slot again. Reading the screen is immune to that.
            let shown = Self.wallpaperURL(for: screen)?.lastPathComponent
            state.toggle = (shown != Self.bakeFileName(uuid: uuid, toggle: true))
            screens[uuid] = state
            let radius = screen.isBuiltin ? settings.cornerRadius : settings.extCornerRadius(for: uuid)
            jobs.append(BakeJob(
                screen: screen, uuid: uuid,
                sourceURL: state.baselineURL, placement: state.placement,
                radius: radius,
                signature: signature(for: screen, uuid: uuid, state: state),
                toggle: state.toggle
            ))
        }
        guard !jobs.isEmpty else { return }

        bakeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performBake(jobs)
        }
        bakeItem = item
        queue.async(execute: item)
    }

    private func performBake(_ jobs: [BakeJob]) {
        for job in jobs {
            guard !(bakeItem?.isCancelled ?? true) else { return }
            guard let cg = Self.loadImage(url: job.sourceURL) else { continue }
            guard let ctx = Self.createContext(for: job.screen) else { continue }

            let w = CGFloat(ctx.width)
            let h = CGFloat(ctx.height)
            let drawRect = Self.wallpaperDrawRect(
                imageSize: CGSize(width: cg.width, height: cg.height),
                screenPixelSize: CGSize(width: w, height: h),
                placement: job.placement
            )
            ctx.draw(cg, in: drawRect)

            let r = job.radius * job.screen.backingScaleFactor
            ctx.setFillColor(CGColor.black)
            Self.fillCorner(ctx: ctx, x: 0,          y: 0, r: r, dx:  1, dy:  1)
            Self.fillCorner(ctx: ctx, x: CGFloat(w), y: 0, r: r, dx: -1, dy:  1)

            guard let out = ctx.makeImage() else { continue }
            let (outURL, _) = Self.exportPNG(image: out, uuid: job.uuid, toggle: job.toggle)
            guard let outURL else { continue }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.screens[job.uuid]?.baselineURL == job.sourceURL else {
                    // Rendered, then dropped: the baseline moved while we worked.
                    // Nothing reschedules, so the corners stay off until some
                    // unrelated trigger calls sync() again.
                    Self.wpLog("bake DISCARDED (baseline moved): job=\(Self.wpName(job.sourceURL)) now=\(Self.wpName(self.screens[job.uuid]?.baselineURL))")
                    return
                }
                Self.wpLog("bake done -> \(Self.wpName(outURL))")
                Self.setWallpaper(url: outURL, for: job.screen)
                self.lastBakedURLs[job.uuid] = outURL
                self.bakedSignature[job.uuid] = job.signature
                // Persist the fingerprint too, so the next launch knows this
                // desktop is already correct and skips the redundant re-bake.
                self.persistBaselines()
            }
        }
    }

    /// Re-applies the last baked PNG on space switch so the cornered wallpaper
    /// persists across all Spaces without re-rendering.
    private func reapplyToAllSpaces() {
        guard !externalChangePending else { return }
        // During Mission Control the desktop is the blurred MC background
        // — setDesktopImageURL would force WindowServer to re-render it,
        // causing a visible hitch. A single CGWindowList query is far cheaper
        // than triggering a system wallpaper reload mid-animation.
        guard !isMissionControlActive, !MissionControlDetector.isActive() else { return }
        // setWallpaper calls NSWorkspace.setDesktopImageURL (IPC with the
        // WindowServer) and, on failure, blocks the calling thread inside
        // NSAppleScript. This used to run on main and freeze it for
        // 100–250ms right inside the space-change notification window,
        // visibly stuttering the pill animation. Snapshot screen→URL
        // pairs on the caller's thread (main is safe for NSScreen) and
        // hand the slow work off to the utility queue.
        var jobs: [(NSScreen, URL)] = []
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid,
                  let url = lastBakedURLs[uuid],
                  let state = screens[uuid] else { continue }
            // The user can change their wallpaper at any moment, and the poll that
            // notices only runs every 5 s. Without this check a space switch inside
            // that window re-applies the *previous* bake straight over their new
            // choice, which then gets adopted and re-baked — the visible flicker
            // back to the old wallpaper.
            guard isSafeToOverwrite(screen: screen, state: state) else {
                Self.wpLog("reapply SKIPPED (unadopted wallpaper on screen): \(Self.wpName(Self.wallpaperURL(for: screen)))")
                continue
            }
            jobs.append((screen, url))
        }
        guard !jobs.isEmpty else { return }
        queue.async {
            for (screen, url) in jobs {
                Self.setWallpaper(url: url, for: screen)
            }
        }
    }

    // MARK: - Polling

    private func beginPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            // Before the MC gate below: a latched editing flag must be released
            // even while the MC reading is suppressing everything else.
            self?.reconcileEditingState()
            self?.checkForExternalChange()
        }
        pollTimer?.tolerance = 1.0 // sampling - let kernel coalesce
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
    }

    private func checkForExternalChange() {
        guard !mcSuppressionActive else { return }

        // Re-arm displays released by releaseUnreadableBaselines(): once their
        // wallpaper is readable again they get a baseline back and resume baking.
        // Must test *live* screens, not counts — `screens` keeps entries for
        // displays that are merely unplugged, so a count comparison can report
        // "armed" while the only connected display has no baseline.
        let needsBaseline = NSScreen.screens.contains { screen in
            guard let uuid = screen.uuid else { return false }
            return screens[uuid] == nil
        }
        if settings.cornersEnabled, needsBaseline {
            let before = screens.count
            fetchMissingDisplays()
            // fetchMissingDisplays() only captures and persists; sync() is the only
            // thing that bakes. Without this the display recovers its baseline and
            // then sits uncornered until some unrelated settings/screen change.
            if screens.count != before { sync() }
        }

        if externalChangePending {
            if !isEditing {
                adoptExternalWallpaper()
                if externalChangePending, pendingSince > 0,
                   ProcessInfo.processInfo.systemUptime - pendingSince > 30 {
                    releaseUnreadableBaselines()
                }
            }
            return
        }

        for screen in NSScreen.screens {
            guard let uuid = screen.uuid,
                  let state = screens[uuid] else { continue }
            guard let cur = Self.wallpaperURL(for: screen) else { continue }

            if !Self.isMSGFile(url: cur), cur != state.baselineURL {
                Self.wpLog("external change detected: \(Self.wpName(cur)) (baseline \(Self.wpName(state.baselineURL))) editing=\(isEditing)")
                externalChangePending = true
                pendingSince = ProcessInfo.processInfo.systemUptime
                if isEditing {
                    // Pane is open: show the confirmation card, let the user decide.
                    onExternalChange?()
                } else {
                    // Nobody is editing: the new wallpaper is the new baseline.
                    adoptExternalWallpaper()
                }
                return
            }
        }
    }

    /// Re-snapshots the externally changed wallpaper and re-applies corners to it.
    private func adoptExternalWallpaper() {
        fetch()   // clears externalChangePending
        sync()
    }

    /// Unwedge: a display whose wallpaper we can no longer capture keeps
    /// externalChangePending true forever, and that flag disables sync(), bake()
    /// and reapplyToAllSpaces() for *every* display. Drop the baselines we can't
    /// re-read — so we never re-bake a stale wallpaper over a new one — and let
    /// the flag go so the rest of the engine lives. fetchMissingDisplays() adopts
    /// them again as soon as their wallpaper is readable.
    private func releaseUnreadableBaselines() {
        for screen in NSScreen.screens {
            guard let uuid = screen.uuid, screens[uuid] != nil else { continue }
            let readable = Self.wallpaperURL(for: screen).map {
                FileManager.default.fileExists(atPath: $0.path) && !Self.isMSGFile(url: $0)
            } ?? false
            guard !readable else { continue }
            screens[uuid] = nil
            lastBakedURLs[uuid] = nil
            bakedSignature[uuid] = nil
        }
        externalChangePending = false
        pendingSince = 0
        persistBaselines()
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
        /// Fingerprint of the bake currently on the desktop, and the file it went
        /// to. Persisted because both used to live only in memory: every launch
        /// started with an empty signature, so sync() judged a perfectly good
        /// wallpaper stale and re-baked it — the redundant bake on every app
        /// relaunch. Optional so an older baselines.json still decodes.
        var signature: String? = nil
        var bakedPath: String? = nil
    }

    private func persistBaselines() {
        let entries: [PersistedEntry] = screens.map { uuid, state in
            PersistedEntry(uuid: uuid, path: state.baselineURL.path,
                           placement: state.placement.rawValue,
                           signature: bakedSignature[uuid],
                           bakedPath: lastBakedURLs[uuid]?.path)
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
                if screen.uuid == entry.uuid,
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
            // Restore what we already baked, so sync() can recognise a desktop
            // that is still correct instead of re-baking it on every launch.
            if let sig = entry.signature { restoredSignatures[entry.uuid] = sig }
            if let baked = entry.bakedPath, FileManager.default.fileExists(atPath: baked) {
                restoredBakedURLs[entry.uuid] = URL(fileURLWithPath: baked)
            }
        }
        if !loaded.isEmpty {
            screens = loaded
            bakedSignature = restoredSignatures
            lastBakedURLs = restoredBakedURLs
        }
        restoredSignatures.removeAll(); restoredBakedURLs.removeAll()
    }

    /// Scratch for loadPersistedBaselines — only applied if the load succeeds.
    private var restoredSignatures: [String: String] = [:]
    private var restoredBakedURLs: [String: URL] = [:]

    private func clearPersistedBaselines() {
        try? FileManager.default.removeItem(atPath: baselinesPath)
    }

    // MARK: - System Wallpaper

    static func wallpaperURL(for screen: NSScreen) -> URL? {
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) { return url }
        // The AppleScript fallback can only address "desktop 1" (the primary
        // display) — never use it for other screens or we'd read the wrong
        // display's wallpaper.
        guard screen == NSScreen.screens.first else { return nil }
        let src = "tell application \"System Events\" to get picture of desktop 1"
        if let r = NSAppleScript(source: src)?.executeAndReturnError(nil).stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !r.isEmpty, r != "missing value" {
            return URL(fileURLWithPath: r)
        }
        return nil
    }

    static func setWallpaper(url: URL, for screen: NSScreen) {
        wpLog("setWallpaper -> \(wpName(url))  (was \(wpName(wallpaperURL(for: screen))))")
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            wpLog("  setDesktopImageURL THREW: \(error.localizedDescription)")
            // "desktop 1" is the primary display; for any other screen the
            // fallback would overwrite the primary's wallpaper — skip instead.
            guard screen == NSScreen.screens.first else { return }
            let src = "tell application \"System Events\" to set picture of desktop 1 to \"\(url.path)\""
            _ = NSAppleScript(source: src)?.executeAndReturnError(nil)
        }
        // Best-effort: propagate to all spaces in the Dock DB so other spaces pick up
        // the baked wallpaper without needing the user to visit them first.
        if let uuid = screen.uuid {
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
        guard let uuid = screen.uuid else { return .fill }
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

    /// `toggle` selects the a/b output filename; the caller advances it before
    /// baking so the desktop never has its current file rewritten in place.
    /// Filename for a bake slot. Shared so the slot chosen in `bake()` and the
    /// file written here can never drift apart.
    static func bakeFileName(uuid: String, toggle: Bool) -> String {
        "\(uuid)_\(toggle ? "a" : "b").png"
    }

    static func exportPNG(image: CGImage, uuid: String, toggle: Bool) -> (URL?, URL?) {
        let dir = wallpaperDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent(bakeFileName(uuid: uuid, toggle: toggle))
        let altURL = dir.appendingPathComponent(bakeFileName(uuid: uuid, toggle: !toggle))
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

}
