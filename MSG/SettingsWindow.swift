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
}

// MARK: - Sidebar sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, about, spacer, corner, music, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .about:   return "About"
        case .spacer:  return "Spacer"
        case .corner:  return "Cornermization"
        case .music:      return "Music Display"
        case .developer:  return "Developer"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .about:   return "info.circle.fill"
        case .spacer:  return "rectangle.split.3x1.fill"
        case .corner:  return "viewfinder"
        case .music:      return "music.note"
        case .developer:  return "hammer.fill"
        }
    }

    var gradientColors: (Color, Color) {
        return (Color(hex: 0x3a3a3c), Color(hex: 0x1c1c1e))
    }

    var iconTint: Color {
        switch self {
        case .general: return Color(hex: 0xa0a0a6)
        case .about:   return Color(hex: 0xff5a3c)
        case .spacer:  return Color(hex: 0x117cfc)
        case .corner:  return Color(hex: 0x5e5ce6)
        case .music:      return Color(hex: 0xff2d55)
        case .developer:  return Color(hex: 0x30d158)
        }
    }

    var description: String {
        switch self {
        case .general: return "Launch, permissions, and app behavior"
        case .about:   return "Version info and acknowledgements"
        case .spacer:  return "Menu bar Deskspace indicator for Mission Control spaces"
        case .corner:  return "Paint black corner masks to match each display's curvature"
        case .music:      return "Menu bar music label with trackpad gesture control"
        case .developer:  return "Debug tools for development and testing"
        }
    }
}

// MARK: - Color helper

extension Color {
    static let appAccent = Color(red: 0/255, green: 89/255, blue: 209/255)

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
            PaneHeader(section: section)
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

// MARK: - Root window

@available(macOS 14.0, *)
struct SettingsWindow: View {
    @StateObject private var vm = SettingsViewModel.shared
    @State private var selection: SettingsSection = .spacer

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section { sidebarRow(.general) }
                Section { sidebarRow(.corner); sidebarRow(.spacer); sidebarRow(.music); sidebarRow(.developer) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
        } detail: {
            pane(for: selection)
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private func sidebarRow(_ s: SettingsSection) -> some View {
        Label {
            Text(s.title)
        } icon: {
            GradientIcon(section: s)
        }
        .tag(s)
    }

    @ViewBuilder
    private func pane(for s: SettingsSection) -> some View {
        switch s {
        case .general: GeneralPane(vm: vm)
        case .spacer:  SpacerPane(vm: vm)
        case .corner:  CornermizationPane(vm: vm)
        case .music:   MusicPane(vm: vm)
        case .developer: DeveloperPane(vm: vm)
        case .about:   GeneralPane(vm: vm)
        }
    }
}

// MARK: - Corner Preview

@available(macOS 14.0, *)
struct CornerPreviewView: View {
    let radius: CGFloat
    let topEnabled: Bool
    let bottomEnabled: Bool
    let underBar: Bool
    var wallpaperImage: NSImage? = nil

    var body: some View {
        DisplayPreviewView(
            stackMode: .inline,
            spaceCount: 4, activeSpace: 2,
            showMusic: false, screenCount: 1,
            cornerRadius: radius,
            topCornersEnabled: topEnabled,
            bottomCornersEnabled: bottomEnabled,
            underMenuBar: underBar,
            wallpaperImage: wallpaperImage
        )
    }
}

// MARK: - Music Preview

@available(macOS 14.0, *)
struct MusicPreviewView: View {
    let mode: MusicDisplayMode
    var wallpaperImage: NSImage? = nil

    var body: some View {
        DisplayPreviewView(
            stackMode: .inline,
            spaceCount: 4, activeSpace: 2,
            showMusic: mode != .off, screenCount: 1,
            fixedHeight: 80,
            wallpaperImage: wallpaperImage
        )
    }
}

struct TrackpadPreview: View {
    @State private var fingerX: CGFloat = -20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(hex: 0xf3f3f5), Color(hex: 0xe2e2e6)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            ForEach([-4, 6], id: \.self) { dy in
                Circle()
                    .fill(Color.appAccent)
                    .frame(width: 9, height: 9)
                    .shadow(color: Color.appAccent.opacity(0.3), radius: 4)
                    .offset(x: fingerX, y: CGFloat(dy))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { fingerX = 20 }
        }
    }
}

// MARK: - Spacer Preview Scene (top-right crop, mirrors MusicPopoverScene)

@available(macOS 14.0, *)
struct SpacerPreviewScene: View {
    let stackMode: StackMode
    let screenCount: Int
    var wallpaperImage: NSImage? = nil
    @State private var activeSpace: Int = 2
    private let spaceCount = 5
    private let menuBarHeight: CGFloat = 30
    private let trailingPad: CGFloat = 16

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Color.clear
            .aspectRatio(screenRatio, contentMode: .fit)
            .overlay(sceneContent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                activeSpace = activeSpace >= spaceCount ? 1 : activeSpace + 1
            }
    }

    private var sceneContent: some View {
        ZStack(alignment: .topTrailing) {
            if let wp = wallpaperImage {
                Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(2.0, anchor: .topTrailing)
            } else {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x5b8def), location: 0),
                        .init(color: Color(hex: 0x8a6df3), location: 0.5),
                        .init(color: Color(hex: 0xd660b4), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    PreviewSpaceIndicator(
                        stackMode: stackMode,
                        spaceCount: spaceCount, activeSpace: activeSpace,
                        screenCount: screenCount,
                        scale: 2.0
                    )
                    Image(systemName: "switch.2")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.85))
                    Text("10:00")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.85))
                }
                .padding(.horizontal, trailingPad)
                .frame(height: menuBarHeight)
                .background(Color.white.opacity(0.65))
                Spacer()
            }
        }
    }
}

// MARK: - Music Popover Preview

@available(macOS 14.0, *)
struct MusicPopoverPreview: View {
    // Proportions mirror MusicPopover.swift: 208×220 popover, 160×160 touchpad,
    // 20pt volume bar column with 6pt track, 30pt corner radius.
    var width: CGFloat = 208
    private var refW: CGFloat { 208 }
    private var refH: CGFloat { 220 }
    private var s: CGFloat { width / refW }
    private var height: CGFloat { refH * s }
    private var inset: CGFloat { 12 * s }
    private var touchpadSize: CGFloat { 160 * s }
    private var volColW: CGFloat { 20 * s }
    private var volBarHeight: CGFloat { 140 * s }
    private var trackW: CGFloat { 6 * s }
    private var cornerR: CGFloat { 30 * s }
    private var touchpadCornerR: CGFloat { 20 * s }
    private var volumeLevel: CGFloat { 0.62 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 4 * s) {
                touchpad
                volumeColumn
                    .padding(.leading, 4)
            }
            .padding(.leading, inset)
            .padding(.top, inset)

