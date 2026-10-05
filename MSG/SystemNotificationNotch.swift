import AppKit
import ApplicationServices
import Combine
import SwiftUI
import UserNotifications

/// The catalog supplies icons and launch targets; it never limits which apps
/// can send a banner. Unknown sources retain their visible name and native action.
struct NotchNotificationApp: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let path: String
    let aliases: [String]
    var isUnresolved: Bool { id.hasPrefix("notification-source:") }

    static func selection(at url: URL) -> Self? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id != "com.apple.notificationcenterui" else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        let names = [bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
                     bundle.localizedInfoDictionary?["CFBundleName"] as? String,
                     bundle.infoDictionary?["CFBundleDisplayName"] as? String,
                     bundle.infoDictionary?["CFBundleName"] as? String, fileName].compactMap { $0 }
        return Self(id: id, name: names.first ?? fileName, path: url.path,
                    aliases: Array(Set(names)).sorted())
    }
}

struct NotchAppNotification: Equatable {
    let id: String
    let app: NotchNotificationApp
    let title: String
    let subtitle: String
    let body: String
    var iconData: Data? = nil
    var detail: String { [subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n") }
    private func isSourceName(_ text: String) -> Bool {
        ([app.name] + app.aliases).contains {
            NotchNotificationParser.clean($0).caseInsensitiveCompare(NotchNotificationParser.clean(text)) == .orderedSame
        }
    }
    var displayTitle: String { isSourceName(title) ? "" : title }
    var displayDetail: String { [isSourceName(subtitle) ? "" : subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n") }
}

/// Measure the same AppKit wrapping labels that the HUD displays. Large messages
/// scroll inside the card rather than extending past the screen or losing lines.
struct NotchNotificationMetrics {
    let size: CGSize
    let sourceFrame: CGRect
    let textFrame: CGRect
    let titleFrame: CGRect
    let detailFrame: CGRect
    let documentHeight: CGFloat
    var needsScrolling: Bool { documentHeight > textFrame.height }

    static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return ceil(label.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width), height: 100_000)).height ?? 0)
    }

    init(notice: NotchAppNotification, notch: CGSize, available: CGSize) {
        let padding: CGFloat = 20
        let sourceFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        func naturalWidth(_ text: String, font: NSFont) -> CGFloat {
            // NSTextFieldCell reserves 2 pt on each horizontal side.
            (text.components(separatedBy: .newlines).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 4
        }
        let maxWidth = max(notch.width + 80, min(600, available.width - 40))
        let requested = max(notch.width + 160,
                            notch.width + 2 * (naturalWidth(notice.app.name, font: sourceFont) + padding + 8),
                            max(naturalWidth(notice.displayTitle, font: titleFont), naturalWidth(notice.displayDetail, font: detailFont)) + 2 * padding)
        let width = ceil(min(maxWidth, requested))
        let wing = (width - notch.width) / 2
        let sourceWidth = max(1, wing - padding - 8)
        let sourceHeight = max(17, Self.textHeight(notice.app.name, width: sourceWidth, font: sourceFont))
        sourceFrame = CGRect(x: width - wing + 8, y: padding, width: sourceWidth, height: sourceHeight)
        let top = max(sourceFrame.maxY, notch.height) + padding
        var textWidth = width - 2 * padding
        var titleHeight = Self.textHeight(notice.displayTitle, width: textWidth, font: titleFont)
        var detailHeight = Self.textHeight(notice.displayDetail, width: textWidth, font: detailFont)
        let gap: CGFloat = titleHeight > 0 && detailHeight > 0 ? 4 : 0
        if titleHeight + gap + detailHeight > max(0, available.height - 40 - top - padding) {
            // Reserve the thumb's width only when the message actually scrolls.
            textWidth -= 12
            titleHeight = Self.textHeight(notice.displayTitle, width: textWidth, font: titleFont)
            detailHeight = Self.textHeight(notice.displayDetail, width: textWidth, font: detailFont)
        }
        titleFrame = CGRect(x: 0, y: 0, width: textWidth, height: titleHeight)
        detailFrame = CGRect(x: 0, y: titleHeight + (titleHeight > 0 && detailHeight > 0 ? 4 : 0), width: textWidth, height: detailHeight)
        documentHeight = detailHeight > 0 ? detailFrame.maxY : titleHeight
        let viewportHeight = min(documentHeight, max(0, available.height - 40 - top - padding))
        textFrame = CGRect(x: padding, y: top, width: width - 2 * padding, height: viewportHeight)
        size = CGSize(width: width, height: documentHeight > 0 ? textFrame.maxY + padding : sourceFrame.maxY + padding)
    }
}

/// A bounded snapshot of the banner's visible Accessibility tree. No private
/// notification database, hidden previews or notification history is read.
struct NotchNotificationNode {
    var role = ""
    var subrole = ""
    var identifier = ""
    var text = ""
    var description = ""
    var frame: CGRect? = nil
    var children: [Self] = []
}

enum NotchNotificationParser {
    static let bannerRoles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]

