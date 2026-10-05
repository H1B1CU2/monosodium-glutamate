import AppKit

// Run with MSG/MediaRemoteAdapter.swift; no MediaRemote connection or playback command needed.
@main
struct MediaRemotePlayerTests {
    static func main() {
        typealias Player = MediaRemoteAdapter.Player
        func player(_ bundle: String, _ name: String?, _ title: String?, active: Bool = false,
                    artist: String? = "Marques Brownlee", art: NSImage? = nil) -> Player {
            Player(bundle: bundle, name: name, active: active,
                   nowPlaying: .init(playing: true, title: title, artist: artist, pid: 0,
                                     art: art, artURL: nil, duration: 100, elapsed: 12, rate: 1, timestamp: nil),
                   commands: bundle.hasPrefix("com.apple.WebKit") ? [0, 1] : [0, 1, 2])
        }
        let app = player("com.kite.Kite", "SP8CE", nil)
        let helper = player("com.apple.WebKit.GPU", "SP8CE", "Dear YouTube!", active: true)
        for input in [[helper, app], [app, helper]] {
            let result = MediaRemoteAdapter.withoutWebKitTwins(input)
            precondition(result.count == 1, "An app with empty metadata is still the WebKit owner")
            precondition(result[0].bundle == app.bundle && result[0].nowPlaying.pid == app.nowPlaying.pid)
            precondition(result[0].nowPlaying.title == helper.nowPlaying.title && result[0].active)
            precondition(result[0].commands == app.commands, "Keep commands routed to the real app")
        }
        let updated = player(app.bundle, app.name, "New video")
        let oldCover = NSImage(size: NSSize(width: 10, height: 10))
        let staleHelper = player(helper.bundle, helper.name, "Old video", art: oldCover)
        let changing = MediaRemoteAdapter.withoutWebKitTwins([staleHelper, updated])
        precondition(changing.count == 1 && changing[0].nowPlaying.title == "New video")
        precondition(changing[0].nowPlaying.art == nil, "Don't carry artwork from the helper's old track")

        let populated = player(app.bundle, app.name, helper.nowPlaying.title)
        let music = player("com.apple.Music", "Music", helper.nowPlaying.title)
        let independent = MediaRemoteAdapter.withoutWebKitTwins([helper, music, populated])
        precondition(independent.map(\.bundle) == [music.bundle, app.bundle],
                     "Independent apps playing the same title remain separate")
        precondition(MediaRemoteAdapter.withoutWebKitTwins([helper, music]).count == 2,
                     "A named WebKit owner must not be matched to a different app by track alone")
        let another = player("another.browser", app.name, nil)
        precondition(MediaRemoteAdapter.withoutWebKitTwins([helper, app, another]).count == 3,
                     "Ambiguous owner names remain separate")
        precondition(MediaRemoteAdapter.withoutWebKitTwins([helper]).count == 1)
        let unnamed = player(helper.bundle, nil, helper.nowPlaying.title)
        precondition(MediaRemoteAdapter.withoutWebKitTwins([unnamed, populated]).count == 1,
                     "An unnamed helper can still match a unique track")
        precondition(MediaRemoteAdapter.withoutWebKitTwins([unnamed, populated, music]).count == 3)

        let finder = player("com.apple.finder", "Finder", nil)
        precondition(MediaRemoteAdapter.applicationIcon(for: finder) != nil,
                     "App bundle identity resolves an icon even without a media PID")
        precondition(MediaRemoteAdapter.applicationIcon(for: unnamed) == nil,
                     "An unknown WebKit owner never uses the generic helper icon")
        print("Media player owner, metadata, command and icon regression checks: PASS")
    }
}
