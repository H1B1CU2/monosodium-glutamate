import AppKit

// MARK: - MediaRemote bindings (weak-linked at build time)

private typealias MRNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias MRSendCommandFunc = @convention(c) (UInt32, CFDictionary?) -> Bool
private typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void
private typealias MRGetNowPlayingPIDFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

private func mrsym<T>(_ name: String, as: T.Type) -> T? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private let MRNowPlayingInfo: MRNowPlayingInfoFunc? = mrsym("MRMediaRemoteGetNowPlayingInfo", as: MRNowPlayingInfoFunc.self)
private let MRSendCommand: MRSendCommandFunc? = mrsym("MRMediaRemoteSendCommand", as: MRSendCommandFunc.self)
private let MRRegister: MRRegisterFunc? = mrsym("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterFunc.self)
private let MRGetNowPlayingPID: MRGetNowPlayingPIDFunc? = mrsym("MRMediaRemoteGetNowPlayingApplicationPID", as: MRGetNowPlayingPIDFunc.self)

// MRMediaRemote commands
private let kMRPlay = UInt32(0)
private let kMRPause = UInt32(1)
private let kMRTogglePlayPause = UInt32(2)
private let kMRNextTrack = UInt32(4)
private let kMRPreviousTrack = UInt32(5)

// MARK: - Media-key routing

/// Music.app's own transport state, tracked independently of the system Now
/// Playing app so the media keys can be aimed at Music while something else
/// (a browser tab, Spotify) holds Now Playing.
enum MusicAppState {
    case notRunning
    case stopped
    case paused
    case playing
}

/// A hardware transport key, once we've decided to route it to Music.app.
enum MediaKeyAction {
    case playPause
    case next
    case previous
}

// MARK: - MusicMonitor

final class MusicMonitor {

    private let settings: AppSettings

    /// Perl-hosted MediaRemote bridge — the only way to read system Now
    /// Playing on macOS 15.4+. When the helper dylib is bundled, it pushes
    /// state and the direct MR/AppleScript paths below become fallbacks.
    private let adapter = MediaRemoteAdapter()

    private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            if !isPlaying {
                // Stopping arms the responsiveness grace window (see
                // desiredPollInterval) and a one-shot to re-evaluate the cadence
                // once that window closes — nothing else would demote the timer.
                lastPlaybackActivityAt = ProcessInfo.processInfo.systemUptime
                armGraceExpiry()
            } else {
                graceExpiryTimer?.invalidate(); graceExpiryTimer = nil
            }
        }
    }
    private(set) var currentTitle: String?
    private(set) var currentArtist: String?
    private(set) var volume: Int = 50
    private(set) var currentSource: String?
    private(set) var currentSourceBundleID: String?
    private(set) var albumArt: NSImage?

    /// Multiple subsystems observe playback (the menu-bar Indicator and the Tray).
    /// A single `onChange` closure would let the last setter clobber the others,
    /// so fan out to a list of observers instead.
    private var observers: [() -> Void] = []
    func addObserver(_ callback: @escaping () -> Void) { observers.append(callback) }
    private func notify() { observers.forEach { $0() } }

    /// Serial queue for ALL NSAppleScript execution. NSAppleScript is not
    /// thread-safe: running it on the concurrent global pool (a 1s poll racing a
    /// media-key/volume script) corrupts AppleScript's component table and hangs
    /// the worker thread — the "stops working after long sleep" + High energy bug.
    /// One serial queue guarantees scripts never execute concurrently.
    private static let scriptQueue = DispatchQueue(label: "com.h1d3s1gn.MSG.applescript", qos: .utility)

    init(settings: AppSettings) {
        self.settings = settings
        self.lastMusicSource = settings.musicSource
        MRRegister?(.main)
    }

    /// Pushes helper updates into the monitor state. In Now Playing mode the
    /// adapter is the source of truth; in Apple Music mode AppleScript drives
    /// title/state and the adapter only contributes album art (the direct
    /// MediaRemote art fetch is blocked on macOS 15.4+).
    private func applyAdapterState(_ np: MediaRemoteAdapter.NowPlaying, forceNotify: Bool = false) {
        switch settings.musicSource {
        case .nowPlaying:
            let wasPlaying = isPlaying
            let incomingTitle = (np.title?.isEmpty == false) ? np.title : nil
            let incomingArtist = (np.artist?.isEmpty == false) ? np.artist : nil
            let hasMetadata = incomingTitle != nil || incomingArtist != nil
            // The helper reports `playing` authoritatively (via
            // MRMediaRemoteGetNowPlayingApplicationIsPlaying), so trust it —
            // inferring "still playing" from unchanged metadata used to keep
            // the visualizer running after a pause.
            let effectivePlaying = np.playing
            let oldTitle = currentTitle
            let oldArtist = currentArtist
            let oldSource = currentSource
            let oldSourceBundleID = currentSourceBundleID
            let hadAlbumArt = albumArt != nil
            if effectivePlaying || hasMetadata {
                isPlaying = effectivePlaying
                if np.pid > 0, let app = NSRunningApplication(processIdentifier: np.pid) {
                    currentSource = app.localizedName ?? "Now Playing"
                    currentSourceBundleID = app.bundleIdentifier
                } else {
                    currentSource = "Now Playing"
                    currentSourceBundleID = nil
                }
                if let title = incomingTitle {
                    currentTitle = title
                    currentArtist = incomingArtist
                } else if effectivePlaying {
                    // Playing, but the current item exposes no title (some
                    // browser videos, ads, etc.). Show the app name rather than
                    // a stale previous track's title.
                    currentTitle = currentSource ?? "Now Playing"
                    currentArtist = nil
                }
                if let art = np.art {
                    albumArt = art
                } else if oldSourceBundleID != currentSourceBundleID {
                    albumArt = nil   // never show the previous source's artwork
                }
                if effectivePlaying, let bid = currentSourceBundleID {
                    // Scriptable sources can fill in what MediaRemote withheld
                    // (or what the source never published).
                    if !hasMetadata { fetchScriptTitle(bid: bid) }
                    if np.art == nil {
                        if let url = np.artURL {
                            fetchURLArtwork(url)
                        } else {
                            fetchScriptArtwork(bid: bid)
                        }
                    }
                }
                let changed = forceNotify
                    || wasPlaying != isPlaying
                    || oldTitle != currentTitle
                    || oldArtist != currentArtist
                    || oldSource != currentSource
                    || oldSourceBundleID != currentSourceBundleID
                    || (!hadAlbumArt && np.art != nil)
                    || (hadAlbumArt && albumArt == nil)
                if changed {
                    NSLog("[Music] Applying Now Playing playing=%@ source=%@ bundle=%@ title=%@",
                          isPlaying ? "true" : "false",
                          currentSource ?? "nil",
                          currentSourceBundleID ?? "nil",
                          currentTitle ?? "nil")
                    notify()
                }
                if wasPlaying != isPlaying { restartPollTimer() }
            } else if wasPlaying || currentTitle != nil {
                isPlaying = false
                currentTitle = nil
                currentArtist = nil
                currentSource = nil
                currentSourceBundleID = nil
                albumArt = nil
                artFetchKey = nil
                urlArtKey = nil
                NSLog("[Music] Now Playing stopped")
                notify()
                if wasPlaying { restartPollTimer() }
            }
        case .appleMusic:
            if let art = np.art, currentSourceBundleID == "com.apple.Music" {
                albumArt = art
                notify()
            }
        }
    }

    @objc func openMusic() {
        let script = "tell application \"Music\" to activate"
        MusicMonitor.scriptQueue.async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    // MARK: - Demand Gating & Polling

    /// Non-zero while some consumer needs fresh Now Playing data. The popover and the
    /// tray hold a token while visible; the indicator holds one while the music display
    /// is switched on. At zero the poller idles completely.
    private var demandTokens = 0

    func retainPolling() {
        demandTokens += 1
        if demandTokens == 1 { restartPollTimer() }
    }

    func releasePolling() {
        demandTokens = max(0, demandTokens - 1)
        if demandTokens == 0 { restartPollTimer() }
    }

    /// True when the indicator itself wants music on the status item.
    private var indicatorWantsMusic: Bool {
        settings.musicEnabled && settings.musicDisplayMode != .off
    }

    private var wantsNowPlaying: Bool { indicatorWantsMusic || demandTokens > 0 }

    private var isAppleMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
    }

    private var pollTimer: Timer?
    private var appleMusicStateTimer: Timer?
    private var isQuerying = false
    /// When the in-flight AppleScript query started (systemUptime). Used by the
    /// watchdog in poll() to recover if a completion is never delivered.
    private var queryStartedAt: TimeInterval = 0
    private var lastMusicSource: MusicSource

    /// How long after playback stops the poller stays at its fast cadence.
    private let playbackGraceWindow: TimeInterval = 45
    private var lastPlaybackActivityAt: TimeInterval = -.greatestFiniteMagnitude
    private var graceExpiryTimer: Timer?

    private var inPlaybackGraceWindow: Bool {
        ProcessInfo.processInfo.systemUptime - lastPlaybackActivityAt < playbackGraceWindow
    }

    /// Re-evaluate the cadence the moment the grace window closes. Without this
    /// the timer would sit at the fast rate until the next state change.
    private func armGraceExpiry() {
        graceExpiryTimer?.invalidate()
        let t = Timer(timeInterval: playbackGraceWindow + 0.1, repeats: false) { [weak self] _ in
            self?.graceExpiryTimer = nil
            self?.restartPollTimer()
        }
        t.tolerance = 2.0
        RunLoop.main.add(t, forMode: .common)
        graceExpiryTimer = t
    }

    /// Poll cadence. 1 s while something is playing (track changes, marquee and
    /// linger all need it) and for `playbackGraceWindow` after it stops — someone
    /// who just stopped is very likely to start again shortly (skipping a track,
    /// switching album, a call ending), and dropping straight to the idle rate is
    /// what made "stop, then play again" feel sluggish. Only once music has been
    /// idle for the whole window does the rate decay, and even then a player
    /// notification or a transport key wakes it instantly via `pokeNow()`.
    private func desiredPollInterval() -> TimeInterval {
        guard wantsNowPlaying else { return 0 }              // 0 == no timer at all
        if settings.musicSource == .appleMusic && !isAppleMusicRunning { return 3.0 }
        if isPlaying || inPlaybackGraceWindow { return 1.0 }
        return 3.0
    }

    /// Something happened that plausibly started playback (a player posted a state
    /// change, a transport key was pressed). Read immediately rather than waiting
    /// out the current tick, and restore the fast cadence.
    func pokeNow() {
        guard wantsNowPlaying else { return }
        lastPlaybackActivityAt = ProcessInfo.processInfo.systemUptime
        armGraceExpiry()
        restartPollTimer()
        poll()
    }

    func restartPollTimer() {
        let wanted = desiredPollInterval()
        if wanted == 0 {
            pollTimer?.invalidate(); pollTimer = nil
            return
        }
        if let t = pollTimer, abs(t.timeInterval - wanted) < 0.01 { return }   // already correct
        pollTimer?.invalidate()
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = wanted * 0.2                                             // sampling - let kernel coalesce
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func settingsChanged() {
        restartPollTimer()
        updateAppleMusicStateTimer()
    }

    private func updateAppleMusicStateTimer() {
        if settings.mediaKeyPriorityMusic {
            if appleMusicStateTimer == nil {
                let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.refreshAppleMusicState()
                }
                t.tolerance = 0.4
                RunLoop.main.add(t, forMode: .common)
                appleMusicStateTimer = t
            }
        } else {
            appleMusicStateTimer?.invalidate()
            appleMusicStateTimer = nil
        }
    }

    /// Player state-change broadcasts. Music.app and Spotify both post these the
    /// instant playback starts or stops, with no entitlement needed and no cost
    /// while nothing is playing — so the poller can idle slowly and still react
    /// immediately for the two most common sources.
    private static let playerNotifications = [
        "com.apple.iTunes.playerInfo",
        "com.spotify.client.PlaybackStateChanged",
    ]
    private var playerObservers: [NSObjectProtocol] = []

    func start() {
        restartPollTimer()
        if wantsNowPlaying { poll() }
        updateAppleMusicStateTimer()

        guard playerObservers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        for name in Self.playerNotifications {
            playerObservers.append(dnc.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in self?.pokeNow() })
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        appleMusicStateTimer?.invalidate(); appleMusicStateTimer = nil
        graceExpiryTimer?.invalidate(); graceExpiryTimer = nil
        let dnc = DistributedNotificationCenter.default()
        playerObservers.forEach { dnc.removeObserver($0) }
        playerObservers.removeAll()
    }

    private func poll() {
        guard wantsNowPlaying else { return }

        // Watchdog: if a previous query never completed (hung/dropped after wake),
        // don't stay blocked forever — clear the guard so polling can resume.
        if isQuerying, ProcessInfo.processInfo.systemUptime - queryStartedAt > 6 {
            isQuerying = false
        }
        let sourceChanged = settings.musicSource != lastMusicSource
        if sourceChanged {
            lastMusicSource = settings.musicSource
            isQuerying = false
        }
        switch settings.musicSource {
        case .nowPlaying:
            // Poll a fresh one-shot read each tick (never a long-lived stream, so
            // it can't go stale). The isQuerying guard keeps spawns from stacking.
            if MediaRemoteAdapter.isAvailable {
                guard !isQuerying else { return }
                isQuerying = true
                queryStartedAt = ProcessInfo.processInfo.systemUptime
                adapter.query { [weak self] np in
                    guard let self else { return }
                    self.isQuerying = false
                    if let np = np { self.applyAdapterState(np, forceNotify: sourceChanged) }
                }
                return
            }
            pollNowPlaying()          // legacy fallback when the helper dylib is absent
        case .appleMusic:
            guard !isQuerying else { return }
            pollAppleMusic()
        }
    }

    // MARK: - Now Playing (AppleScript for Music/Spotify + MR fallback for everything else)

    private func pollNowPlaying() {
        guard !isQuerying else { return }
        isQuerying = true
        queryStartedAt = ProcessInfo.processInfo.systemUptime
        let wasPlaying = isPlaying

        // Check Music and Spotify ONLY if already running — never launch them.
        // AppleScript runs on a background thread; no main-thread blocking here.
        let script = """
        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    return "Music|" & t & "|" & a
                end if
            end tell
        end if
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then
                    set t to name of current track
                    set a to artist of current track
                    return "Spotify|" & t & "|" & a
                end if
            end tell
        end if
        return "none"
        """

        MusicMonitor.scriptQueue.async { [weak self] in
            let result = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue ?? "none"
            DispatchQueue.main.async {
                guard let self else { return }

                if result != "none" {
                    let parts = result.components(separatedBy: "|")
                    let newTitle  = parts.count > 1 ? parts[1] : nil
                    let newArtist = parts.count > 2 ? parts[2] : nil
                    self.isQuerying = false
                    self.isPlaying     = true
                    self.currentTitle  = newTitle
                    self.currentArtist = newArtist
                    self.currentSource = parts.first
                    if parts.first == "Music" {
                        self.currentSourceBundleID = "com.apple.Music"
                    } else if parts.first == "Spotify" {
                        self.currentSourceBundleID = "com.spotify.client"
                    } else {
                        self.currentSourceBundleID = nil
                    }
                    self.fetchAlbumArt()
                    if wasPlaying != self.isPlaying || self.isPlaying { self.notify() }
                    if !wasPlaying { self.restartPollTimer() }
                } else {
                    // Nothing found via AppleScript — try MediaRemote for browsers/other apps.
                    // Keep isQuerying = true so the next poll doesn't race with the MR callback.
                    self.pollNowPlayingMR(wasPlaying: wasPlaying)
                }
            }
        }
    }

    /// Secondary check via MediaRemote; called only when AppleScript found nothing.
    /// Do NOT call readSystemVolume() here — it runs on the main thread and would
    /// block the CGEventTap, causing macOS to disable ⌘⇥ interception.
    private func pollNowPlayingMR(wasPlaying: Bool) {
        guard let mrInfo = MRNowPlayingInfo else {
            isQuerying = false
            if isPlaying {
                isPlaying = false
                currentTitle = nil
                currentArtist = nil
                currentSource = nil
                currentSourceBundleID = nil
                notify()
            }
            return
        }
        mrInfo(.main) { [weak self] info in
            guard let self else { return }
            self.isQuerying = false
            let dict = (info as? [String: Any]) ?? [:]

            // Rate key present → trust it; absent → infer from title/artist presence.
            let rateNum = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber
            let nowPlaying: Bool
            if let r = rateNum {
                nowPlaying = r.doubleValue > 0
            } else {
                nowPlaying = !dict.isEmpty
                    && dict.keys.contains(where: { $0.contains("Title") || $0.contains("Artist") })
            }

            if nowPlaying {
                let title  = dict.first(where: { $0.key.contains("Title")  })?.value as? String
                let artist = dict.first(where: { $0.key.contains("Artist") })?.value as? String
                let stateChanged = !self.isPlaying
                self.isPlaying     = true
                self.currentTitle  = title
                self.currentArtist = artist
                if stateChanged { self.restartPollTimer() }
                
                if let getPID = MRGetNowPlayingPID {
                    getPID(.main) { [weak self] pid in
                        guard let self else { return }
                        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
                            self.currentSource = app.localizedName ?? "Now Playing"
                            self.currentSourceBundleID = app.bundleIdentifier
                        } else {
                            self.currentSource = "Now Playing"
                            self.currentSourceBundleID = nil
                        }
                        self.finishPollNowPlayingMR(dict: dict, wasPlaying: wasPlaying)
                    }
                } else {
                    self.currentSource = "Now Playing"
                    self.currentSourceBundleID = nil
                    self.finishPollNowPlayingMR(dict: dict, wasPlaying: wasPlaying)
                }
            } else {
                if self.isPlaying || self.currentTitle != nil {
                    let was = self.isPlaying
                    self.isPlaying = false
                    self.currentTitle = nil
                    self.currentArtist = nil
                    self.currentSource = nil
                    self.currentSourceBundleID = nil
                    self.notify()
                    if was { self.restartPollTimer() }
                }
            }
        }
    }

    private func finishPollNowPlayingMR(dict: [String: Any], wasPlaying: Bool) {
        if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
           let img = NSImage(data: data) {
            self.albumArt = img
        } else {
            for (_, val) in dict {
                if let data = val as? Data, data.count > 1000,
                   let img = NSImage(data: data) { self.albumArt = img; break }
            }
        }
        if wasPlaying != self.isPlaying || self.isPlaying { self.notify() }
    }

    // MARK: - Apple Music (AppleScript)

    private func pollAppleMusic() {
        // Check if Music is running
        let musicRunning = isAppleMusicRunning
        if !musicRunning {
            if isPlaying || currentTitle != nil {
                isPlaying = false; currentTitle = nil; currentArtist = nil; currentSource = nil; currentSourceBundleID = nil
                notify()
            }
            restartPollTimer()
            return
        }

        isQuerying = true
        queryStartedAt = ProcessInfo.processInfo.systemUptime
        let wasPlaying = isPlaying

        let script = """
        tell application "Music"
            set v to sound volume
            if player state is playing then
                set t to name of current track
                set a to artist of current track
                return "playing|" & t & "|" & a & "|" & (v as text)
            else
                return "stopped|" & (v as text)
            end if
        end tell
        """

        MusicMonitor.scriptQueue.async { [weak self] in
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            let result = appleScript?.executeAndReturnError(&error).stringValue ?? ""

            DispatchQueue.main.async {
                guard let self else { return }
                self.isQuerying = false

                if error != nil {
                    if self.isPlaying || self.currentTitle != nil {
                        self.isPlaying = false
                        self.currentTitle = nil
                        self.currentArtist = nil
                        self.currentSource = nil
                        self.currentSourceBundleID = nil
                        self.notify()
                        self.restartPollTimer()
                    }
                    return
                }

                self.currentSource = "Apple Music"
                self.currentSourceBundleID = "com.apple.Music"
                let stateChanged: Bool
                if result.hasPrefix("playing|") {
                    let parts = String(result.dropFirst(8)).components(separatedBy: "|")
                    stateChanged = !self.isPlaying
                    self.isPlaying = true
                    self.currentTitle = parts.first
                    self.currentArtist = parts.count > 1 ? parts[1] : nil
                    if parts.count > 2, let v = Int(parts[2]) { self.volume = v }
                } else if result.hasPrefix("stopped|") {
                    let parts = result.components(separatedBy: "|")
                    stateChanged = self.isPlaying
                    self.isPlaying = false
                    if parts.count > 1, let v = Int(parts[1]) { self.volume = v }
                } else {
                    stateChanged = self.isPlaying
                    self.isPlaying = false
                }

                self.fetchAlbumArt()
                if wasPlaying != self.isPlaying || self.isPlaying {
                    self.notify()
                }
                if stateChanged { self.restartPollTimer() }
            }
        }
    }

    private func fetchAlbumArt() {
        // Prefer the helper (a fresh get read); the direct MR read below returns
        // nothing on macOS 15.4+ anyway. In Apple Music mode only adopt the art
        // when Music is the now-playing app.
        if MediaRemoteAdapter.isAvailable {
            adapter.query { [weak self] np in
                guard let self else { return }
                if self.settings.musicSource == .appleMusic
                    && self.currentSourceBundleID != "com.apple.Music" { return }
                if let art = np?.art {
                    self.albumArt = art
                    self.notify()
                } else if let url = np?.artURL {
                    self.fetchURLArtwork(url)
                } else if let bid = self.currentSourceBundleID {
                    self.fetchScriptArtwork(bid: bid)
                }
            }
            return
        }
        guard let mrInfo = MRNowPlayingInfo else { return }
        mrInfo(.main) { [weak self] info in
            guard let self, let dict = info as? [String: Any] else { return }
            // Try the known key name; also scan for any large Data blob that decodes as an image
            let candidate: NSImage? = {
                if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                   let img = NSImage(data: data) { return img }
                for (_, val) in dict {
                    if let data = val as? Data, data.count > 1000,
                       let img = NSImage(data: data) { return img }
                }
                return nil
            }()
            guard let image = candidate else { return }
            DispatchQueue.main.async {
                self.albumArt = image
                self.notify()   // notify after art is set, not before
            }
        }
    }

    // MARK: - Scriptable-source enrichment (Music / Spotify)

    /// Sources whose track info AppleScript can read without any MediaRemote
    /// entitlement. Browsers and other apps have no scriptable fallback.
    private static let scriptableSources: [String: String] = [
        "com.apple.Music": "Music",
        "com.spotify.client": "Spotify",
    ]

    private var titleFetchInFlight = false
    private var artFetchKey: String?          // "bundleID|title" of the last attempt
    private var artFetchAt: TimeInterval = 0
    private var urlArtKey: String?            // URL of the last download attempt
    private var urlArtAt: TimeInterval = 0

    /// Downloads artwork MediaRemote referenced by URL instead of embedding
    /// (macOS 26+ snapshots carry only the artwork identifier, a CDN URL for
    /// Music). One attempt per URL; retried every few seconds while absent.
    private func fetchURLArtwork(_ url: URL) {
        let key = url.absoluteString
        let now = ProcessInfo.processInfo.systemUptime
        guard urlArtKey != key || (albumArt == nil && now - urlArtAt > 3) else { return }
        urlArtKey = key
        urlArtAt = now
        let bid = currentSourceBundleID
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.currentSourceBundleID == bid else { return }
                self.albumArt = img
                self.notify()
            }
        }.resume()
    }

    /// The helper can report "playing" with empty metadata (OS builds that
    /// redact fields for unentitled readers). AppleScript still returns the
    /// real track info for Music/Spotify.
    private func fetchScriptTitle(bid: String) {
        guard let appName = Self.scriptableSources[bid], !titleFetchInFlight else { return }
        titleFetchInFlight = true
        let script = """
        tell application "\(appName)"
            if player state is playing then
                return name of current track & "|" & artist of current track
            end if
        end tell
        return ""
        """
        MusicMonitor.scriptQueue.async { [weak self] in
            let result = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.titleFetchInFlight = false
                guard self.currentSourceBundleID == bid, !result.isEmpty else { return }
                let parts = result.components(separatedBy: "|")
                guard let title = parts.first, !title.isEmpty, title != self.currentTitle else { return }
                self.currentTitle = title
                self.currentArtist = (parts.count > 1 && !parts[1].isEmpty) ? parts[1] : nil
                self.notify()
            }
        }
    }

    /// AppleScript artwork: Music hands over the raw bytes, Spotify a URL.
    /// Fetched once per (source, title); retried every few seconds while absent.
    private func fetchScriptArtwork(bid: String) {
        guard Self.scriptableSources[bid] != nil else { return }
        let key = bid + "|" + (currentTitle ?? "")
        let now = ProcessInfo.processInfo.systemUptime
        guard artFetchKey != key || (albumArt == nil && now - artFetchAt > 3) else { return }
        artFetchKey = key
        artFetchAt = now
        if bid == "com.apple.Music" {
            let script = "tell application \"Music\" to get data of artwork 1 of current track"
            MusicMonitor.scriptQueue.async { [weak self] in
                var error: NSDictionary?
                let desc = NSAppleScript(source: script)?.executeAndReturnError(&error)
                guard error == nil, let desc, let img = NSImage(data: desc.data) else { return }
                DispatchQueue.main.async {
                    guard let self, self.currentSourceBundleID == bid else { return }
                    self.albumArt = img
                    self.notify()
                }
            }
        } else {
            let script = "tell application \"Spotify\" to get artwork url of current track"
            MusicMonitor.scriptQueue.async { [weak self] in
                guard let urlString = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue,
                      let url = URL(string: urlString) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        guard let self, self.currentSourceBundleID == bid else { return }
                        self.albumArt = img
                        self.notify()
                    }
                }.resume()
            }
        }
    }

    // MARK: - Media-key routing (Apple Music priority)
    //
    // When two things are playing at once (Music plus a browser tab, say), the
    // hardware play key goes to whichever app macOS picked as the Now Playing
    // app — usually the one that started most recently. With the setting on we
    // consume the key in SystemHUDMonitor's tap and drive Music.app directly by
    // AppleScript, which never touches the other source.
    //
    // Deciding that has to be instant (it happens inside the event tap), so
    // Music's state is polled here and cached rather than queried on the press.

    private(set) var musicAppState: MusicAppState = .notRunning
    private var isQueryingMusicState = false
    private var musicStateQueryStartedAt: TimeInterval = 0

    /// Set when MSG itself paused Music via a routed key. Without it, pressing
    /// play again would see Music paused, decline to route, and hand the key to
    /// whatever else is playing — so you could pause Music but never resume it.
    private var didPauseAppleMusic = false

    /// Whether the next transport key should go to Music.app instead of the
    /// system Now Playing app. Read from the event tap: cached state only.
    var shouldRouteMediaKeysToAppleMusic: Bool {
        guard settings.mediaKeyPriorityMusic else { return false }
        switch musicAppState {
        case .playing:              return true
        case .paused:               return didPauseAppleMusic
        case .stopped, .notRunning: return false
        }
    }

    func handleRoutedMediaKey(_ action: MediaKeyAction) {
        switch action {
        case .playPause:
            // Flip locally rather than waiting for the poll: the cache is up to
            // a second stale, and a quick second press must not re-decide the
            // target from a state we already know is out of date.
            if musicAppState == .playing {
                musicAppState = .paused
                didPauseAppleMusic = true
            } else {
                musicAppState = .playing
                didPauseAppleMusic = false
            }
            tellMusic("playpause")
        case .next:     tellMusic("next track")
        case .previous: tellMusic("previous track")
        }
    }

    /// Refresh the cached Music.app state. Runs on the shared serial script
    /// queue like every other NSAppleScript call here, and never launches Music.
    private func refreshAppleMusicState() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil else {
            musicAppState = .notRunning
            didPauseAppleMusic = false
            return
        }
        if isQueryingMusicState,
           ProcessInfo.processInfo.systemUptime - musicStateQueryStartedAt > 6 {
            isQueryingMusicState = false
        }
        guard !isQueryingMusicState else { return }
        isQueryingMusicState = true
        musicStateQueryStartedAt = ProcessInfo.processInfo.systemUptime

        // Compared against the constants rather than coerced with `as string`:
        // `player state` is an enumeration, and coercing it isn't dependable.
        let script = """
        tell application "Music"
            if player state is playing then
                return "playing"
            else if player state is paused then
                return "paused"
            else
                return "stopped"
            end if
        end tell
        """
        MusicMonitor.scriptQueue.async { [weak self] in
            let result = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.isQueryingMusicState = false
                switch result {
                case "playing":
                    self.musicAppState = .playing
                    self.didPauseAppleMusic = false
                case "paused":
                    self.musicAppState = .paused
                default:
                    self.musicAppState = .stopped
                    self.didPauseAppleMusic = false
                }
            }
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        switch settings.musicSource {
        case .nowPlaying:
            if MediaRemoteAdapter.isAvailable { MediaRemoteAdapter.sendCommand(kMRTogglePlayPause); return }
            if let mr = MRSendCommand { _ = mr(kMRTogglePlayPause, nil); return }
            tellApp("Music", "playpause")
        case .appleMusic:
            tellMusic("playpause")
        }
    }

    func nextTrack() {
        switch settings.musicSource {
        case .nowPlaying:
            if MediaRemoteAdapter.isAvailable { MediaRemoteAdapter.sendCommand(kMRNextTrack); return }
            if let mr = MRSendCommand { _ = mr(kMRNextTrack, nil); return }
            tellApp("Music", "next track")
        case .appleMusic:
            tellMusic("next track")
        }
    }

    func previousTrack() {
        switch settings.musicSource {
        case .nowPlaying:
            if MediaRemoteAdapter.isAvailable { MediaRemoteAdapter.sendCommand(kMRPreviousTrack); return }
            if let mr = MRSendCommand { _ = mr(kMRPreviousTrack, nil); return }
            tellApp("Music", "previous track")
        case .appleMusic:
            tellMusic("previous track")
        }
    }

    func adjustVolume(by delta: Int) {
        volume = max(0, min(100, volume + delta))
        switch settings.musicSource {
        case .nowPlaying:
            Self.setSystemVolume(volume)
        case .appleMusic:
            tellMusic("set sound volume to \(volume)")
        }
    }

    // MARK: - Helpers

    private func tellApp(_ app: String, _ command: String) {
        let script = "tell application \"\(app)\" to \(command)"
        MusicMonitor.scriptQueue.async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    private func tellMusic(_ command: String) {
        tellApp("Music", command)
    }

    private static func setSystemVolume(_ vol: Int) {
        scriptQueue.async {
            NSAppleScript(source: "set volume output volume \(vol)")?.executeAndReturnError(nil)
        }
    }
}