            VStack(alignment: .leading, spacing: 2 * s) {
                Text("Miss Summer")
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(.white)
                Text("temp.")
                    .font(.system(size: 11 * s))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.leading, 26 * s)
            .padding(.top, inset + touchpadSize + 6 * s)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow)
                Color.black.opacity(0.08)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerR))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerR).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var touchpad: some View {
        RoundedRectangle(cornerRadius: touchpadCornerR)
            .fill(Color.white.opacity(0.06))
            .overlay(
                Canvas { ctx, size in
                    let dot = Color.white.opacity(0.10)
                    let padInset: CGFloat = 24 * s
                    let rows = 8
                    let vSpacing = (size.height - 2 * padInset) / CGFloat(rows - 1)
                    let cols = max(8, Int((size.width - 2 * padInset) / vSpacing + 0.5))
                    let spacing = min((size.width - 2 * padInset) / CGFloat(cols - 1), vSpacing)
                    let gridW = spacing * CGFloat(cols - 1)
                    let gridH = spacing * CGFloat(rows - 1)
                    let offsetX = (size.width - gridW) / 2
                    let offsetY = (size.height - gridH) / 2
                    let r: CGFloat = 1.0 * s
                    for row in 0..<rows {
                        for col in 0..<cols {
                            let x = offsetX + CGFloat(col) * spacing
                            let y = offsetY + CGFloat(row) * spacing
                            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                            ctx.fill(Path(ellipseIn: rect), with: .color(dot))
                        }
                    }
                }
            )
            .frame(width: touchpadSize, height: touchpadSize)
    }

    private var volumeColumn: some View {
        ZStack(alignment: .top) {
            // Track + fill stack
            HStack(spacing: 7 * s) {
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: trackW)
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: trackW, height: max(trackW, volBarHeight * volumeLevel - 8 * s))
                }
                .frame(height: volBarHeight - 8 * s)
                .padding(.vertical, 4 * s)

                // Indicator dots
                VStack(spacing: 16 * s - 2 * s) {
                    ForEach(0..<8) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 2 * s, height: 2 * s)
                    }
                }
                .padding(.top, 6 * s)
            }
        }
        .frame(width: volColW, height: volBarHeight, alignment: .top)
        .padding(.top, 10 * s)
    }
}

// Downward-pointing notch connecting menu bar label to popover
struct DownNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

@available(macOS 14.0, *)
struct MusicPopoverScene: View {
    var wallpaperImage: NSImage? = nil
    private let popoverWidth: CGFloat = 200
    private let menuBarHeight: CGFloat = 30
    private let trailingPad: CGFloat = 16

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Color.clear
            .aspectRatio(screenRatio, contentMode: .fit)
            .overlay(sceneContent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private var sceneContent: some View {
        ZStack(alignment: .topTrailing) {
            if let wp = wallpaperImage {
                Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(2.0, anchor: .topTrailing)
            } else {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x5b8def), location: 0),
                        .init(color: Color(hex: 0x8a6df3), location: 0.5),
                        .init(color: Color(hex: 0xd660b4), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }

            // Minimal right-edge menu bar slice (music label + control center + time)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    musicLabel
                    Image(systemName: "switch.2")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.85))
                    Text("10:00")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.85))
                }
                .padding(.horizontal, trailingPad)
                .frame(height: menuBarHeight)
                .background(Color.white.opacity(0.65))
                Spacer()
            }

            // Popover anchored under the music label
            popoverAnimatedView
            .padding(.top, menuBarHeight + 6)
            .padding(.trailing, 78)
        }
    }

    private var musicLabel: some View {
        HStack(spacing: 6) {
            Text("Miss Summer — temp.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.black.opacity(0.85))
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.65))
                            .frame(width: 2, height: barH(i, at: t))
                    }
                }
            }
        }
    }

    private func barH(_ i: Int, at t: TimeInterval) -> CGFloat {
        let offsets: [CGFloat] = [0, 0.4, 0.9, 1.3]
        let phase = t * 2 * .pi / 1.2
        let h = sin(phase + offsets[i]) * 0.5 + 0.5
        return 5 + h * 8
    }

    private var popoverAnimatedView: some View {
        TimelineView(.animation) { timeline in
            MusicPopoverPreview(width: popoverWidth)
                .opacity(popoverAnim(at: timeline.date).opacity)
                .offset(x: 20, y: popoverAnim(at: timeline.date).offsetY)
        }
    }

    private func popoverAnim(at date: Date) -> (opacity: Double, offsetY: CGFloat) {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 10.0)
        let appearing = cycle < 0.35
        let opacity: Double = appearing ? cycle / 0.35 : 1.0
        let offsetY: CGFloat = appearing ? CGFloat((1.0 - cycle / 0.35) * 10.0) : 0
        return (opacity, offsetY)
    }
}

// MARK: - Display Preview (16:10 simulated screen)

