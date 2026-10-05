import AppKit
import QuartzCore
final class MusicMonitor {
 static let shared: MusicMonitor? = MusicMonitor()
 var currentTitle: String? = "Test song"
 var currentArtist: String? = "Artist"
 var currentSource: String? = "Music"
 var albumArt: NSImage? = nil
 var isPlaying = true
 var progress: Double? = 0.5
 var consumers = 0
 func addObserver(_ cb: @escaping () -> Void) {}
 func retainPolling() { consumers += 1 }
 func releasePolling() { consumers -= 1; precondition(consumers >= 0) }
 func togglePlayPause() {}
 func previousTrack() {}
 func nextTrack() {}
}

// PRODUCTION_MUSIC_PANE

@main
enum NotchMusicTests {
    static func main() {
        var changes = NotchMusicTrackChange()
        precondition(!changes.update(title: nil, artist: nil, source: nil))
        precondition(!changes.update(title: "Song A", artist: "Artist", source: "Music"), "No startup popup")
        precondition(!changes.update(title: "Song A", artist: "Artist", source: "Music"), "Ignore repeated progress updates")
        precondition(changes.update(title: "Song B", artist: "Artist", source: "Music"))
        precondition(changes.update(title: "Song B", artist: "Other artist", source: "Music"))
        precondition(!changes.update(title: "", artist: nil, source: nil))
        precondition(changes.update(title: "Song B", artist: "Other artist", source: "Music"), "Playback resumes after an empty state")
        _ = NSApplication.shared
        let pane: NotchMusicPane? = NotchMusicPane()
        pane!.frame = NSRect(x: 0, y: 0, width: 680, height: 160)
        pane!.layoutSubtreeIfNeeded()
        let buttons = pane!.subviews.compactMap { $0 as? NSButton }.sorted { $0.frame.minX < $1.frame.minX }
        precondition(buttons.count == 3 && buttons.last!.frame.maxX == 656)
        let progress = pane!.subviews.compactMap { $0 as? NotchMusicProgress }.first!
        precondition(progress.frame.height == 3 && progress.frame.maxY == 136)
        precondition(buttons.allSatisfy { $0.frame.midY == 80 })
        precondition(pane!.subviews.count == 8, "No visualizer in the music pane")
        progress.layoutSubtreeIfNeeded()
        precondition(progress.layer!.sublayers!.first!.frame.width == progress.bounds.width / 2)
        pane!.setPresented(true)
        pane!.setPresented(true)
        precondition(MusicMonitor.shared!.consumers == 1)
        pane!.setPresented(false)
        precondition(MusicMonitor.shared!.consumers == 0)
        let compact = NotchCompactMusicPane()
        compact.frame.size = CGSize(width: 305, height: 44)
        compact.layoutSubtreeIfNeeded()
        precondition(compact.subviews.count == 6, "Compact music has artwork, labels and controls only")
        compact.setPresented(true)
        compact.setPresented(true)
        precondition(MusicMonitor.shared!.consumers == 1)
        compact.setPresented(false)
        precondition(MusicMonitor.shared!.consumers == 0)
        print("Centred music controls, thin progress, compact player and polling lifecycle passed")
    }
}
