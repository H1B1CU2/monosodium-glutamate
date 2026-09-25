import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - Window controller

@available(macOS 14.0, *)
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private override init() {}

    func show(pane: SettingsSection? = nil) {
        if let pane { SettingsViewModel.shared.selectedSection = pane }
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            syncPreviewClock()
            return
        }
        let hosting = NSHostingView(rootView: SettingsWindow())
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // No titlebar safe-area inset: all top spacing is explicit in SwiftUI.
        hosting.safeAreaRegions = []
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        // The glass lives in the SwiftUI layer (behind-window .sidebar
        // material on the root view); the window itself must stay clear
        // (isOpaque = false, backgroundColor = .clear below) so that material
        // can blend with the desktop. The content card is opaque on top of it.
        w.contentView = hosting
        w.title = "Settings"
        w.setContentSize(NSSize(width: 860, height: 746))
        w.minSize = NSSize(width: 860, height: 746)
        w.maxSize = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        w.collectionBehavior.insert(.fullScreenNone)
        w.standardWindowButton(.zoomButton)?.isEnabled = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        w.toolbarStyle = .unified
        let tb = NSToolbar(identifier: "MSG.SettingsToolbar")
        tb.showsBaselineSeparator = false
        tb.displayMode = .iconOnly
        tb.isVisible = false
        w.toolbar = tb
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.center()

        // Yellow button hides window + Dock icon instead of minimizing
        NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification, object: w, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            w.orderOut(nil)
            // The hosting view stays in the retained window, so no SwiftUI
            // onDisappear fires — release editing here or the Cornermizer pane
            // leaves the desktop on its uncornered preview baseline.
            WallpaperEngine.shared.endEditing()
            self.syncPreviewClock()
            if !AppSettings.shared.dockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        // The hosting view outlives every hide, so nothing in SwiftUI notices
        // the window left the screen. Occlusion covers what the close and
        // miniaturize paths don't — fully covered, or on an inactive Space.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
            self?.syncPreviewClock()
        }

        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Concentric corners: now that the window is realized (theme frame fully
        // configured with toolbar/titlebar style), read the radius macOS actually
        // draws so the inset content card can subtract the gutter from the real
        // native outer radius instead of a hardcoded guess.
        SettingsViewModel.shared.windowCornerRadius = w.nativeFrameCornerRadius
        window = w
        syncPreviewClock()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Park or resume the settings previews' animation clock to match what the
    /// user can actually see. See `PreviewAnimationGate` for why this matters:
    /// unparked, the previews redraw at display refresh forever, including
    /// while the window is ordered out.
    private func syncPreviewClock() {
        let w = window
        let visible = (w?.isVisible ?? false) && (w?.occlusionState.contains(.visible) ?? false)
        if PreviewAnimationGate.shared.isRunning != visible {
            PreviewAnimationGate.shared.isRunning = visible
        }
    }

    /// Same reason as the miniaturize path above: closing the window only orders
    /// it out (isReleasedWhenClosed = false), so the pane's onDisappear never
    /// runs and WallpaperEngine would stay latched in editing mode.
    func windowWillClose(_ notification: Notification) {
        WallpaperEngine.shared.endEditing()
        // windowWillClose fires before isVisible flips, so don't re-derive it here.
        PreviewAnimationGate.shared.isRunning = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        DispatchQueue.main.async {
            if !AppSettings.shared.dockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        return true
    }

    func windowDidBecomeMain(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

// MARK: - Native window corner radius

@available(macOS 14.0, *)
private extension NSWindow {
    /// The corner radius macOS draws for this window's frame. Titled windows are
    /// rounded at the WindowServer level with no public getter, so we read the
    /// private `_cornerRadius` accessor on the theme frame (contentView.superview).
    /// Falls back to 16 if the selector is ever unavailable, so the concentric
    /// card math still yields a reasonable inner radius.
    var nativeFrameCornerRadius: CGFloat {
        guard let frame = contentView?.superview else { return 16 }
        let sel = NSSelectorFromString("_cornerRadius")
        guard frame.responds(to: sel),
              let method = class_getInstanceMethod(type(of: frame), sel) else { return 16 }
        typealias RadiusFn = @convention(c) (AnyObject, Selector) -> CGFloat
        let radius = unsafeBitCast(method_getImplementation(method), to: RadiusFn.self)(frame, sel)
        return radius > 0 ? radius : 16
    }
}

// MARK: - View model

@available(macOS 14.0, *)
final class SettingsViewModel: ObservableObject {
    static let shared = SettingsViewModel()
    private let s = AppSettings.shared
    private init() {
        s.onUIChange = { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// Transient UI state (not persisted) so AppKit callers outside SwiftUI —
    /// e.g. the hardware stats popover — can open Settings on a specific pane.
    @Published var selectedSection: SettingsSection = .spacer

    /// Native OS-drawn window corner radius, measured from the theme frame once
    /// the settings window exists (see `NSWindow.nativeFrameCornerRadius`). The
    /// inset content card uses this to stay concentric: cardRadius = value − gutter.
    @Published var windowCornerRadius: CGFloat = 16

    var stackMode: StackMode               { get { s.stackMode }            set { s.stackMode = newValue;            objectWillChange.send() } }
    var animationStyle: AnimationStyle     { get { s.animationStyle }       set { s.animationStyle = newValue;       objectWillChange.send() } }
    var focusDetectionMode: FocusDetectionMode { get { s.focusDetectionMode } set { s.focusDetectionMode = newValue; objectWillChange.send() } }
    var displayOrderMode: DisplayOrderMode { get { s.displayOrderMode }     set { s.displayOrderMode = newValue;     objectWillChange.send() } }
    var displayOrder: [Int]                { get { s.displayOrder }         set { s.displayOrder = newValue;         objectWillChange.send() } }
    var monitorInputAutoEject: Bool        { get { s.monitorInputAutoEject } set { s.monitorInputAutoEject = newValue; objectWillChange.send() } }
    var musicDisplayMode: MusicDisplayMode { get { s.musicDisplayMode }     set { s.musicDisplayMode = newValue;     objectWillChange.send() } }
    var musicLingerDuration: TimeInterval  { get { s.musicLingerDuration }  set { s.musicLingerDuration = newValue;  objectWillChange.send() } }
    var musicSource: MusicSource            { get { s.musicSource }         set { s.musicSource = newValue;         objectWillChange.send() } }
    var mediaKeyPriorityMusic: Bool         { get { s.mediaKeyPriorityMusic } set { s.mediaKeyPriorityMusic = newValue; objectWillChange.send() } }
    var mirrorMainDisplay: Bool            { get { s.mirrorMainDisplay }    set { s.mirrorMainDisplay = newValue;    objectWillChange.send() } }
    var cornerRadius: CGFloat              { get { s.cornerRadius }         set { s.cornerRadius = newValue;         objectWillChange.send() } }
    var cornerCurve: CornerCurve           { get { s.cornerCurve }          set { s.cornerCurve = newValue;          objectWillChange.send() } }
    var topCornersEnabled: Bool            { get { s.topCornersEnabled }    set { s.topCornersEnabled = newValue;    objectWillChange.send() } }
    var bottomCornersEnabled: Bool         { get { s.bottomCornersEnabled } set { s.bottomCornersEnabled = newValue; objectWillChange.send() } }
    var topCornersUnderMenuBar: Bool       { get { s.topCornersUnderMenuBar } set { s.topCornersUnderMenuBar = newValue; objectWillChange.send() } }
    var topCornersFullscreenOnly: Bool     { get { s.topCornersFullscreenOnly } set { s.topCornersFullscreenOnly = newValue; objectWillChange.send() } }
    var cornerGrowEnabled: Bool            { get { s.cornerGrowEnabled }     set { s.cornerGrowEnabled = newValue;     objectWillChange.send() } }
    var lidOpeningGlassEnabled: Bool        { get { s.lidOpeningGlassEnabled } set { s.lidOpeningGlassEnabled = newValue; objectWillChange.send() } }
    var dockIcon: Bool                     { get { s.dockIcon }             set { s.dockIcon = newValue;             objectWillChange.send() } }
    var brightFocusAlpha: CGFloat          { get { s.brightFocusAlpha }     set { s.brightFocusAlpha = newValue;     objectWillChange.send() } }
    var dimFocusAlpha: CGFloat             { get { s.dimFocusAlpha }        set { s.dimFocusAlpha = newValue;        objectWillChange.send() } }
    var brightNonFocusAlpha: CGFloat       { get { s.brightNonFocusAlpha }  set { s.brightNonFocusAlpha = newValue;  objectWillChange.send() } }
    var dimNonFocusAlpha: CGFloat          { get { s.dimNonFocusAlpha }     set { s.dimNonFocusAlpha = newValue;     objectWillChange.send() } }
    var spacerEnabled: Bool     { get { s.spacerEnabled }  set { s.spacerEnabled = newValue;  objectWillChange.send() } }
    var cornersEnabled: Bool    { get { s.cornersEnabled } set { s.cornersEnabled = newValue; objectWillChange.send() } }
    var musicEnabled: Bool      { get { s.musicEnabled }   set { s.musicEnabled = newValue;   objectWillChange.send() } }
    var autoUpdate: Bool                   { get { s.autoUpdate }           set { s.autoUpdate = newValue;           objectWillChange.send() } }
    var updateChannel: String              { get { s.updateChannel }        set { s.updateChannel = newValue;        objectWillChange.send() } }
    var fakeDisplays: [FakeDisplay]          { get { s.fakeDisplays }         set { s.fakeDisplays = newValue;         objectWillChange.send() } }
    var appSwitcherMode: String { get { s.appSwitcherMode } set { s.appSwitcherMode = newValue; objectWillChange.send() } }
    var appSwitcherLayout: String { get { s.appSwitcherLayout } set { s.appSwitcherLayout = newValue; objectWillChange.send() } }
    var appSwitcherDisplayMode: String { get { s.appSwitcherDisplayMode } set { s.appSwitcherDisplayMode = newValue; objectWillChange.send() } }
    var appSwitcherGroupBySpace: Bool { get { s.appSwitcherGroupBySpace } set { s.appSwitcherGroupBySpace = newValue; objectWillChange.send() } }
    var appSwitcherStartAtCurrent: Bool { get { s.appSwitcherStartAtCurrent } set { s.appSwitcherStartAtCurrent = newValue; objectWillChange.send() } }
    var appSwitcherMaxPerRow: Int { get { s.appSwitcherMaxPerRow } set { s.appSwitcherMaxPerRow = max(3, min(6, newValue)); objectWillChange.send() } }
    var dockPreviewEnabled: Bool             { get { s.dockPreviewEnabled }   set { s.dockPreviewEnabled = newValue;   objectWillChange.send() } }
    var notchPreviewEnabled: Bool            { get { s.notchPreviewEnabled }  set { s.notchPreviewEnabled = newValue;  objectWillChange.send() } }
    var appSwitcherPreviewEnabled: Bool      { get { s.appSwitcherPreviewEnabled } set { s.appSwitcherPreviewEnabled = newValue; objectWillChange.send() } }
    var appSwitcherPreviewDelay: TimeInterval { get { s.appSwitcherPreviewDelay } set { s.appSwitcherPreviewDelay = newValue; objectWillChange.send() } }
    var appSwitcherPreviewOffset: CGFloat    { get { s.appSwitcherPreviewOffset } set { s.appSwitcherPreviewOffset = newValue; objectWillChange.send() } }
    var tilingEnabled: Bool                  { get { s.tilingEnabled } set { s.tilingEnabled = newValue; objectWillChange.send() } }
    var tilingShowControlBar: Bool           { get { s.tilingShowControlBar } set { s.tilingShowControlBar = newValue; objectWillChange.send() } }
    var tilingControlBarMode: TilingControlBarMode { get { s.tilingControlBarMode } set { s.tilingControlBarMode = newValue; objectWillChange.send() } }
    var tilingControlBarScope: TilingControlBarScope { get { s.tilingControlBarScope } set { s.tilingControlBarScope = newValue; objectWillChange.send() } }
    var tilingPillScope: TilingPillScope { get { s.tilingPillScope } set { s.tilingPillScope = newValue; objectWillChange.send() } }
    var tilingOneAppPerDeskspace: Bool { get { s.tilingOneAppPerDeskspace } set { s.tilingOneAppPerDeskspace = newValue; objectWillChange.send() } }
    var tilingAutoDeleteEmptySpaces: Bool { get { s.tilingAutoDeleteEmptySpaces } set { s.tilingAutoDeleteEmptySpaces = newValue; objectWillChange.send() } }
    var tilingPadding: CGFloat               { get { s.tilingPadding } set { s.tilingPadding = max(0, min(32, newValue)); objectWillChange.send() } }
    var tilingStablePreviewResize: Bool      { get { s.tilingStablePreviewResize } set { s.tilingStablePreviewResize = newValue; objectWillChange.send() } }
    var tilingSwipeCyclesTabs: Bool      { get { s.tilingSwipeCyclesTabs } set { s.tilingSwipeCyclesTabs = newValue; objectWillChange.send() } }
    var tilingSwipeSwitchesSpaces: Bool  { get { s.tilingSwipeSwitchesSpaces } set { s.tilingSwipeSwitchesSpaces = newValue; objectWillChange.send() } }
    var tilingSpaceSwipeFingers: Int     { get { s.tilingSpaceSwipeFingers } set { s.tilingSpaceSwipeFingers = newValue; objectWillChange.send() } }
    var tilingControlBarPreviews: Bool       { get { s.tilingControlBarPreviews } set { s.tilingControlBarPreviews = newValue; objectWillChange.send() } }
    var tilingControlBarDuoBatteryWifi: Bool { get { s.tilingControlBarDuoBatteryWifi } set { s.tilingControlBarDuoBatteryWifi = newValue; objectWillChange.send() } }
    var dockPreviewHoverDelay: TimeInterval  { get { s.dockPreviewHoverDelay } set { s.dockPreviewHoverDelay = newValue; objectWillChange.send() } }
    var dockPreviewThumbHeight: CGFloat      { get { s.dockPreviewThumbHeight } set { s.dockPreviewThumbHeight = newValue; objectWillChange.send() } }
    var dockPreviewOffset: CGFloat           { get { s.dockPreviewOffset } set { s.dockPreviewOffset = newValue; objectWillChange.send() } }
    var notchPreviewHoverDelay: TimeInterval { get { s.notchPreviewHoverDelay } set { s.notchPreviewHoverDelay = newValue; objectWillChange.send() } }
    var notchPreviewThumbHeight: CGFloat     { get { s.notchPreviewThumbHeight } set { s.notchPreviewThumbHeight = newValue; objectWillChange.send() } }
    var notchPreviewShowOtherSpaces: Bool    { get { s.notchPreviewShowOtherSpaces } set { s.notchPreviewShowOtherSpaces = newValue; objectWillChange.send() } }
    var notchShowDock: Bool                  { get { s.notchShowDock } set { s.notchShowDock = newValue; objectWillChange.send() } }
    var appSwitcherShowDock: Bool            { get { s.appSwitcherShowDock } set { s.appSwitcherShowDock = newValue; objectWillChange.send() } }
    var displaplacerEnabled: Bool { get { s.displaplacerEnabled } set { s.displaplacerEnabled = newValue; objectWillChange.send() } }
    var displaplacerPresets: [DisplaplacerPreset] { get { s.displaplacerPresets } set { s.displaplacerPresets = newValue; objectWillChange.send() } }
    var menuBarSpacing: Int        { get { s.menuBarSpacing }        set { s.menuBarSpacing = newValue;        objectWillChange.send() } }
    var menuBarSpacingPadding: Int { get { s.menuBarSpacingPadding } set { s.menuBarSpacingPadding = newValue; objectWillChange.send() } }
    var systemHUDEnabled: Bool     { get { s.systemHUDEnabled }     set { s.systemHUDEnabled = newValue;     objectWillChange.send() } }
    var systemHUDVolume: Bool      { get { s.systemHUDVolume }      set { s.systemHUDVolume = newValue;      objectWillChange.send() } }
    var systemHUDBrightness: Bool  { get { s.systemHUDBrightness }  set { s.systemHUDBrightness = newValue;  objectWillChange.send() } }
    var systemHUDPresentationMode: SystemHUDPresentationMode { get { s.systemHUDPresentationMode } set { s.systemHUDPresentationMode = newValue; objectWillChange.send() } }
    var systemHUDDeviceIcons: Bool { get { s.systemHUDDeviceIcons } set { s.systemHUDDeviceIcons = newValue; objectWillChange.send() } }
    var systemHUDInTilingBar: Bool { get { s.systemHUDInTilingBar } set { s.systemHUDInTilingBar = newValue; objectWillChange.send() } }
    var inputSourceHUDEnabled: Bool { get { s.inputSourceHUDEnabled } set { s.inputSourceHUDEnabled = newValue; objectWillChange.send() } }
    var showDeveloper: Bool        { get { s.showDeveloper }        set { s.showDeveloper = newValue;        objectWillChange.send() } }
    var hardwareStatsEnabled: Bool        { get { s.hardwareStatsEnabled }      set { s.hardwareStatsEnabled = newValue;      objectWillChange.send() } }
    var hardwareStatsShowCPU: Bool        { get { s.hardwareStatsShowCPU }      set { s.hardwareStatsShowCPU = newValue;      objectWillChange.send() } }
    var hardwareStatsShowGPU: Bool        { get { s.hardwareStatsShowGPU }      set { s.hardwareStatsShowGPU = newValue;      objectWillChange.send() } }
    var hardwareStatsShowMemory: Bool     { get { s.hardwareStatsShowMemory }   set { s.hardwareStatsShowMemory = newValue;   objectWillChange.send() } }
    var hardwareStatsShowTemp: Bool       { get { s.hardwareStatsShowTemp }     set { s.hardwareStatsShowTemp = newValue;     objectWillChange.send() } }
    var hardwareStatsShowFPS: Bool        { get { s.hardwareStatsShowFPS }      set { s.hardwareStatsShowFPS = newValue;      objectWillChange.send() } }
    var hardwareStatsShowFan: Bool        { get { s.hardwareStatsShowFan }      set { s.hardwareStatsShowFan = newValue;      objectWillChange.send() } }
    var hardwareStatsShowPower: Bool      { get { s.hardwareStatsShowPower }    set { s.hardwareStatsShowPower = newValue;    objectWillChange.send() } }
    var hardwareStatsShowBattery: Bool    { get { s.hardwareStatsShowBattery }  set { s.hardwareStatsShowBattery = newValue;  objectWillChange.send() } }
    var hardwareStatsBatterySeparate: Bool { get { s.hardwareStatsBatterySeparate } set { s.hardwareStatsBatterySeparate = newValue; objectWillChange.send() } }
    var hardwareStatsCPURaw: Bool         { get { s.hardwareStatsCPURaw }       set { s.hardwareStatsCPURaw = newValue;       objectWillChange.send() } }
    var hardwareStatsGPURaw: Bool         { get { s.hardwareStatsGPURaw }       set { s.hardwareStatsGPURaw = newValue;       objectWillChange.send() } }
    var hardwareStatsMemoryRaw: Bool      { get { s.hardwareStatsMemoryRaw }    set { s.hardwareStatsMemoryRaw = newValue;    objectWillChange.send() } }
    var hardwareStatsTempRaw: Bool        { get { s.hardwareStatsTempRaw }      set { s.hardwareStatsTempRaw = newValue;      objectWillChange.send() } }
    var hardwareStatsFanRaw: Bool         { get { s.hardwareStatsFanRaw }       set { s.hardwareStatsFanRaw = newValue;       objectWillChange.send() } }
    var hardwareStatsPowerRaw: Bool       { get { s.hardwareStatsPowerRaw }     set { s.hardwareStatsPowerRaw = newValue;     objectWillChange.send() } }
    var hardwareStatsPowerSamples: Double { get { Double(s.hardwareStatsPowerSamples) } set { s.hardwareStatsPowerSamples = max(10, Int(newValue)); objectWillChange.send() } }
    var hardwareStatsBatteryStyle: String { get { s.hardwareStatsBatteryStyle } set { s.hardwareStatsBatteryStyle = newValue; objectWillChange.send() } }
    var hardwareStatsModuleOrder: [String] { get { s.hardwareStatsModuleOrder } set { s.hardwareStatsModuleOrder = newValue; objectWillChange.send() } }
    var hardwareStatsHiddenCards: [String] { get { s.hardwareStatsHiddenCards } set { s.hardwareStatsHiddenCards = newValue; objectWillChange.send() } }
    var hardwareStatsColumns: Int          { get { s.hardwareStatsColumns }     set { s.hardwareStatsColumns = max(1, min(3, newValue)); objectWillChange.send() } }
    func applyHardwareLayout(_ layout: HardwareCardLayout) {
        s.applyHardwareLayout(layout)
        objectWillChange.send()
    }
    var hardwareStatsCardColumns: [[String]] { get { s.hardwareStatsCardColumns } set { s.hardwareStatsCardColumns = newValue; objectWillChange.send() } }
    var hardwareStatsBatteryCardSpan: String { get { s.hardwareStatsBatteryCardSpan } set { s.hardwareStatsBatteryCardSpan = newValue; objectWillChange.send() } }
    var hardwareStatsBatteryCardSide: String { get { s.hardwareStatsBatteryCardSide } set { s.hardwareStatsBatteryCardSide = newValue; objectWillChange.send() } }
    var hardwareStatsBarStyle: String     { get { s.hardwareStatsBarStyle }     set { s.hardwareStatsBarStyle = newValue;     objectWillChange.send() } }
    var hardwareStatsLabelPos: String     { get { s.hardwareStatsLabelPos }     set { s.hardwareStatsLabelPos = newValue;     objectWillChange.send() } }
    var hardwareStatsColorScale: String   { get { s.hardwareStatsColorScale }   set { s.hardwareStatsColorScale = newValue;   objectWillChange.send() } }
    var hardwareStatsInterval: Double     { get { s.hardwareStatsInterval }     set { s.hardwareStatsInterval = newValue;     objectWillChange.send() } }
    var hardwareStatsTempSensor: String   { get { s.hardwareStatsTempSensor }   set { s.hardwareStatsTempSensor = newValue;   objectWillChange.send() } }
    var hardwareStatsMemMode: String      { get { s.hardwareStatsMemMode }      set { s.hardwareStatsMemMode = newValue;      objectWillChange.send() } }
    var hardwareStatsTempMin: Double {
        get { s.hardwareStatsTempMin }
        set {
            let val = min(newValue, s.hardwareStatsTempMax - 5)
            s.hardwareStatsTempMin = val
            objectWillChange.send()
        }
    }
    var hardwareStatsTempMax: Double {
        get { s.hardwareStatsTempMax }
        set {
            let val = max(newValue, s.hardwareStatsTempMin + 5)
            s.hardwareStatsTempMax = val
            objectWillChange.send()
        }
    }
    var hardwareStatsFanPreset: String   { get { s.hardwareStatsFanPreset }   set { s.hardwareStatsFanPreset = newValue;   objectWillChange.send() } }
    var hardwareStatsFanCurves: [String: [[Double]]] {
        get { s.hardwareStatsFanCurves }
        set { s.hardwareStatsFanCurves = newValue; objectWillChange.send() }
    }
    func fanCurveBinding(for preset: String) -> Binding<[[Double]]> {
        Binding(
            get: { self.hardwareStatsFanCurves[preset] ?? [[30, 30], [50, 50], [65, 70], [80, 85], [95, 100]] },
            set: { self.hardwareStatsFanCurves[preset] = $0 }
        )
    }
}

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, about, menubar, spacer, tiling, hud, corner, lidGlass, music, dock, displaplacer, hardware, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .about:        return "About"
        case .menubar:      return "Menu Bar"
        case .spacer:       return "Space Indicator"
        case .tiling:       return "Tiling"
        case .hud:          return "System HUD"
        case .corner:       return "Corners"
        case .lidGlass:     return "Lid Glass"
        case .music:        return "Music"
        case .dock:         return "Window Preview"
        case .displaplacer: return "Displays"
        case .hardware:     return "Hardware Stats"
        case .developer:    return "Developer"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .about:        return "info.circle.fill"
        case .menubar:      return "menubar.rectangle"
        case .spacer:       return "rectangle.split.3x1.fill"
        case .tiling:       return "rectangle.split.2x1.fill"
        case .hud:          return "slider.horizontal.3"
        case .corner:       return "viewfinder"
        case .lidGlass:     return "laptopcomputer.and.arrow.down"
        case .music:        return "music.note"
        case .dock:         return "macwindow.on.rectangle"
        case .displaplacer: return "display.2"
        case .hardware:     return "cpu.fill"
        case .developer:    return "hammer.fill"
        }
    }

    var gradientColors: (Color, Color) {
        return (Color(hex: 0x3a3a3c), Color(hex: 0x1c1c1e))
    }

    var iconTint: Color {
        switch self {
        case .general:      return Color(hex: 0xa0a0a6)
        case .about:        return Color(hex: 0xff5a3c)
        case .menubar:      return Color(hex: 0x64d2ff)
        case .spacer:       return Color(hex: 0x117cfc)
        case .tiling:       return Color(hex: 0x30d158)
        case .hud:          return Color(hex: 0xbf5af2)
        case .corner:       return Color(hex: 0x5e5ce6)
        case .lidGlass:     return Color(hex: 0x64d2ff)
        case .music:        return Color(hex: 0xff2d55)
        case .dock:         return Color(hex: 0x32d74b)
        case .displaplacer: return Color(hex: 0x0A84FF)
        case .hardware:     return Color(hex: 0x0A84FF)
        case .developer:    return Color(hex: 0x30d158)
        }
    }

    var description: String {
        switch self {
        case .general:      return "Launch, permissions, and app behavior"
        case .about:        return "Version info and acknowledgements"
        case .menubar:      return "Adjust spacing between menu bar icons"
        case .spacer:       return "See your Desktop Spaces in the menu bar"
        case .tiling:       return "Tile windows with a control bar on each display"
        case .hud:          return "Replace the macOS volume and brightness popup"
        case .corner:       return "Round the corners of your displays"
        case .lidGlass:     return "Reveal the desktop with glass as your MacBook opens"
        case .music:        return "See what is playing and control your music"
        case .dock:         return "Preview and switch windows from the Dock or Cmd-Tab"
        case .displaplacer: return "Manage displays, inputs, and saved layouts"
        case .hardware:     return "Choose the system stats you want to see"
        case .developer:    return "Debug tools for development and testing"
        }
    }
}

// MARK: - Color helper

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >>  8) & 0xff) / 255,
            blue:  Double( hex        & 0xff) / 255
        )
    }
}

