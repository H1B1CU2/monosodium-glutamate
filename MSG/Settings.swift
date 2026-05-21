import AppKit

// MARK: - Enums

enum StackMode: String, CaseIterable {
    case inline  = "Inline"
    case stack   = "Stack"
    case dynamic = "Dynamic"
}

enum AnimationStyle: String, CaseIterable {
    case liquid = "Liquid"
    case solid  = "Solid"
}

enum DisplayOrderMode: String, CaseIterable {
    case physicalDetection = "Physical Display Detection"
    case prioritizeMain    = "Prioritize Main Display"
}

enum FocusDetectionMode: String, CaseIterable {
    case off     = "Off"
    case click   = "Click Detection"
    case dynamic = "Pointer Position Detection"
}

enum MusicDisplayMode: String, CaseIterable {
    case dynamic = "Dynamic"
    case `static` = "Static"
    case off     = "Off"
}

enum MusicSource: String, CaseIterable {
    case nowPlaying = "System Now Playing"
    case appleMusic = "Apple Music"

    var isAvailable: Bool {
        switch self {
        case .nowPlaying: return false
        case .appleMusic: return true
        }
    }

    var displayLabel: String {
        isAvailable ? rawValue : "\(rawValue) (unavailable)"
    }
}

// MARK: - Fake Display

struct FakeDisplay: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Fake Display"
    var spaceCount: Int = 3
    var arrangeX: CGFloat = 0
    var arrangeY: CGFloat = 0
}

// MARK: - Settings

/// Centralized persistent settings. All values flush to UserDefaults on change.
/// Subscribe to `onChange` to react. The `category` argument tells subscribers
/// which subsystem(s) need to refresh.
final class AppSettings {

    enum Category {
        case corners        // overlay redraw
        case indicator      // status bar render
        case structural     // rebuild windows/menus
    }

    private enum Key {
        static let cornerRadius             = "cornerRadius"
        static let topCornersEnabled        = "topCornersEnabled"
        static let bottomCornersEnabled     = "bottomCornersEnabled"
        static let topCornersUnderMenuBar   = "topCornersUnderMenuBar"
        static let extCornerRadius          = "extCornerRadius"
        static let extTopCornersEnabled     = "extTopCornersEnabled"
        static let extBottomCornersEnabled  = "extBottomCornersEnabled"
        static let extTopCornersUnderMenuBar = "extTopCornersUnderMenuBar"
        static let mirrorMainDisplay        = "mirrorMainDisplay"
        static let externalMonitorCorners   = "externalMonitorCorners"
        static let stackMode                = "stackMode"
        static let animationStyle           = "animationStyle"
        static let displayOrderMode         = "displayOrderMode"
        static let focusDetectionMode       = "focusDetectionMode"
        static let displayOrder             = "displayOrder"
        static let musicDisplayMode          = "musicDisplayMode"
        static let musicLingerDuration      = "musicLingerDuration"
        static let musicSource               = "musicSource"
        static let spacerEnabled            = "spacerEnabled"
        static let cornersEnabled           = "cornersEnabled"
        static let musicEnabled             = "musicEnabled"
        static let menuBarVisible           = "menuBarVisible"
        static let dockIcon                 = "dockIcon"
        static let autoUpdate               = "autoUpdate"
        static let updateChannel            = "updateChannel"
        static let fakeDisplays             = "fakeDisplays"
    }

    static let shared = AppSettings()

    var onChange: ((Category) -> Void)?
    var onUIChange: (() -> Void)?

    // MARK: Corners
    var cornerRadius: CGFloat {
        didSet { save(); if mirrorMainDisplay { extCornerRadius = cornerRadius }; onChange?(.corners) }
    }
    var topCornersEnabled: Bool {
        didSet { save(); if mirrorMainDisplay { extTopCornersEnabled = topCornersEnabled }; onChange?(.corners) }
    }
    var bottomCornersEnabled: Bool {
        didSet { save(); if mirrorMainDisplay { extBottomCornersEnabled = bottomCornersEnabled }; onChange?(.corners) }
    }
    var topCornersUnderMenuBar: Bool {
        didSet { save(); if mirrorMainDisplay { extTopCornersUnderMenuBar = topCornersUnderMenuBar }; onChange?(.corners) }
    }

    // MARK: External corners (per-display via UUID)

    private func extKey(_ base: String, uuid: String) -> String { "\(base)_\(uuid)" }

