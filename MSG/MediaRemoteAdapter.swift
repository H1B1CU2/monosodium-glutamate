import AppKit

/// Bridges to MediaRemote through an Apple-signed perl process.
///
/// macOS 15.4+ refuses now-playing data to processes without the private
/// `com.apple.mediaremote.fetch-now-playing-info` entitlement, and AMFI kills
/// self-signed binaries that claim it. Platform binaries still pass the check,
/// so `Resources/libMSGMediaRemote.dylib` (built from MediaRemoteHelper.m) is
/// loaded into `/usr/bin/perl` via DynaLoader.
///
/// Reads are POLLED, not streamed (modelled on github.com/kernoeb/mac-now-playing):
/// each `query()` spawns a fresh short-lived helper in "get" mode that reads the
/// current now-playing snapshot via the synchronous `MRNowPlayingRequest` class
/// and prints one JSON line — `{"playing":Bool,"title":…,"artist":…,"pid":Int,
/// "art":base64}`. A brand-new process per poll can never go stale the way a
/// long-lived notification stream does (which was the "works for a while then
/// freezes" bug). `sendCommand` spawns the same helper in one-shot command mode.
final class MediaRemoteAdapter {

    struct NowPlaying {
        let playing: Bool
        let title: String?
        let artist: String?
        let pid: pid_t
        let art: NSImage?
        /// Artwork referenced by URL instead of embedded bytes — macOS 26+
        /// snapshots only carry the artwork identifier (a CDN URL for Music).
        let artURL: URL?
        let duration: Double?
        let elapsed: Double?
        let rate: Double?
        let timestamp: Double?

        /// Estimated current progress 0.0 ... 1.0
        var progress: Double? {
            guard let duration, duration > 0, let elapsed else { return nil }
            let r = rate ?? (playing ? 1.0 : 0.0)
            let dt = timestamp.map { max(0, Date().timeIntervalSince1970 - $0) } ?? 0
            let current = elapsed + dt * r
            return max(0.0, min(1.0, current / duration))
        }
    }

    /// The most recent successful read (used by the Apple Music art path).
    private(set) var latest: NowPlaying?

    // Decoded-artwork cache: the helper re-sends the (base64) artwork on every
    // poll, but decoding it into an NSImage each second is wasteful, so reuse the
    // last image when the bytes are unchanged. Only touched from the serialized
    // read below (queries never overlap — MusicMonitor guards with `isQuerying`).
    private var lastArtB64: String?
    private var lastArtImage: NSImage?

    static var helperURL: URL? {
        Bundle.main.url(forResource: "libMSGMediaRemote", withExtension: "dylib")
    }
    static var isAvailable: Bool { helperURL != nil }

