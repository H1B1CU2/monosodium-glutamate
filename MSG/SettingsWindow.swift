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

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsWindow())
        let darkAppearance = NSAppearance(named: .darkAqua)
        hosting.view.appearance = darkAppearance
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.appearance = darkAppearance
        effect.autoresizingMask = [.width, .height]
        effect.addSubview(hosting.view)
        hosting.view.frame = effect.bounds
        hosting.view.autoresizingMask = [.width, .height]
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentView = effect
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

    var stackMode: StackMode               { get { s.stackMode }            set { s.stackMode = newValue;            objectWillChange.send() } }
    var animationStyle: AnimationStyle     { get { s.animationStyle }       set { s.animationStyle = newValue;       objectWillChange.send() } }
    var focusDetectionMode: FocusDetectionMode { get { s.focusDetectionMode } set { s.focusDetectionMode = newValue; objectWillChange.send() } }
    var displayOrderMode: DisplayOrderMode { get { s.displayOrderMode }     set { s.displayOrderMode = newValue;     objectWillChange.send() } }
    var displayOrder: [Int]                { get { s.displayOrder }         set { s.displayOrder = newValue;         objectWillChange.send() } }
    var musicDisplayMode: MusicDisplayMode { get { s.musicDisplayMode }     set { s.musicDisplayMode = newValue;     objectWillChange.send() } }
    var musicLingerDuration: TimeInterval  { get { s.musicLingerDuration }  set { s.musicLingerDuration = newValue;  objectWillChange.send() } }
    var musicSource: MusicSource            { get { s.musicSource }         set { s.musicSource = newValue;         objectWillChange.send() } }
    var mirrorMainDisplay: Bool            { get { s.mirrorMainDisplay }    set { s.mirrorMainDisplay = newValue;    objectWillChange.send() } }
    var cornerRadius: CGFloat              { get { s.cornerRadius }         set { s.cornerRadius = newValue;         objectWillChange.send() } }
    var topCornersEnabled: Bool            { get { s.topCornersEnabled }    set { s.topCornersEnabled = newValue;    objectWillChange.send() } }
    var bottomCornersEnabled: Bool         { get { s.bottomCornersEnabled } set { s.bottomCornersEnabled = newValue; objectWillChange.send() } }
    var topCornersUnderMenuBar: Bool       { get { s.topCornersUnderMenuBar } set { s.topCornersUnderMenuBar = newValue; objectWillChange.send() } }
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
    var displaplacerEnabled: Bool { get { s.displaplacerEnabled } set { s.displaplacerEnabled = newValue; objectWillChange.send() } }
    var displaplacerPresets: [DisplaplacerPreset] { get { s.displaplacerPresets } set { s.displaplacerPresets = newValue; objectWillChange.send() } }
}

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, about, spacer, corner, music, tray, displaplacer, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:      return "General"
        case .about:        return "About"
        case .spacer:       return "Spacer"
        case .corner:       return "Cornermization"
        case .music:        return "Music Display"
        case .tray:         return "Tray"
        case .displaplacer: return "Displaplacer"
        case .developer:    return "Developer"
        }
    }

    var icon: String {
        switch self {
        case .general:      return "gearshape.fill"
        case .about:        return "info.circle.fill"
        case .spacer:       return "rectangle.split.3x1.fill"
        case .corner:       return "viewfinder"
        case .music:        return "music.note"
        case .tray:         return "pad.header"
        case .displaplacer: return "display.2"
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
        case .spacer:       return Color(hex: 0x117cfc)
        case .corner:       return Color(hex: 0x5e5ce6)
        case .music:        return Color(hex: 0xff2d55)
        case .tray:         return Color(hex: 0xff9500)
        case .displaplacer: return Color(hex: 0x0A84FF)
        case .developer:    return Color(hex: 0x30d158)
        }
    }

    var description: String {
        switch self {
        case .general:      return "Launch, permissions, and app behavior"
        case .about:        return "Version info and acknowledgements"
        case .spacer:       return "Menu bar Deskspace indicator for Mission Control spaces"
        case .corner:       return "Paint black corner masks to match each display's curvature"
        case .music:        return "Menu bar music label with trackpad gesture control"
        case .tray:         return "Floating ⌘⇥ app switcher HUD with pinned apps and Now Playing"
        case .displaplacer: return "Arrange, disconnect, and reconnect displays with saved layout presets"
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
                .contentMargins(.top, headerHeight - 36, for: .scrollContent)
                .padding(.top, -36)
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
                .padding(.horizontal, 20).padding(.vertical, 14)
                .padding(.bottom, 14)
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
                .ignoresSafeArea(.container, edges: .top)
        }
        .onPreferenceChange(HeaderHeightKey.self) { headerHeight = $0 }
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
            Label { Text(section.title) } icon: { GradientIcon(section: section) }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
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
    @State private var selection: SettingsSection = .spacer

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(spacing: 2) {
                    sidebarRow(.general)
                    Color.clear.frame(height: 8)
                    sidebarRow(.corner)
                    sidebarRow(.spacer)
                    sidebarRow(.music)
                    sidebarRow(.tray)
                    sidebarRow(.displaplacer)
                    sidebarRow(.developer)
                }
                .padding(.top, 8)
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
        } detail: {
            pane(for: selection)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        .tint(.accentColor)
    }

    private func sidebarRow(_ s: SettingsSection) -> some View {
        SidebarRowView(section: s, isSelected: selection == s) { selection = s }
    }

    @ViewBuilder
    private func pane(for s: SettingsSection) -> some View {
        switch s {
        case .general:      GeneralPane(vm: vm)
        case .spacer:       SpacerPane(vm: vm)
        case .corner:       CornermizationPane(vm: vm)
        case .music:        MusicPane(vm: vm)
        case .tray:         TrayPane(vm: vm)
        case .displaplacer: DisplaplacerPane(vm: vm)
        case .developer:    DeveloperPane(vm: vm)
        case .about:        GeneralPane(vm: vm)
        }
    }
}
