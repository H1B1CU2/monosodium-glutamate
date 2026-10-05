import AppKit
import QuartzCore
import ApplicationServices

/// Shuffle, repeat, favourite, lyrics and Playing Next for the Edge Keys —
/// read from and toggled in Music (Spotify has shuffle and repeat), each key
/// drawn filled while its setting is on, as Music's own buttons are.
final class PlayerExtras {
    static let shared = PlayerExtras()

    struct State: Equatable {
        var available = false
        var shuffle = false
        /// 0 off, 1 all, 2 one.
        var repeatMode = 0
        var favorite = false
        var lyrics = false
        var queue = false
    }

    private(set) var state = State()
    var onChange: (() -> Void)?
    /// Until when a just-set value outranks what the player reports.
    private var holds: [EdgeKeyAction.Control: CFTimeInterval] = [:]
    private var inFlight = false

    private static let music = "com.apple.Music"
    private static let spotify = "com.spotify.client"

    private enum Player { case music, spotify }

    /// Spotify while it's the source; otherwise Music if it's open.
    private var player: Player? {
        func running(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
        if MusicMonitor.shared?.currentSourceBundleID == Self.spotify, running(Self.spotify) { return .spotify }
        if running(Self.music) { return .music }
        if running(Self.spotify) { return .spotify }
        return nil
    }

    func isOn(_ control: EdgeKeyAction.Control) -> Bool {
        switch control {
        case .shuffle: return state.shuffle
        case .repeatMode: return state.repeatMode != 0
        case .favorite: return state.favorite
        case .lyrics: return state.lyrics
        case .queue: return state.queue
        default: return false
        }
    }

    static func symbol(_ control: EdgeKeyAction.Control, on: Bool, repeatMode: Int) -> String {
        switch control {
        case .shuffle: return "shuffle"
        case .repeatMode: return repeatMode == 2 ? "repeat.1" : "repeat"
        case .favorite: return on ? "star.fill" : "star"
        case .lyrics: return on ? "quote.bubble.fill" : "quote.bubble"
        case .queue: return "list.bullet"
        default: return "questionmark"
        }
    }

    /// Shuffle, repeat and Playing Next have no filled symbol: while on they
    /// sit cut out of a filled rounded square, as in Music.
    static func usesBadge(_ control: EdgeKeyAction.Control) -> Bool {
        [.shuffle, .repeatMode, .queue].contains(control)
    }

    // MARK: Reading

    func refresh() {
        guard !inFlight else { return }
        guard let player else { publish(State()); return }
        inFlight = true
        let script: String
        switch player {
        case .music:
            script = """
            tell application id "\(Self.music)"
                set s to shuffle enabled
                set r to song repeat as text
                set f to false
                try
                    set f to favorited of current track
                on error
                    try
                        set f to loved of current track
                    end try
                end try
                return (s as text) & "|" & r & "|" & (f as text)
            end tell
            """
        case .spotify:
            script = """
            tell application id "\(Self.spotify)"
                return (shuffling as text) & "|" & (repeating as text) & "|false"
            end tell
            """
        }
        Self.osascript(script) { [weak self] output in
            guard let self else { return }
            self.inFlight = false
            var next = State()
            if let output {
                let parts = output.components(separatedBy: "|")
                next.available = true
                next.shuffle = parts.first == "true"
                let r = parts.count > 1 ? parts[1] : "off"
                next.repeatMode = (r == "all" || r == "true") ? 1 : r == "one" ? 2 : 0
                next.favorite = parts.count > 2 && parts[2] == "true"
            }
            if player == .music {
                // A menu that can't be read right now keeps what was shown.
                next.lyrics = Self.menuItem(lyrics: true).map(Self.isHideItem) ?? self.state.lyrics
                next.queue = Self.menuItem(lyrics: false).map(Self.isHideItem) ?? self.state.queue
            }
            // Music answers with the old value for a second or so after a
            // change: what was just set stands until then.
            let now = CACurrentMediaTime()
            func held(_ c: EdgeKeyAction.Control) -> Bool { (self.holds[c] ?? 0) > now }
            if held(.shuffle) { next.shuffle = self.state.shuffle }
            if held(.repeatMode) { next.repeatMode = self.state.repeatMode }
            if held(.favorite) { next.favorite = self.state.favorite }
            if held(.lyrics) { next.lyrics = self.state.lyrics }
            if held(.queue) { next.queue = self.state.queue }
            self.publish(next)
        }
    }

    private func publish(_ next: State) {
        guard next != state else { return }
        state = next
        onChange?()
    }

    // MARK: Toggling

    func toggle(_ control: EdgeKeyAction.Control) {
        guard let player else { return }
        // Shown at once; the next read confirms it.
        var next = state
        switch control {
        case .shuffle: next.shuffle.toggle()
        case .repeatMode: next.repeatMode = (state.repeatMode + 1) % 3
        case .favorite: next.favorite.toggle()
        case .lyrics: next.lyrics.toggle()
        case .queue: next.queue.toggle()
        default: return
        }

        switch control {
        case .lyrics, .queue:
            guard player == .music, let item = Self.menuItem(lyrics: control == .lyrics) else { return }
            let showing = !Self.isHideItem(item)
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            // Opening the pane is for looking at it: bring Music forward.
            if showing {
                NSRunningApplication.runningApplications(withBundleIdentifier: Self.music).first?.activate()
            }
            hold(control)
            publish(next)
            return
        case .favorite:
            guard player == .music else { return }
        default:
            break
        }

        let script: String
        switch (player, control) {
        case (.music, .shuffle):
            script = "tell application id \"\(Self.music)\" to set shuffle enabled to \(next.shuffle)"
        case (.music, .repeatMode):
            let mode = ["off", "all", "one"][next.repeatMode]
            script = "tell application id \"\(Self.music)\" to set song repeat to \(mode)"
        case (.music, .favorite):
            script = """
            tell application id "\(Self.music)"
                try
                    set favorited of current track to \(next.favorite)
                on error
                    set loved of current track to \(next.favorite)
                end try
            end tell
            """
        case (.spotify, .shuffle):
            script = "tell application id \"\(Self.spotify)\" to set shuffling to \(next.shuffle)"
        case (.spotify, .repeatMode):
            // Spotify's script has only on and off.
            next.repeatMode = state.repeatMode == 0 ? 1 : 0
            script = "tell application id \"\(Self.spotify)\" to set repeating to \(next.repeatMode != 0)"
        default:
            return
        }
        hold(control)
        publish(next)
        Self.osascript(script) { _ in }
    }

    /// The value just set stands for a few seconds, then reads confirm it.
    private func hold(_ control: EdgeKeyAction.Control) {
        holds[control] = CACurrentMediaTime() + 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) { [weak self] in self?.refresh() }
    }