    func extCornerRadius(for uuid: String) -> CGFloat {
        if mirrorMainDisplay { return cornerRadius }
        return CGFloat(UserDefaults.standard.float(forKey: extKey(Key.extCornerRadius, uuid: uuid)))
    }
    func setExtCornerRadius(_ v: CGFloat, for uuid: String) {
        UserDefaults.standard.set(Float(v), forKey: extKey(Key.extCornerRadius, uuid: uuid))
        onChange?(.corners)
    }
    func extTopCornersEnabled(for uuid: String) -> Bool {
        if mirrorMainDisplay { return topCornersEnabled }
        return UserDefaults.standard.object(forKey: extKey(Key.extTopCornersEnabled, uuid: uuid)) as? Bool ?? true
    }
    func setExtTopCornersEnabled(_ v: Bool, for uuid: String) {
        UserDefaults.standard.set(v, forKey: extKey(Key.extTopCornersEnabled, uuid: uuid))
        onChange?(.corners)
    }
    func extBottomCornersEnabled(for uuid: String) -> Bool {
        if mirrorMainDisplay { return bottomCornersEnabled }
        return UserDefaults.standard.object(forKey: extKey(Key.extBottomCornersEnabled, uuid: uuid)) as? Bool ?? true
    }
    func setExtBottomCornersEnabled(_ v: Bool, for uuid: String) {
        UserDefaults.standard.set(v, forKey: extKey(Key.extBottomCornersEnabled, uuid: uuid))
        onChange?(.corners)
    }
    func extTopCornersUnderMenuBar(for uuid: String) -> Bool {
        if mirrorMainDisplay { return topCornersUnderMenuBar }
        return UserDefaults.standard.bool(forKey: extKey(Key.extTopCornersUnderMenuBar, uuid: uuid))
    }
    func setExtTopCornersUnderMenuBar(_ v: Bool, for uuid: String) {
        UserDefaults.standard.set(v, forKey: extKey(Key.extTopCornersUnderMenuBar, uuid: uuid))
        onChange?(.corners)
    }

    // Stored fallbacks for code that doesn't use UUIDs
    var extCornerRadius: CGFloat = 10       { didSet { save(); onChange?(.corners) } }
    var extTopCornersEnabled: Bool = true   { didSet { save(); onChange?(.corners) } }
    var extBottomCornersEnabled: Bool = true { didSet { save(); onChange?(.corners) } }
    var extTopCornersUnderMenuBar: Bool = false { didSet { save(); onChange?(.corners) } }

    var mirrorMainDisplay: Bool {
        didSet {
            save()
            if mirrorMainDisplay {
                extCornerRadius = cornerRadius
                extTopCornersEnabled = topCornersEnabled
                extBottomCornersEnabled = bottomCornersEnabled
                extTopCornersUnderMenuBar = topCornersUnderMenuBar
            }
            onChange?(.structural)
        }
    }
    var externalMonitorCorners: Bool { didSet { save(); onChange?(.structural) } }

    // MARK: Indicator
    var stackMode: StackMode            { didSet { save(); onChange?(.indicator) } }
    var animationStyle: AnimationStyle  { didSet { save() } }
    var displayOrderMode: DisplayOrderMode { didSet { save(); onChange?(.indicator) } }
    var focusDetectionMode: FocusDetectionMode { didSet { save(); onChange?(.indicator) } }
    var displayOrder: [Int]             { didSet { save(); onChange?(.indicator) } }
    var musicDisplayMode: MusicDisplayMode { didSet { save(); onChange?(.indicator) } }
    var musicLingerDuration: TimeInterval { didSet { save() } }
    var musicSource: MusicSource { didSet { save(); onChange?(.indicator) } }
    var spacerEnabled: Bool   { didSet { save(); onChange?(.indicator) } }
    var cornersEnabled: Bool  { didSet { save(); onChange?(.structural) } }
    var musicEnabled: Bool    { didSet { save(); onChange?(.indicator) } }
    var menuBarVisible: Bool { didSet { save(); onChange?(.structural) } }
    var dockIcon: Bool       { didSet { save(); onChange?(.structural) } }
    var autoUpdate: Bool     { didSet { save() } }
    var updateChannel: String { didSet { save() } }
    var fakeDisplays: [FakeDisplay] { didSet { save(); onChange?(.structural) } }

    var effectiveDisplayCount: Int { NSScreen.screens.count + fakeDisplays.count }

