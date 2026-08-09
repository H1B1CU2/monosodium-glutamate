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
        w.title = ""
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
            if !AppSettings.shared.dockIcon {
                NSApp.setActivationPolicy(.accessory)
            }
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
    }

    var isVisible: Bool { window?.isVisible ?? false }

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
    var musicDisplayMode: MusicDisplayMode { get { s.musicDisplayMode }     set { s.musicDisplayMode = newValue;     objectWillChange.send() } }
    var musicLingerDuration: TimeInterval  { get { s.musicLingerDuration }  set { s.musicLingerDuration = newValue;  objectWillChange.send() } }
    var musicSource: MusicSource            { get { s.musicSource }         set { s.musicSource = newValue;         objectWillChange.send() } }
    var mediaKeyPriorityMusic: Bool         { get { s.mediaKeyPriorityMusic } set { s.mediaKeyPriorityMusic = newValue; objectWillChange.send() } }
    var mirrorMainDisplay: Bool            { get { s.mirrorMainDisplay }    set { s.mirrorMainDisplay = newValue;    objectWillChange.send() } }
    var cornerRadius: CGFloat              { get { s.cornerRadius }         set { s.cornerRadius = newValue;         objectWillChange.send() } }
    var topCornersEnabled: Bool            { get { s.topCornersEnabled }    set { s.topCornersEnabled = newValue;    objectWillChange.send() } }
    var bottomCornersEnabled: Bool         { get { s.bottomCornersEnabled } set { s.bottomCornersEnabled = newValue; objectWillChange.send() } }
    var topCornersUnderMenuBar: Bool       { get { s.topCornersUnderMenuBar } set { s.topCornersUnderMenuBar = newValue; objectWillChange.send() } }
    var topCornersFullscreenOnly: Bool     { get { s.topCornersFullscreenOnly } set { s.topCornersFullscreenOnly = newValue; objectWillChange.send() } }
    var cornerGrowEnabled: Bool            { get { s.cornerGrowEnabled }     set { s.cornerGrowEnabled = newValue;     objectWillChange.send() } }
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
    var trayEnabled: Bool                    { get { s.trayEnabled }          set { s.trayEnabled = newValue;          objectWillChange.send() } }
    var trayDockSync: Bool                   { get { s.trayDockSync }         set { s.trayDockSync = newValue;         objectWillChange.send() } }
    var trayShowNowPlaying: Bool             { get { s.trayShowNowPlaying }   set { s.trayShowNowPlaying = newValue;   objectWillChange.send() } }
    var dockPreviewEnabled: Bool             { get { s.dockPreviewEnabled }   set { s.dockPreviewEnabled = newValue;   objectWillChange.send() } }
    var dockPreviewHoverDelay: TimeInterval  { get { s.dockPreviewHoverDelay } set { s.dockPreviewHoverDelay = newValue; objectWillChange.send() } }
    var dockPreviewThumbHeight: CGFloat      { get { s.dockPreviewThumbHeight } set { s.dockPreviewThumbHeight = newValue; objectWillChange.send() } }
    var dockPreviewOffset: CGFloat           { get { s.dockPreviewOffset } set { s.dockPreviewOffset = newValue; objectWillChange.send() } }
    var displaplacerEnabled: Bool { get { s.displaplacerEnabled } set { s.displaplacerEnabled = newValue; objectWillChange.send() } }
    var displaplacerPresets: [DisplaplacerPreset] { get { s.displaplacerPresets } set { s.displaplacerPresets = newValue; objectWillChange.send() } }
    var menuBarSpacing: Int        { get { s.menuBarSpacing }        set { s.menuBarSpacing = newValue;        objectWillChange.send() } }
    var menuBarSpacingPadding: Int { get { s.menuBarSpacingPadding } set { s.menuBarSpacingPadding = newValue; objectWillChange.send() } }
    var systemHUDEnabled: Bool     { get { s.systemHUDEnabled }     set { s.systemHUDEnabled = newValue;     objectWillChange.send() } }
    var systemHUDVolume: Bool      { get { s.systemHUDVolume }      set { s.systemHUDVolume = newValue;      objectWillChange.send() } }
    var systemHUDBrightness: Bool  { get { s.systemHUDBrightness }  set { s.systemHUDBrightness = newValue;  objectWillChange.send() } }
    var systemHUDPresentationMode: SystemHUDPresentationMode { get { s.systemHUDPresentationMode } set { s.systemHUDPresentationMode = newValue; objectWillChange.send() } }
    var systemHUDDeviceIcons: Bool { get { s.systemHUDDeviceIcons } set { s.systemHUDDeviceIcons = newValue; objectWillChange.send() } }
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
    var hardwareStatsBatteryStyle: String { get { s.hardwareStatsBatteryStyle } set { s.hardwareStatsBatteryStyle = newValue; objectWillChange.send() } }
    var hardwareStatsModuleOrder: [String] { get { s.hardwareStatsModuleOrder } set { s.hardwareStatsModuleOrder = newValue; objectWillChange.send() } }
    var hardwareStatsHiddenCards: [String] { get { s.hardwareStatsHiddenCards } set { s.hardwareStatsHiddenCards = newValue; objectWillChange.send() } }
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
    case general, about, menubar, spacer, hud, corner, music, tray, dock, displaplacer, hardware, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .about:        return "About"
        case .menubar:      return "Spacer"
        case .spacer:       return "Space Indicator"
        case .hud:          return "HUD Replacer"
        case .corner:       return "Cornermizer"
        case .music:        return "Music Display"
        case .tray:         return "Tray"
        case .dock:         return "Dock Previews"
        case .displaplacer: return "Displaplacer"
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
        case .hud:          return "slider.horizontal.3"
        case .corner:       return "viewfinder"
        case .music:        return "music.note"
        case .tray:         return "pad.header"
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
        case .hud:          return Color(hex: 0xbf5af2)
        case .corner:       return Color(hex: 0x5e5ce6)
        case .music:        return Color(hex: 0xff2d55)
        case .tray:         return Color(hex: 0xff9500)
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
        case .menubar:      return "Tighten the spacing and click area around every menu bar icon, system-wide"
        case .spacer:       return "Menu bar Deskspace indicator for Mission Control spaces"
        case .hud:          return "Replace the macOS volume and brightness popup"
        case .corner:       return "Paint black corner masks to match each display's curvature"
        case .music:        return "Menu bar music label with trackpad gesture control"
        case .tray:         return "Floating ⌘⇥ app switcher HUD with pinned apps and Now Playing"
        case .dock:         return "Hover a Dock app to preview its windows, then click to switch"
        case .displaplacer: return "Arrange, disconnect, and reconnect displays with saved layout presets"
        case .hardware:     return "Menu bar CPU, GPU, memory & temperature monitor"
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
            GradientIcon(section: section, size: 44, iconPt: 20, radius: 10)
                .shadow(color: section.gradientColors.1.opacity(0.4), radius: 6, y: 3)
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
                Toggle("", isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
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
    @State private var headerHeight: CGFloat = 68

    var body: some View {
        ZStack(alignment: .top) {
            Form { content }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListHeaderHeight, 0)
                .contentMargins(.top, headerHeight, for: .scrollContent)
                .contentMargins(.top, headerHeight, for: .scrollIndicators)
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear,                location: 0.00),
                        .init(color: .black.opacity(0.25), location: 0.03),
                        .init(color: .black.opacity(0.75), location: 0.07),
                        .init(color: .black,                location: 0.12),
                        .init(color: .black,                location: 1.00),
                    ], startPoint: .top, endPoint: .bottom)
                )
            PaneHeader(section: section, toggle: headerToggle)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HeaderHeightKey.self, value: geo.size.height)
                    }
                )
                .background(
                    VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)
                        .mask(LinearGradient(stops: [
                            .init(color: .black, location: 0.00),
                            .init(color: .black, location: 0.55),
                            .init(color: .black.opacity(0.55), location: 0.80),
                            .init(color: .black.opacity(0.20), location: 0.92),
                            .init(color: .clear, location: 1.00),
                        ], startPoint: .top, endPoint: .bottom))
                )
        }
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
    }
}

