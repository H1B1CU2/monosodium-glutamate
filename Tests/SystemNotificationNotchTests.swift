import AppKit

// Production models are inserted by the runner; no live notifications are read.
// PRODUCTION_NOTIFICATION_MODELS

@main
struct SystemNotificationNotchTests {
    static func main() {
        _ = NSApplication.shared
        let app = NotchNotificationApp(id: "example.chat", name: "Chat", path: "/Applications/Chat.app", aliases: ["Chat Desktop"])
        func label(_ id: String, _ text: String) -> NotchNotificationNode {
            NotchNotificationNode(role: "AXStaticText", identifier: id, text: text)
        }
        let banner = NotchNotificationNode(subrole: "AXNotificationCenterBanner", description: "\u{200E}CHAT, notification", children: [
            label("title", "Sender"), label("subtitle", "Project"), label("body", "สวัสดี 👨‍👩‍👧"), label("date", "Now")
        ])
        let notice = NotchNotificationParser.parse(banner, id: "one", apps: [app])!
        precondition(notice.app.id == app.id && notice.title == "Sender" && notice.subtitle == "Project")
        precondition(notice.body == "สวัสดี 👨‍👩‍👧", "Preserve Thai and emoji joiners")
        precondition(!notice.detail.contains("Now"), "A timestamp isn't message text")
        let uncatalogued = NotchNotificationParser.parse(banner, id: "one", apps: [])!
        precondition(uncatalogued.app.name == "CHAT" && uncatalogued.app.isUnresolved,
                     "An empty app selection must still receive every visible source")
        precondition(uncatalogued.title == notice.title && uncatalogued.body == notice.body)
        let other = NotchNotificationApp(id: "other.chat", name: "Chat", path: "", aliases: [])
        precondition(NotchNotificationParser.parse(banner, id: "one", apps: [app, other])!.app.isUnresolved,
                     "Ambiguous names appear without borrowing another app's identity")
        var unknown = banner
        unknown.description = "Unlisted app, notification"
        let unknownNotice = NotchNotificationParser.parse(unknown, id: "unknown", apps: [app])!
        precondition(unknownNotice.app.name == "Unlisted app" && unknownNotice.app.isUnresolved)
        var nameless = banner
        nameless.description = ""
        precondition(NotchNotificationParser.parse(nameless, id: "nameless", apps: [app]) == nil)
        var history = banner
        history.subrole = "AXNotificationCenterNotification"
        precondition(NotchNotificationParser.parse(history, id: "old", apps: [app]) == nil, "History isn't a fresh banner")
        var oldBanner = banner
        oldBanner.children = [label("", "Chat"), label("", "A legacy title"), label("", "Visible preview")]
        let legacy = NotchNotificationParser.parse(oldBanner, id: "legacy", apps: [app])!
        precondition(legacy.title == "A legacy title" && legacy.body == "Visible preview")
        var hidden = banner
        hidden.children = [label("title", "New notification")]
        let redacted = NotchNotificationParser.parse(hidden, id: "hidden", apps: [app])!
        precondition(redacted.body.isEmpty, "Never reconstruct a hidden preview from an attributed description")
        let duplicate = NotchAppNotification(id: "duplicate", app: app, title: "CHAT Desktop", subtitle: "Chat", body: "Chat is mentioned inside this message.")
        precondition(duplicate.displayTitle.isEmpty && duplicate.displayDetail == duplicate.body,
                     "Keep the source name only in the wing, preserving actual message text")
        let bodyOnly = NotchAppNotification(id: "body-only", app: app, title: app.name, subtitle: "", body: "A body without a title")
        precondition(bodyOnly.displayTitle.isEmpty && bodyOnly.displayDetail == bodyOnly.body)
        var iconBanner = banner
        iconBanner.frame = CGRect(x: 100, y: 100, width: 344, height: 100)
        let iconFrame = CGRect(x: 112, y: 112, width: 32, height: 32)
        iconBanner.children.append(NotchNotificationNode(role: "AXImage", identifier: "appIcon", frame: iconFrame))
        iconBanner.children.append(NotchNotificationNode(role: "AXImage", identifier: "attachment", frame: CGRect(x: 340, y: 115, width: 60, height: 60)))
        precondition(NotchNotificationParser.sourceIconFrame(in: iconBanner, source: "CHAT") == iconFrame,
                     "Capture only the app icon, not an attachment or message content")
        precondition(NotchNotificationParser.sourceIconFrame(in: banner, source: "CHAT") == nil)
        let instagram = NotchNotificationApp(id: "notification-source:instagram", name: "Instagram", path: "", aliases: [])
        let compact = NotchAppNotification(id: "short", app: instagram, title: "Instagram", subtitle: "", body: "Hello")
        let notch = CGSize(width: 185, height: 32)
        let available = CGSize(width: 1200, height: 800)
        let compactLayout = NotchNotificationMetrics(notice: compact, notch: notch, available: available)
        let sourceWidth = (instagram.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width
        precondition(compactLayout.sourceFrame.width >= ceil(sourceWidth), "Instagram must not truncate in the right wing")
        precondition(compactLayout.titleFrame.height == 0, "No blank title row for a duplicate app name")
        let longMessage = NotchAppNotification(id: "long", app: instagram, title: "A real notification title that needs to wrap across multiple lines on a narrow display", subtitle: "", body: String(repeating: "ข้อความภาษาไทยและ emoji 👨‍👩‍👧 รายละเอียดแจ้งเตือน ", count: 180))
        let longLayout = NotchNotificationMetrics(notice: longMessage, notch: notch, available: available)
        precondition(longLayout.size.width > compactLayout.size.width && longLayout.size.height > compactLayout.size.height)
        precondition(longLayout.size.width <= 600 && longLayout.size.height <= available.height - 40)
        precondition(longLayout.needsScrolling && longLayout.documentHeight > longLayout.textFrame.height,
                     "Long messages retain every line in a scrollable viewport")
        var arrivals = NotchNotificationArrivals()
        precondition(arrivals.update([notice]).isEmpty, "Startup quietly seeds existing banners")
        precondition(arrivals.update([notice]).isEmpty, "Duplicate layout events don't repeat")
        let new = NotchAppNotification(id: "two", app: app, title: "Sender", subtitle: "Project", body: notice.body)
        precondition(arrivals.update([notice, new]) == [new], "Identical text in a new banner is a new notification")
        let hydrated = NotchAppNotification(id: "two", app: app, title: "Sender", subtitle: "Project", body: "Hydrated text")
        precondition(arrivals.update([notice, hydrated]) == [hydrated], "A changed preview updates that banner")
        precondition(arrivals.update([]).isEmpty)
        precondition(arrivals.update([notice]) == [notice], "A reused AX element may arrive again after removal")
        let time = Date(timeIntervalSince1970: 100)
        var queue = NotchNotificationQueue()
        queue.append(notice, at: time)
        queue.append(new, at: time)
        queue.append(hydrated, at: time)
        precondition(queue.next(at: time)?.id == notice.id)
        queue.remove(notice.id)
        precondition(queue.next(at: time) == hydrated, "Queued hydration replaces older text")
        precondition(queue.next(at: time.addingTimeInterval(12)) == nil, "Don't replay stale private previews")
        for i in 0..<12 {
            queue.append(NotchAppNotification(id: "burst-\(i)", app: app, title: "Title", subtitle: "", body: "Body"), at: time)
        }
        precondition(queue.next(at: time)?.id == "burst-4", "A burst has a bounded in-memory queue")
        queue.clear()
        precondition(queue.next(at: time) == nil)
        let encoded = try! JSONEncoder().encode([app])
        precondition(try! JSONDecoder().decode([NotchNotificationApp].self, from: encoded) == [app])
        print("All-app notification parsing, unknown/ambiguous sources, preview privacy, startup, deduplication and burst queue passed")
    }
}