    // MARK: Music's View menu

    /// View ▸ Show/Hide Lyrics (⌃⌘U) or Show/Hide Playing Next (⌥⌘U), found by
    /// shortcut so the menu's language doesn't matter.
    private static func menuItem(lyrics: Bool) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: music).first else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return nil }
        let wanted = lyrics ? 4 : 2   // AXMenuItemCmdModifiers: control 4, option 2
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    guard let char: String = attribute(item, kAXMenuItemCmdCharAttribute),
                          char.uppercased() == "U",
                          let mods: Int = attribute(item, kAXMenuItemCmdModifiersAttribute),
                          mods == wanted else { continue }
                    return item
                }
            }
        }
        return nil
    }

    /// "Hide Lyrics" / "Hide Playing Next": the pane is open.
    private static func isHideItem(_ item: AXUIElement) -> Bool {
        let title: String = attribute(item, kAXTitleAttribute) ?? ""
        return title.lowercased().hasPrefix("hide")
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    // MARK: Script

    /// In its own process, so it never races MSG's own NSAppleScript use.
    private static func osascript(_ source: String, completion: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { finished in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(finished.terminationStatus == 0 ? text : nil) }
        }
        do { try process.run() } catch { DispatchQueue.main.async { completion(nil) } }
    }
}