// MARK: - Sidebar row

/// Reports each sidebar row's natural (unexpanded) width so the sidebar can
/// size itself to the longest title instead of a hardcoded constant.
private struct SidebarRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@available(macOS 14.0, *)
private struct SidebarRowView: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(section.title) } icon: { GradientIcon(section: section) }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: SidebarRowWidthKey.self, value: geo.size.width)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
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

    /// Sidebar width tracks the longest row (icon + title), measured live via
    /// `SidebarRowWidthKey` — no hardcoded constant to keep in sync with labels.
    @State private var sidebarContentWidth: CGFloat = 0
    private let sidebarRowOuterPadding: CGFloat = 16   // the row's own .horizontal(8) on each side
    private let minSidebarWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar: no background of its own — the root view's glass shows through.
            ScrollView {
                VStack(spacing: 2) {
                    sidebarRow(.general)
                    Color.clear.frame(height: 8)
                    sidebarRow(.corner)
                    sidebarRow(.displaplacer)
                    sidebarRow(.dock)
                    sidebarRow(.hardware)
                    sidebarRow(.hud)
                    sidebarRow(.music)
                    sidebarRow(.spacer)
                    sidebarRow(.menubar)
                    sidebarRow(.tray)
                    if vm.showDeveloper {
                        sidebarRow(.developer)
                    }
                }
                .padding(.top, 44)   // explicit clearance under the traffic lights
            }
            .onPreferenceChange(SidebarRowWidthKey.self) { sidebarContentWidth = $0 }
            .frame(width: max(minSidebarWidth, sidebarContentWidth + sidebarRowOuterPadding))

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
            VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow, state: .active)
                .overlay(Color.black.opacity(0.10))
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        .tint(.accentColor)
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
        case .hud:          HUDReplacerPane(vm: vm)
        case .corner:       CornermizerPane(vm: vm)
        case .music:        MusicPane(vm: vm)
        case .tray:         TrayPane(vm: vm)
        case .dock:         DockPane(vm: vm)
        case .displaplacer: DisplaplacerPane(vm: vm)
        case .hardware:     HardwarePane(vm: vm)
        case .developer:    DeveloperPane(vm: vm)
        case .about:        GeneralPane(vm: vm)
        }
    }
}