    static func clean(_ text: String) -> String {
        // Preserve emoji joiners and non-Latin text; only remove direction marks.
        String(text.unicodeScalars.filter { ![0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                              0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sourceIconFrame(in node: NotchNotificationNode, source: String) -> CGRect? {
        guard let banner = node.frame else { return nil }
        var candidates: [(frame: CGRect, explicit: Bool)] = []
        func collect(_ item: NotchNotificationNode) {
            if item.role == "AXImage", let frame = item.frame,
               (12...72).contains(frame.width), (12...72).contains(frame.height),
               (0.75...1.33).contains(frame.width / frame.height), banner.contains(frame) {
                let key = item.identifier.lowercased().filter { $0.isLetter }
                let explicit = ["appicon", "applicationicon", "sourceicon"].contains(key)
                    || clean(item.description).caseInsensitiveCompare(clean(source)) == .orderedSame
                if explicit || (frame.minX < banner.minX + 72 && frame.minY < banner.minY + 56) {
                    candidates.append((frame, explicit))
                }
            }
            item.children.forEach(collect)
        }
        collect(node)
        return candidates.sorted {
            if $0.explicit != $1.explicit { return $0.explicit }
            return $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }.first?.frame
    }

    static func parse(_ node: NotchNotificationNode, id: String,
                      apps: [NotchNotificationApp]) -> NotchAppNotification? {
        guard bannerRoles.contains(node.subrole) else { return nil }
        let visibleName = clean(node.description.components(separatedBy: ", ").first ?? "")
        let matching = apps.filter { app in
            ([app.name] + app.aliases).contains { clean($0).caseInsensitiveCompare(visibleName) == .orderedSame }
        }
        guard !visibleName.isEmpty else { return nil }
        // Missing or ambiguous catalog entries still appear, with a generic icon
        // and the banner's own action rather than another app's launch target.
        let app = matching.count == 1 ? matching[0] : NotchNotificationApp(
            id: "notification-source:" + visibleName.lowercased(), name: visibleName,
            path: "", aliases: [])
        var identified: [String: String] = [:]
        var lines: [String] = []
        func collect(_ node: NotchNotificationNode) {
            if node.role == "AXStaticText" {
                let text = clean(node.text)
                if !text.isEmpty && !["date", "time", "appName", "applicationName", "header"].contains(node.identifier) {
                    if ["title", "subtitle", "body"].contains(node.identifier) { identified[node.identifier] = text }
                    if text.caseInsensitiveCompare(visibleName) != .orderedSame { lines.append(text) }
                }
            }
            node.children.forEach(collect)
        }
        collect(node)
        let title: String
        let subtitle: String
        let body: String
        if !identified.isEmpty {
            title = identified["title"] ?? app.name
            subtitle = identified["subtitle"] ?? ""
            body = identified["body"] ?? ""
        } else {
            guard !lines.isEmpty else { return nil }
            title = lines[0]
            subtitle = ""
            body = lines.dropFirst().joined(separator: "\n")
        }
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return NotchAppNotification(id: id, app: app, title: String(title.prefix(500)),
                                    subtitle: String(subtitle.prefix(500)), body: String(body.prefix(2000)))
    }
}

struct NotchNotificationArrivals {
    private var seeded = false
    private var previous: [String: NotchAppNotification] = [:]
    mutating func update(_ notifications: [NotchAppNotification]) -> [NotchAppNotification] {
        let fresh = seeded ? notifications.filter { previous[$0.id] != $0 } : []
        previous = Dictionary(notifications.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        seeded = true
        return fresh
    }
}

struct NotchNotificationQueue {
    private var pending: [(notice: NotchAppNotification, at: Date)] = []
    mutating func append(_ notice: NotchAppNotification, at now: Date = Date()) {
        pending.removeAll { $0.notice.id == notice.id }
        pending.append((notice, now))
        if pending.count > 8 { pending.removeFirst(pending.count - 8) }
    }
    mutating func next(at now: Date = Date()) -> NotchAppNotification? {
        pending.removeAll { now.timeIntervalSince($0.at) >= 12 }
        return pending.first?.notice
    }
    mutating func remove(_ id: String) { pending.removeAll { $0.notice.id == id } }
    mutating func clear() { pending.removeAll() }
}

/// AX calls run on a serial worker, with a messaging timeout and tree budget.
/// Its source listens on the main run loop; the callback only schedules work.
@_silgen_name("_AXUIElementGetWindow")
private func notificationAXWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

private enum NotchNotificationIconCapture {
    private typealias Creator = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> CGImage?
    private static let create: Creator? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: Creator.self)
    }()

    static func capture(frame: CGRect, window: AXUIElement) -> Data? {
        // Only the visible icon rectangle is captured, never the notification
        // text or desktop. Reuse existing access; do not request new permissions.
        guard CGPreflightScreenCaptureAccess(), let create else { return nil }
        var id: CGWindowID = 0
        guard notificationAXWindow(window, &id) == .success, id != 0,
              let image = create(frame, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
              image.width <= 256, image.height <= 256 else { return nil }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        return data.flatMap { $0.count <= 131_072 ? $0 : nil }
    }
}

private final class NotchNotificationObserver {
    private let worker = DispatchQueue(label: "MSG.notification-banners", qos: .utility)
    private var observer: AXObserver?
    private var root: AXUIElement?
    private var pid: pid_t = 0
    private var apps: [NotchNotificationApp] = []
    private var installedApps: [NotchNotificationApp]?
    private var iconCache: [String: Data] = [:]
    private var generation = 0
    private var scanWork: DispatchWorkItem?
    private var arrivals = NotchNotificationArrivals()
    private var watchedWindows: [AXUIElement] = []
    private struct Banner {
        let element: AXUIElement
        let window: AXUIElement
    }
    private var banners: [String: Banner] = [:]
    private var windowBannerIDs: [CFHashCode: [String]] = [:]
    private var hidden: (id: String, window: AXUIElement, position: CGPoint)?
    private var restoreWork: DispatchWorkItem?
    var onArrival: ((NotchAppNotification) -> Void)?
    var onStatus: ((Bool) -> Void)?

    func configure(pid: pid_t) {
        worker.async { [self] in
            if pid > 0 { refreshAppCatalog() }
            guard self.pid != pid || observer == nil else { return }
            detach()
            guard pid > 0 else { return }
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.1)
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, _, context in
                guard let context else { return }
                Unmanaged<NotchNotificationObserver>.fromOpaque(context).takeUnretainedValue().changed()
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
                report(false); return
            }
            self.root = root
            self.observer = observer
            self.pid = pid
            register(root)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            // Seed quietly; enabling the feature doesn't replay existing banners.
            scan()
            report(true)
        }
    }

    private func refreshAppCatalog() {
        if installedApps == nil {
            var found: [NotchNotificationApp] = []
            let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices",
                         NSHomeDirectory() + "/Applications"]
            for path in roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator where url.pathExtension == "app" {
                    if let app = NotchNotificationApp.selection(at: url) { found.append(app) }
                }
            }
            installedApps = found
        }
        var catalog: [String: NotchNotificationApp] = [:]
        for app in installedApps ?? [] { catalog[app.id] = app }
        // Include apps launched from Downloads, external disks, or custom paths.
        for running in NSWorkspace.shared.runningApplications {
            if let url = running.bundleURL, let app = NotchNotificationApp.selection(at: url) {
                catalog[app.id] = app
            }
        }
        apps = Array(catalog.values)
    }

