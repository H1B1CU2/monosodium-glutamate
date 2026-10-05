import AppKit
import ApplicationServices

// MARK: - App shortcut

/// One of an app's keyboard shortcuts, as an Edge Key: pressed, MSG types the
/// shortcut into the front app.
struct AppShortcut: Codable, Hashable {
    let keyCode: UInt16
    /// ⌘ ⌥ ⌃ ⇧ only, as `NSEvent.ModifierFlags` raw bits.
    let modifiers: UInt
    /// The character the menu shows (uppercased), for matching menu items.
    let char: String
    var title: String
    var symbol: String?
    /// AppleScript run instead of typing a shortcut (Dia's sidebar has none).
    var script: String? = nil

    /// "⌃⌥⇧⌘T": the same for a key press and for the menu item it fires.
    var id: String { Self.id(modifiers: NSEvent.ModifierFlags(rawValue: modifiers), char: char) }

    static func id(modifiers: NSEvent.ModifierFlags, char: String) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + char.uppercased()
    }

    static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    func post() {
        if script == "diaSearch" {
            EdgeKeyAppKeys.toggleDiaSearch()
            return
        }
        if script == "bambuPrepare" {
            EdgeKeyAppKeys.switchBambuTab(.prepare)
            return
        }
        if script == "bambuPreview" {
            EdgeKeyAppKeys.switchBambuTab(.preview)
            return
        }
        if script == "dictate" {
            EdgeKeyAppKeys.toggleDictation()
            return
        }
        if script == "bambuDevice" {
            EdgeKeyAppKeys.switchBambuTab(.device)
            return
        }
        if script == "bambuProject" {
            EdgeKeyAppKeys.switchBambuTab(.project)
            return
        }
        if script == "obsidianLeftSidebar" {
            EdgeKeyAppKeys.toggleObsidianSidebar(.left)
            return
        }
        if script == "obsidianRightSidebar" {
            EdgeKeyAppKeys.toggleObsidianSidebar(.right)
            return
        }
        if script == "sp8ceYouTube" {
            EdgeKeyAppKeys.openYouTubeInSp8ce()
            return
        }
        if let script {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            return
        }
        let flags = Self.cgFlags(NSEvent.ModifierFlags(rawValue: modifiers))
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func cgFlags(_ m: NSEvent.ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.shift) { f.insert(.maskShift) }
        return f
    }
}

// MARK: - App keys

/// F3–F9 follow the front app: its most-used shortcuts, left to right.
///
/// Built from a few presets plus what MSG learns — every ⌘ or ⌃ shortcut you
/// press in an app is counted, named from that app's own menu, and the most
/// used rise to the left. The order is settled when you switch to the app,
/// never while you're using it, so keys don't move under your fingers.
final class EdgeKeyAppKeys {
    static let shared = EdgeKeyAppKeys()

    /// The keys that follow the app.
    static let keys = 3...9

    /// Uses per app and shortcut id.
    private var usage: [String: [String: Double]] = [:]
    /// Shortcuts seen in each app, by id, with the name last read from its menu.
    private var learned: [String: [String: AppShortcut]] = [:]
    /// Each running app's menu shortcuts (id → title), read once per launch.
    private var menuTitles: [pid_t: [String: String]] = [:]
    private var readingMenus: Set<pid_t> = []
    private var saveWork: DispatchWorkItem?
    /// Told when an app's menu has been read, so its keys can be named.
    var onMenusRead: ((pid_t) -> Void)?

    private static let usageKey = "edgeKeysAppUsage"
    private static let learnedKey = "edgeKeysAppLearned"

    /// Everyday editing and window shortcuts: pressed constantly, never worth a key.
    private static let ignored: Set<String> = [
        "⌘C", "⌘V", "⌘X", "⌘Z", "⌘⇧Z", "⌘A", "⌘Q", "⌘H", "⌘⌥H", "⌘M", "⌘S", "⌘,", "⌘`", "⌘ ", "⌘\t", "⌘⇧4", "⌘⇧3", "⌘⇧5",
    ].reduce(into: Set<String>()) { set, id in
        // Written "⌘C"; stored modifiers-first as `AppShortcut.id` spells them.
        let mods = id.filter { "⌃⌥⇧⌘".contains($0) }
        let rest = id.filter { !"⌃⌥⇧⌘".contains($0) }
        var m: NSEvent.ModifierFlags = []
        if mods.contains("⌘") { m.insert(.command) }
        if mods.contains("⌥") { m.insert(.option) }
        if mods.contains("⌃") { m.insert(.control) }
        if mods.contains("⇧") { m.insert(.shift) }
        set.insert(AppShortcut.id(modifiers: m, char: rest))
    }

