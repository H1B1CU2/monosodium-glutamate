import AppKit
import Combine
import Darwin
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
    case hidden(Int)
    case pinned(Int)
    case none
}

// MARK: - TrayState

@available(macOS 14.0, *)
final class TrayState: ObservableObject {
    @Published var activeApps:  [TrayApp] = []
    @Published var hiddenApps:  [TrayApp] = []
    @Published var pinnedApps:  [TrayApp] = []
    @Published var search:      String    = ""
    @Published var selection:   TraySelection = .none
    @Published var isVisible:   Bool      = false
    @Published var nowPlayingTitle:  String? = nil
    @Published var nowPlayingArtist: String? = nil
    @Published var nowPlayingSource: String? = nil
    @Published var nowPlayingBundleID: String? = nil
    @Published var nowPlayingAppIcon: NSImage? = nil
    @Published var isNowPlaying: Bool = false
    @Published var albumArt: NSImage? = nil
    @Published var desktopAppIDs: Set<String> = []
    @Published var previewImages: [NSImage] = []

    private let settings: AppSettings
    private let tracker  = TrayAppTracker()
    private let pins     = TrayPinSource()
    /// Readable by TrayPanel so it can hold a Now Playing polling token while
    /// the panel is on screen (F1 demand gating).
    private(set) var musicMonitor: MusicMonitor?
    private var cancellables = Set<AnyCancellable>()

    private var hiddenAppIDs: Set<String> = []
    var filteredActive: [TrayApp] {
        let base = (search.isEmpty ? activeApps : activeApps.filter { matches($0) })
            .filter { !hiddenAppIDs.contains($0.id) }
        return base.sorted { a, b in
            let aDesktop = desktopAppIDs.contains(a.id)
            let bDesktop = desktopAppIDs.contains(b.id)
            if aDesktop != bDesktop { return aDesktop }
            return base.firstIndex(of: a) ?? 0 < base.firstIndex(of: b) ?? 0
        }
    }
    var filteredHidden: [TrayApp] {
        let base = hiddenApps.filter { !desktopAppIDs.contains($0.id) }
        return search.isEmpty ? base : base.filter { matches($0) }
    }
    var filteredPinned: [TrayApp] {
        let activeIDs = Set(activeApps.map(\.id))
        let pins = pinnedApps.filter { !activeIDs.contains($0.id) }
        return search.isEmpty ? pins : pins.filter { matches($0) }
    }
    var previewedApp: TrayApp? {
        switch selection {
        case .active(let i): return filteredActive.indices.contains(i) ? filteredActive[i] : nil
        case .hidden(let i): return filteredHidden.indices.contains(i) ? filteredHidden[i] : nil
        case .pinned(let i): return filteredPinned.indices.contains(i) ? filteredPinned[i] : nil
        case .none: return nil
        }
    }