// MARK: - Shared sub-views

@available(macOS 14.0, *)
struct GradientIcon: View {
    let section: SettingsSection
    var size: CGFloat = 22
    var iconPt: CGFloat = 11
    var radius: CGFloat = 5

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(
                    colors: [section.gradientColors.0, section.gradientColors.1],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: section.icon)
                .font(.system(size: iconPt, weight: .semibold))
                .foregroundStyle(section.iconTint)
        }
        .frame(width: size, height: size)
    }
}

@available(macOS 14.0, *)
struct PaneHeader: View {
    let section: SettingsSection
    var toggle: Binding<Bool>? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: section.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(section.iconTint)
                .frame(width: 40, height: 40)
                .background(section.iconTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold))
                    .kerning(-0.3)
                Text(section.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let toggle {
                Text(toggle.wrappedValue ? "On" : "Off")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Enable \(section.title)", isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }
}

/// A consistent title, explanation and switch for feature settings.
@available(macOS 14.0, *)
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 3)
    }
}

// MARK: - Visual Effect Blur (bridges NSVisualEffectView)

@available(macOS 14.0, *)
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Header height preference

struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Pane container

@available(macOS 14.0, *)
struct PaneContainer<Content: View>: View {
    let section: SettingsSection
    var headerToggle: Binding<Bool>? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(section: section, toggle: headerToggle)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.45)
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListHeaderHeight, 0)
                .contentMargins(.top, 8, for: .scrollContent)
                .controlSize(.regular)
        }
    }
}

