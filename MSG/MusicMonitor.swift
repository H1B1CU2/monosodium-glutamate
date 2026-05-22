import AppKit

// MARK: - MediaRemote bindings (weak-linked at build time)

private typealias MRNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
private typealias MRSendCommandFunc = @convention(c) (UInt32, CFDictionary?) -> Bool
private typealias MRRegisterFunc = @convention(c) (DispatchQueue) -> Void

private func mrsym<T>(_ name: String, as: T.Type) -> T? {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

private let MRNowPlayingInfo: MRNowPlayingInfoFunc? = mrsym("MRMediaRemoteGetNowPlayingInfo", as: MRNowPlayingInfoFunc.self)
private let MRSendCommand: MRSendCommandFunc? = mrsym("MRMediaRemoteSendCommand", as: MRSendCommandFunc.self)
private let MRRegister: MRRegisterFunc? = mrsym("MRMediaRemoteRegisterForNowPlayingNotifications", as: MRRegisterFunc.self)

// MRMediaRemote commands
private let kMRPlay = UInt32(0)
private let kMRPause = UInt32(1)
private let kMRTogglePlayPause = UInt32(2)
private let kMRNextTrack = UInt32(4)
private let kMRPreviousTrack = UInt32(5)

// MARK: - MusicMonitor

final class MusicMonitor {

    private let settings: AppSettings

    private(set) var isPlaying = false
    private(set) var currentTitle: String?
    private(set) var currentArtist: String?
    private(set) var volume: Int = 50
    private(set) var currentSource: String?
    private(set) var albumArt: NSImage?

    var onChange: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        MRRegister?(.main)
    }

    @objc func openMusic() {
        let script = "tell application \"Music\" to activate"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    // MARK: - Polling

    private var pollTimer: Timer?
    private var isQuerying = false

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
        poll()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func poll() {
        guard !isQuerying else { return }
        switch settings.musicSource {
        case .nowPlaying:
            pollNowPlaying()
        case .appleMusic:
            pollAppleMusic()
        }
    }

    // MARK: - Now Playing (poll multiple apps)

    private var mrPending = false

    private func pollNowPlaying() {
        guard !isQuerying else { return }
        isQuerying = true
        let wasPlaying = isPlaying

        // AppleScript first — checks Music + Spotify (reliable, works now)
        let script = """
        tell application "Music"
            if player state is playing then
                set t to name of current track
                set a to artist of current track
                return "Music|playing|" & t & "|" & a
            end if
        end tell
        tell application "Spotify"
            if player state is playing then
                set t to name of current track
                set a to artist of current track
                return "Spotify|playing|" & t & "|" & a
            end if
        end tell
        return "none|"
        """

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.isQuerying = false

                if result.hasPrefix("Music|playing|") || result.hasPrefix("Spotify|playing|") {
                    let parts = result.components(separatedBy: "|")
                    self.currentSource = parts[0]
                    self.isPlaying = true
                    self.currentTitle = parts.count > 2 ? parts[2] : nil
                    self.currentArtist = parts.count > 3 ? parts[3] : nil
                } else {
                    self.isPlaying = false
                    self.currentTitle = nil
                    self.currentArtist = nil
                    // Bonus: try MediaRemote for other apps (Safari, etc.)
                    self.tryBonusMR()
                }
                self.volume = Self.readSystemVolume()
                self.fetchAlbumArt()
                if wasPlaying != self.isPlaying || self.isPlaying {
                    self.onChange?()
                }
            }
        }
    }

    private func tryBonusMR() {
        guard let mrInfo = MRNowPlayingInfo, !mrPending else { return }
        mrPending = true
        mrInfo(.main) { [weak self] info in
            guard let self else { return }
            self.mrPending = false
            guard let dict = info as? [String: Any], !dict.isEmpty,
                  let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber,
                  rate.doubleValue > 0 else { return }
            let title = dict.first(where: { $0.key.contains("Title") })?.value as? String
            let artist = dict.first(where: { $0.key.contains("Artist") })?.value as? String
            if title != nil || artist != nil {
                self.isPlaying = true
                self.currentTitle = title
                self.currentArtist = artist
                self.currentSource = "Now Playing"
                self.onChange?()
            }
        }
    }

    // MARK: - Apple Music (AppleScript)

    private func pollAppleMusic() {
        // Check if Music is running
        let musicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
        if !musicRunning {
            if isPlaying || currentTitle != nil {
                isPlaying = false; currentTitle = nil; currentArtist = nil; currentSource = nil
                onChange?()
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

        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                        self.onChange?()
                    }
                    return
                }

                self.currentSource = "Apple Music"
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
                    self.onChange?()
                }
            }
        }
    }

    private func fetchAlbumArt() {
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
                self.onChange?()   // notify after art is set, not before
            }
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        switch settings.musicSource {
        case .nowPlaying:
            if let mr = MRSendCommand { _ = mr(kMRTogglePlayPause, nil); return }
            tellApp("Music", "playpause")
        case .appleMusic:
            tellMusic("playpause")
        }
    }

    func nextTrack() {
        switch settings.musicSource {
        case .nowPlaying:
            if let mr = MRSendCommand { _ = mr(kMRNextTrack, nil); return }
            tellApp("Music", "next track")
        case .appleMusic:
            tellMusic("next track")
        }
    }

    func previousTrack() {
        switch settings.musicSource {
        case .nowPlaying:
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
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    private func tellMusic(_ command: String) {
        tellApp("Music", command)
    }

    private static func readSystemVolume() -> Int {
        let script = "output volume of (get volume settings)"
        if let result = NSAppleScript(source: script)?.executeAndReturnError(nil) {
            return Int(result.int32Value)
        }
        return 50
    }

    private static func setSystemVolume(_ vol: Int) {
        NSAppleScript(source: "set volume output volume \(vol)")?.executeAndReturnError(nil)
    }
}