    private static func makeHelperProcess(mode: String) -> Process? {
        guard let helper = helperURL else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0]) or exit 1;", "--", helper.path]
        p.environment = [
            "MSG_MR_MODE": mode,
            "MSG_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
        ]
        p.standardError = FileHandle.nullDevice
        return p
    }

    /// One-shot fresh read of the current now-playing state. The completion runs
    /// on the main thread with `nil` when the read failed or timed out (in which
    /// case the caller should keep its previous state rather than clear it).
    func query(completion: @escaping (NowPlaying?) -> Void) {
        guard let p = Self.makeHelperProcess(mode: "get") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
        } catch {
            NSLog("[Music] MediaRemote get failed to start: %@", String(describing: error))
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Watchdog: a wedged read must never freeze the poller. Terminating the
        // process closes the pipe, so the read below unblocks and returns.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: watchdog)

        // Drain concurrently (not in terminationHandler): a large artwork line can
        // exceed the pipe buffer, and reading only after exit would deadlock the
        // child on its write.
        DispatchQueue.global().async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            let np = self?.parse(data)
            if let np { self?.latest = np }
            DispatchQueue.main.async { completion(np) }
        }
    }

    private func parse(_ data: Data) -> NowPlaying? {
        guard !data.isEmpty else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Self.firstLine(data))) as? [String: Any] else { return nil }
        return nowPlaying(from: obj)
    }

    /// The helper prints a single JSON line; ignore any trailing bytes.
    private static func firstLine(_ data: Data) -> Data {
        guard let nl = data.firstIndex(of: 0x0A) else { return data }
        return data.subdata(in: data.startIndex..<nl)
    }

    private func nowPlaying(from obj: [String: Any]) -> NowPlaying {

        var art: NSImage? = nil
        if let b64 = obj["art"] as? String {
            if b64 == lastArtB64 {
                art = lastArtImage
            } else if let decoded = Data(base64Encoded: b64), let img = NSImage(data: decoded) {
                art = img
                lastArtB64 = b64
                lastArtImage = img
            }
        }

        return NowPlaying(
            playing: obj["playing"] as? Bool ?? false,
            title: obj["title"] as? String,
            artist: obj["artist"] as? String,
            pid: pid_t(obj["pid"] as? Int ?? 0),
            art: art,
            artURL: (obj["artURL"] as? String).flatMap(URL.init(string:)),
            duration: obj["duration"] as? Double,
            elapsed: obj["elapsed"] as? Double,
            rate: obj["rate"] as? Double,
            timestamp: obj["timestamp"] as? Double
        )
    }

    /// One app's player, of every app that has one (as Control Center lists).
    struct Player {
        let bundle: String
        let name: String?
        /// The system's own now-playing app — what the media keys reach.
        let active: Bool
        let nowPlaying: NowPlaying
        /// Enabled command codes; nil when unknown (then everything is assumed).
        let commands: Set<Int>?

        var canSkipForward: Bool { commands.map { $0.contains(4) } ?? true }
        var canSkipBack: Bool { commands.map { $0.contains(5) } ?? true }
    }

    /// WebKit registers playback separately from its host app. Its display name identifies
    /// the host even while the app's metadata is still empty or updating.
    static func withoutWebKitTwins(_ players: [Player]) -> [Player] {
        func text(_ value: String?) -> String {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        }
        func isWebKit(_ player: Player) -> Bool { player.bundle.hasPrefix("com.apple.WebKit") }
        func sameTrack(_ a: Player, _ b: Player) -> Bool {
            let title = text(a.nowPlaying.title)
            guard !title.isEmpty, title == text(b.nowPlaying.title) else { return false }
            let first = text(a.nowPlaying.artist), second = text(b.nowPlaying.artist)
            return first.isEmpty || second.isEmpty || first == second
        }
        let apps = players.indices.filter { !isWebKit(players[$0]) }
        var twins: [Int: [Player]] = [:]
        var removed = Set<Int>()
        for index in players.indices where isWebKit(players[index]) {
            let helper = players[index]
            let name = text(helper.name)
            let named = apps.filter { !name.isEmpty && text(players[$0].name) == name }
            // Conflicting owner names are ambiguous; never collapse independent apps.
            let candidates = name.isEmpty
                ? apps.filter { sameTrack(helper, players[$0]) }
                : named
            guard candidates.count == 1, let owner = candidates.first else { continue }
            twins[owner, default: []].append(helper)
            removed.insert(index)
        }
        return players.indices.compactMap { index in
            guard !removed.contains(index) else { return nil }
            let app = players[index]
            guard let helpers = twins[index] else { return app }
            // Keep the app's command destination and icon identity, but fill a metadata-free
            // app entry from its helper so it doesn't become a second, empty SP8CE player.
            let np = app.nowPlaying
            let helper = helpers.first(where: { !text($0.nowPlaying.title).isEmpty })
            let metadata = text(np.title).isEmpty ? helper?.nowPlaying ?? np : np
            let artwork = helpers.first(where: { sameTrack(app, $0) })?.nowPlaying
            let merged = NowPlaying(playing: metadata.playing, title: metadata.title, artist: metadata.artist,
                                    pid: np.pid, art: metadata.art ?? artwork?.art,
                                    artURL: metadata.artURL ?? artwork?.artURL,
                                    duration: metadata.duration, elapsed: metadata.elapsed,
                                    rate: metadata.rate, timestamp: metadata.timestamp)
            return Player(bundle: app.bundle, name: app.name,
                          active: app.active || helpers.contains(where: \.active),
                          nowPlaying: merged, commands: app.commands)
        }
    }

    /// A media PID can belong to an XPC helper, whose icon is the generic plug-in cube.
    /// Resolve the registered app first, including an unpaired WebKit entry's host name.
    static func applicationIcon(for player: Player) -> NSImage? {
        let workspace = NSWorkspace.shared
        if !player.bundle.hasPrefix("com.apple.WebKit") {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: player.bundle).first,
               let icon = app.icon { return icon }
            if let url = workspace.urlForApplication(withBundleIdentifier: player.bundle) {
                return workspace.icon(forFile: url.path)
            }
        } else {
            if let name = player.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                let owners = workspace.runningApplications.filter {
                    $0.bundleIdentifier?.hasPrefix("com.apple.WebKit") != true
                        && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
                }
                if owners.count == 1 { return owners[0].icon }
            }
            // Never show the WebKit process's generic icon as the app's icon.
            return nil
        }
        return player.nowPlaying.pid > 0
            ? NSRunningApplication(processIdentifier: player.nowPlaying.pid)?.icon : nil
    }

    /// Every player, each with its own info. Main thread; empty on failure.
    func queryPlayers(completion: @escaping ([Player]) -> Void) {
        guard let p = Self.makeHelperProcess(mode: "players") else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        DispatchQueue.global().async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            var players: [Player] = []
            if let self, !data.isEmpty,
               let list = (try? JSONSerialization.jsonObject(with: Self.firstLine(data))) as? [[String: Any]] {
                players = list.compactMap { obj in
                    guard let bundle = obj["bundle"] as? String else { return nil }
                    return Player(bundle: bundle, name: obj["name"] as? String,
                                  active: obj["active"] as? Bool ?? false,
                                  nowPlaying: self.nowPlaying(from: obj),
                                  commands: (obj["commands"] as? [Int]).map(Set.init))
                }
            }
            DispatchQueue.main.async { completion(players) }
        }
    }

    /// A long-lived helper that calls `onChange` (main thread) each time
    /// Now Playing changes. Terminate the returned process to stop it.
    static func watch(onChange: @escaping () -> Void) -> Process? {
        guard let p = makeHelperProcess(mode: "watch") else { return nil }
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { onChange() }
        }
        do { try p.run() } catch { return nil }
        return p
    }

    /// A command to one app's player only (codes as `sendCommand`).
    /// `reached` is false when the app wouldn't take it and the system sent
    /// it to its own now-playing app instead (a pause there is undone).
    static func sendCommand(_ cmd: UInt32, toBundle bundle: String, reached: ((Bool) -> Void)? = nil) {
        guard let p = makeHelperProcess(mode: "player-command") else { return }
        p.environment?["MSG_MR_CMD"] = String(cmd)
        p.environment?["MSG_MR_BUNDLE"] = bundle
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { process in
            let ok = process.terminationStatus != 3
            DispatchQueue.main.async { reached?(ok) }
        }
        try? p.run()
    }

    /// kMRMediaRemote command codes: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    static func sendCommand(_ cmd: UInt32) {
        guard let p = makeHelperProcess(mode: "command") else { return }
        p.environment?["MSG_MR_CMD"] = String(cmd)
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }
}