// MARK: - Sidebar row

@available(macOS 14.0, *)
private struct SidebarRowView: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Match TokenBar's native glass chrome, including the system wallpaper-tint preference.
@available(macOS 26.0, *)
private struct SettingsGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.cornerRadius = cornerRadius
        view.style = UserDefaults.standard.bool(forKey: "AppleReduceDesktopTinting") ? .clear : .regular
    }
}

// MARK: - Root window

@available(macOS 14.0, *)
struct SettingsWindow: View {
    @StateObject private var vm = SettingsViewModel.shared

    /// Concentric corner math: inner card radius = outer − padding, where the
    /// outer is whatever macOS natively draws for the window (measured at window
    /// creation into `vm.windowCornerRadius`) and the padding is the gutter. We
    /// never draw our own outer corners.
    private let gutter: CGFloat = 8
    private var cardRadius: CGFloat { max(0, vm.windowCornerRadius - gutter) }

    // TokenBar's proportions, with 8pt extra for MSG's longer page titles.
    private let sidebarWidth: CGFloat = 192

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)

            // Floating content card: opaque body tint so the form stays
            // readable, inset by the gutter so the sidebar chrome shows on
            // all four sides.
            pane(for: vm.selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    Color(nsColor: .controlBackgroundColor)
                }
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .inset(by: 0.5)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
                .padding(gutter)
        }
        // Window chrome glass: the behind-window .sidebar material blends with
        // the desktop (Liquid Glass on macOS 26+) and renders opaque under
        // Reduce Transparency. Requires the window to be clear, which the
        // controller sets up.
        .background {
            if #available(macOS 26.0, *) {
                SettingsGlassBackground(cornerRadius: vm.windowCornerRadius)
            } else {
                VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow, state: .active)
                    .overlay(Color.black.opacity(0.10))
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        .tint(.accentColor)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("MSG")
                        .font(.system(size: 15, weight: .bold))
                    Text("Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    sidebarRow(.general)
                    sidebarHeading("Appearance")
                    sidebarRow(.corner)
                    sidebarRow(.lidGlass)
                    sidebarRow(.spacer)
                    sidebarRow(.menubar)
                    sidebarHeading("Controls")
                    sidebarRow(.tiling)
                    sidebarRow(.dock)
                    sidebarRow(.hud)
                    sidebarRow(.music)
                    sidebarHeading("System")
                    sidebarRow(.displaplacer)
                    sidebarRow(.hardware)
                    if vm.showDeveloper {
                        sidebarRow(.developer)
                    }
                }
            }
            .padding(.top, 44)
            .padding([.horizontal, .bottom], 16)
        }
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func sidebarRow(_ s: SettingsSection) -> some View {
        SidebarRowView(section: s, isSelected: vm.selectedSection == s) { vm.selectedSection = s }
    }

    @ViewBuilder
    private func pane(for s: SettingsSection) -> some View {
        switch s {
        case .general:      GeneralPane(vm: vm)
        case .menubar:      MenuBarPane(vm: vm)
        case .spacer:       SpacerPane(vm: vm)
        case .tiling:       TilingPane(vm: vm)
        case .hud:          HUDReplacerPane(vm: vm)
        case .corner:       CornermizerPane(vm: vm)
        case .lidGlass:     LidGlassPane(vm: vm)
        case .music:        MusicPane(vm: vm)
        case .dock:         DockPane(vm: vm)
        case .displaplacer: DisplaplacerPane(vm: vm)
        case .hardware:     HardwarePane(vm: vm)
        case .developer:    DeveloperPane(vm: vm)
        case .about:        GeneralPane(vm: vm)
        }
    }
}