    private init() {
        let d = UserDefaults.standard
        usage = d.dictionary(forKey: Self.usageKey) as? [String: [String: Double]] ?? [:]
        if let data = d.data(forKey: Self.learnedKey),
           let decoded = try? JSONDecoder().decode([String: [String: AppShortcut]].self, from: data) {
            learned = decoded
        }
    }

    // MARK: Learning

    /// A key press in the front app. Only ⌘ or ⌃ shortcuts count — never typing.
    func record(keyCode: UInt16, flags: CGEventFlags, event: CGEvent) {
        guard AppSettings.shared.edgeKeysAppKeysLearn,
              flags.contains(.maskCommand) || flags.contains(.maskControl),
              let app = NSWorkspace.shared.frontmostApplication,
              let bundle = app.bundleIdentifier, bundle != Bundle.main.bundleIdentifier,
              let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers, !chars.isEmpty
        else { return }
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection(AppShortcut.modifierMask)
        let char = chars.uppercased()
        let id = AppShortcut.id(modifiers: modifiers, char: char)
        guard !Self.ignored.contains(id) else { return }
        let title = menuTitles[app.processIdentifier]?[id] ?? learned[bundle]?[id]?.title ?? ""
        var shortcut = AppShortcut(keyCode: keyCode, modifiers: modifiers.rawValue, char: char, title: title,
                                   symbol: Self.symbol(forTitle: title))
        if shortcut.title.isEmpty, let known = learned[bundle]?[id] { shortcut = known }
        learned[bundle, default: [:]][id] = shortcut
        usage[bundle, default: [:]][id, default: 0] += 1
        scheduleSave()
    }

    /// An app key pressed on the strip counts as a use too.
    func recordPress(_ shortcut: AppShortcut, bundle: String) {
        guard AppSettings.shared.edgeKeysAppKeysLearn else { return }
        usage[bundle, default: [:]][shortcut.id, default: 0] += 1
        scheduleSave()
    }

    func resetLearned() {
        usage = [:]
        learned = [:]
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.usage, forKey: Self.usageKey)
            if let data = try? JSONEncoder().encode(self.learned) {
                UserDefaults.standard.set(data, forKey: Self.learnedKey)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: Keys

    /// F3–F9 for the app: its presets in their set order — use never moves
    /// them — then learned shortcuts, most used first, in any keys left.
    /// Learned ones show only once the app's menu has named them.
    func row(for app: NSRunningApplication) -> [Int: EdgeKeyAction] {
        guard AppSettings.shared.edgeKeysAppKeys, let bundle = app.bundleIdentifier else { return [:] }
        if let fixed = Self.fixedRow(for: bundle) { return fixed }
        readMenusIfNeeded(app)
        let titles = menuTitles[app.processIdentifier] ?? [:]
        let counts = usage[bundle] ?? [:]
        var candidates: [(AppShortcut, Double)] = []
        var seen = Set<String>()
        // Presets always first, in their listed order.
        for (index, preset) in Self.presets(for: bundle).enumerated() {
            seen.insert(preset.id)
            candidates.append((preset, 1_000_000 - Double(index)))
        }
        for (id, shortcut) in learned[bundle] ?? [:] where !seen.contains(id) {
            let count = counts[id] ?? 0
            guard count >= 2 else { continue }
            var named = shortcut
            if let title = titles[id] { named.title = title; named.symbol = Self.symbol(forTitle: title) }
            guard !named.title.isEmpty else { continue }
            candidates.append((named, count))
        }
        // An app with a usage limit MSG can read keeps the last key for it.
        let usageSource = AIUsage.source(for: bundle)
        // The AI chat apps keep F9 for dictation; their usage key moves to F8.
        let dictates = Self.dictationApps.contains(bundle)
        let slots = Self.keys.count - (usageSource == nil ? 0 : 1) - (dictates ? 1 : 0)
        let ranked = candidates.sorted { $0.1 > $1.1 }.prefix(slots).map(\.0)
        var row: [Int: EdgeKeyAction] = [:]
        for (offset, shortcut) in ranked.enumerated() {
            row[Self.keys.lowerBound + offset] = .shortcut(shortcut)
        }
        if let usageSource { row[Self.keys.upperBound - (dictates ? 1 : 0)] = .usage(usageSource) }
        if dictates { row[Self.keys.upperBound] = .shortcut(Self.dictate) }
        return row
    }

    // MARK: Menu names

    /// Reads the app's menu bar once, off the main thread: every item's
    /// shortcut and title, to name what was learned.
    private func readMenusIfNeeded(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard menuTitles[pid] == nil, !readingMenus.contains(pid) else { return }
        readingMenus.insert(pid)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let titles = Self.menuShortcuts(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingMenus.remove(pid)
                self.menuTitles[pid] = titles
                if self.menuTitles.count > 40 {
                    let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                    self.menuTitles = self.menuTitles.filter { running.contains($0.key) }
                }
                self.onMenusRead?(pid)
            }
        }
    }

