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
        // The helper prints a single JSON line; ignore any trailing bytes.
        let line: Data
        if let nl = data.firstIndex(of: 0x0A) {
            line = data.subdata(in: data.startIndex..<nl)
        } else {
            line = data
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }

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
            artURL: (obj["artURL"] as? String).flatMap(URL.init(string:))
        )
    }

    /// kMRMediaRemote command codes: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    static func sendCommand(_ cmd: UInt32) {
        guard let p = makeHelperProcess(mode: "command") else { return }
        p.environment?["MSG_MR_CMD"] = String(cmd)
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }
}
