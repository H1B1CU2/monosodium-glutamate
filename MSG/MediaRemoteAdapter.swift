import AppKit

/// Bridges to MediaRemote through an Apple-signed perl process.
///
/// macOS 15.4+ refuses now-playing data to processes without the private
/// `com.apple.mediaremote.fetch-now-playing-info` entitlement, and AMFI kills
/// self-signed binaries that claim it. Platform binaries still pass the check,
/// so `Resources/libMSGMediaRemote.dylib` (built from MediaRemoteHelper.m) is
/// loaded into `/usr/bin/perl` via DynaLoader and streams JSON lines —
/// `{"playing":Bool,"title":…,"artist":…,"pid":Int,"art":base64}` — over
/// stdout. The helper exits on its own when MSG dies.
final class MediaRemoteAdapter {

    struct NowPlaying {
        let playing: Bool
        let title: String?
        let artist: String?
        let pid: pid_t
        let art: NSImage?
    }

    private(set) var latest: NowPlaying?
    /// Called on the main thread whenever the helper reports a change.
    var onUpdate: ((NowPlaying) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var stopped = true

    static var helperURL: URL? {
        Bundle.main.url(forResource: "libMSGMediaRemote", withExtension: "dylib")
    }
    static var isAvailable: Bool { helperURL != nil }
    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        guard stopped else { return }
        stopped = false
        spawn()
    }

    func stop() {
        stopped = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private static func makeHelperProcess(mode: String) -> Process? {
        guard let helper = helperURL else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0]) or exit 1;", "--", helper.path]
        p.environment = ["MSG_MR_MODE": mode]
        p.standardError = FileHandle.nullDevice
        return p
    }

    private func spawn() {
        guard let p = Self.makeHelperProcess(mode: "stream") else { return }
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            // Helper died (sleep/wake, mediaremoted restart) — respawn unless stopped.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.stopped else { return }
                self.spawn()
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            stopped = true
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
        // Defensive cap: art lines are large but bounded; anything bigger is garbage.
        if buffer.count > 16_000_000 { buffer.removeAll() }
    }

    private func handle(line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let art = (obj["art"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { NSImage(data: $0) }
        let np = NowPlaying(
            playing: obj["playing"] as? Bool ?? false,
            title: obj["title"] as? String,
            artist: obj["artist"] as? String,
            pid: pid_t(obj["pid"] as? Int ?? 0),
            art: art
        )
        latest = np
        onUpdate?(np)
    }

    /// kMRMediaRemote command codes: 0 play, 1 pause, 2 toggle, 4 next, 5 previous.
    static func sendCommand(_ cmd: UInt32) {
        guard let p = makeHelperProcess(mode: "command") else { return }
        p.environment?["MSG_MR_CMD"] = String(cmd)
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
    }
}