    private static func menuShortcuts(pid: pid_t) -> [String: String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = attribute(app, kAXMenuBarAttribute) as AXUIElement? else { return [:] }
        var result: [String: String] = [:]
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 4, let children = attribute(element, kAXChildrenAttribute) as [AXUIElement]? else { return }
            for child in children {
                if let char = attribute(child, "AXMenuItemCmdChar") as String?, !char.isEmpty,
                   let title = attribute(child, kAXTitleAttribute) as String?, !title.isEmpty {
                    let axMods = (attribute(child, "AXMenuItemCmdModifiers") as NSNumber?)?.intValue ?? 0
                    var m: NSEvent.ModifierFlags = []
                    if axMods & 8 == 0 { m.insert(.command) }
                    if axMods & 1 != 0 { m.insert(.shift) }
                    if axMods & 2 != 0 { m.insert(.option) }
                    if axMods & 4 != 0 { m.insert(.control) }
                    let id = AppShortcut.id(modifiers: m, char: char)
                    if result[id] == nil { result[id] = title }
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(bar, depth: 0)
        return result
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: Presets

    private static func shortcut(_ char: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags = .command,
                                 _ title: String, _ symbol: String) -> AppShortcut {
        AppShortcut(keyCode: keyCode, modifiers: mods.rawValue, char: char, title: title, symbol: symbol)
    }

    private static let browsers: Set<String> = [
        "company.thebrowser.dia", "company.thebrowser.Browser", "com.apple.Safari", "com.google.Chrome",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
    ]

    /// Dia's View ▸ Auto-Hide Tabs (⌘S): shows or hides the sidebar.
    private static let diaSidebar = shortcut("S", 1, .command, "Sidebar", "sidebar.left")

    /// Apps whose F9 starts and stops dictation.
    private static let dictationApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
    ]

    /// macOS's own dictation, from the front app's Edit ▸ Start Dictation —
    /// the item the system adds to every app's Edit menu. Again stops it.
    private static let dictate = AppShortcut(keyCode: 0, modifiers: 0, char: "DICTATE", title: "Dictate",
                                             symbol: "mic.fill", script: "dictate")

    static func toggleDictation() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return }
        func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) ?? [] }
        // Menu bar ▸ menu title ▸ menu ▸ items.
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    let title: String = attribute(item, kAXTitleAttribute) ?? ""
                    guard title.localizedCaseInsensitiveContains("Dictation") else { continue }
                    AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return
                }
            }
        }
    }

    /// Dia's Search bar toggle (⌘L to open, Esc to close).
    private static let diaSearch = AppShortcut(
        keyCode: 37,
        modifiers: NSEvent.ModifierFlags.command.rawValue,
        char: "L",
        title: "Search",
        symbol: "magnifyingglass",
        script: "diaSearch"
    )

    private static var diaSearchOpen = false
    private static var lastDiaSearchToggle: CFTimeInterval = 0

    static func resetDiaSearchState() {
        diaSearchOpen = false
    }

    static func toggleDiaSearch() {
        guard let dia = NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.dia").first else {
            return
        }

        let now = CACurrentMediaTime()
        let app = AXUIElementCreateApplication(dia.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)

        var isSearchFocused = false
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef as! AXUIElement? {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            if role == "AXTextField" || role == "AXComboBox" {
                var current = focused
                var inWeb = false
                for _ in 0..<10 {
                    var rRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &rRef) == .success,
                       let r = rRef as? String, r == "AXWebArea" {
                        inWeb = true
                        break
                    }
                    var pRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &pRef) == .success,
                       let parent = pRef as! AXUIElement? {
                        current = parent
                    } else {
                        break
                    }
                }
                if !inWeb {
                    isSearchFocused = true
                }
            }
        }

        let shouldClose: Bool
        if isSearchFocused {
            shouldClose = true
        } else if diaSearchOpen && (now - lastDiaSearchToggle) < 15.0 {
            shouldClose = true
        } else {
            shouldClose = false
        }

        if shouldClose {
            // Post Escape (virtual key 53) to close the search bar
            postVirtualKey(53, modifiers: [])
            diaSearchOpen = false
        } else {
            // Post ⌘L (virtual key 37) to open the search bar
            postVirtualKey(37, modifiers: .command)
            diaSearchOpen = true
            lastDiaSearchToggle = now
        }
    }

    private static func postVirtualKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = AppShortcut.cgFlags(modifiers)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Bambu Studio Tab Switching

    enum BambuTab {
        case prepare
        case preview
        case device
        case project
    }

    private static let bambuPrepare = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "PREPARE",
        title: "Prepare",
        symbol: "cube",
        script: "bambuPrepare"
    )

    private static let bambuPreview = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "PREVIEW",
        title: "Preview",
        symbol: "square.3.layers.3d",
        script: "bambuPreview"
    )

    private static let bambuDevice = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "DEVICE",
        title: "Device",
        symbol: "printer.dotmatrix",
        script: "bambuDevice"
    )

    private static let bambuProject = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "PROJECT",
        title: "Project",
        symbol: "doc.text",
        script: "bambuProject"
    )

    static func switchBambuTab(_ tab: BambuTab) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.bambulab.bambu-studio").first ??
                        NSRunningApplication.runningApplications(withBundleIdentifier: "com.softfever3d.orca-slicer").first else {
            return
        }

        var winPos = CGPoint.zero
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &winRef) == .success,
           let win = winRef as! AXUIElement? {
            var posRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
               let posRef {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &winPos)
            }
        }
        if winPos == .zero {
            let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in windowList where (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier {
                let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let width = bounds["Width"] as? Double ?? 0
                let height = bounds["Height"] as? Double ?? 0
                if width > 600 && height > 400 {
                    let x = bounds["X"] as? Double ?? 0
                    let y = bounds["Y"] as? Double ?? 0
                    winPos = CGPoint(x: x, y: y)
                    break
                }
            }
        }

        let xOffset: CGFloat
        switch tab {
        case .prepare: xOffset = 115
        case .preview: xOffset = 245
        case .device:  xOffset = 375
        case .project: xOffset = 500
        }
        let yOffset: CGFloat = 50
        let targetPoint = CGPoint(x: winPos.x + xOffset, y: winPos.y + yOffset)

        let currentPos = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left),
           let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
        }
        if currentPos != .zero {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: currentPos, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Obsidian Sidebar Toggling

    enum ObsidianSidebar {
        case left
        case right
    }

    private static let obsidianLeftSidebar = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "LEFT_SIDEBAR",
        title: "Left Sidebar",
        symbol: "sidebar.left",
        script: "obsidianLeftSidebar"
    )

    private static let obsidianRightSidebar = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "RIGHT_SIDEBAR",
        title: "Right Sidebar",
        symbol: "sidebar.right",
        script: "obsidianRightSidebar"
    )

    static func toggleObsidianSidebar(_ side: ObsidianSidebar) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "md.obsidian").first else {
            return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef as! AXUIElement? else {
            return
        }
        let targetTitle = (side == .left) ? "Left Sidebar" : "Right Sidebar"

        func findAndPress(_ el: AXUIElement) -> Bool {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, t == targetTitle {
                return AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for c in children {
                    if findAndPress(c) { return true }
                }
            }
            return false
        }

        if !findAndPress(bar) {
            let script = "tell application \"System Events\" to tell process \"Obsidian\" to click menu item \"\(targetTitle)\" of menu \"View\" of menu bar 1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            try? process.run()
        }
    }

    // MARK: - SP8CE YouTube

    private static let sp8ceYouTube = AppShortcut(
        keyCode: 0,
        modifiers: 0,
        char: "YOUTUBE",
        title: "YouTube",
        symbol: "youtube",
        script: "sp8ceYouTube"
    )

    static func openYouTubeInSp8ce() {
        guard let url = URL(string: "https://www.youtube.com") else { return }
        if let sp8ce = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kite.Kite").first,
           let bundleURL = sp8ce.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: config)
        } else if let sp8ceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kite.Kite") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: sp8ceURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Apps whose keys are set outright rather than ranked: Music gets its
    /// player's switches (shown filled while on) and its own shortcuts.
    static func fixedRow(for bundle: String) -> [Int: EdgeKeyAction]? {
        switch bundle {
        case "com.apple.Music":
            return [
                3: .control(.shuffle),
                4: .control(.repeatMode),
                5: .control(.favorite),
                6: .control(.lyrics),
                7: .control(.queue),
                8: .shortcut(shortcut("F", 3, .command, "Search", "magnifyingglass")),
                9: .shortcut(shortcut("L", 37, .command, "Current Song", "music.note")),
            ]
        default:
            return nil
        }
    }

    static func presets(for bundle: String) -> [AppShortcut] {
        if bundle == "com.kite.Kite" {
            return [
                shortcut("S", 1, .command, "Sidebar", "sidebar.left"),
                shortcut("[", 33, [.command, .shift], "Previous Tab", "chevron.up"),
                shortcut("]", 30, [.command, .shift], "Next Tab", "chevron.down"),
                shortcut("T", 17, .command, "New Tab", "plus.square.on.square"),
                sp8ceYouTube,
                shortcut("R", 15, .command, "Reload", "arrow.clockwise"),
                shortcut("[", 33, .command, "Back", "chevron.left"),
            ]
        }
        if bundle == "company.thebrowser.dia" {
            return [
                diaSidebar,
                shortcut("[", 33, .command, "Back", "chevron.left"),
                shortcut("]", 30, .command, "Forward", "chevron.right"),
                shortcut("R", 15, .command, "Reload", "arrow.clockwise"),
                // Dia's address bar is its search bar: toggles between ⌘L (show) and Esc (hide).
                diaSearch,
                shortcut("T", 17, .command, "New Tab", "plus.square.on.square"),
                shortcut("W", 13, .command, "Close Tab", "xmark.square"),
            ]
        }
        if browsers.contains(bundle) {
            return [
                shortcut("[", 33, .command, "Back", "chevron.left"),
                shortcut("]", 30, .command, "Forward", "chevron.right"),
                shortcut("R", 15, .command, "Reload", "arrow.clockwise"),
                shortcut("T", 17, .command, "New Tab", "plus.square.on.square"),
                shortcut("W", 13, .command, "Close Tab", "xmark.square"),
                shortcut("T", 17, [.command, .shift], "Reopen Tab", "arrow.uturn.backward.square"),
                shortcut("L", 37, .command, "Address", "link"),
                shortcut("F", 3, .command, "Find", "magnifyingglass"),
            ]
        }
        switch bundle {
        case "com.apple.finder":
            return [
                shortcut("[", 33, .command, "Back", "chevron.left"),
                shortcut("]", 30, .command, "Forward", "chevron.right"),
                shortcut("N", 45, .command, "New Window", "macwindow.badge.plus"),
                shortcut("N", 45, [.command, .shift], "New Folder", "folder.badge.plus"),
                shortcut("I", 34, .command, "Get Info", "info.circle"),
                shortcut("Y", 16, .command, "Quick Look", "eye"),
                shortcut("F", 3, .command, "Find", "magnifyingglass"),
            ]
        case "com.apple.dt.Xcode":
            return [
                shortcut("R", 15, .command, "Run", "play.fill"),
                shortcut(".", 47, .command, "Stop", "stop.fill"),
                shortcut("B", 11, .command, "Build", "hammer.fill"),
                shortcut("O", 31, [.command, .shift], "Open Quickly", "magnifyingglass"),
                shortcut("0", 29, .command, "Navigator", "sidebar.left"),
                shortcut("K", 40, [.command, .shift], "Clean", "trash"),
            ]
        case "com.anthropic.claudefordesktop":
            return [
                shortcut("B", 11, .command, "Sidebar", "sidebar.left"),
                shortcut("[", 33, [.command, .shift], "Previous Session", "chevron.up"),
                shortcut("]", 30, [.command, .shift], "Next Session", "chevron.down"),
                shortcut("N", 45, .command, "New Session", "square.and.pencil"),
                shortcut("K", 40, .command, "Command Palette", "command"),
                shortcut(";", 41, .command, "Side Chat", "bubble.left.and.bubble.right"),
                shortcut("J", 38, .command, "Terminal", "terminal"),
            ]
        case "com.openai.codex", "com.openai.chat":
            return [
                shortcut("B", 11, .command, "Sidebar", "sidebar.left"),
                shortcut("[", 33, [.command, .shift], "Previous Chat", "chevron.up"),
                shortcut("]", 30, [.command, .shift], "Next Chat", "chevron.down"),
                shortcut("N", 45, .command, "New Chat", "square.and.pencil"),
                shortcut("N", 45, [.command, .shift], "Temporary Chat", "eye.slash"),
                shortcut("F", 3, .command, "Find", "magnifyingglass"),
                shortcut("J", 38, .command, "Bottom Panel", "rectangle.bottomthird.inset.filled"),
            ]
        case "com.google.antigravity", "com.google.antigravity.ide":
            return [
                shortcut("B", 11, .command, "Sidebar", "sidebar.left"),
                shortcut("[", 33, [.command, .shift], "Previous Tab", "chevron.up"),
                shortcut("]", 30, [.command, .shift], "Next Tab", "chevron.down"),
                shortcut("N", 45, [.command, .shift], "New Window", "macwindow.badge.plus"),
                shortcut("K", 40, .command, "Command Palette", "command"),
                shortcut("R", 15, .command, "Reload", "arrow.clockwise"),
                shortcut("W", 13, .command, "Close", "xmark.square"),
            ]
        case "com.apple.Terminal", "com.googlecode.iterm2":
            return [
                shortcut("T", 17, .command, "New Tab", "plus.square.on.square"),
                shortcut("N", 45, .command, "New Window", "macwindow.badge.plus"),
                shortcut("K", 40, .command, "Clear", "clear"),
                shortcut("W", 13, .command, "Close", "xmark.square"),
            ]
        case "com.bambulab.bambu-studio", "com.softfever3d.orca-slicer":
            return [
                bambuPrepare,
                bambuPreview,
                bambuDevice,
                bambuProject,
                shortcut("R", 15, .command, "Slice", "slider.horizontal.3"),
                shortcut("G", 5, [.command, .shift], "Print", "printer.fill"),
                shortcut("S", 1, .command, "Save Project", "square.and.arrow.down"),
            ]
        case "md.obsidian":
            return [
                obsidianLeftSidebar,
                obsidianRightSidebar,
                shortcut("O", 31, .command, "Quick Open", "magnifyingglass"),
                shortcut("P", 35, .command, "Command Palette", "command"),
                shortcut("N", 45, .command, "New Note", "square.and.pencil"),
                shortcut("E", 14, .command, "Reading View", "book"),
                shortcut("F", 3, .command, "Find", "magnifyingglass"),
            ]
        default:
            return []
        }
    }

    /// A symbol for a learned shortcut, from words in its menu title; nil
    /// shows the title itself.
    static func symbol(forTitle title: String) -> String? {
        let t = title.lowercased()
        let table: [(String, String)] = [
            ("new tab", "plus.square.on.square"), ("new window", "macwindow.badge.plus"),
            ("new folder", "folder.badge.plus"), ("new chat", "square.and.pencil"),
            ("new conversation", "square.and.pencil"), ("new", "plus"),
            ("reload", "arrow.clockwise"), ("refresh", "arrow.clockwise"),
            ("back", "chevron.left"), ("forward", "chevron.right"),
            ("find", "magnifyingglass"), ("search", "magnifyingglass"),
            ("close", "xmark.square"), ("print", "printer"),
            ("right sidebar", "sidebar.right"), ("left sidebar", "sidebar.left"), ("sidebar", "sidebar.left"),
            ("youtube", "play.rectangle.fill"),
            ("slice", "slider.horizontal.3"), ("prepare", "cube"),
            ("preview", "square.3.layers.3d"), ("device", "printer.dotmatrix"),
            ("save project", "square.and.arrow.down"),
            ("zoom in", "plus.magnifyingglass"), ("zoom out", "minus.magnifyingglass"),
            ("actual size", "1.magnifyingglass"), ("bookmark", "bookmark"), ("history", "clock"),
            ("download", "arrow.down.circle"), ("share", "square.and.arrow.up"),
            ("duplicate", "plus.square.on.square"), ("info", "info.circle"), ("preferences", "gearshape"),
            ("settings", "gearshape"), ("full screen", "arrow.up.left.and.arrow.down.right"),
            ("bold", "bold"), ("italic", "italic"), ("underline", "underline"),
            ("comment", "text.bubble"), ("run", "play.fill"), ("build", "hammer.fill"),
            ("open", "folder"), ("export", "square.and.arrow.up"),
        ]
        return table.first { t.contains($0.0) }?.1
    }
}