@available(macOS 14.0, *)
struct DisplayPreviewView: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let showMusic: Bool
    let screenCount: Int
    var cornerRadius: CGFloat = 0
    var topCornersEnabled: Bool = false
    var bottomCornersEnabled: Bool = false
    var underMenuBar: Bool = false
    var fixedHeight: CGFloat? = nil
    var wallpaperImage: NSImage? = nil

    private let menuBarH: CGFloat = 20

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Group {
            if let h = fixedHeight {
                Color.clear.frame(height: h).aspectRatio(screenRatio, contentMode: .fill)
            } else {
                Color.clear.aspectRatio(screenRatio, contentMode: .fit)
            }
        }
        .overlay(displayContent)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private var displayContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let wp = wallpaperImage {
                    Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x5b8def), location: 0),
                            .init(color: Color(hex: 0x8a6df3), location: 0.5),
                            .init(color: Color(hex: 0xd660b4), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }

                VStack(spacing: 0) {
                    PreviewMenuBar(
                        stackMode: stackMode,
                        spaceCount: spaceCount, activeSpace: activeSpace,
                        showMusic: showMusic, screenCount: screenCount
                    )
                    Spacer()
                }

                if cornerRadius > 0 {
                    Canvas { ctx, _ in drawCorners(ctx: &ctx, size: geo.size) }
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    private func drawCorners(ctx: inout GraphicsContext, size: CGSize) {
        let r = cornerRadius, c = Color.black.opacity(0.65), ty = underMenuBar ? menuBarH : CGFloat(0)

        func pie(_ path: inout Path, _ p: CGPoint, _ dx: CGFloat, _ center: CGPoint, _ start: Double, _ delta: Double) {
            path.move(to: p)
            path.addLine(to: CGPoint(x: p.x + dx, y: p.y))
            path.addRelativeArc(center: center, radius: r, startAngle: .degrees(start), delta: .degrees(delta))
            path.closeSubpath()
        }

        if topCornersEnabled {
            var tl = Path(); pie(&tl, CGPoint(x: 0, y: ty), r, CGPoint(x: r, y: ty + r), 270, -90)
            ctx.fill(tl, with: .color(c))
            var tr = Path(); pie(&tr, CGPoint(x: size.width, y: ty), -r, CGPoint(x: size.width - r, y: ty + r), 270, 90)
            ctx.fill(tr, with: .color(c))
        }
        if bottomCornersEnabled {
            var bl = Path(); pie(&bl, CGPoint(x: 0, y: size.height), r, CGPoint(x: r, y: size.height - r), 90, 90)
            ctx.fill(bl, with: .color(c))
            var br = Path(); pie(&br, CGPoint(x: size.width, y: size.height), -r, CGPoint(x: size.width - r, y: size.height - r), 90, -90)
            ctx.fill(br, with: .color(c))
        }
    }
}

// MARK: - Preview sub-views

struct PreviewMenuBar: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let showMusic: Bool
    let screenCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 7, weight: .medium))
            Text("Finder").font(.system(size: 8, weight: .semibold))
            Text("File").font(.system(size: 8)).opacity(0.75)
            Text("Edit").font(.system(size: 8)).opacity(0.75)
            Text("View").font(.system(size: 8)).opacity(0.75)
            Spacer()
            PreviewSpaceIndicator(stackMode: stackMode,
                                  spaceCount: spaceCount, activeSpace: activeSpace, screenCount: screenCount)
            if showMusic { PreviewMusicPill() }
            Image(systemName: "switch.2")
                .font(.system(size: 9))
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 8))
            }
            Spacer().frame(width: 4)
        }
        .foregroundColor(Color.black.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Color.white.opacity(0.65))
    }
}

// Real renderer constants from IndicatorRenderer.swift, scaled for 20pt preview menu bar.
struct PillDotsDims {
    let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat
    static func pill(compact: Bool) -> PillDotsDims {
        compact ? .init(dotD: 2, pillW: 9, pillH: 2, sp: 2, rowH: 4)
                : .init(dotD: 3, pillW: 14, pillH: 5, sp: 3, rowH: 11)
    }
    func naturalWidth(spaceCount: Int) -> CGFloat {
        CGFloat(spaceCount) * dotD + max(0, CGFloat(spaceCount - 1)) * sp + (pillW - dotD)
    }
    func scaled(_ s: CGFloat) -> PillDotsDims {
        .init(dotD: dotD*s, pillW: pillW*s, pillH: pillH*s, sp: sp*s, rowH: rowH*s)
    }
}

struct PreviewSpaceIndicator: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let screenCount: Int
    var scale: CGFloat = 1.0

    private var stacked: Bool {
        screenCount > 1
            && (stackMode == .stack || stackMode == .dynamic)
    }

    var body: some View {
        pillBody
    }

    @ViewBuilder
    private var pillBody: some View {
        let compact = stacked
        let dims = PillDotsDims.pill(compact: compact).scaled(scale)
        let rowCounts: [Int] = screenCount > 1 ? [spaceCount, max(1, spaceCount - 1)] : [spaceCount]

        if stacked {
            // Equal-length stacked rows — matches real renderer's rowStretch behavior.
            let widest = rowCounts.map { dims.naturalWidth(spaceCount: $0) }.max() ?? 0
            VStack(spacing: 1 * scale) {
                ForEach(0..<rowCounts.count, id: \.self) { i in
                    AnimatedPillDotsRow(
                        spaceCount: rowCounts[i],
                        activeSpace: i == 0 ? activeSpace : 1,
                        dims: dims,
                        dimmed: i != 0,
                        stretchToWidth: widest
                    )
                }
            }
        } else if rowCounts.count > 1 {
            // Inline multi-display: side-by-side rows with a separator capsule.
            HStack(spacing: 0) {
                ForEach(0..<rowCounts.count, id: \.self) { i in
                    if i > 0 {
                        Capsule()
                            .fill(Color.black.opacity(0.40))
                            .frame(width: 1.5 * scale, height: 8 * scale)
                            .padding(.horizontal, 8 * scale)
                    }
                    AnimatedPillDotsRow(
                        spaceCount: rowCounts[i],
                        activeSpace: i == 0 ? activeSpace : 1,
                        dims: dims,
                        dimmed: false
                    )
                }
            }
        } else {
            AnimatedPillDotsRow(
                spaceCount: spaceCount, activeSpace: activeSpace,
                dims: dims, dimmed: false
            )
        }
    }
}

// TimelineView-driven row that interpolates fractional active-pill position to match
// IndicatorRenderer's widthForSpace / heightForSpace / colorForSpace math.
struct AnimatedPillDotsRow: View {
    let spaceCount: Int
    let activeSpace: Int
    let dims: PillDotsDims
    let dimmed: Bool
    var stretchToWidth: CGFloat? = nil

    @State private var fromActive: Int = 1
    @State private var toActive: Int = 1
    @State private var transitionStart: Date = Date()