    init(settings: AppSettings, musicMonitor: MusicMonitor) {
        self.settings = settings
        self.musicMonitor = musicMonitor
        tracker.onChange = { [weak self] apps in
            DispatchQueue.main.async {
                self?.activeApps = apps
                self?.updatePlayingStatuses()
            }
        }
        pins.onChange = { [weak self] apps in
            DispatchQueue.main.async {
                self?.pinnedApps = apps
                self?.updatePlayingStatuses()
            }
        }
        musicMonitor.addObserver { [weak self] in
            guard let self, let m = self.musicMonitor else { return }
            DispatchQueue.main.async {
                self.isNowPlaying      = m.isPlaying
                self.nowPlayingTitle   = m.currentTitle
                self.nowPlayingArtist  = m.currentArtist
                self.nowPlayingSource  = m.currentSource
                self.albumArt         = m.albumArt
                if self.nowPlayingBundleID != m.currentSourceBundleID {
                    self.nowPlayingBundleID = m.currentSourceBundleID
                    self.nowPlayingAppIcon = m.currentSourceBundleID.flatMap { bid in
                        NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.icon
                            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
                                .map { NSWorkspace.shared.icon(forFile: $0.path) }
                    }
                }
                self.updatePlayingStatuses()
            }
        }

        $selection
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.capturePreviewImages()
            }
            .store(in: &cancellables)
    }

    private func updatePlayingStatuses() {
        guard let m = musicMonitor else { return }
        let updatePlaying: (TrayApp) -> TrayApp = { app in
            var copy = app
            let sourceMatches: Bool
            if let sourceBID = m.currentSourceBundleID {
                sourceMatches = (sourceBID.lowercased() == app.id.lowercased())
            } else {
                sourceMatches = (m.currentSource?.lowercased().contains(app.name.lowercased()) == true)
            }
            copy.isPlaying = sourceMatches && m.isPlaying
            return copy
        }
        self.activeApps = self.activeApps.map(updatePlaying)
        self.hiddenApps = self.hiddenApps.map(updatePlaying)
        self.pinnedApps = self.pinnedApps.map(updatePlaying)
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
            self?.previewImages = await WindowPreviewCapture.capture(pid: pid, maxWindows: 3).map(\.image)
        }
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
        refreshHiddenApps()
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

    private func refreshHiddenApps() {
        // Apps with windows but none visible: Cmd+H hidden or all minimized.
        guard let all = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            hiddenApps = []
            hiddenAppIDs = []
            return
        }
        var allPIDs = Set<pid_t>()
        for info in all {
            if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
               let layer = info[kCGWindowLayer as String] as? Int, layer == 0 {
                allPIDs.insert(pid)
            }
        }
        // Candidates: have windows but none visible
        let candidates = NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bid = app.bundleIdentifier else { return false }
                return allPIDs.contains(app.processIdentifier)
                    && !desktopAppIDs.contains(bid)
            }
        // Include if Cmd+H hidden or all windows AX-minimized
        var hidden = Set<String>()
        for app in candidates {
            if app.isHidden || allWindowsMinimized(pid: app.processIdentifier) {
                hidden.insert(app.bundleIdentifier ?? "")
            }
        }
        hiddenAppIDs = hidden
        hiddenApps = activeApps.filter { hiddenAppIDs.contains($0.id) }
    }

    private func allWindowsMinimized(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement],
              !windows.isEmpty else { return false }
        return windows.allSatisfy { win in
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &mini)
            return (mini as? Bool) == true
        }
    }

    func resetSearch() { search = "" }

    func defaultSelection(goBack: Bool = false) {
        let apps = filteredActive
        guard !apps.isEmpty else { selection = .none; return }
        if goBack {
            selection = .active(apps.count - 1)
        } else {
            selection = apps.count > 1 ? .active(1) : .active(0)
        }
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
        focus(app)
        dismissAction?()
    }

    func activateWindowPreview(at index: Int) {
        guard let app = previewedApp else { return }
        if app.pid > 0 { raiseAXWindow(pid: app.pid, at: index) }
        focus(app)
        dismissAction?()
    }

    /// Brings an app to the foreground from this never-active background app.
    ///
    /// macOS 14+ cooperative activation silently ignores
    /// `NSRunningApplication.activate` from a process that isn't the active app
    /// — the call still returns true. AX frontmost (we hold Accessibility for
    /// the ⌘⇥ tap) works in most cases; when the frontmost check still fails
    /// shortly after, fall back to LaunchServices (the `open -a` path), which
    /// the system honors for background callers.
    private func focus(_ app: TrayApp) {
        let running = (app.pid > 0 ? NSRunningApplication(processIdentifier: app.pid) : nil)
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first
        guard let running, !running.isTerminated else {
            launch(app.id)
            return
        }
        if running.isHidden { running.unhide() }

        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)   // a hung app must not stall the HUD
        let windows = axWindows(axApp)

        // Running but windowless (every window closed). Frontmost + activate
        // puts it in the menu bar with nothing on screen, and because it *is*
        // frontmost the fallback below never fires. LaunchServices sends the
        // reopen AppleEvent instead — the Dock-click path, which makes the app
        // recreate its default window.
        guard !windows.isEmpty else {
            launch(app.id)
            return
        }

        unminimizeIfNeeded(windows)

        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        running.activate(from: .current, options: [.activateAllWindows])
        raiseFrontWindow(windows)

        let pid = running.processIdentifier
        let bid = app.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSLog("Tray: activation of %@ not honored — falling back to LaunchServices", bid)
                self?.launch(bid)
            }
        }
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if let error {
                NSLog("Tray: LaunchServices activation failed for %@: %@", bundleID, String(describing: error))
            }
        }
    }

    private func axWindows(_ axApp: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    /// Frontmost alone doesn't pull in a window living on another Space or in
    /// its own fullscreen Space — raising it does.
    private func raiseFrontWindow(_ windows: [AXUIElement]) {
        let target = windows.first { win in
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &mini)
            return (mini as? Bool) != true
        }
        guard let target else { return }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
    }

    /// An app whose windows are all minimized comes forward with nothing on
    /// screen — restore its first minimized window so the switch is visible.
    private func unminimizeIfNeeded(_ windows: [AXUIElement]) {
        var firstMinimized: AXUIElement?
        for win in windows {
            var mini: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &mini)
            if (mini as? Bool) == true {
                if firstMinimized == nil { firstMinimized = win }
            } else {
                return   // has a visible window — nothing to restore
            }
        }
        if let win = firstMinimized {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
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
        AXUIElementSetAttributeValue(visible[index], kAXMainAttribute as CFString, kCFBooleanTrue)
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
        let runningMap = Dictionary(running.compactMap { app -> (String, NSRunningApplication)? in
            guard let bid = app.bundleIdentifier else { return nil }
            return (bid, app)
        }, uniquingKeysWith: { first, _ in first })
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