    // MARK: Init

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.cornerRadius:           CGFloat(10),
            Key.topCornersEnabled:      true,
            Key.bottomCornersEnabled:   true,
            Key.topCornersUnderMenuBar: false,
            Key.extCornerRadius:        CGFloat(10),
            Key.extTopCornersEnabled:    true,
            Key.extBottomCornersEnabled: true,
            Key.extTopCornersUnderMenuBar: false,
            Key.mirrorMainDisplay:      false,
            Key.externalMonitorCorners: false,
            Key.stackMode:              StackMode.stack.rawValue,
            Key.animationStyle:         AnimationStyle.liquid.rawValue,
            Key.displayOrderMode:       DisplayOrderMode.prioritizeMain.rawValue,
            Key.focusDetectionMode:     FocusDetectionMode.click.rawValue,
            Key.displayOrder:           [Int](),
            Key.musicDisplayMode:       MusicDisplayMode.dynamic.rawValue,
            Key.musicLingerDuration:    TimeInterval(15),
            Key.musicSource:            MusicSource.nowPlaying.rawValue,
            Key.spacerEnabled:          true,
            Key.cornersEnabled:         true,
            Key.musicEnabled:           true,
            Key.menuBarVisible:         true,
            Key.dockIcon:               false,
            Key.autoUpdate:             true,
            Key.updateChannel:          "stable",
            Key.fakeDisplays:            Data(),
        ])

        cornerRadius             = CGFloat(d.float(forKey: Key.cornerRadius))
        topCornersEnabled        = d.bool(forKey: Key.topCornersEnabled)
        bottomCornersEnabled     = d.bool(forKey: Key.bottomCornersEnabled)
        topCornersUnderMenuBar   = d.bool(forKey: Key.topCornersUnderMenuBar)
        extCornerRadius          = CGFloat(d.float(forKey: Key.extCornerRadius))
        extTopCornersEnabled     = d.bool(forKey: Key.extTopCornersEnabled)
        extBottomCornersEnabled  = d.bool(forKey: Key.extBottomCornersEnabled)
        extTopCornersUnderMenuBar = d.bool(forKey: Key.extTopCornersUnderMenuBar)
        mirrorMainDisplay        = d.bool(forKey: Key.mirrorMainDisplay)
        externalMonitorCorners   = d.bool(forKey: Key.externalMonitorCorners)

        stackMode         = StackMode(rawValue: d.string(forKey: Key.stackMode) ?? "") ?? .stack
        animationStyle    = AnimationStyle(rawValue: d.string(forKey: Key.animationStyle) ?? "") ?? .liquid
        displayOrderMode  = DisplayOrderMode(rawValue: d.string(forKey: Key.displayOrderMode) ?? "") ?? .prioritizeMain
        focusDetectionMode = FocusDetectionMode(rawValue: d.string(forKey: Key.focusDetectionMode) ?? "") ?? .click
        displayOrder      = (d.array(forKey: Key.displayOrder) as? [Int]) ?? []
        musicDisplayMode     = MusicDisplayMode(rawValue: d.string(forKey: Key.musicDisplayMode) ?? "") ?? .dynamic
        musicLingerDuration  = d.double(forKey: Key.musicLingerDuration)
        musicSource          = MusicSource(rawValue: d.string(forKey: Key.musicSource) ?? "") ?? .nowPlaying
        spacerEnabled        = d.object(forKey: Key.spacerEnabled) as? Bool ?? true
        cornersEnabled       = d.object(forKey: Key.cornersEnabled) as? Bool ?? true
        musicEnabled         = d.object(forKey: Key.musicEnabled) as? Bool ?? true
        menuBarVisible       = d.object(forKey: Key.menuBarVisible) as? Bool ?? true
        dockIcon             = d.bool(forKey: Key.dockIcon)
        autoUpdate           = d.object(forKey: Key.autoUpdate) as? Bool ?? true
        updateChannel        = d.string(forKey: Key.updateChannel) ?? "stable"
        if let data = d.data(forKey: Key.fakeDisplays),
           let decoded = try? JSONDecoder().decode([FakeDisplay].self, from: data) {
            fakeDisplays = decoded
        } else { fakeDisplays = [] }
    }

    private func save() {
        onUIChange?()
        let d = UserDefaults.standard
        d.set(Float(cornerRadius),          forKey: Key.cornerRadius)
        d.set(topCornersEnabled,            forKey: Key.topCornersEnabled)
        d.set(bottomCornersEnabled,         forKey: Key.bottomCornersEnabled)
        d.set(topCornersUnderMenuBar,       forKey: Key.topCornersUnderMenuBar)
        d.set(Float(extCornerRadius),       forKey: Key.extCornerRadius)
        d.set(extTopCornersEnabled,         forKey: Key.extTopCornersEnabled)
        d.set(extBottomCornersEnabled,      forKey: Key.extBottomCornersEnabled)
        d.set(extTopCornersUnderMenuBar,    forKey: Key.extTopCornersUnderMenuBar)
        d.set(mirrorMainDisplay,            forKey: Key.mirrorMainDisplay)
        d.set(externalMonitorCorners,       forKey: Key.externalMonitorCorners)
        d.set(stackMode.rawValue,           forKey: Key.stackMode)
        d.set(animationStyle.rawValue,      forKey: Key.animationStyle)
        d.set(displayOrderMode.rawValue,    forKey: Key.displayOrderMode)
        d.set(focusDetectionMode.rawValue,  forKey: Key.focusDetectionMode)
        d.set(displayOrder,                 forKey: Key.displayOrder)
        d.set(musicDisplayMode.rawValue,    forKey: Key.musicDisplayMode)
        d.set(musicLingerDuration,          forKey: Key.musicLingerDuration)
        d.set(musicSource.rawValue,         forKey: Key.musicSource)
        d.set(spacerEnabled,                forKey: Key.spacerEnabled)
        d.set(cornersEnabled,               forKey: Key.cornersEnabled)
        d.set(musicEnabled,                 forKey: Key.musicEnabled)
        d.set(menuBarVisible,               forKey: Key.menuBarVisible)
        d.set(dockIcon,                     forKey: Key.dockIcon)
        d.set(autoUpdate,                   forKey: Key.autoUpdate)
        d.set(updateChannel,                forKey: Key.updateChannel)
        if let data = try? JSONEncoder().encode(fakeDisplays) { d.set(data, forKey: Key.fakeDisplays) }
    }
}