// MARK: - AI usage

/// How much of an AI app's usage limit is gone, read from what the app itself
/// keeps on disk — no sign-in, nothing sent anywhere.
///
/// ChatGPT's Codex records its limits in each session log
/// (~/.codex/sessions/…/rollout-*.jsonl): the 5-hour window's and the week's
/// used percent. Claude keeps nothing like it locally, so it has no key yet.
enum AIUsage {
    struct Limits {
        let session: Double     // the 5-hour window, used percent
        let week: Double
        let sessionResets: Date?
    }

    static func source(for bundle: String) -> String? {
        bundle == "com.openai.codex" && codex() != nil ? "codex" : nil
    }

    private static var cached: (at: CFTimeInterval, limits: Limits?)?

    /// The latest limits in the newest Codex session log; re-read at most
    /// every 30 s.
    static func codex() -> Limits? {
        let now = CACurrentMediaTime()
        if let cached, now - cached.at < 30 { return cached.limits }
        let limits = readCodex()
        cached = (now, limits)
        return limits
    }

    private static func readCodex() -> Limits? {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        // Newest year / month / day folder, then its newest log.
        func newest(_ url: URL) -> URL? {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .max { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da < db
                }
        }
        guard let year = newest(root), let month = newest(year), let day = newest(month),
              let file = newest(day), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // The last 256 KB is plenty to hold the latest record.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = find("rate_limits", in: json) as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? Double else { continue }
            let week = (limits["secondary"] as? [String: Any])?["used_percent"] as? Double ?? 0
            let resets = (primary["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return Limits(session: used, week: week, sessionResets: resets)
        }
        return nil
    }

    private static func find(_ key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key] { return value }
            for value in dict.values { if let found = find(key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key, in: value) { return found } }
        }
        return nil
    }

    /// A ring filled to the 5-hour window's use, with the percent beside it.
    static func glyph(source: String, height: CGFloat, color: NSColor) -> NSImage? {
        guard source == "codex", let limits = codex() else { return nil }
        let used = max(0, min(100, limits.session))
        let text = NSAttributedString(string: "\(Int(used.rounded()))%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(8, height * 0.62), weight: .semibold),
            .foregroundColor: color,
        ])
        let ring = height * 0.9
        let textSize = text.size()
        let width = ceil(ring + 4 + textSize.width)
        return NSImage(size: CGSize(width: width, height: height), flipped: false) { _ in
            let rect = CGRect(x: 1, y: (height - ring) / 2 + 0.5, width: ring - 2, height: ring - 2)
            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = 2
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            arc.appendArc(withCenter: center, radius: rect.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * used / 100, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            (used >= 90 ? NSColor.systemRed : color).setStroke()
            arc.stroke()
            text.draw(at: CGPoint(x: ring + 4, y: (height - textSize.height) / 2))
            return true
        }
    }
}
