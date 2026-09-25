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

enum TilingControlBarMode: String, CaseIterable {
    case fullWidth = "Full Width"
    case hybridNotch = "Hybrid Notch"
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

enum SystemHUDPresentationMode: String, CaseIterable {
    case dynamic = "Dynamic"
    case separate = "Separate Menu Bar"
}

enum CornerCurve: String, CaseIterable, Codable {
    case g1 = "g1"
    case g2 = "g2"

    var label: String {
        switch self {
        case .g1: return "G1 (Circular)"
        case .g2: return "G2 (Continuous)"
        }
    }
}

enum CornerGeometry {
    static let k0: CGFloat = 1.52866495
    static let k1: CGFloat = 1.08849001
    static let k2: CGFloat = 0.86840701
    static let k3: CGFloat = 0.63149399
    static let k4: CGFloat = 0.07491140
    static let k5: CGFloat = 0.37282401
    static let k6: CGFloat = 0.16906001

    static func reach(for radius: CGFloat, curve: CornerCurve) -> CGFloat {
        curve == .g2 ? radius * k0 : radius
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
        case tiling         // tiling engine and top control bar
        case structural     // rebuild windows/menus
    }

    private enum Key {
        static let cornerRadius             = "cornerRadius"
        static let cornerCurve              = "cornerCurve"
        static let topCornersEnabled        = "topCornersEnabled"
        static let bottomCornersEnabled     = "bottomCornersEnabled"
        static let topCornersUnderMenuBar   = "topCornersUnderMenuBar"
        static let topCornersFullscreenOnly = "topCornersFullscreenOnly"
        static let cornerGrowEnabled        = "cornerGrowEnabled"
        static let lidOpeningGlassEnabled   = "lidOpeningGlassEnabled"
        static let extCornerRadius          = "extCornerRadius"
        static let extCornerCurve           = "extCornerCurve"
        static let extTopCornersEnabled     = "extTopCornersEnabled"
        static let extBottomCornersEnabled  = "extBottomCornersEnabled"
        static let extTopCornersUnderMenuBar = "extTopCornersUnderMenuBar"
        static let extTopCornersFullscreenOnly = "extTopCornersFullscreenOnly"
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
        static let dockPreviewEnabled       = "dockPreviewEnabled"
        static let dockPreviewHoverDelay    = "dockPreviewHoverDelay"
        static let dockPreviewThumbHeight   = "dockPreviewThumbHeight"
        static let dockPreviewOffset        = "dockPreviewOffset"
        static let notchPreviewEnabled      = "notchPreviewEnabled"
        static let notchPreviewHoverDelay   = "notchPreviewHoverDelay"
        static let notchPreviewThumbHeight  = "notchPreviewThumbHeight"
        static let notchPreviewShowOtherSpaces = "notchPreviewShowOtherSpaces"
        static let notchShowDock             = "notchShowDock"
        static let appSwitcherLayout         = "appSwitcherLayout"
        static let appSwitcherShowDock       = "appSwitcherShowDock"
        static let appSwitcherPreviewEnabled = "appSwitcherPreviewEnabled"
        static let appSwitcherPreviewDelay   = "appSwitcherPreviewDelay"
        static let appSwitcherPreviewOffset  = "appSwitcherPreviewOffset"
        static let appSwitcherStartAtCurrent = "appSwitcherStartAtCurrent"
        static let appSwitcherMaxPerRow      = "appSwitcherMaxPerRow"
        static let tilingEnabled              = "tilingEnabled"
        static let tilingShowControlBar       = "tilingShowControlBar"
        static let tilingControlBarMode       = "tilingControlBarMode"
        static let tilingControlBarScope      = "tilingControlBarScope"
        static let tilingPillScope            = "tilingPillScope"
        static let tilingOneAppPerDeskspace   = "tilingOneAppPerDeskspace"
        static let tilingAutoDeleteEmptySpaces = "tilingAutoDeleteEmptySpaces"
        static let tilingPadding              = "tilingPadding"
        static let tilingStablePreviewResize  = "tilingStablePreviewResize"
        static let tilingSwipeDownCyclesTabs  = "tilingSwipeDownCyclesTabs"
        static let tilingSwipeSwitchesSpaces  = "tilingSwipeSwitchesSpaces"
        static let tilingSpaceSwipeFingers    = "tilingSpaceSwipeFingers"
        static let tilingControlBarPreviews   = "tilingControlBarPreviews"
        static let tilingControlBarDuoBatteryWifi = "tilingControlBarDuoBatteryWifi"
        static let tilingMasterRatios         = "tilingMasterRatios"
        static let displaplacerPresets      = "displaplacerPresets"
        static let displaplacerEnabled      = "displaplacerEnabled"
        static let monitorInputAutoEject    = "monitorInputAutoEject"
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
        static let hardwareStatsShowPower       = "hardwareStatsShowPower"
        static let hardwareStatsShowBattery     = "hardwareStatsShowBattery"
        static let hardwareStatsBatterySeparate = "hardwareStatsBatterySeparate"
        static let hardwareStatsFanPreset      = "hardwareStatsFanPreset"
        static let hardwareStatsFanCurves      = "hardwareStatsFanCurves"
        static let hardwareStatsBarStyle       = "hardwareStatsBarStyle"
        static let hardwareStatsLabelPos       = "hardwareStatsLabelPos"
        static let hardwareStatsColorScale     = "hardwareStatsColorScale"
        static let hardwareStatsInterval       = "hardwareStatsInterval"
        static let hardwareStatsTempSensor     = "hardwareStatsTempSensor"
        static let hardwareStatsMemMode        = "hardwareStatsMemMode"
        static let hardwareStatsTempMin        = "hardwareStatsTempMin"
        static let hardwareStatsTempMax        = "hardwareStatsTempMax"
        static let hardwareStatsCPURaw         = "hardwareStatsCPURaw"
        static let hardwareStatsGPURaw         = "hardwareStatsGPURaw"
        static let hardwareStatsMemoryRaw      = "hardwareStatsMemoryRaw"
        static let hardwareStatsTempRaw        = "hardwareStatsTempRaw"
        static let hardwareStatsFanRaw         = "hardwareStatsFanRaw"
        static let hardwareStatsPowerRaw       = "hardwareStatsPowerRaw"
        static let hardwareStatsPowerSamples   = "hardwareStatsPowerSamples"
        static let hardwareStatsBatteryStyle   = "hardwareStatsBatteryStyle"
        static let hardwareStatsModuleOrder    = "hardwareStatsModuleOrder"
        static let hardwareStatsHiddenCards    = "hardwareStatsHiddenCards"
        static let hardwareStatsColumns        = "hardwareStatsColumns"
        static let hardwareStatsCardColumns    = "hardwareStatsCardColumns"
        static let hardwareStatsBatteryCardSpan = "hardwareStatsBatteryCardSpan"
        static let hardwareStatsBatteryCardSide = "hardwareStatsBatteryCardSide"
        static let systemHUDEnabled            = "systemHUDEnabled"
        static let systemHUDVolume             = "systemHUDVolume"
        static let systemHUDBrightness         = "systemHUDBrightness"
        static let systemHUDPresentationMode   = "systemHUDPresentationMode"
        static let systemHUDDeviceIcons        = "systemHUDDeviceIcons"
        static let systemHUDInTilingBar        = "systemHUDInTilingBar"
        static let inputSourceHUDEnabled       = "inputSourceHUDEnabled"
        static let mediaKeyPriorityMusic       = "mediaKeyPriorityMusic"
    }

