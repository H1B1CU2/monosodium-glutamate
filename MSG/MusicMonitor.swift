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

// MARK: - MusicMonitor

final class MusicMonitor {

    private let settings: AppSettings

    /// Perl-hosted MediaRemote bridge — the only way to read system Now
    /// Playing on macOS 15.4+. When the helper dylib is bundled, it pushes
    /// state and the direct MR/AppleScript paths below become fallbacks.
    private let adapter = MediaRemoteAdapter()

    private(set) var isPlaying = false
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
        MRRegister?(.main)
        adapter.onUpdate = { [weak self] np in
            self?.applyAdapterState(np)
        }
    }

    /// Pushes helper updates into the monitor state. In Now Playing mode the
    /// adapter is the source of truth; in Apple Music mode AppleScript drives
    /// title/state and the adapter only contributes album art (the direct
    /// MediaRemote art fetch is blocked on macOS 15.4+).
    private func applyAdapterState(_ np: MediaRemoteAdapter.NowPlaying) {
        switch settings.musicSource {
        case .nowPlaying:
            let wasPlaying = isPlaying
            if np.playing {
                isPlaying = true
                currentTitle = np.title
                currentArtist = np.artist
                if np.pid > 0, let app = NSRunningApplication(processIdentifier: np.pid) {
                    currentSource = app.localizedName ?? "Now Playing"
                    currentSourceBundleID = app.bundleIdentifier
                } else {
                    currentSource = "Now Playing"
                    currentSourceBundleID = nil
                }
                if let art = np.art { albumArt = art }
                notify()
            } else if wasPlaying || currentTitle != nil {
                isPlaying = false
                currentTitle = nil
                currentArtist = nil
                currentSource = nil
                currentSourceBundleID = nil
                notify()
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

    // MARK: - Polling

    private var pollTimer: Timer?
    private var isQuerying = false
    /// When the in-flight AppleScript query started (systemUptime). Used by the
    /// watchdog in poll() to recover if a completion is never delivered.
    private var queryStartedAt: TimeInterval = 0

    func start() {
        if MediaRemoteAdapter.isAvailable { adapter.start() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
        poll()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        adapter.stop()
    }

    private func poll() {
        // Watchdog: if a previous query never completed (hung/dropped after wake),
        // don't stay blocked forever — clear the guard so polling can resume.
        if isQuerying, ProcessInfo.processInfo.systemUptime - queryStartedAt > 6 {
            isQuerying = false
        }
        switch settings.musicSource {
        case .nowPlaying:
            // Adapter pushes state; poll only as fallback when it isn't running.
            guard !adapter.isRunning else { return }
            pollNowPlaying()          // MR is non-blocking; no isQuerying guard needed
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
                self.isPlaying     = true
                self.currentTitle  = title
                self.currentArtist = artist
                
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
                    self.isPlaying = false
                    self.currentTitle = nil
                    self.currentArtist = nil
                    self.currentSource = nil
                    self.currentSourceBundleID = nil
                    self.notify()
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
        let musicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
        if !musicRunning {
            if isPlaying || currentTitle != nil {
                isPlaying = false; currentTitle = nil; currentArtist = nil; currentSource = nil; currentSourceBundleID = nil
                notify()
            }
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
            return
        }

        if pollTimer?.timeInterval != 1.0 {
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
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
                    }
                    return
                }

                self.currentSource = "Apple Music"
                self.currentSourceBundleID = "com.apple.Music"
                if result.hasPrefix("playing|") {
                    let parts = String(result.dropFirst(8)).components(separatedBy: "|")
                    self.isPlaying = true
                    self.currentTitle = parts.first
                    self.currentArtist = parts.count > 1 ? parts[1] : nil
                    if parts.count > 2, let v = Int(parts[2]) { self.volume = v }
                } else if result.hasPrefix("stopped|") {
                    let parts = result.components(separatedBy: "|")
                    self.isPlaying = false
                    if parts.count > 1, let v = Int(parts[1]) { self.volume = v }
                } else {
                    self.isPlaying = false
                }

                self.fetchAlbumArt()
                if wasPlaying != self.isPlaying || self.isPlaying {
                    self.notify()
                }
            }
        }
    }

    private func fetchAlbumArt() {
        // Helper streams art with its updates; the direct MR read below
        // returns nothing on macOS 15.4+ anyway.
        if adapter.isRunning {
            if let art = adapter.latest?.art { albumArt = art }
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