    private func detach() {
        restore()
        generation += 1
        scanWork?.cancel(); scanWork = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; root = nil; pid = 0
        watchedWindows = []
        banners = [:]; windowBannerIDs = [:]
        iconCache = [:]
        arrivals = NotchNotificationArrivals()
    }

    func stop() { worker.sync { detach() } }

    private func report(_ observing: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(observing) }
    }

    private func register(_ element: AXUIElement) {
        guard let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXLayoutChangedNotification,
                     kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
    }

    private func changed() {
        worker.async { [self] in
            guard root != nil else { return }
            scanWork?.cancel()
            let generation = self.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, generation == self.generation else { return }
                self.scanWork = nil
                self.scan()
                // SwiftUI often publishes the container before its text.
                let retry = DispatchWorkItem { [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.scan()
                }
                self.worker.asyncAfter(deadline: .now() + 0.2, execute: retry)
            }
            scanWork = work
            worker.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String {
        guard let value = value(element, name) else { return "" }
        if let text = value as? String { return text }
        if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
            return CFAttributedStringGetString((value as! CFAttributedString)) as String
        }
        return ""
    }

    private func scan() {
        guard let root, let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for window in windows where !watchedWindows.contains(where: { CFEqual($0, window) }) {
            register(window)
        }
        watchedWindows = windows
        var remaining = 250
        let deadline = Date().addingTimeInterval(0.8)
        var notices: [NotchAppNotification] = []
        var currentBanners: [String: Banner] = [:]
        var iconFrames: [String: (CGRect, AXUIElement)] = [:]
        var currentWindowIDs: [CFHashCode: [String]] = [:]
        var complete = true
        func children(_ element: AXUIElement) -> [AXUIElement] {
            let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if children.count > 60 { complete = false }
            return Array(children.prefix(60))
        }
        func snapshot(_ element: AXUIElement, depth: Int) -> NotchNotificationNode? {
            guard remaining > 0, depth < 12, Date() < deadline else { complete = false; return nil }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            var node = NotchNotificationNode(role: string(element, kAXRoleAttribute),
                                             identifier: string(element, kAXIdentifierAttribute),
                                             text: string(element, kAXValueAttribute))
            if node.role.isEmpty { complete = false; return nil }
            if node.role == "AXImage" {
                node.frame = rect(element)
                node.description = string(element, kAXDescriptionAttribute)
            }
            for child in children(element) {
                if let childNode = snapshot(child, depth: depth + 1) { node.children.append(childNode) }
            }
            return node
        }
        func findBanners(_ element: AXUIElement, window: AXUIElement, depth: Int) {
            guard remaining > 0, depth < 12, Date() < deadline else { complete = false; return }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            let subrole = string(element, kAXSubroleAttribute)
            if NotchNotificationParser.bannerRoles.contains(subrole) {
                let id = "\(pid)-\(CFHash(element))"
                currentWindowIDs[CFHash(window), default: []].append(id)
                guard var node = snapshot(element, depth: depth) else { return }
                node.subrole = subrole
                node.frame = rect(element)
                node.description = string(element, "AXAttributedDescription")
                if node.description.isEmpty { node.description = string(element, kAXDescriptionAttribute) }
                if var notice = NotchNotificationParser.parse(node, id: id, apps: apps) {
                    if notice.app.isUnresolved, iconCache[id] == nil,
                       let iconFrame = NotchNotificationParser.sourceIconFrame(in: node, source: notice.app.name) {
                        iconFrames[id] = (iconFrame, window)
                    }
                    notice.iconData = iconCache[id]
                    notices.append(notice)
                    currentBanners[id] = Banner(element: element, window: window)
                }
                return
            }
            for child in children(element) { findBanners(child, window: window, depth: depth + 1) }
        }
        for window in windows { findBanners(window, window: window, depth: 0) }
        // A failed/partial read preserves the baseline instead of replaying it.
        guard complete else { return }
        for index in notices.indices {
            let id = notices[index].id
            if let (frame, window) = iconFrames[id], let data = NotchNotificationIconCapture.capture(frame: frame, window: window) {
                iconCache[id] = data
            }
            notices[index].iconData = iconCache[id]
        }
        iconCache = iconCache.filter { currentBanners[$0.key] != nil || hidden?.id == $0.key }
        banners = currentBanners
        windowBannerIDs = currentWindowIDs
        if let hidden, windowBannerIDs[CFHash(hidden.window)] != [hidden.id] { restore() }
        let fresh = arrivals.update(notices)
        let generation = self.generation
        for notice in fresh {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Delivery eligibility is rechecked by the service on main.
                self.worker.async { [weak self] in
                    guard let self, generation == self.generation else { return }
                    DispatchQueue.main.async { [weak self] in self?.onArrival?(notice) }
                }
            }
        }
    }

    /// Only move a host containing this one banner. A mixed stack, widgets,
    /// Notification Center itself, or an unsupported AX position stays native.
    func suppress(_ id: String, completion: @escaping (Bool) -> Void) {
        worker.async { [self] in
            restore()
            guard let banner = banners[id], windowBannerIDs[CFHash(banner.window)] == [id],
                  let old = point(banner.window), !isFocused(banner.window) else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let moved = setPosition(banner.window, CGPoint(x: old.x, y: -20000))
                && point(banner.window).map { $0.y < -19000 } == true
            if moved {
                hidden = (id, banner.window, old)
                let expiry = DispatchWorkItem { [weak self] in
                    guard let self, self.hidden?.id == id else { return }
                    self.restore()
                }
                restoreWork = expiry
                worker.asyncAfter(deadline: .now() + 9, execute: expiry)
            }
            else { _ = setPosition(banner.window, old) }
            DispatchQueue.main.async { completion(moved) }
        }
    }

    func restoreNative(_ id: String? = nil) {
        worker.async { [self] in
            if id == nil || hidden?.id == id { restore() }
        }
    }

    func openNative(_ id: String) {
        worker.async { [self] in
            restore()
            guard let banner = banners[id] else { return }
            _ = AXUIElementPerformAction(banner.element, kAXPressAction as CFString)
        }
    }

    private func restore() {
        restoreWork?.cancel(); restoreWork = nil
        if let hidden { _ = setPosition(hidden.window, hidden.position) }
        hidden = nil
    }

    private func point(_ element: AXUIElement) -> CGPoint? {
        guard let value = value(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let position = point(element), let raw = value(element, kAXSizeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func setPosition(_ element: AXUIElement, _ position: CGPoint) -> Bool {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    private func isFocused(_ window: AXUIElement) -> Bool {
        guard let root, let focused = value(root, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(focused, window)
    }
}

private final class NotchNotificationTestDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

final class SystemNotificationNotch: ObservableObject {
    static let shared = SystemNotificationNotch()
    @Published private(set) var status = "Off"
    @Published private(set) var receivedCount = 0
    @Published private(set) var replacedCount = 0
    private let observer = NotchNotificationObserver()
    private var started = false
    private var monitorTimer: Timer?
    private var presentWork: DispatchWorkItem?
    private var queue = NotchNotificationQueue()
    private var testingUntil = Date.distantPast
    private let testDelegate = NotchNotificationTestDelegate()
    private static let testTitle = "MSG notification test"
    private var isTesting: Bool { Date() < testingUntil }
    private var testApp: NotchNotificationApp {
        NotchNotificationApp(id: "H1D3S1GN.MSG", name: "MSG", path: Bundle.main.bundlePath, aliases: ["MSG"])
    }

    private init() {
        observer.onArrival = { [weak self] in self?.receive($0) }
        observer.onStatus = { [weak self] listening in
            guard let self, AppSettings.shared.notchAppNotifications || self.isTesting else { return }
            self.status = listening ? "Listening for banners from all apps" : "Notification Center is unavailable"
        }
    }

    func start() {
        guard !started else { return }
        started = true
        PresentationState.shared.addObserver { [weak self] in
            guard let self else { return }
            if !PresentationState.shared.canPresent {
                self.queue.clear()
                self.observer.restoreNative()
                NotchHUD.shared.dismissAppNotification()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                           object: nil, queue: .main) { [weak self] info in
            guard let app = info.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.notificationcenterui" else { return }
            self?.observer.restoreNative()
            NotchHUD.shared.dismissAppNotification()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            self?.observer.stop()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            self?.observer.restoreNative()
            NotchHUD.shared.dismissAppNotification()
        }
        // A test-only hook exercises the signed app's real AX permission. Its
        // report contains counts/status only, never notification text.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("H1D3S1GN.MSG.debug.notificationTest"),
                                                             object: nil, queue: .main) { [weak self] info in
            guard let request = info.object as? String, UUID(uuidString: request) != nil else { return }
            self?.testSystemBanner(promptForPermission: false, reportID: request)
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("H1D3S1GN.MSG.debug.notificationStatus"),
                                                             object: nil, queue: .main) { [weak self] info in
            guard let self, let request = info.object as? String, UUID(uuidString: request) != nil else { return }
            self.writeTestReport(request, received: self.receivedCount, replaced: self.replacedCount)
        }
        settingChanged()
    }

    func settingChanged() {
        monitorTimer?.invalidate(); monitorTimer = nil
        presentWork?.cancel(); presentWork = nil
        queue.clear()
        NotchHUD.shared.dismissAppNotification()
        refreshObserver()
        guard AppSettings.shared.notchAppNotifications || isTesting else { return }
        // Only permission/process health is checked here; AX trees are event-driven.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshObserver() }
        RunLoop.main.add(timer, forMode: .common)
        monitorTimer = timer
    }

    private func refreshObserver() {
        let settings = AppSettings.shared
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
            .first?.processIdentifier ?? 0
        let enabled = (settings.notchAppNotifications || isTesting) && AXIsProcessTrusted()
        observer.configure(pid: enabled ? pid : 0)
        if !settings.notchAppNotifications && !isTesting { status = "Off" }
        else if !AXIsProcessTrusted() { status = "Allow MSG in Accessibility to receive banners" }
        else if pid == 0 { status = "Waiting for Notification Center" }
    }

    private func receive(_ notice: NotchAppNotification) {
        let test = isTesting && notice.app.id == testApp.id && notice.title == Self.testTitle
        guard test || AppSettings.shared.notchAppNotifications,
              PresentationState.shared.canPresent,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.notificationcenterui" else { return }
        receivedCount += 1
        queue.append(notice)
        flush()
    }

    private func flush() {
        presentWork?.cancel(); presentWork = nil
        guard PresentationState.shared.canPresent else { queue.clear(); return }
        guard let notice = queue.next() else { return }
        let accepted = NotchHUD.shared.showAppNotification(notice)
        if accepted {
            queue.remove(notice.id)
            observer.suppress(notice.id) { [weak self] hidden in
                guard let self else { return }
                if hidden { self.replacedCount += 1 }
                else if notice.app.id != "H1D3S1GN.MSG" { self.status = "Notch shown; native banner could not be hidden" }
                if !NotchHUD.shared.isShowingAppNotification(notice.id) { self.observer.restoreNative(notice.id) }
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        presentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (accepted ? 8 : 0.5), execute: work)
    }

    func openApp(_ notice: NotchAppNotification) {
        if notice.app.isUnresolved { observer.openNative(notice.id); return }
        observer.restoreNative(notice.id)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: notice.app.id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func cardEnded(_ id: String) { observer.restoreNative(id) }

    func testCard() {
        let app = NotchNotificationApp(id: "H1D3S1GN.MSG", name: "MSG", path: Bundle.main.bundlePath, aliases: ["MSG"])
        queue.append(NotchAppNotification(id: UUID().uuidString, app: app, title: "Notch notifications",
                                          subtitle: "", body: "New notifications from all apps will appear here."))
        flush()
    }

    func testSystemBanner(promptForPermission: Bool = true, reportID: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    self.sendTestBanner(reportID: reportID)
                } else if promptForPermission {
                    center.requestAuthorization(options: [.alert]) { allowed, _ in
                        DispatchQueue.main.async {
                            if allowed { self.sendTestBanner(reportID: reportID) }
                            else { self.status = "Allow MSG notifications to test a system banner" }
                        }
                    }
                } else {
                    self.status = "MSG notification permission is needed for the system test"
                    self.writeTestReport(reportID, received: 0, replaced: 0)
                }
            }
        }
    }

    private func sendTestBanner(reportID: String?) {
        let received = receivedCount
        let replaced = replacedCount
        testingUntil = Date().addingTimeInterval(20)
        settingChanged()
        let identifier = "MSG.notch-test.\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = Self.testTitle
        content.body = "This banner is routed through Notification Center into the notch."
        let center = UNUserNotificationCenter.current()
        center.delegate = testDelegate
        center.add(UNNotificationRequest(identifier: identifier, content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))) { [weak self] error in
            if error != nil { DispatchQueue.main.async { self?.status = "The system test notification could not be sent" } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self else { return }
            self.writeTestReport(reportID, received: self.receivedCount - received, replaced: self.replacedCount - replaced)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 21) { [weak self] in
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            self?.settingChanged()
        }
    }

    private func writeTestReport(_ id: String?, received: Int, replaced: Int) {
        guard let id, UUID(uuidString: id) != nil else { return }
        let report: [String: Any] = ["status": status, "received": received, "replaced": replaced,
                                    "accessibility": AXIsProcessTrusted(), "canPresent": PresentationState.shared.canPresent,
                                    "screenCapture": CGPreflightScreenCaptureAccess(),
                                    "notchAvailable": AgentNotchCard.notchScreen() != nil]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/MSG-notification-test-\(id).json"), options: .atomic)
    }
}

@available(macOS 14.0, *)
struct NotchNotificationSettings: View {
    @ObservedObject var vm: SettingsViewModel
    @ObservedObject private var service = SystemNotificationNotch.shared

    var body: some View {
        SettingsToggleRow("All app notifications in the notch (Experimental)",
                          detail: "Shows new visible banners from all apps. No app selection is needed. If the notch or banner control is unavailable, the native banner stays visible.",
                          isOn: Binding(get: { vm.notchAppNotifications }, set: { vm.notchAppNotifications = $0 }))
        if vm.notchAppNotifications {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Test Notch Card") { service.testCard() }
                    Button("Test System Banner") { service.testSystemBanner() }
                }
                Text(service.status + (service.receivedCount > 0 ? " · \(service.receivedCount) received, \(service.replacedCount) replaced" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if !AXIsProcessTrusted() {
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

}