    static let shared = AppSettings()

    var onChange: ((Category) -> Void)?
    var onUIChange: (() -> Void)?

    // MARK: Corners
    var cornerRadius: CGFloat {
        didSet { save(); if mirrorMainDisplay { extCornerRadius = cornerRadius }; onChange?(.corners) }
    }
    var cornerCurve: CornerCurve {
        didSet { save(); if mirrorMainDisplay { extCornerCurve = cornerCurve }; onChange?(.corners) }
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
    /// Top corners only while the display is showing a fullscreen space — hidden
    /// on the desktop. Driven per display by the CGS space type, not by the
    /// overlay's own geometry (a canJoinAllSpaces window always reads the
    /// desktop's, so it cannot see the fullscreen round trip itself).
    var topCornersFullscreenOnly: Bool {
        didSet { save(); if mirrorMainDisplay { extTopCornersFullscreenOnly = topCornersFullscreenOnly }; onChange?(.corners) }
    }
    /// Grow-in animation for corners (space switch, Mission Control exit).
    /// Behavioral (all displays), so no ext-mirroring.
    var cornerGrowEnabled: Bool {
        didSet { save(); onChange?(.corners) }
    }
    /// Angle-driven full-screen glass shown briefly when a MacBook lid opens.
    var lidOpeningGlassEnabled: Bool {
        didSet { save(); onChange?(.corners) }
    }

    // MARK: External corners (per-display via UUID)

    private func extKey(_ base: String, uuid: String) -> String { "\(base)_\(uuid)" }

    func extCornerRadius(for uuid: String) -> CGFloat {
        if mirrorMainDisplay { return cornerRadius }
        let key = extKey(Key.extCornerRadius, uuid: uuid)
        guard UserDefaults.standard.object(forKey: key) != nil else { return extCornerRadius }
        return CGFloat(UserDefaults.standard.float(forKey: key))
    }
    func setExtCornerRadius(_ v: CGFloat, for uuid: String) {
        UserDefaults.standard.set(Float(v), forKey: extKey(Key.extCornerRadius, uuid: uuid))
        onChange?(.corners)
    }
    func extCornerCurve(for uuid: String) -> CornerCurve {
        if mirrorMainDisplay { return cornerCurve }
        let key = extKey(Key.extCornerCurve, uuid: uuid)
        guard let raw = UserDefaults.standard.string(forKey: key),
              let curve = CornerCurve(rawValue: raw) else { return extCornerCurve }
        return curve
    }
    func setExtCornerCurve(_ v: CornerCurve, for uuid: String) {
        UserDefaults.standard.set(v.rawValue, forKey: extKey(Key.extCornerCurve, uuid: uuid))
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
    func extTopCornersFullscreenOnly(for uuid: String) -> Bool {
        if mirrorMainDisplay { return topCornersFullscreenOnly }
        return UserDefaults.standard.object(forKey: extKey(Key.extTopCornersFullscreenOnly, uuid: uuid)) as? Bool
            ?? extTopCornersFullscreenOnly
    }
    func setExtTopCornersFullscreenOnly(_ v: Bool, for uuid: String) {
        UserDefaults.standard.set(v, forKey: extKey(Key.extTopCornersFullscreenOnly, uuid: uuid))
        onChange?(.corners)
    }

    // Stored fallbacks for code that doesn't use UUIDs
    var extCornerRadius: CGFloat = 10       { didSet { save(); onChange?(.corners) } }
    var extCornerCurve: CornerCurve = .g1   { didSet { save(); onChange?(.corners) } }
    var extTopCornersEnabled: Bool = true   { didSet { save(); onChange?(.corners) } }
    var extBottomCornersEnabled: Bool = true { didSet { save(); onChange?(.corners) } }
    var extTopCornersUnderMenuBar: Bool = false { didSet { save(); onChange?(.corners) } }
    var extTopCornersFullscreenOnly: Bool = true { didSet { save(); onChange?(.corners) } }

    var mirrorMainDisplay: Bool {
        didSet {
            save()
            if mirrorMainDisplay {
                extCornerRadius = cornerRadius
                extCornerCurve = cornerCurve
                extTopCornersEnabled = topCornersEnabled
                extBottomCornersEnabled = bottomCornersEnabled
                extTopCornersUnderMenuBar = topCornersUnderMenuBar
                extTopCornersFullscreenOnly = topCornersFullscreenOnly
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
    var dockPreviewEnabled: Bool     { didSet { save() } }
    var dockPreviewHoverDelay: TimeInterval { didSet { save() } }
    var dockPreviewThumbHeight: CGFloat { didSet { save() } }
    var dockPreviewOffset: CGFloat   { didSet { save() } }
    var notchPreviewEnabled: Bool     { didSet { save() } }
    var notchPreviewHoverDelay: TimeInterval { didSet { save() } }
    var notchPreviewThumbHeight: CGFloat { didSet { save() } }
    var notchPreviewShowOtherSpaces: Bool { didSet { save() } }
    var notchShowDock: Bool { didSet { save() } }
    var appSwitcherMode: String { didSet { save() } }
    var appSwitcherLayout: String { didSet { save() } }
    var appSwitcherShowDock: Bool { didSet { save() } }
    /// How the replacement switcher treats multiple displays:
    /// `"all"` (one list), `"current"` (only the display under the pointer),
    /// `"grouped"` (every window, split into a section per display).
    var appSwitcherDisplayMode: String { didSet { save() } }
    var appSwitcherGroupBySpace: Bool { didSet { save() } }
    var appSwitcherStartAtCurrent: Bool { didSet { save() } }
    var appSwitcherMaxPerRow: Int { didSet { save() } }
    var appSwitcherPreviewEnabled: Bool { didSet { save() } }
    var appSwitcherPreviewDelay: TimeInterval { didSet { save() } }
    var appSwitcherPreviewOffset: CGFloat { didSet { save() } }

    // MARK: Tiling
    var tilingEnabled: Bool { didSet { save(); onChange?(.tiling) } }
    var tilingShowControlBar: Bool { didSet { save(); onChange?(.tiling) } }
    var tilingControlBarMode: TilingControlBarMode { didSet { save(); onChange?(.tiling) } }
    var tilingControlBarScope: TilingControlBarScope { didSet { save(); onChange?(.tiling) } }
    var tilingPillScope: TilingPillScope { didSet { save(); onChange?(.tiling) } }
    var tilingOneAppPerDeskspace: Bool { didSet { save(); onChange?(.tiling) } }
    var tilingAutoDeleteEmptySpaces: Bool { didSet { save(); onChange?(.tiling) } }
    /// One value drives both the outer display inset and inner window gaps.
    var tilingPadding: CGFloat { didSet { save(); onChange?(.tiling) } }
    /// Alternative interaction that previews geometry and commits once on release.
    var tilingStablePreviewResize: Bool { didSet { save(); onChange?(.tiling) } }
    /// A vertical three-finger swipe flips through the tabbed windows: up
    /// forward, down back. Stored under its original key, from when only a
    /// swipe down did anything.
    var tilingSwipeCyclesTabs: Bool { didSet { save(); onChange?(.tiling) } }
    /// A horizontal three-finger swipe opens the deskspace preview HUD and switches spaces.
    var tilingSwipeSwitchesSpaces: Bool { didSet { save(); onChange?(.tiling) } }
    /// Fingers (3 or 4) for the deskspace swipe. Four leaves three free for
    /// macOS's own swipe between spaces.
    var tilingSpaceSwipeFingers: Int { didSet { save(); onChange?(.tiling) } }
    /// Hovering a window icon in the top control bar previews that window,
    /// and the preview can be dragged onto the desktop to move the window here.
    var tilingControlBarPreviews: Bool { didSet { save(); onChange?(.tiling) } }
    /// An iPhone Duo-style merged battery gauge and Wi-Fi icon on the tiling bar.
    var tilingControlBarDuoBatteryWifi: Bool { didSet { save(); onChange?(.tiling) } }

    func tilingMasterRatio(for displayUUID: String) -> CGFloat {
        let stored = UserDefaults.standard.dictionary(forKey: Key.tilingMasterRatios)?[displayUUID] as? NSNumber
        return min(0.8, max(0.2, CGFloat(stored?.doubleValue ?? 0.5)))
    }

    func setTilingMasterRatio(_ ratio: CGFloat, for displayUUID: String) {
        let clamped = min(0.8, max(0.2, ratio))
        var stored = UserDefaults.standard.dictionary(forKey: Key.tilingMasterRatios) ?? [:]
        guard abs(CGFloat((stored[displayUUID] as? NSNumber)?.doubleValue ?? -1) - clamped) >= 0.001 else { return }
        stored[displayUUID] = Double(clamped)
        UserDefaults.standard.set(stored, forKey: Key.tilingMasterRatios)
    }
    // Turning the feature off hides the only UI that can un-eject a display, so
    // restore them first — otherwise a monitor stays dark with no way back to it.
    var displaplacerEnabled: Bool {
        didSet {
            if !displaplacerEnabled && oldValue { DisplaplacerEngine.reconnectAll() }
            save(); onChange?(.structural)
        }
    }
    var displaplacerPresets: [DisplaplacerPreset] { didSet { save() } }
    /// Hand the monitor to another machine on an input switch: eject it from this
    /// Mac's workspace so windows move to the built-in display instead of stranding
    /// on a panel that is now showing something else. Only ever acts when the
    /// monitor's "This Mac" input has been marked — see DisplayInputEngine.
    var monitorInputAutoEject: Bool { didSet { save() } }
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
    var hardwareStatsShowPower: Bool       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsShowBattery: Bool     { didSet { save(); onChange?(.structural) } }
    var hardwareStatsBatterySeparate: Bool { didSet { save(); onChange?(.structural) } }
    var hardwareStatsBarStyle: String      { didSet { save(); onChange?(.structural) } }
    var hardwareStatsLabelPos: String      { didSet { save(); onChange?(.structural) } }
    var hardwareStatsColorScale: String    { didSet { save(); onChange?(.structural) } }
    var hardwareStatsInterval: Double      { didSet { save() } }
    var hardwareStatsTempSensor: String    { didSet { save(); onChange?(.structural) } }
    var hardwareStatsMemMode: String       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsFanPreset: String    { didSet { save(); onChange?(.structural) } }
    var hardwareStatsFanCurves: [String: [[Double]]] { didSet { save(); onChange?(.structural) } }
    var hardwareStatsTempMin: Double       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsTempMax: Double       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsCPURaw: Bool          { didSet { save(); onChange?(.structural) } }
    var hardwareStatsGPURaw: Bool          { didSet { save(); onChange?(.structural) } }
    var hardwareStatsMemoryRaw: Bool       { didSet { save(); onChange?(.structural) } }
    var hardwareStatsTempRaw: Bool         { didSet { save(); onChange?(.structural) } }
    var hardwareStatsFanRaw: Bool          { didSet { save(); onChange?(.structural) } }
    var hardwareStatsPowerRaw: Bool        { didSet { save(); onChange?(.structural) } }
    var hardwareStatsPowerSamples: Int     { didSet { save(); HardwareMonitor.shared.trimPowerHistory(); onChange?(.structural) } }
    /// "bar" | "number" | "icon" (native-style battery glyph)
    var hardwareStatsBatteryStyle: String  { didSet { save(); onChange?(.structural) } }
    /// Canonical module ids in their default order.
    static let hardwareModuleIDs = HardwareCardLayout.modules
    /// Module ids that render as grid cards inside popover columns.
    static let hardwareGridCardIDs = HardwareCardLayout.statistics
    /// Order the modules render in, left→right. Sanitized on load to always
    /// hold exactly the known ids (see `hardwareModuleIDs`).
    var hardwareStatsModuleOrder: [String] { didSet { hardwareLayoutChanged() } }
    /// Module ids whose popover detail card is hidden (empty = all shown).
    var hardwareStatsHiddenCards: [String] { didSet { save(); onChange?(.structural) } }
    /// Number of columns for popover cards (1...3).
    var hardwareStatsColumns: Int          { didSet { save(); onChange?(.structural) } }
    /// Multi-column layout for popover grid cards (1 to 3 columns).
    var hardwareStatsCardColumns: [[String]] { didSet { hardwareLayoutChanged() } }
    /// "2x2" | "full" (card size for battery in popover)
    var hardwareStatsBatteryCardSpan: String { didSet { hardwareLayoutChanged() } }
    /// "left" | "right" (which side battery card is placed when 2x2)
    var hardwareStatsBatteryCardSide: String { didSet { hardwareLayoutChanged() } }

    private var applyingHardwareLayout = false
    private func hardwareLayoutChanged() {
        guard !applyingHardwareLayout else { return }
        save(); onChange?(.structural)
    }
    func applyHardwareLayout(_ layout: HardwareCardLayout) {
        applyingHardwareLayout = true
        hardwareStatsModuleOrder = layout.order
        hardwareStatsCardColumns = layout.columns
        hardwareStatsBatteryCardSpan = layout.batterySpan
        hardwareStatsBatteryCardSide = layout.batterySide
        applyingHardwareLayout = false
        hardwareLayoutChanged()
    }

    // System HUD (replace native volume/brightness OSD)
    var systemHUDEnabled: Bool    { didSet { save(); onChange?(.structural) } }
    var systemHUDVolume: Bool     { didSet { save() } }
    var systemHUDBrightness: Bool { didSet { save() } }
    var systemHUDPresentationMode: SystemHUDPresentationMode { didSet { save(); onChange?(.structural) } }
    var systemHUDDeviceIcons: Bool { didSet { save() } }
    /// Dynamic mode only: while the tiling control bar is showing, the HUD
    /// morphs out of its Space Indicator instead of the menu bar's, which the
    /// bar covers.
    var systemHUDInTilingBar: Bool { didSet { save() } }

    // Keyboard language HUD (space indicator morphs into the input source name)
    var inputSourceHUDEnabled: Bool { didSet { save(); onChange?(.structural) } }

    // Send the hardware play/next/previous keys to Music.app instead of
    // whichever app macOS currently considers the Now Playing app.
    var mediaKeyPriorityMusic: Bool { didSet { save(); onChange?(.structural) } }

    var effectiveDisplayCount: Int { NSScreen.screens.count + fakeDisplays.count }

    // MARK: Init

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.cornerRadius:           CGFloat(10),
            Key.cornerCurve:            CornerCurve.g1.rawValue,
            Key.topCornersEnabled:      true,
            Key.bottomCornersEnabled:   true,
            Key.topCornersUnderMenuBar: false,
            Key.topCornersFullscreenOnly: true,
            Key.cornerGrowEnabled:      true,
            Key.lidOpeningGlassEnabled: true,
            Key.extCornerRadius:        CGFloat(10),
            Key.extCornerCurve:         CornerCurve.g1.rawValue,
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
            Key.dockPreviewEnabled:      true,
            Key.dockPreviewHoverDelay:   TimeInterval(0.35),
            Key.dockPreviewThumbHeight:  CGFloat(140),
            Key.dockPreviewOffset:       CGFloat(0),
            Key.notchPreviewEnabled:     true,
            Key.notchPreviewHoverDelay:  TimeInterval(0.25),
            Key.notchPreviewThumbHeight: CGFloat(140),
            Key.notchPreviewShowOtherSpaces: true,
            Key.notchShowDock:             true,
            Key.appSwitcherLayout:         "grid",
            Key.appSwitcherShowDock:       false,
            Key.appSwitcherPreviewEnabled: true,
            Key.appSwitcherPreviewDelay:   TimeInterval(0.5),
            Key.appSwitcherPreviewOffset:  CGFloat(0),
            Key.appSwitcherStartAtCurrent: false,
            Key.appSwitcherMaxPerRow:      5,
            Key.tilingEnabled:             false,
            Key.tilingShowControlBar:      true,
            Key.tilingControlBarMode:      TilingControlBarMode.fullWidth.rawValue,
            Key.tilingControlBarScope:     TilingControlBarScope.currentSpace.rawValue,
            Key.tilingPillScope:           TilingPillScope.currentSpace.rawValue,
            Key.tilingOneAppPerDeskspace:  true,
            Key.tilingAutoDeleteEmptySpaces: false,
            Key.tilingPadding:             CGFloat(4),
            Key.tilingStablePreviewResize: false,
            Key.tilingSwipeDownCyclesTabs: true,
            Key.tilingSwipeSwitchesSpaces: true,
            Key.tilingSpaceSwipeFingers: 3,
            Key.tilingControlBarPreviews:  true,
            Key.tilingControlBarDuoBatteryWifi: true,
            Key.displaplacerEnabled:     true,
            Key.displaplacerPresets:     Data(),
            Key.monitorInputAutoEject:   false,
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
            Key.hardwareStatsShowPower:     false,
            Key.hardwareStatsShowBattery:   false,
            Key.hardwareStatsBatterySeparate: false,
            Key.hardwareStatsBarStyle:      "vertical",
            Key.hardwareStatsLabelPos:      "vertical",
            Key.hardwareStatsColorScale:    "white",
            Key.hardwareStatsInterval:      2.0,
            Key.hardwareStatsTempSensor:    "auto",
            Key.hardwareStatsMemMode:       "pressure",
            Key.hardwareStatsFanPreset:    "default",
            Key.hardwareStatsFanCurves:    [
                "performance": [[30.0, 30.0], [50.0, 50.0], [65.0, 70.0], [80.0, 85.0], [95.0, 100.0]],
                "silent":      [[40.0, 0.0], [60.0, 20.0], [75.0, 40.0], [85.0, 60.0], [95.0, 80.0]],
            ],
            Key.hardwareStatsTempMin:      30.0,
            Key.hardwareStatsTempMax:      100.0,
            Key.hardwareStatsCPURaw:       false,
            Key.hardwareStatsGPURaw:       false,
            Key.hardwareStatsMemoryRaw:    false,
            Key.hardwareStatsTempRaw:      false,
            Key.hardwareStatsFanRaw:       false,
            Key.hardwareStatsPowerRaw:     false,
            Key.hardwareStatsBatteryStyle: "bar",
            Key.systemHUDEnabled:        false,
            Key.systemHUDVolume:         true,
            Key.systemHUDBrightness:     true,
            Key.systemHUDPresentationMode: SystemHUDPresentationMode.dynamic.rawValue,
            Key.systemHUDDeviceIcons:    true,
            Key.systemHUDInTilingBar:    false,
            Key.inputSourceHUDEnabled:   true,
            Key.mediaKeyPriorityMusic:   false,
        ])

        cornerRadius             = CGFloat(d.float(forKey: Key.cornerRadius))
        cornerCurve              = CornerCurve(rawValue: d.string(forKey: Key.cornerCurve) ?? "") ?? .g1
        topCornersEnabled        = d.bool(forKey: Key.topCornersEnabled)
        bottomCornersEnabled     = d.bool(forKey: Key.bottomCornersEnabled)
        topCornersUnderMenuBar   = d.bool(forKey: Key.topCornersUnderMenuBar)
        topCornersFullscreenOnly = d.bool(forKey: Key.topCornersFullscreenOnly)
        cornerGrowEnabled        = d.bool(forKey: Key.cornerGrowEnabled)
        lidOpeningGlassEnabled   = d.object(forKey: Key.lidOpeningGlassEnabled) as? Bool ?? true
        extCornerRadius          = CGFloat(d.float(forKey: Key.extCornerRadius))
        extCornerCurve           = CornerCurve(rawValue: d.string(forKey: Key.extCornerCurve) ?? "") ?? .g1
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
        dockPreviewEnabled   = d.object(forKey: Key.dockPreviewEnabled) as? Bool ?? true
        dockPreviewHoverDelay = d.object(forKey: Key.dockPreviewHoverDelay) as? Double ?? 0.35
        dockPreviewThumbHeight = CGFloat(d.object(forKey: Key.dockPreviewThumbHeight) as? Double ?? 140)
        dockPreviewOffset    = CGFloat(d.object(forKey: Key.dockPreviewOffset) as? Double ?? 0)
        notchPreviewEnabled  = d.object(forKey: Key.notchPreviewEnabled) as? Bool ?? true
        notchPreviewHoverDelay = d.object(forKey: Key.notchPreviewHoverDelay) as? Double ?? 0.25
        notchPreviewThumbHeight = CGFloat(d.object(forKey: Key.notchPreviewThumbHeight) as? Double ?? 140)
        notchPreviewShowOtherSpaces = d.object(forKey: Key.notchPreviewShowOtherSpaces) as? Bool ?? true
        notchShowDock = d.object(forKey: Key.notchShowDock) as? Bool ?? true
        appSwitcherMode = d.string(forKey: "appSwitcherMode") ?? "replacement"
        let storedLayout = d.string(forKey: Key.appSwitcherLayout) ?? d.string(forKey: "appSwitcherLayout") ?? "grid"
        let validLayouts = ["grid", "singleRow", "spacePerRow"]
        appSwitcherLayout = validLayouts.contains(storedLayout) ? storedLayout : "grid"
        appSwitcherShowDock = d.object(forKey: Key.appSwitcherShowDock) as? Bool ?? false
        appSwitcherDisplayMode = d.string(forKey: "appSwitcherDisplayMode") ?? "all"
        appSwitcherGroupBySpace = d.object(forKey: "appSwitcherGroupBySpace") as? Bool ?? true
        appSwitcherStartAtCurrent = d.object(forKey: Key.appSwitcherStartAtCurrent) as? Bool ?? false
        appSwitcherMaxPerRow = max(3, min(6, d.object(forKey: Key.appSwitcherMaxPerRow) as? Int ?? 5))
        appSwitcherPreviewEnabled = d.object(forKey: Key.appSwitcherPreviewEnabled) as? Bool ?? true
        appSwitcherPreviewDelay = d.object(forKey: Key.appSwitcherPreviewDelay) as? Double ?? 0.5
        appSwitcherPreviewOffset = CGFloat(d.object(forKey: Key.appSwitcherPreviewOffset) as? Double ?? 0)
        tilingEnabled = d.object(forKey: Key.tilingEnabled) as? Bool ?? false
        tilingShowControlBar = d.object(forKey: Key.tilingShowControlBar) as? Bool ?? true
        tilingControlBarMode = TilingControlBarMode(rawValue: d.string(forKey: Key.tilingControlBarMode) ?? "") ?? .fullWidth
        tilingControlBarScope = TilingControlBarScope(rawValue: d.string(forKey: Key.tilingControlBarScope) ?? "") ?? .currentSpace
        tilingPillScope = TilingPillScope(rawValue: d.string(forKey: Key.tilingPillScope) ?? "") ?? .currentSpace
        tilingOneAppPerDeskspace = d.object(forKey: Key.tilingOneAppPerDeskspace) as? Bool ?? true
        tilingAutoDeleteEmptySpaces = d.object(forKey: Key.tilingAutoDeleteEmptySpaces) as? Bool ?? false
        tilingPadding = max(0, CGFloat(d.object(forKey: Key.tilingPadding) as? Double ?? 4))
        tilingStablePreviewResize = d.object(forKey: Key.tilingStablePreviewResize) as? Bool ?? false
        tilingSwipeCyclesTabs = d.object(forKey: Key.tilingSwipeDownCyclesTabs) as? Bool ?? true
        tilingSwipeSwitchesSpaces = d.object(forKey: Key.tilingSwipeSwitchesSpaces) as? Bool ?? true
        tilingSpaceSwipeFingers = (d.object(forKey: Key.tilingSpaceSwipeFingers) as? Int) == 4 ? 4 : 3
        tilingControlBarPreviews = d.object(forKey: Key.tilingControlBarPreviews) as? Bool ?? true
        tilingControlBarDuoBatteryWifi = d.object(forKey: Key.tilingControlBarDuoBatteryWifi) as? Bool ?? true
        if let data = d.data(forKey: Key.displaplacerPresets),
           let decoded = try? JSONDecoder().decode([DisplaplacerPreset].self, from: data) {
            displaplacerPresets = decoded
        } else { displaplacerPresets = [] }
        displaplacerEnabled  = d.object(forKey: Key.displaplacerEnabled) as? Bool ?? true
        monitorInputAutoEject = d.object(forKey: Key.monitorInputAutoEject) as? Bool ?? false
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
        hardwareStatsShowPower    = d.object(forKey: Key.hardwareStatsShowPower) as? Bool ?? false
        hardwareStatsShowBattery  = d.object(forKey: Key.hardwareStatsShowBattery) as? Bool ?? false
        hardwareStatsBatterySeparate = d.object(forKey: Key.hardwareStatsBatterySeparate) as? Bool ?? false
        hardwareStatsBarStyle     = d.string(forKey: Key.hardwareStatsBarStyle) ?? "vertical"
        hardwareStatsLabelPos     = d.string(forKey: Key.hardwareStatsLabelPos) ?? "vertical"
        hardwareStatsColorScale   = d.string(forKey: Key.hardwareStatsColorScale) ?? "white"
        hardwareStatsInterval     = d.object(forKey: Key.hardwareStatsInterval) as? Double ?? 2.0
        hardwareStatsTempSensor   = d.string(forKey: Key.hardwareStatsTempSensor) ?? "auto"
        hardwareStatsMemMode      = d.string(forKey: Key.hardwareStatsMemMode) ?? "pressure"
        hardwareStatsTempMin      = d.object(forKey: Key.hardwareStatsTempMin) as? Double ?? 30.0
        hardwareStatsTempMax      = d.object(forKey: Key.hardwareStatsTempMax) as? Double ?? 100.0
        hardwareStatsCPURaw       = d.object(forKey: Key.hardwareStatsCPURaw) as? Bool ?? false
        hardwareStatsGPURaw       = d.object(forKey: Key.hardwareStatsGPURaw) as? Bool ?? false
        hardwareStatsMemoryRaw    = d.object(forKey: Key.hardwareStatsMemoryRaw) as? Bool ?? false
        hardwareStatsTempRaw      = d.object(forKey: Key.hardwareStatsTempRaw) as? Bool ?? false
        hardwareStatsFanRaw       = d.object(forKey: Key.hardwareStatsFanRaw) as? Bool ?? false
        hardwareStatsPowerRaw     = d.object(forKey: Key.hardwareStatsPowerRaw) as? Bool ?? false
        hardwareStatsPowerSamples = d.object(forKey: Key.hardwareStatsPowerSamples) as? Int ?? 120
        hardwareStatsBatteryStyle = d.string(forKey: Key.hardwareStatsBatteryStyle) ?? "bar"
        // If power was enabled in menu bar and battery wasn't, migrate to battery with watts style
        if (d.object(forKey: Key.hardwareStatsShowPower) as? Bool ?? false) &&
           !(d.object(forKey: Key.hardwareStatsShowBattery) as? Bool ?? false) {
            hardwareStatsShowBattery = true
            hardwareStatsBatteryStyle = "watts"
        }
        // Keep known ids in the saved order, then append any known id that's
        // missing (e.g. after adding a module) and drop anything unrecognized.
        // Map any legacy "power" id to "battery" and deduplicate.
        var seenOrder = Set<String>()
        var savedOrder: [String] = []
        for id in (d.stringArray(forKey: Key.hardwareStatsModuleOrder) ?? []) {
            let mapped = id == "power" ? "battery" : id
            if AppSettings.hardwareModuleIDs.contains(mapped) && seenOrder.insert(mapped).inserted {
                savedOrder.append(mapped)
            }
        }
        hardwareStatsModuleOrder = savedOrder + AppSettings.hardwareModuleIDs.filter { !savedOrder.contains($0) }

        var seenHidden = Set<String>()
        var savedHidden: [String] = []
        for id in (d.stringArray(forKey: Key.hardwareStatsHiddenCards) ?? []) {
            let mapped = id == "power" ? "battery" : id
            if AppSettings.hardwareModuleIDs.contains(mapped) && seenHidden.insert(mapped).inserted {
                savedHidden.append(mapped)
            }
        }
        hardwareStatsHiddenCards = savedHidden

        hardwareStatsColumns     = max(1, min(3, d.object(forKey: Key.hardwareStatsColumns) as? Int ?? 2))
        hardwareStatsCardColumns = HardwareCardLayout.normalize(
            d.array(forKey: Key.hardwareStatsCardColumns) as? [[String]]
                ?? [["cpu", "memory"], ["gpu", "temp", "fps"]])
        let savedBatterySpan = d.string(forKey: Key.hardwareStatsBatteryCardSpan) ?? "2x2"
        hardwareStatsBatteryCardSpan = ["2x2", "full"].contains(savedBatterySpan) ? savedBatterySpan : "2x2"
        let savedBatterySide = d.string(forKey: Key.hardwareStatsBatteryCardSide) ?? "left"
        hardwareStatsBatteryCardSide = ["left", "right"].contains(savedBatterySide) ? savedBatterySide : "left"
        let savedFanPreset = d.string(forKey: Key.hardwareStatsFanPreset) ?? "default"
        hardwareStatsFanPreset = ["performance", "silent"].contains(savedFanPreset) ? savedFanPreset : "default"
        let decodedFanCurves = (try? JSONDecoder().decode([String: [[Double]]].self,
                                       from: d.data(forKey: Key.hardwareStatsFanCurves) ?? Data())) ?? [:]
        hardwareStatsFanCurves = [
            "performance": decodedFanCurves["performance"] ?? [[30, 30], [50, 50], [65, 70], [80, 85], [95, 100]],
            "silent":      decodedFanCurves["silent"] ?? [[40, 0], [60, 20], [75, 40], [85, 60], [95, 80]],
        ]
        if let data = d.data(forKey: Key.fakeDisplays),
           let decoded = try? JSONDecoder().decode([FakeDisplay].self, from: data) {
            fakeDisplays = decoded
        } else { fakeDisplays = [] }
        systemHUDEnabled    = d.object(forKey: Key.systemHUDEnabled) as? Bool ?? false
        systemHUDVolume     = d.object(forKey: Key.systemHUDVolume) as? Bool ?? true
        systemHUDBrightness = d.object(forKey: Key.systemHUDBrightness) as? Bool ?? true
        systemHUDPresentationMode = SystemHUDPresentationMode(rawValue: d.string(forKey: Key.systemHUDPresentationMode) ?? "") ?? .dynamic
        systemHUDDeviceIcons = d.object(forKey: Key.systemHUDDeviceIcons) as? Bool ?? true
        systemHUDInTilingBar = d.object(forKey: Key.systemHUDInTilingBar) as? Bool ?? false
        inputSourceHUDEnabled = d.object(forKey: Key.inputSourceHUDEnabled) as? Bool ?? true
        mediaKeyPriorityMusic = d.object(forKey: Key.mediaKeyPriorityMusic) as? Bool ?? false
    }

    private func save() {
        onUIChange?()
        let d = UserDefaults.standard
        d.set(Float(cornerRadius),          forKey: Key.cornerRadius)
        d.set(cornerCurve.rawValue,         forKey: Key.cornerCurve)
        d.set(topCornersEnabled,            forKey: Key.topCornersEnabled)
        d.set(bottomCornersEnabled,         forKey: Key.bottomCornersEnabled)
        d.set(topCornersUnderMenuBar,       forKey: Key.topCornersUnderMenuBar)
        d.set(topCornersFullscreenOnly,     forKey: Key.topCornersFullscreenOnly)
        d.set(cornerGrowEnabled,            forKey: Key.cornerGrowEnabled)
        d.set(lidOpeningGlassEnabled,       forKey: Key.lidOpeningGlassEnabled)
        d.set(Float(extCornerRadius),       forKey: Key.extCornerRadius)
        d.set(extCornerCurve.rawValue,      forKey: Key.extCornerCurve)
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
        d.set(dockPreviewEnabled,           forKey: Key.dockPreviewEnabled)
        d.set(dockPreviewHoverDelay,        forKey: Key.dockPreviewHoverDelay)
        d.set(Double(dockPreviewThumbHeight), forKey: Key.dockPreviewThumbHeight)
        d.set(Double(dockPreviewOffset),    forKey: Key.dockPreviewOffset)
        d.set(notchPreviewEnabled,          forKey: Key.notchPreviewEnabled)
        d.set(notchPreviewHoverDelay,       forKey: Key.notchPreviewHoverDelay)
        d.set(Double(notchPreviewThumbHeight), forKey: Key.notchPreviewThumbHeight)
        d.set(notchPreviewShowOtherSpaces,   forKey: Key.notchPreviewShowOtherSpaces)
        d.set(notchShowDock,                 forKey: Key.notchShowDock)
        d.set(appSwitcherMode, forKey: "appSwitcherMode")
        d.set(appSwitcherLayout, forKey: Key.appSwitcherLayout)
        d.set(appSwitcherShowDock, forKey: Key.appSwitcherShowDock)
        d.set(appSwitcherDisplayMode, forKey: "appSwitcherDisplayMode")
        d.set(appSwitcherGroupBySpace, forKey: "appSwitcherGroupBySpace")
        d.set(appSwitcherStartAtCurrent, forKey: Key.appSwitcherStartAtCurrent)
        d.set(appSwitcherMaxPerRow, forKey: Key.appSwitcherMaxPerRow)
        d.set(appSwitcherPreviewEnabled,    forKey: Key.appSwitcherPreviewEnabled)
        d.set(appSwitcherPreviewDelay,      forKey: Key.appSwitcherPreviewDelay)
        d.set(Double(appSwitcherPreviewOffset), forKey: Key.appSwitcherPreviewOffset)
        d.set(tilingEnabled,                  forKey: Key.tilingEnabled)
        d.set(tilingShowControlBar,           forKey: Key.tilingShowControlBar)
        d.set(tilingControlBarMode.rawValue,   forKey: Key.tilingControlBarMode)
        d.set(tilingControlBarScope.rawValue,  forKey: Key.tilingControlBarScope)
        d.set(tilingPillScope.rawValue,         forKey: Key.tilingPillScope)
        d.set(tilingOneAppPerDeskspace,         forKey: Key.tilingOneAppPerDeskspace)
        d.set(tilingAutoDeleteEmptySpaces,      forKey: Key.tilingAutoDeleteEmptySpaces)
        d.set(Double(tilingPadding),          forKey: Key.tilingPadding)
        d.set(tilingStablePreviewResize,       forKey: Key.tilingStablePreviewResize)
        d.set(tilingSwipeCyclesTabs,       forKey: Key.tilingSwipeDownCyclesTabs)
        d.set(tilingSwipeSwitchesSpaces,   forKey: Key.tilingSwipeSwitchesSpaces)
        d.set(tilingSpaceSwipeFingers,     forKey: Key.tilingSpaceSwipeFingers)
        d.set(tilingControlBarPreviews,        forKey: Key.tilingControlBarPreviews)
        d.set(tilingControlBarDuoBatteryWifi,  forKey: Key.tilingControlBarDuoBatteryWifi)
        d.set(displaplacerEnabled,          forKey: Key.displaplacerEnabled)
        d.set(monitorInputAutoEject,        forKey: Key.monitorInputAutoEject)
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
        d.set(hardwareStatsShowPower,        forKey: Key.hardwareStatsShowPower)
        d.set(hardwareStatsShowBattery,      forKey: Key.hardwareStatsShowBattery)
        d.set(hardwareStatsBatterySeparate,  forKey: Key.hardwareStatsBatterySeparate)
        d.set(hardwareStatsBarStyle,         forKey: Key.hardwareStatsBarStyle)
        d.set(hardwareStatsLabelPos,         forKey: Key.hardwareStatsLabelPos)
        d.set(hardwareStatsColorScale,       forKey: Key.hardwareStatsColorScale)
        d.set(hardwareStatsInterval,         forKey: Key.hardwareStatsInterval)
        d.set(hardwareStatsTempSensor,       forKey: Key.hardwareStatsTempSensor)
        d.set(hardwareStatsMemMode,          forKey: Key.hardwareStatsMemMode)
        d.set(hardwareStatsTempMin,          forKey: Key.hardwareStatsTempMin)
        d.set(hardwareStatsTempMax,          forKey: Key.hardwareStatsTempMax)
        d.set(hardwareStatsCPURaw,           forKey: Key.hardwareStatsCPURaw)
        d.set(hardwareStatsGPURaw,           forKey: Key.hardwareStatsGPURaw)
        d.set(hardwareStatsMemoryRaw,        forKey: Key.hardwareStatsMemoryRaw)
        d.set(hardwareStatsTempRaw,          forKey: Key.hardwareStatsTempRaw)
        d.set(hardwareStatsFanRaw,           forKey: Key.hardwareStatsFanRaw)
        d.set(hardwareStatsPowerRaw,         forKey: Key.hardwareStatsPowerRaw)
        d.set(hardwareStatsPowerSamples,     forKey: Key.hardwareStatsPowerSamples)
        d.set(hardwareStatsBatteryStyle,     forKey: Key.hardwareStatsBatteryStyle)
        d.set(hardwareStatsModuleOrder,      forKey: Key.hardwareStatsModuleOrder)
        d.set(hardwareStatsHiddenCards,      forKey: Key.hardwareStatsHiddenCards)
        d.set(hardwareStatsColumns,          forKey: Key.hardwareStatsColumns)
        d.set(hardwareStatsCardColumns,      forKey: Key.hardwareStatsCardColumns)
        d.set(hardwareStatsBatteryCardSpan,  forKey: Key.hardwareStatsBatteryCardSpan)
        d.set(hardwareStatsBatteryCardSide,  forKey: Key.hardwareStatsBatteryCardSide)
        d.set(hardwareStatsFanPreset,       forKey: Key.hardwareStatsFanPreset)
        if let data = try? JSONEncoder().encode(hardwareStatsFanCurves) {
            d.set(data, forKey: Key.hardwareStatsFanCurves)
        }
        if let data = try? JSONEncoder().encode(displaplacerPresets) { d.set(data, forKey: Key.displaplacerPresets) }
        if let data = try? JSONEncoder().encode(fakeDisplays) { d.set(data, forKey: Key.fakeDisplays) }
        d.set(systemHUDEnabled,    forKey: Key.systemHUDEnabled)
        d.set(systemHUDVolume,     forKey: Key.systemHUDVolume)
        d.set(systemHUDBrightness, forKey: Key.systemHUDBrightness)
        d.set(systemHUDPresentationMode.rawValue, forKey: Key.systemHUDPresentationMode)
        d.set(systemHUDDeviceIcons, forKey: Key.systemHUDDeviceIcons)
        d.set(systemHUDInTilingBar, forKey: Key.systemHUDInTilingBar)
        d.set(inputSourceHUDEnabled, forKey: Key.inputSourceHUDEnabled)
        d.set(mediaKeyPriorityMusic, forKey: Key.mediaKeyPriorityMusic)
    }
}
