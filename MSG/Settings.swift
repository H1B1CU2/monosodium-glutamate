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

    var isAvailable: Bool { true }

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
        static let brightFocusAlpha         = "brightFocusAlpha"
        static let dimFocusAlpha            = "dimFocusAlpha"
        static let brightNonFocusAlpha      = "brightNonFocusAlpha"
        static let dimNonFocusAlpha         = "dimNonFocusAlpha"
        static let trayEnabled              = "trayEnabled"
        static let trayDockSync             = "trayDockSync"
        static let trayShowNowPlaying       = "trayShowNowPlaying"
        static let dockPreviewEnabled       = "dockPreviewEnabled"
        static let dockPreviewHoverDelay    = "dockPreviewHoverDelay"
        static let dockPreviewThumbHeight   = "dockPreviewThumbHeight"
        static let dockPreviewOffset        = "dockPreviewOffset"
        static let displaplacerPresets      = "displaplacerPresets"
        static let displaplacerEnabled      = "displaplacerEnabled"
        static let menuBarSpacing           = "menuBarSpacing"
        static let menuBarSpacingPadding    = "menuBarSpacingPadding"
        static let showDeveloper            = "showDeveloper"
        static let hardwareStatsEnabled        = "hardwareStatsEnabled"
        static let hardwareStatsShowCPU        = "hardwareStatsShowCPU"
        static let hardwareStatsShowGPU        = "hardwareStatsShowGPU"
        static let hardwareStatsShowMemory     = "hardwareStatsShowMemory"
        static let hardwareStatsShowTemp       = "hardwareStatsShowTemp"
        static let hardwareStatsShowFPS        = "hardwareStatsShowFPS"
        static let hardwareStatsShowFan         = "hardwareStatsShowFan"
        static let hardwareStatsFanPreset      = "hardwareStatsFanPreset"
        static let hardwareStatsFanCurves      = "hardwareStatsFanCurves"
        static let hardwareStatsBarStyle       = "hardwareStatsBarStyle"
        static let hardwareStatsLabelPos       = "hardwareStatsLabelPos"
        static let hardwareStatsInterval       = "hardwareStatsInterval"
        static let hardwareStatsTempSensor     = "hardwareStatsTempSensor"
        static let hardwareStatsMemMode        = "hardwareStatsMemMode"
        static let hardwareStatsTempMin        = "hardwareStatsTempMin"
        static let hardwareStatsTempMax        = "hardwareStatsTempMax"
        static let systemHUDEnabled            = "systemHUDEnabled"
        static let systemHUDVolume             = "systemHUDVolume"
        static let systemHUDBrightness         = "systemHUDBrightness"
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
    var brightFocusAlpha: CGFloat    { didSet { save(); onChange?(.indicator) } }
    var dimFocusAlpha: CGFloat       { didSet { save(); onChange?(.indicator) } }
    var brightNonFocusAlpha: CGFloat { didSet { save(); onChange?(.indicator) } }
    var dimNonFocusAlpha: CGFloat    { didSet { save(); onChange?(.indicator) } }
    var trayEnabled: Bool            { didSet { save(); onChange?(.structural) } }
    var trayDockSync: Bool           { didSet { save() } }
    var trayShowNowPlaying: Bool     { didSet { save() } }
    var dockPreviewEnabled: Bool     { didSet { save() } }
    var dockPreviewHoverDelay: TimeInterval { didSet { save() } }
    var dockPreviewThumbHeight: CGFloat { didSet { save() } }
    var dockPreviewOffset: CGFloat   { didSet { save() } }
    var displaplacerEnabled: Bool { didSet { save(); onChange?(.structural) } }
    var displaplacerPresets: [DisplaplacerPreset] { didSet { save() } }
    var menuBarSpacing: Int        { didSet { save() } }
    var menuBarSpacingPadding: Int { didSet { save() } }
    var showDeveloper: Bool        { didSet { save() } }
    var hardwareStatsEnabled: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowCPU: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowGPU: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowMemory: Bool      { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowTemp: Bool        { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowFPS: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowFan: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsBarStyle: String      { didSet { save(); onChange?(.structural) } }
    var hardwareStatsLabelPos: String      { didSet { save(); onChange?(.structural) } }
    var hardwareStatsInterval: Double      { didSet { save() } }
    var hardwareStatsTempSensor: String    { didSet { save(); onChange?(.structural) } }
    var hardwareStatsMemMode: String       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsFanPreset: String    { didSet { save(); onChange?(.structural) } }
    var hardwareStatsFanCurves: [String: [[Double]]] { didSet { save(); onChange?(.structural) } }
    var hardwareStatsTempMin: Double       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsTempMax: Double       { didSet { save(); onChange?(.structural) } }

    // System HUD (replace native volume/brightness OSD)
    var systemHUDEnabled: Bool    { didSet { save(); onChange?(.structural) } }
    var systemHUDVolume: Bool     { didSet { save() } }
    var systemHUDBrightness: Bool { didSet { save() } }

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
            Key.brightFocusAlpha:        CGFloat(1.0),
            Key.dimFocusAlpha:           CGFloat(0.55),
            Key.brightNonFocusAlpha:     CGFloat(0.55),
            Key.dimNonFocusAlpha:        CGFloat(0.55),
            Key.trayEnabled:             true,
            Key.trayDockSync:            true,
            Key.trayShowNowPlaying:      true,
            Key.dockPreviewEnabled:      true,
            Key.dockPreviewHoverDelay:   TimeInterval(0.35),
            Key.dockPreviewThumbHeight:  CGFloat(140),
            Key.dockPreviewOffset:       CGFloat(0),
            Key.displaplacerEnabled:     true,
            Key.displaplacerPresets:     Data(),
            Key.menuBarSpacing:          MenuBarSpacingManager.systemDefault,
            Key.menuBarSpacingPadding:   MenuBarSpacingManager.systemDefault,
            Key.showDeveloper:           false,
            Key.hardwareStatsEnabled:       false,
            Key.hardwareStatsShowCPU:       true,
            Key.hardwareStatsShowGPU:       true,
            Key.hardwareStatsShowMemory:    true,
            Key.hardwareStatsShowTemp:      true,
            Key.hardwareStatsShowFPS:       false,
            Key.hardwareStatsShowFan:       false,
            Key.hardwareStatsBarStyle:      "vertical",
            Key.hardwareStatsLabelPos:      "vertical",
            Key.hardwareStatsInterval:      2.0,
            Key.hardwareStatsTempSensor:    "auto",
            Key.hardwareStatsMemMode:       "pressure",
            Key.hardwareStatsFanPreset:    "default",
            Key.hardwareStatsFanCurves:    [
                "silent":      [[30.0, 15.0], [50.0, 25.0], [65.0, 40.0], [80.0, 60.0], [95.0, 80.0]],
                "performance": [[30.0, 30.0], [50.0, 50.0], [65.0, 70.0], [80.0, 85.0], [95.0, 100.0]],
                "fullBlast":   [[0.0, 100.0], [100.0, 100.0]],
            ],
            Key.hardwareStatsTempMin:      30.0,
            Key.hardwareStatsTempMax:      100.0,
            Key.systemHUDEnabled:        false,
            Key.systemHUDVolume:         true,
            Key.systemHUDBrightness:     true,
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
        brightFocusAlpha     = CGFloat(d.float(forKey: Key.brightFocusAlpha))
        dimFocusAlpha        = CGFloat(d.float(forKey: Key.dimFocusAlpha))
        brightNonFocusAlpha  = CGFloat(d.float(forKey: Key.brightNonFocusAlpha))
        dimNonFocusAlpha     = CGFloat(d.float(forKey: Key.dimNonFocusAlpha))
        trayEnabled          = d.bool(forKey: Key.trayEnabled)
        trayDockSync         = d.object(forKey: Key.trayDockSync) as? Bool ?? true
        trayShowNowPlaying   = d.object(forKey: Key.trayShowNowPlaying) as? Bool ?? true
        dockPreviewEnabled   = d.object(forKey: Key.dockPreviewEnabled) as? Bool ?? true
        dockPreviewHoverDelay = d.object(forKey: Key.dockPreviewHoverDelay) as? Double ?? 0.35
        dockPreviewThumbHeight = CGFloat(d.object(forKey: Key.dockPreviewThumbHeight) as? Double ?? 140)
        dockPreviewOffset    = CGFloat(d.object(forKey: Key.dockPreviewOffset) as? Double ?? 0)
        if let data = d.data(forKey: Key.displaplacerPresets),
           let decoded = try? JSONDecoder().decode([DisplaplacerPreset].self, from: data) {
            displaplacerPresets = decoded
        } else { displaplacerPresets = [] }
        displaplacerEnabled  = d.object(forKey: Key.displaplacerEnabled) as? Bool ?? true
        menuBarSpacing        = d.object(forKey: Key.menuBarSpacing) as? Int ?? MenuBarSpacingManager.systemDefault
        menuBarSpacingPadding = d.object(forKey: Key.menuBarSpacingPadding) as? Int ?? MenuBarSpacingManager.systemDefault
        showDeveloper         = d.object(forKey: Key.showDeveloper) as? Bool ?? false
        hardwareStatsEnabled      = d.object(forKey: Key.hardwareStatsEnabled) as? Bool ?? false
        hardwareStatsShowCPU      = d.object(forKey: Key.hardwareStatsShowCPU) as? Bool ?? true
        hardwareStatsShowGPU      = d.object(forKey: Key.hardwareStatsShowGPU) as? Bool ?? true
        hardwareStatsShowMemory   = d.object(forKey: Key.hardwareStatsShowMemory) as? Bool ?? true
        hardwareStatsShowTemp     = d.object(forKey: Key.hardwareStatsShowTemp) as? Bool ?? true
        hardwareStatsShowFPS      = d.object(forKey: Key.hardwareStatsShowFPS) as? Bool ?? false
        hardwareStatsShowFan      = d.object(forKey: Key.hardwareStatsShowFan) as? Bool ?? false
        hardwareStatsBarStyle     = d.string(forKey: Key.hardwareStatsBarStyle) ?? "vertical"
        hardwareStatsLabelPos     = d.string(forKey: Key.hardwareStatsLabelPos) ?? "vertical"
        hardwareStatsInterval     = d.object(forKey: Key.hardwareStatsInterval) as? Double ?? 2.0
        hardwareStatsTempSensor   = d.string(forKey: Key.hardwareStatsTempSensor) ?? "auto"
        hardwareStatsMemMode      = d.string(forKey: Key.hardwareStatsMemMode) ?? "pressure"
        hardwareStatsTempMin      = d.object(forKey: Key.hardwareStatsTempMin) as? Double ?? 30.0
        hardwareStatsTempMax      = d.object(forKey: Key.hardwareStatsTempMax) as? Double ?? 100.0
        hardwareStatsFanPreset    = d.string(forKey: Key.hardwareStatsFanPreset) ?? "default"
        hardwareStatsFanCurves    = (try? JSONDecoder().decode([String: [[Double]]].self,
                                       from: d.data(forKey: Key.hardwareStatsFanCurves) ?? Data()))
                                    ?? [
                                        "silent":      [[30, 15], [50, 25], [65, 40], [80, 60], [95, 80]],
                                        "performance": [[30, 30], [50, 50], [65, 70], [80, 85], [95, 100]],
                                        "fullBlast":   [[0, 100], [100, 100]],
                                    ]
        if let data = d.data(forKey: Key.fakeDisplays),
           let decoded = try? JSONDecoder().decode([FakeDisplay].self, from: data) {
            fakeDisplays = decoded
        } else { fakeDisplays = [] }
        systemHUDEnabled    = d.object(forKey: Key.systemHUDEnabled) as? Bool ?? false
        systemHUDVolume     = d.object(forKey: Key.systemHUDVolume) as? Bool ?? true
        systemHUDBrightness = d.object(forKey: Key.systemHUDBrightness) as? Bool ?? true
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
        d.set(Float(brightFocusAlpha),      forKey: Key.brightFocusAlpha)
        d.set(Float(dimFocusAlpha),         forKey: Key.dimFocusAlpha)
        d.set(Float(brightNonFocusAlpha),   forKey: Key.brightNonFocusAlpha)
        d.set(Float(dimNonFocusAlpha),      forKey: Key.dimNonFocusAlpha)
        d.set(trayEnabled,                  forKey: Key.trayEnabled)
        d.set(trayDockSync,                 forKey: Key.trayDockSync)
        d.set(trayShowNowPlaying,           forKey: Key.trayShowNowPlaying)
        d.set(dockPreviewEnabled,           forKey: Key.dockPreviewEnabled)
        d.set(dockPreviewHoverDelay,        forKey: Key.dockPreviewHoverDelay)
        d.set(Double(dockPreviewThumbHeight), forKey: Key.dockPreviewThumbHeight)
        d.set(Double(dockPreviewOffset),    forKey: Key.dockPreviewOffset)
        d.set(displaplacerEnabled,          forKey: Key.displaplacerEnabled)
        d.set(menuBarSpacing,               forKey: Key.menuBarSpacing)
        d.set(menuBarSpacingPadding,        forKey: Key.menuBarSpacingPadding)
        d.set(showDeveloper,                forKey: Key.showDeveloper)
        d.set(hardwareStatsEnabled,          forKey: Key.hardwareStatsEnabled)
        d.set(hardwareStatsShowCPU,          forKey: Key.hardwareStatsShowCPU)
        d.set(hardwareStatsShowGPU,          forKey: Key.hardwareStatsShowGPU)
        d.set(hardwareStatsShowMemory,       forKey: Key.hardwareStatsShowMemory)
        d.set(hardwareStatsShowTemp,         forKey: Key.hardwareStatsShowTemp)
        d.set(hardwareStatsShowFPS,          forKey: Key.hardwareStatsShowFPS)
        d.set(hardwareStatsShowFan,          forKey: Key.hardwareStatsShowFan)
        d.set(hardwareStatsBarStyle,         forKey: Key.hardwareStatsBarStyle)
        d.set(hardwareStatsLabelPos,         forKey: Key.hardwareStatsLabelPos)
        d.set(hardwareStatsInterval,         forKey: Key.hardwareStatsInterval)
        d.set(hardwareStatsTempSensor,       forKey: Key.hardwareStatsTempSensor)
        d.set(hardwareStatsMemMode,          forKey: Key.hardwareStatsMemMode)
        d.set(hardwareStatsTempMin,          forKey: Key.hardwareStatsTempMin)
        d.set(hardwareStatsTempMax,          forKey: Key.hardwareStatsTempMax)
        d.set(hardwareStatsFanPreset,       forKey: Key.hardwareStatsFanPreset)
        if let data = try? JSONEncoder().encode(hardwareStatsFanCurves) {
            d.set(data, forKey: Key.hardwareStatsFanCurves)
        }
        if let data = try? JSONEncoder().encode(displaplacerPresets) { d.set(data, forKey: Key.displaplacerPresets) }
        if let data = try? JSONEncoder().encode(fakeDisplays) { d.set(data, forKey: Key.fakeDisplays) }
        d.set(systemHUDEnabled,    forKey: Key.systemHUDEnabled)
        d.set(systemHUDVolume,     forKey: Key.systemHUDVolume)
        d.set(systemHUDBrightness, forKey: Key.systemHUDBrightness)
    }
}