    private var renderWidth: CGFloat {
        max(dims.naturalWidth(spaceCount: spaceCount), stretchToWidth ?? 0)
    }
    private var rowStretch: CGFloat {
        max(0, (stretchToWidth ?? 0) - dims.naturalWidth(spaceCount: spaceCount))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let frac = fractionalActive(at: timeline.date)
            Canvas { ctx, _ in draw(ctx: &ctx, frac: frac) }
                .frame(width: renderWidth, height: dims.rowH)
        }
        .onAppear { fromActive = activeSpace; toActive = activeSpace }
        .onChange(of: activeSpace) { newValue in
            let snapshot = fractionalActive(at: Date())
            fromActive = max(1, min(spaceCount, Int(round(snapshot))))
            toActive = newValue
            transitionStart = Date()
        }
    }

    private func fractionalActive(at date: Date) -> CGFloat {
        if fromActive == toActive { return CGFloat(toActive) }
        let elapsed = date.timeIntervalSince(transitionStart)
        let duration: Double = 0.5
        let raw = max(0, min(1, CGFloat(elapsed / duration)))
        let eased = applyEasing(raw)
        return CGFloat(fromActive) + CGFloat(toActive - fromActive) * eased
    }

    private func draw(ctx: inout GraphicsContext, frac: CGFloat) {
        let clamped = max(1.0, min(CGFloat(spaceCount), frac))
        let pL = floor(clamped), pH = ceil(clamped)
        let f = clamped - pL

        func widthFor(_ i: Int) -> CGFloat {
            let iF = CGFloat(i)
            if pL == pH { return iF == pL ? (dims.pillW + rowStretch) : dims.dotD }
            if iF == pL { return dims.dotD + (dims.pillW + rowStretch - dims.dotD) * (1 - f) }
            if iF == pH { return dims.dotD + (dims.pillW + rowStretch - dims.dotD) * f }
            return dims.dotD
        }
        func heightFor(_ i: Int) -> CGFloat {
            let iF = CGFloat(i)
            if pL == pH { return iF == pL ? dims.pillH : dims.dotD }
            if iF == pL { return dims.dotD + (dims.pillH - dims.dotD) * (1 - f) }
            if iF == pH { return dims.dotD + (dims.pillH - dims.dotD) * f }
            return dims.dotD
        }
        func colorFor(_ i: Int) -> Color {
            let iF = CGFloat(i)
            let alpha: CGFloat
            if pL == pH { alpha = iF == pL ? 1 : 0 }
            else if iF == pL { alpha = 1 - f }
            else if iF == pH { alpha = f }
            else { alpha = 0 }
            return blendBlack(weight: alpha, dimmed: dimmed)
        }

        var x: CGFloat = 0
        for i in 1...spaceCount {
            let w = widthFor(i)
            let h = heightFor(i)
            let y = (dims.rowH - h) / 2
            let rect = CGRect(x: x, y: y, width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerSize: CGSize(width: h/2, height: h/2)),
                     with: .color(colorFor(i)))
            x += w
            if i < spaceCount { x += dims.sp }
        }
    }
}

// MARK: - Animation helpers (mirroring Indicator.swift + IndicatorRenderer.swift constants)

private func applyEasing(_ t: CGFloat) -> CGFloat {
    let c = max(0, min(1, t))
    return 1 - pow(1 - c, 4)  // Easing.outQuart
}

private func blendBlack(weight: CGFloat, dimmed: Bool) -> Color {
    let a = 0.40 + 0.45 * max(0, min(1, weight))
    return Color.black.opacity(a * (dimmed ? 0.55 : 1.0))
}

struct PreviewMusicPill: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Miss Summer — temp.")
                .font(.system(size: 8))
                .foregroundColor(Color.black.opacity(0.85))
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 1) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 1.5, height: barHeight(i, at: t))
                    }
                }
            }
        }
    }

    private func barHeight(_ i: Int, at t: TimeInterval) -> CGFloat {
        let offsets: [CGFloat] = [0, 0.4, 0.9, 1.3]
        let phase = t * 2 * .pi / 1.2
        let h = sin(phase + offsets[i]) * 0.5 + 0.5
        return 2 + h * 4
    }
}

// MARK: - Spacer pane

