import AppKit

/// Monitors Music.app playback via AppleScript polling.
/// Polls at 1s when Music is running, 3s when idle.
final class MusicMonitor: NSObject {
    private(set) var isPlaying = false
    private(set) var currentTitle: String?
    private(set) var currentArtist: String?
    private(set) var volume: Int = 50

    var onChange: (() -> Void)?

    @objc func openMusic() {
        let script = "tell application \"Music\" to activate"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

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

        // Skip AppleScript if Music isn't running
        let musicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first != nil
        if !musicRunning {
            if isPlaying || currentTitle != nil {
                isPlaying = false; currentTitle = nil; currentArtist = nil
                onChange?()
            }
            // Slow down polling when Music isn't running
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            if let t = pollTimer { RunLoop.current.add(t, forMode: .common) }
            return
        }

        // Ensure we're polling at 1s when Music is running
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
                    // AppleScript failed (likely sandbox/permission)
                    if self.isPlaying || self.currentTitle != nil {
                        self.isPlaying = false
                        self.currentTitle = nil
                        self.currentArtist = nil
                        self.onChange?()
                    }
                    return
                }

                if result.hasPrefix("playing|") {
                    let parts = String(result.dropFirst(8)).components(separatedBy: "|")
                    self.isPlaying = true
                    self.currentTitle = parts.first
                    self.currentArtist = parts.count > 1 ? parts[1] : nil
                    if parts.count > 2, let v = Int(parts[2]) { self.volume = v }
                } else if result.hasPrefix("stopped|") {
                    let parts = result.components(separatedBy: "|")
                    self.isPlaying = false
                    self.currentTitle = nil
                    self.currentArtist = nil
                    if parts.count > 1, let v = Int(parts[1]) { self.volume = v }
                } else {
                    self.isPlaying = false
                    self.currentTitle = nil
                    self.currentArtist = nil
                }

                if wasPlaying != self.isPlaying || self.isPlaying {
                    self.onChange?()
                }
            }
        }
    }

    func togglePlayPause() {
        tellMusic("playpause")
    }

    func nextTrack() {
        tellMusic("next track")
    }

    func previousTrack() {
        tellMusic("previous track")
    }

    func adjustVolume(by delta: Int) {
        volume = max(0, min(100, volume + delta))
        tellMusic("set sound volume to \(volume)")
    }

    private func tellMusic(_ command: String) {
        let script = "tell application \"Music\" to \(command)"
        DispatchQueue.global(qos: .utility).async {
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}
