import AppKit
import Combine
import ScreenCaptureKit

// MARK: - Models

struct TrayApp: Identifiable, Equatable {
    let id: String          // bundle identifier
    let name: String
    let icon: NSImage?
    let pid: pid_t
    var badge: String?
    var isPlaying: Bool = false

    static func == (lhs: TrayApp, rhs: TrayApp) -> Bool { lhs.id == rhs.id }
}

enum TraySelection: Equatable {
    case active(Int)
    case pinned(Int)
    case none
}

// MARK: - TrayState

final class TrayState: ObservableObject {
    @Published var activeApps:  [TrayApp] = []
    @Published var pinnedApps:  [TrayApp] = []
    @Published var search:      String    = ""
    @Published var selection:   TraySelection = .none
    @Published var isVisible:   Bool      = false
    @Published var nowPlayingTitle:  String? = nil
    @Published var nowPlayingArtist: String? = nil
    @Published var nowPlayingSource: String? = nil
    @Published var isNowPlaying: Bool = false
    @Published var albumArt: NSImage? = nil
    @Published var desktopAppIDs: Set<String> = []
    @Published var previewImages: [NSImage] = []

    private let settings: AppSettings
    private let tracker  = TrayAppTracker()
    private let pins     = TrayPinSource()
    private var musicMonitor: MusicMonitor?
    private var cancellables = Set<AnyCancellable>()

    var filteredActive: [TrayApp] {
        let base = search.isEmpty ? activeApps : activeApps.filter { matches($0) }
        // Desktop apps first, then rest — maintain MRU order within each group
        return base.sorted { a, b in
            let aDesktop = desktopAppIDs.contains(a.id)
            let bDesktop = desktopAppIDs.contains(b.id)
            if aDesktop != bDesktop { return aDesktop }
            return base.firstIndex(of: a) ?? 0 < base.firstIndex(of: b) ?? 0
        }
    }
    var filteredPinned: [TrayApp] {
        let activeIDs = Set(activeApps.map(\.id))
        let pins = pinnedApps.filter { !activeIDs.contains($0.id) }
        return search.isEmpty ? pins : pins.filter { matches($0) }
    }
    var previewedApp: TrayApp? {
        switch selection {
        case .active(let i): return filteredActive.indices.contains(i) ? filteredActive[i] : nil
        case .pinned(let i): return filteredPinned.indices.contains(i) ? filteredPinned[i] : nil
        case .none: return nil
        }
    }

    init(settings: AppSettings, musicMonitor: MusicMonitor) {
        self.settings = settings
        self.musicMonitor = musicMonitor
        tracker.onChange = { [weak self] apps in
            DispatchQueue.main.async { self?.activeApps = apps }
        }
        pins.onChange = { [weak self] apps in
            DispatchQueue.main.async { self?.pinnedApps = apps }
        }
        musicMonitor.onChange = { [weak self] in
            guard let self, let m = self.musicMonitor else { return }
            DispatchQueue.main.async {
                self.isNowPlaying      = m.isPlaying
                self.nowPlayingTitle   = m.currentTitle
                self.nowPlayingArtist  = m.currentArtist
                self.nowPlayingSource  = m.currentSource
                self.albumArt         = m.albumArt
                self.activeApps = self.activeApps.map { app in
                    var copy = app
                    copy.isPlaying = (m.currentSource?.lowercased().contains(app.name.lowercased()) == true) && m.isPlaying
                    return copy
                }
            }
        }

        $selection
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                if #available(macOS 14.0, *) { self?.capturePreviewImages() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Window preview capture

    @available(macOS 14.0, *)
    private func capturePreviewImages() {
        guard let app = previewedApp, app.pid > 0 else {
            previewImages = []
            return
        }
        let pid = app.pid
        Task { @MainActor [weak self] in
            self?.previewImages = await Self.captureWindowsSCK(pid: pid)
        }
    }

    @available(macOS 14.0, *)
    private static func captureWindowsSCK(pid: pid_t) async -> [NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return [] }

        let windows = content.windows
            .filter {
                $0.owningApplication?.processID == Int32(pid) &&
                $0.windowLayer == 0 &&
                $0.frame.width >= 200 && $0.frame.height >= 100
            }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }

        var images: [NSImage] = []
        for win in windows.prefix(3) {
            guard win.frame.width > 0, win.frame.height > 0 else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            cfg.width  = max(1, Int(win.frame.width  * 2))
            cfg.height = max(1, Int(win.frame.height * 2))
            if let cg = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg
            ) {
                images.append(NSImage(cgImage: cg, size: win.frame.size))
            }
        }
        return images
    }

    // MARK: - Lifecycle

    func prepare() {
        tracker.start()
        pins.start(dockSync: settings.trayDockSync)
    }

    func refresh() {
        tracker.reload()
        pins.reload(dockSync: settings.trayDockSync)
        refreshDesktopApps()
    }

    private func refreshDesktopApps() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            desktopAppIDs = []
            return
        }
        var pids = Set<pid_t>()
        for info in list {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
               let layer = info[kCGWindowLayer as String] as? Int, layer == 0 {
                pids.insert(pid)
            }
        }
        let bids = NSWorkspace.shared.runningApplications
            .filter { pids.contains($0.processIdentifier) }
            .compactMap { $0.bundleIdentifier }
        desktopAppIDs = Set(bids)
    }

    func resetSearch() { search = "" }

    func defaultSelection() {
        // Select index 1 (next-MRU) like the system switcher, fallback to 0
        let apps = filteredActive
        selection = apps.count > 1 ? .active(1) : (apps.isEmpty ? .none : .active(0))
    }

    // MARK: - Keyboard navigation

    func selectNext() {
        let apps = filteredActive
        guard !apps.isEmpty else { return }
        switch selection {
        case .active(let i): selection = .active((i + 1) % apps.count)
        default:             selection = .active(0)
        }
    }

    func selectPrev() {
        let apps = filteredActive
        guard !apps.isEmpty else { return }
        switch selection {
        case .active(let i): selection = .active((i - 1 + apps.count) % apps.count)
        default:             selection = .active(apps.count - 1)
        }
    }

    var dismissAction: (() -> Void)?

    func activateSelection() {
        guard let app = previewedApp else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first {
            running.activate(options: [.activateIgnoringOtherApps])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
            NSWorkspace.shared.open(url)
        }
        dismissAction?()
    }

    func activateWindowPreview(at index: Int) {
        guard let app = previewedApp else { return }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first {
            running.activate(options: [.activateIgnoringOtherApps])
        }
        if app.pid > 0 { raiseAXWindow(pid: app.pid, at: index) }
        dismissAction?()
    }

    private func raiseAXWindow(pid: pid_t, at index: Int) {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        let visible = windows.filter { win in
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &mini)
            return (mini as? Bool) != true
        }
        guard index < visible.count else { return }
        AXUIElementPerformAction(visible[index], kAXRaiseAction as CFString)
    }

    func quitSelection() {
        guard let app = previewedApp else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
            .first?.terminate()
    }

    private func matches(_ app: TrayApp) -> Bool {
        app.name.localizedCaseInsensitiveContains(search)
    }
}

// MARK: - TrayAppTracker

final class TrayAppTracker {
    var onChange: (([TrayApp]) -> Void)?
    private var mruOrder: [String] = []   // bundle IDs, most-recent first
    private var observers: [Any] = []

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bid = app.bundleIdentifier else { return }
            self?.prepend(bid)
            self?.emit()
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.emit() })
        reload()
    }

    func reload() {
        // Seed MRU from currently running apps if we have no history yet
        if mruOrder.isEmpty {
            mruOrder = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleIdentifier }
        }
        emit()
    }

    private func prepend(_ bid: String) {
        mruOrder.removeAll { $0 == bid }
        mruOrder.insert(bid, at: 0)
    }

    private func emit() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let runningMap = Dictionary(uniqueKeysWithValues: running.compactMap { app -> (String, NSRunningApplication)? in
            guard let bid = app.bundleIdentifier else { return nil }
            return (bid, app)
        })
        // MRU-ordered, then any remaining running apps not yet in mruOrder
        var seen = Set<String>()
        var ordered: [TrayApp] = []
        for bid in mruOrder {
            guard let app = runningMap[bid], !seen.contains(bid) else { continue }
            seen.insert(bid)
            ordered.append(TrayApp(id: bid, name: app.localizedName ?? bid,
                                   icon: app.icon, pid: app.processIdentifier))
        }
        for (bid, app) in runningMap where !seen.contains(bid) {
            ordered.append(TrayApp(id: bid, name: app.localizedName ?? bid,
                                   icon: app.icon, pid: app.processIdentifier))
        }
        onChange?(ordered)
    }
}

// MARK: - TrayPinSource

final class TrayPinSource {
    var onChange: (([TrayApp]) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    func start(dockSync: Bool) {
        reload(dockSync: dockSync)
        guard dockSync else { return }
        watchDockPlist()
    }

    func reload(dockSync: Bool) {
        if dockSync {
            onChange?(readDockPins())
        }
        // Custom list support can be added later via UserDefaults
    }

    private func watchDockPlist() {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: .write,
                                                          queue: .main)
        s.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.onChange?(self?.readDockPins() ?? [])
            }
        }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
        }
        s.resume()
        source = s
    }

    private func readDockPins() -> [TrayApp] {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let dict = NSDictionary(contentsOfFile: path),
              let apps = dict["persistent-apps"] as? [[String: Any]] else { return [] }

        return apps.compactMap { entry -> TrayApp? in
            guard let tileData = entry["tile-data"] as? [String: Any],
                  let bid = tileData["bundle-identifier"] as? String else { return nil }
            let name = tileData["file-label"] as? String ?? bid
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return TrayApp(id: bid, name: name, icon: icon, pid: 0)
        }
    }
}