@available(macOS 14.0, *)
struct SpacerPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var previewWallpaper: NSImage? = nil

    private var effectiveScreenCount: Int { screens.count + vm.fakeDisplays.count }
    private var stackVisible: Bool { effectiveScreenCount > 1 }
    var body: some View {
        PaneContainer(section: .spacer) {
            Section("Preview") {
                SpacerPreviewScene(
                    stackMode: vm.stackMode,
                    screenCount: effectiveScreenCount,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("Indicator") {
                Picker("Animation", selection: Binding(get: { vm.animationStyle }, set: { vm.animationStyle = $0 })) {
                    ForEach(AnimationStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if stackVisible {
                    Picker("Stack Mode", selection: Binding(get: { vm.stackMode }, set: { vm.stackMode = $0 })) {
                        ForEach(StackMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }

            Section("Behavior") {
                Picker("Focus Detection", selection: Binding(get: { vm.focusDetectionMode }, set: { vm.focusDetectionMode = $0 })) {
                    ForEach(FocusDetectionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Display Order", selection: Binding(get: { vm.displayOrderMode }, set: { vm.displayOrderMode = $0 })) {
                    ForEach(DisplayOrderMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }

        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                previewWallpaper = WallpaperEngine.shared.baselineImage(for: screen)
                    ?? NSWorkspace.shared.desktopImageURL(for: screen).flatMap {
                        WallpaperEngine.loadImage(url: $0).map { NSImage(cgImage: $0, size: .zero) }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

// MARK: - Cornermization pane

@available(macOS 14.0, *)
struct CornermizationPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var lastHaptic: Int = -1
    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var hasPendingChanges = false
    @State private var externalChangeDetected = false
    @State private var previewWallpaper: NSImage? = nil

    private var externals: [NSScreen] {
        screens.filter { !$0.isBuiltin }
    }
    private var hasExternals: Bool { !externals.isEmpty }
    private var radiusVisible: Bool { vm.topCornersEnabled || vm.bottomCornersEnabled }

    var body: some View {
        PaneContainer(section: .corner) {
            Section("Preview") {
                CornerPreviewView(
                    radius: vm.cornerRadius,
                    topEnabled: vm.topCornersEnabled,
                    bottomEnabled: vm.bottomCornersEnabled,
                    underBar: vm.topCornersUnderMenuBar,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)

                statusCard
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }

            Section(swCachedModelName()) {
                if hasExternals {
                    Toggle("Apply to all displays",
                           isOn: bind({ vm.mirrorMainDisplay }, { vm.mirrorMainDisplay = $0 }))
                }
                Toggle("Top Corners",
                       isOn: bind({ vm.topCornersEnabled }, { vm.topCornersEnabled = $0 }))
                if vm.topCornersEnabled {
                    Picker("Position", selection: bind({ vm.topCornersUnderMenuBar },
                                                       { vm.topCornersUnderMenuBar = $0 })) {
                        Text("At Screen Edge").tag(false)
                        Text("Below Menu Bar").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Bottom Corners",
                       isOn: bind({ vm.bottomCornersEnabled }, { vm.bottomCornersEnabled = $0 }))
                if radiusVisible {
                    radiusSlider(value: bind({ Double(vm.cornerRadius) },
                                             { vm.cornerRadius = CGFloat($0) }))
                }
            }

            ForEach(externals, id: \.self) { screen in
                if let uuid = swScreenUUID(screen) {
                    let pos = screens.first.map { swDisplayPosition(for: screen, relativeTo: $0) } ?? ""
                    let label = pos.isEmpty ? screen.localizedName : "\(screen.localizedName) (\(pos))"
                    Section(label) {
                        externalControls(uuid: uuid, vm: vm)
                            .disabled(vm.mirrorMainDisplay)
                            .opacity(vm.mirrorMainDisplay ? 0.4 : 1)
                            .animation(.easeInOut(duration: 0.2), value: vm.mirrorMainDisplay)
                    }
                }
            }
        }
        .onAppear {
            externalChangeDetected = WallpaperEngine.shared.externalChangePending
            loadPreviewWallpaper()
            // Only revert to the clean baseline for preview when there is no
            // unresolved external wallpaper change. If the user changed their
            // wallpaper we must NOT overwrite it with the old baseline.
            if !WallpaperEngine.shared.externalChangePending {
                WallpaperEngine.shared.showBaseline()
            }
            if !WallpaperEngine.shared.isFetched {
                WallpaperEngine.shared.fetch()
                loadPreviewWallpaper()
            }
            WallpaperEngine.shared.onExternalChange = {
                externalChangeDetected = true
            }
        }
        .onDisappear {
            if hasPendingChanges && !WallpaperEngine.shared.externalChangePending {
                WallpaperEngine.shared.bake()
            } else if !WallpaperEngine.shared.externalChangePending {
                // showBaseline() was called on appear; put the baked wallpaper back.
                WallpaperEngine.shared.restoreBakedWallpaper()
            }
            hasPendingChanges = false
            WallpaperEngine.shared.onExternalChange = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { newValue in
            set(newValue)
            // Defer @State mutation to the next run-loop tick so it doesn't
            // publish in the same cycle as objectWillChange from the vm setter.
            DispatchQueue.main.async {
                if !hasPendingChanges && !WallpaperEngine.shared.externalChangePending {
                    WallpaperEngine.shared.showBaseline()
                }
                hasPendingChanges = true
            }
        })
    }

    // MARK: - Status card

    @ViewBuilder
    private var statusCard: some View {
        if externalChangeDetected {
            // Wallpaper was changed in System Settings while the pane was open.
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wallpaper changed")
                    Text("Update the snapshot to keep your corner settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update") {
                    WallpaperEngine.shared.fetch()   // clears externalChangePending
                    loadPreviewWallpaper()
                    WallpaperEngine.shared.bake()
                    externalChangeDetected = false
                    hasPendingChanges = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        } else if hasPendingChanges {
            // Settings changed, not yet baked into the wallpaper.
            HStack(spacing: 10) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes not applied")
                    Text("Apply to save your corner settings to the wallpaper")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply") {
                    if !WallpaperEngine.shared.isFetched {
                        WallpaperEngine.shared.fetch()
                        loadPreviewWallpaper()
                    }
                    WallpaperEngine.shared.bake()
                    hasPendingChanges = false
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !WallpaperEngine.shared.isFetched {
            // Auto-fetch failed (edge case). Show manual fallback.
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapshot needed")
                    Text("Snapshot your wallpaper so corners can be baked into it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Snapshot") {
                    WallpaperEngine.shared.fetch()
                    loadPreviewWallpaper()
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            // Everything is in sync.
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Corners applied")
                    Text("Your corner settings are baked into the wallpaper")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Re-snapshot") {
                    WallpaperEngine.shared.fetch()
                    loadPreviewWallpaper()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func loadPreviewWallpaper() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        previewWallpaper = WallpaperEngine.shared.baselineImage(for: screen)
            ?? NSWorkspace.shared.desktopImageURL(for: screen).flatMap {
                WallpaperEngine.loadImage(url: $0).map { NSImage(cgImage: $0, size: .zero) }
            }
    }

    @ViewBuilder
    private func externalControls(uuid: String, vm: SettingsViewModel) -> some View {
        Toggle("Top Corners", isOn: bind(
            { AppSettings.shared.extTopCornersEnabled(for: uuid) },
            { AppSettings.shared.setExtTopCornersEnabled($0, for: uuid); vm.objectWillChange.send() }
        ))
        if AppSettings.shared.extTopCornersEnabled(for: uuid) {
            Picker("Position", selection: bind(
                { AppSettings.shared.extTopCornersUnderMenuBar(for: uuid) },
                { AppSettings.shared.setExtTopCornersUnderMenuBar($0, for: uuid); vm.objectWillChange.send() }
            )) {
                Text("At Screen Edge").tag(false)
                Text("Below Menu Bar").tag(true)
            }
            .pickerStyle(.segmented)
        }
        Toggle("Bottom Corners", isOn: bind(
            { AppSettings.shared.extBottomCornersEnabled(for: uuid) },
            { AppSettings.shared.setExtBottomCornersEnabled($0, for: uuid); vm.objectWillChange.send() }
        ))
        if AppSettings.shared.extTopCornersEnabled(for: uuid) || AppSettings.shared.extBottomCornersEnabled(for: uuid) {
            radiusSlider(value: bind(
                { Double(AppSettings.shared.extCornerRadius(for: uuid)) },
                { AppSettings.shared.setExtCornerRadius(CGFloat($0), for: uuid); vm.objectWillChange.send() }
            ))
        }
    }

    @ViewBuilder
    private func radiusSlider(value: Binding<Double>) -> some View {
        HStack {
            Text("Radius")
            Slider(value: value, in: 0...30, step: 1)
                .onChange(of: value.wrappedValue) { newVal in
                    let i = Int(newVal)
                    if i != lastHaptic {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        lastHaptic = i
                    }
                }
            Text("\(Int(value.wrappedValue)) px")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Music pane

@available(macOS 14.0, *)
struct MusicPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var lastHaptic: Int = -1
    @State private var previewWallpaper: NSImage? = nil

    var body: some View {
        PaneContainer(section: .music) {
            Section("Preview") {
                MusicPopoverScene(wallpaperImage: previewWallpaper)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)

                HStack(spacing: 14) {
                    TrackpadPreview()
                                                .frame(width: 90, height: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Trackpad gestures")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Swipe left/right to skip · vertical to adjust volume · tap to play/pause")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            Section {
                Picker("Source", selection: Binding(
                    get: { vm.musicSource },
                    set: { vm.musicSource = $0 }
                )) {
                    ForEach(MusicSource.allCases, id: \.self) { source in
                        Text(source.displayLabel).tag(source).disabled(!source.isAvailable)
                    }
                }
            }

            Section {
                Picker("Mode", selection: Binding(
                    get: { vm.musicDisplayMode },
                    set: { vm.musicDisplayMode = $0 }
                )) {
                    ForEach(MusicDisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                HStack {
                    Text("Linger after pause")
                    Slider(value: Binding(
                        get: { vm.musicLingerDuration },
                        set: { vm.musicLingerDuration = $0 }
                    ), in: 0...60)
                    .onChange(of: vm.musicLingerDuration) { newVal in
                        let i = Int(newVal)
                        if i != lastHaptic {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            lastHaptic = i
                        }
                    }
                    .disabled(vm.musicDisplayMode != .dynamic)
                    Text("\(Int(vm.musicLingerDuration))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .opacity(vm.musicDisplayMode != .dynamic ? 0.45 : 1)
                .animation(.easeInOut(duration: 0.15), value: vm.musicDisplayMode)
            }
        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                previewWallpaper = WallpaperEngine.shared.baselineImage(for: screen)
                    ?? NSWorkspace.shared.desktopImageURL(for: screen).flatMap {
                        WallpaperEngine.loadImage(url: $0).map { NSImage(cgImage: $0, size: .zero) }
                    }
            }
        }
    }
}

// MARK: - Arrange Displays View

@available(macOS 14.0, *)
struct ArrangeDisplaysView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var realScreens: [NSScreen] = NSScreen.screens
    @State private var draggingID: UUID? = nil
    @State private var dragStartArrange: CGPoint = .zero

    private let canvasH: CGFloat = 200
    private let snapRadius: CGFloat = 14

    // Stable tile identity: real screens use their CGDirectDisplayID,
    // fake displays use their stored UUID. Avoids new UUID() on every render.
    private enum TileID: Hashable {
        case real(UInt32)
        case fake(UUID)
    }

    private struct Tile {
        let id: TileID
        let name: String
        let isMain: Bool
        let isReal: Bool
        let cx: CGFloat   // center in canvas coords
        let cy: CGFloat
        let w: CGFloat
        let h: CGFloat
        var fakeUUID: UUID? {
            if case .fake(let u) = id { return u }
            return nil
        }
    }

    // MARK: Layout

    private struct LayoutParams {
        let scale: CGFloat
        let canvasCX: CGFloat
        let canvasCY: CGFloat
        let screenCX: CGFloat
        let screenCY: CGFloat
        let fakeW: CGFloat
        let fakeH: CGFloat
    }

    private func layoutParams(canvasSize: CGSize) -> LayoutParams? {
        guard !realScreens.isEmpty else { return nil }
        let allX = realScreens.flatMap { [$0.frame.minX, $0.frame.maxX] }
        let allY = realScreens.flatMap { [$0.frame.minY, $0.frame.maxY] }
        guard let sMinX = allX.min(), let sMaxX = allX.max(),
              let sMinY = allY.min(), let sMaxY = allY.max() else { return nil }
        let padX: CGFloat = 60, padY: CGFloat = 40
        let scaleX = (canvasSize.width - padX * 2) / max(1, sMaxX - sMinX)
        let scaleY = (canvasH - padY * 2) / max(1, sMaxY - sMinY)
        let scale = min(scaleX, scaleY)
        let main = realScreens[0]
        let aspect = main.frame.width / max(1, main.frame.height)
        let fakeW = max(80, min(main.frame.width * scale * 0.75, 130))
        return LayoutParams(
            scale: scale,
            canvasCX: canvasSize.width / 2,
            canvasCY: canvasH / 2,
            screenCX: (sMinX + sMaxX) / 2,
            screenCY: (sMinY + sMaxY) / 2,
            fakeW: fakeW,
            fakeH: fakeW / aspect
        )
    }

    private func buildTiles(canvasSize: CGSize) -> [Tile] {
        guard let lp = layoutParams(canvasSize: canvasSize) else {
            return vm.fakeDisplays.map { fd in
                Tile(id: .fake(fd.id), name: fd.name, isMain: false, isReal: false,
                     cx: canvasSize.width / 2 + fd.arrangeX,
                     cy: canvasH / 2 + fd.arrangeY, w: 100, h: 62)
            }
        }
        var tiles: [Tile] = []
        for screen in realScreens {
            let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            tiles.append(Tile(
                id: .real(dID), name: screen.localizedName,
                isMain: screen == NSScreen.main, isReal: true,
                cx: lp.canvasCX + (screen.frame.midX - lp.screenCX) * lp.scale,
                cy: lp.canvasCY - (screen.frame.midY - lp.screenCY) * lp.scale,
                w: screen.frame.width * lp.scale,
                h: screen.frame.height * lp.scale
            ))
        }
        for fd in vm.fakeDisplays {
            tiles.append(Tile(
                id: .fake(fd.id), name: fd.name, isMain: false, isReal: false,
                cx: lp.canvasCX + fd.arrangeX,
                cy: lp.canvasCY + fd.arrangeY,
                w: lp.fakeW, h: lp.fakeH
            ))
        }
        return tiles
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let tiles = buildTiles(canvasSize: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

                ForEach(tiles, id: \.id) { tile in
                    tileView(tile)
                        .position(x: tile.cx, y: tile.cy)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    guard let fakeID = tile.fakeUUID else { return }
                                    if draggingID == nil {
                                        draggingID = fakeID
                                        if let fd = vm.fakeDisplays.first(where: { $0.id == fakeID }) {
                                            dragStartArrange = CGPoint(x: fd.arrangeX, y: fd.arrangeY)
                                        }
                                    }
                                    guard draggingID == fakeID,
                                          let idx = vm.fakeDisplays.firstIndex(where: { $0.id == fakeID }) else { return }
                                    var newX = dragStartArrange.x + v.translation.width
                                    var newY = dragStartArrange.y + v.translation.height
                                    if let lp = layoutParams(canvasSize: geo.size) {
                                        let fakeW = lp.fakeW, fakeH = lp.fakeH
                                        let fakeCX = lp.canvasCX + newX
                                        let fakeCY = lp.canvasCY + newY
                                        var snappedX = false, snappedY = false
                                        for screen in realScreens {
                                            let rx = lp.canvasCX + (screen.frame.midX - lp.screenCX) * lp.scale
                                            let ry = lp.canvasCY - (screen.frame.midY - lp.screenCY) * lp.scale
                                            let rw = screen.frame.width * lp.scale
                                            let rh = screen.frame.height * lp.scale
                                            if !snappedX {
                                                if abs((fakeCX - fakeW / 2) - (rx + rw / 2)) < snapRadius {
                                                    newX = rx + rw / 2 + fakeW / 2 - lp.canvasCX; snappedX = true
                                                } else if abs((fakeCX + fakeW / 2) - (rx - rw / 2)) < snapRadius {
                                                    newX = rx - rw / 2 - fakeW / 2 - lp.canvasCX; snappedX = true
                                                }
                                            }
                                            if !snappedY {
                                                if abs((fakeCY - fakeH / 2) - (ry + rh / 2)) < snapRadius {
                                                    newY = ry + rh / 2 + fakeH / 2 - lp.canvasCY; snappedY = true
                                                } else if abs((fakeCY + fakeH / 2) - (ry - rh / 2)) < snapRadius {
                                                    newY = ry - rh / 2 - fakeH / 2 - lp.canvasCY; snappedY = true
                                                }
                                            }
                                        }
                                    }
                                    var updated = vm.fakeDisplays
                                    updated[idx].arrangeX = newX
                                    updated[idx].arrangeY = newY
                                    vm.fakeDisplays = updated
                                }
                                .onEnded { _ in draggingID = nil; dragStartArrange = .zero }
                        )
                        .zIndex(tile.fakeUUID != nil && tile.fakeUUID == draggingID ? 10 : 0)
                }
            }
            .frame(width: geo.size.width, height: canvasH)
            .clipped()
        }
        .frame(height: canvasH)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            realScreens = NSScreen.screens
        }
    }

    // MARK: Tile View

    @ViewBuilder
    private func tileView(_ tile: Tile) -> some View {
        let isDragging = tile.fakeUUID != nil && tile.fakeUUID == draggingID
        let menuBarH: CGFloat = max(5, tile.h * 0.09)
        let labelPt: CGFloat = min(9, max(7, tile.w * 0.065))

        VStack(spacing: 0) {
            // Menu bar stripe sits above every tile (visible only on primary display).
            // All tiles reserve the same height so .position() centers the body consistently.
            ZStack {
                Color.clear
                if tile.isMain {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: tile.w * 0.55, height: menuBarH)
                }
            }
            .frame(width: tile.w, height: menuBarH + 3)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tile.isReal ? Color(hex: 0x2c2c2e) : Color(hex: 0x2d1a00))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isDragging ? Color.blue :
                        tile.isReal ? Color.white.opacity(0.2) : Color.orange.opacity(0.55),
                        lineWidth: isDragging ? 2 : 1.5
                    )
                VStack(spacing: max(2, tile.h * 0.06)) {
                    Image(systemName: tile.isReal ? "display" : "display.and.arrow.down")
                        .font(.system(size: max(12, tile.h * 0.22)))
                        .foregroundStyle(tile.isReal ? Color.white.opacity(0.45) : Color.orange)
                    Text(tile.name)
                        .font(.system(size: labelPt, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: tile.w - 10)
                    if !tile.isReal {
                        Text("virtual")
                            .font(.system(size: 6.5))
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                }
            }
            .frame(width: tile.w, height: tile.h)
            .shadow(color: isDragging ? Color.blue.opacity(0.4) : .clear, radius: 12, y: 4)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Developer pane

@available(macOS 14.0, *)
struct DeveloperPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var lastHapticBF: Int = -1
    @State private var lastHapticDF: Int = -1
    @State private var lastHapticBN: Int = -1
    @State private var lastHapticDN: Int = -1

    var body: some View {
        PaneContainer(section: .developer) {
            Section {
                ForEach(vm.fakeDisplays) { display in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.name)
                                .font(.system(size: 13, weight: .medium))
                            Text("\(display.spaceCount) deskspaces")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Stepper("Spaces", value: Binding(
                            get: { display.spaceCount },
                            set: { newCount in
                                if let idx = vm.fakeDisplays.firstIndex(where: { $0.id == display.id }) {
                                    var updated = vm.fakeDisplays
                                    updated[idx].spaceCount = max(1, min(10, newCount))
                                    vm.fakeDisplays = updated
                                }
                            }
                        ), in: 1...10)
                        .labelsHidden()
                        .frame(width: 100)
                        Button {
                            vm.fakeDisplays.removeAll { $0.id == display.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    let count = vm.fakeDisplays.count + 1
                    vm.fakeDisplays.append(FakeDisplay(
                        name: "Fake Display \(count)",
                        spaceCount: 3
                    ))
                } label: {
                    Label("Add Fake Display", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)

                Text("Fake displays only affect MSG's internal display count for testing multi-display layouts")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                opacitySlider(label: "Bright Focus",
                              value: Binding(get: { Double(vm.brightFocusAlpha) },
                                             set: { vm.brightFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticBF)
                opacitySlider(label: "Dim Focus",
                              value: Binding(get: { Double(vm.dimFocusAlpha) },
                                             set: { vm.dimFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticDF)
                opacitySlider(label: "Bright Non-Focus",
                              value: Binding(get: { Double(vm.brightNonFocusAlpha) },
                                             set: { vm.brightNonFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticBN)
                opacitySlider(label: "Dim Non-Focus",
                              value: Binding(get: { Double(vm.dimNonFocusAlpha) },
                                             set: { vm.dimNonFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticDN)
            } header: {
                Text("Indicator Opacity")
            } footer: {
                Text("Fine-tune per-state opacities of the space indicator. Values are alpha multipliers.")
            }

            Section {
                ArrangeDisplaysView(vm: vm)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Arrange Displays")
            } footer: {
                Text("Drag virtual displays to position them. They snap to the edges of real displays.")
            }
        }
    }

    private func opacitySlider(label: String, value: Binding<Double>, haptic: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0.05...1.0, step: 0.05)
                .onChange(of: value.wrappedValue) { newVal in
                    let i = Int(round(newVal * 100))
                    if i != haptic.wrappedValue {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                        haptic.wrappedValue = i
                    }
                }
            Text("\(Int(round(value.wrappedValue * 100)))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - General pane

@available(macOS 14.0, *)
struct GeneralPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }()
    @State private var showResetConfirm = false

    private var versionString: String {
        let d = Bundle.main.infoDictionary
        let v = d?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = d?["CFBundleVersion"] as? String ?? "0"
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        return "Version \(v) (build \(b)) · \(arch)"
    }

    var body: some View {
        PaneContainer(section: .general) {
            Section {
                VStack(spacing: 8) {
                    if let img = NSImage(named: "AppIcon") {
                        Image(nsImage: img)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Text("MSG")
                        .font(.system(size: 22, weight: .bold))
                        .kerning(-0.5)
                    Text("Monosodium Glutamate · MSG for your Mac Menu Bar")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(versionString)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    HStack(spacing: 8) {
                        featureChip(.spacer)
                        featureChip(.corner)
                        featureChip(.music)
                    }
                    .padding(.top, 4)

                    VStack(spacing: 0) {
                        Button("Source on GitHub") {
                            if let url = URL(string: "https://github.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)

                        Divider()

                        Button("Acknowledgements") {}
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                    Text("© 2026 · No added MSG")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 12)
            }
            .listRowBackground(Color.clear)

            Section("Behavior") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { on in
                            if #available(macOS 13.0, *) {
                                do {
                                    if on { try SMAppService.mainApp.register() }
                                    else  { try SMAppService.mainApp.unregister() }
                                } catch { NSLog("SMAppService: \(error)") }
                            }
                        }
                }
                Toggle("Show in Dock",
                       isOn: Binding(get: { vm.dockIcon }, set: { vm.dockIcon = $0 }))
            }

            Section("Features") {
                Toggle("Space indicator", isOn: Binding(get: { vm.spacerEnabled }, set: { vm.spacerEnabled = $0 }))
                Toggle("Corner masks", isOn: Binding(get: { vm.cornersEnabled }, set: { vm.cornersEnabled = $0 }))
                Toggle("Music display", isOn: Binding(get: { vm.musicEnabled }, set: { vm.musicEnabled = $0 }))
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    permissionView(granted: AXIsProcessTrusted(), urlKey: "Privacy_Accessibility")
                }
                LabeledContent("Screen Recording") {
                    permissionView(granted: CGPreflightScreenCaptureAccess(), urlKey: "Privacy_ScreenCapture")
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically",
                       isOn: Binding(get: { vm.autoUpdate }, set: { vm.autoUpdate = $0 }))
                Picker("Update channel", selection: Binding(get: { vm.updateChannel }, set: { vm.updateChannel = $0 })) {
                    Text("Stable").tag("stable")
                    Text("Beta").tag("beta")
                    Text("Nightly").tag("nightly")
                }
                .disabled(!vm.autoUpdate)
            }

            Section {
                Button("Reset all settings to defaults") {
                    showResetConfirm = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .confirmationDialog(
                    "Reset all settings to defaults?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        if let id = Bundle.main.bundleIdentifier {
                            UserDefaults.standard.removePersistentDomain(forName: id)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This cannot be undone.")
                }

                Button {
                    NSApp.keyWindow?.orderOut(nil)
                    if !vm.dockIcon {
                        NSApp.setActivationPolicy(.accessory)
                    }
                } label: {
                    HStack {
                        Text("Quit MSG")
                        Spacer()
                        (Text("No added ") + Text("MSG").font(.system(.body, design: .monospaced)))
                            .foregroundStyle(.secondary)
                        Text("⌘Q").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: [.command])
            }
        }
    }

    @ViewBuilder
    private func permissionView(granted: Bool, urlKey: String) -> some View {
        if granted {
            Text("Granted")
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 8) {
                Text("Not granted")
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(urlKey)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
    }

    private func featureChip(_ s: SettingsSection) -> some View {
        HStack(spacing: 5) {
            GradientIcon(section: s, size: 16, iconPt: 8, radius: 4)
            Text(s.title)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - About pane

@available(macOS 14.0, *)
struct AboutPane: View {
    @State private var headerHeight: CGFloat = 68

    private var versionString: String {
        let d = Bundle.main.infoDictionary
        let v = d?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = d?["CFBundleVersion"] as? String ?? "0"
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        return "Version \(v) (build \(b)) · \(arch)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        if let img = NSImage(named: "AppIcon") {
                            Image(nsImage: img)
                                .resizable()
                                .frame(width: 112, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                        }
                        Text("MSG")
                            .font(.system(size: 28, weight: .bold))
                            .kerning(-0.5)
                        Text("Monosodium Glutamate · MSG for your Mac Menu Bar")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(versionString)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .padding(.top, 36)
                    .padding(.bottom, 24)

                    HStack(spacing: 10) {
                        featureChip(.spacer)
                        featureChip(.corner)
                        featureChip(.music)
                    }
                    .padding(.bottom, 24)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 0) {
                            Button("Source on GitHub") {
                                if let url = URL(string: "https://github.com/") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)

                            Divider()

                            Button("Acknowledgements") {}
                                .buttonStyle(.borderless)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 9)
                        }
                        .padding(.horizontal, 2)
                    }
                    .padding(.bottom, 24)

                    (Text("© 2026 · No added ") + Text("MSG").font(.system(.caption, design: .monospaced)))
                        .font(.system(.caption))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(.top, headerHeight - 16)
                .padding(.bottom, 36)
            }
            PaneHeader(section: .about)
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

    private func featureChip(_ s: SettingsSection) -> some View {
        HStack(spacing: 6) {
            GradientIcon(section: s, size: 18, iconPt: 9, radius: 4)
            Text(s.title)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Module-level helpers

private func swScreenUUID(_ screen: NSScreen) -> String? {
    guard let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let u = CGDisplayCreateUUIDFromDisplayID(dID),
          let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String?
    else { return nil }
    return s
}

private func swDisplayPosition(for screen: NSScreen, relativeTo main: NSScreen) -> String {
    let e = screen.frame, m = main.frame
    var h = "", v = ""
    if e.maxX <= m.minX { h = "Left" } else if e.minX >= m.maxX { h = "Right" }
    if e.minY >= m.maxY { v = "Above" } else if e.maxY <= m.minY { v = "Below" }
    if h.isEmpty && v.isEmpty { return "Overlapping" }
    if h.isEmpty { return v }
    if v.isEmpty { return h }
    return "\(v) & \(h)"
}

private let _cachedModelName: String = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    p.arguments = ["SPHardwareDataType"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8),
          let line = out.components(separatedBy: "\n").first(where: { $0.contains("Model Name") }),
          let name = line.split(separator: ":").last
    else { return "Mac" }
    return name.trimmingCharacters(in: .whitespaces)
}()

private func swCachedModelName() -> String { _cachedModelName }
