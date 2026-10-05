import AppKit
import QuartzCore

enum SystemHUDKind { case volume, brightness }
enum AudioOutputKind { case speaker }
enum AIProvider { case codex }
struct AgentSessionLink: Equatable { var helpText: String { "Open" } }
struct InputSourceOption: Equatable { let id: String }
struct ChargerPowerState: Equatable {
    let titleText = "Power", detailText = "Connected", symbolName = "bolt", valueText = "60W"
}
struct SystemNotchEvent: Equatable {
    let id = "event", title = "Event", detail = "Detail", symbol = "bell", value = "Event"
}
final class AppSettings {
    static let shared = AppSettings()
    let systemHUDDeviceIcons = true
}
enum IndicatorRenderer {
    static func systemHUDIcon(kind: SystemHUDKind, value: CGFloat, muted: Bool, audioOutputKind: AudioOutputKind?, deviceIcons: Bool, pointSize: CGFloat, color: NSColor) -> NSImage? { nil }
}
enum AgentActivityCardView { static func icon(for provider: AIProvider) -> NSImage? { nil } }
final class NotchCompactMusicPane: NSView {
    func setPresented(_ presented: Bool) {}
    func reload() {}
}
final class NotchLevelBar: NSView {
    static let thickness: CGFloat = 6
    var onChange: ((CGFloat, Bool) -> Void)?
    var onDragEnded: (() -> Void)?
    var isEnabled = true
    let isDragging = false
    func set(_ value: CGFloat, muted: Bool, animated: Bool) {}
}
final class NotchSourcePicker: NSView {
    var onSelect: ((String) -> Void)?
    var selectedID: String?
    func height(for width: CGFloat) -> CGFloat { 0 }
    func set(_ sources: [InputSourceOption], slideFrom: String?, duration: CFTimeInterval) {}
}
final class NotchHUDRow: NSView {
    var onClick: (() -> Void)?
    init(output: NotchHUDView.Output, inset: CGFloat) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

// PRODUCTION_NOTIFICATION_MODELS
// PRODUCTION_NOTIFICATION_VIEW

@main struct NotchNotificationViewTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = NotchHUDView()
        view.configure(notch: CGSize(width: 185, height: 32), available: CGSize(width: 1200, height: 800))
        view.layer?.backgroundColor = NSColor.black.cgColor
        let app = NotchNotificationApp(id: "notification-source:instagram", name: "Instagram", path: "", aliases: [])
        let notice = NotchAppNotification(id: "sample", app: app, title: "Instagram", subtitle: "", body: "A new message\nสวัสดี 👨‍👩‍👧")
        view.apply(.appNotification(notice), animated: false)
        view.frame = CGRect(origin: .zero, size: view.cardSize)
        view.layout()
        func all(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(all) }
        let labels = all(view).compactMap { $0 as? NSTextField }
        let source = labels.first { $0.stringValue == "Instagram" && !$0.isHidden }!
        precondition(source.frame.width >= source.cell!.cellSize.width, "The rendered source label must fit Instagram")
        precondition(labels.filter { $0.stringValue == "Instagram" && !$0.isHidden }.count == 1,
                     "The rendered card displays its app name once")
        let body = labels.first { $0.stringValue == notice.body }!
        precondition(body.frame.height >= body.cell!.cellSize(forBounds: body.frame).height)
        let icon = view.subviews.compactMap { $0 as? NSImageView }.first!
        precondition(icon.image != nil && !icon.isHidden)
        if let output = ProcessInfo.processInfo.environment["MSG_NOTIFICATION_RENDER_DIR"] {
            let url = URL(fileURLWithPath: output, isDirectory: true)
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: url.appendingPathComponent("notification-short.png"))
            }
        }
        let shortSize = view.cardSize
        let long = NotchAppNotification(id: "long", app: app, title: String(repeating: "Long title ", count: 20), subtitle: "", body: String(repeating: "Long message with ไทย and emoji 👨‍👩‍👧\n", count: 150))
        view.apply(.appNotification(long), animated: false)
        view.frame = CGRect(origin: .zero, size: view.cardSize)
        view.layout()
        precondition(view.cardSize.width > shortSize.width && view.cardSize.height > shortSize.height)
        let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
        precondition(scroll.hasVerticalScroller && scroll.documentView!.frame.height > scroll.frame.height)
        precondition(view.cardSize.height <= 760 && scroll.frame.maxY <= view.cardSize.height - 20)
        let realTitle = all(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == long.title }!
        precondition(realTitle.frame.height > 17 && realTitle.maximumNumberOfLines == 0,
                     "Notification titles wrap and expand rather than truncate")
        print("Rendered notification view: source name once, fitting wing, dynamic width/height, wrapping and scrolling passed")
    }
}
