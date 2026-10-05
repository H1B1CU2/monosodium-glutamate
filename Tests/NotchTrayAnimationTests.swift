import AppKit
import QuartzCore

// These fakes never read, write or clear the user's actual tray.
final class NotchTray {
    static let shared = NotchTray()
    var items: [URL] = []
    private var observers: [() -> Void] = []
    func addObserver(_ observer: @escaping () -> Void) { observers.append(observer) }
    func set(_ files: [URL]) { items = files; observers.forEach { $0() } }
    func clear() { set([]) }
    func pruneMissing() {}
    func remove(_ url: URL) { set(items.filter { $0 != url }) }
    func add(_ files: [URL]) { set(files + items) }
}
enum NotchDropReader {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = []
    static func operation(for sender: NSDraggingInfo) -> NSDragOperation { [] }
    static func read(_ board: NSPasteboard, completion: @escaping ([URL]) -> Void) -> Bool { false }
}
final class NotchTrayTile: NSView {
    static let size = CGSize(width: 84, height: 96)
    let url: URL
    var onRemove: (() -> Void)?
    init(url: URL) { self.url = url; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
}
final class NotchTrayTextButton: NSView {
    var onClick: (() -> Void)?
    init(title: String) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

// PRODUCTION_TRAY_PANE

@main struct NotchTrayAnimationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NotchTray.shared.set((0..<10).map { URL(fileURLWithPath: "/tmp/fake-tray-\($0)") })
        let pane = NotchTrayPane()
        pane.frame = CGRect(x: 0, y: 0, width: 680, height: pane.fittingHeight(width: 680))
        pane.layoutSubtreeIfNeeded()
        let tiles = pane.subviews.compactMap { $0 as? NotchTrayTile }
        let fullHeight = pane.fittingHeight(width: 680)
        NotchTray.shared.clear()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            precondition(tiles.allSatisfy { $0.superview === pane && $0.layer?.animation(forKey: "trayRemoval") != nil })
            precondition(pane.fittingHeight(width: 680) == fullHeight,
                         "Keep the card tall enough to show the outgoing tile animation")
        }
        let newFile = URL(fileURLWithPath: "/tmp/fake-new-drop")
        NotchTray.shared.add([newFile])
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(tiles.allSatisfy { $0.superview == nil })
        precondition(pane.subviews.compactMap { $0 as? NotchTrayTile }.map(\.url) == [newFile],
                     "An old clear animation cannot remove a newly dropped file")
        NotchTray.shared.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(pane.fittingHeight(width: 680) == 65)
        print("Tray clear animation and drops arriving during removal passed")
    }
}
