import SwiftUI
import AppKit

// MARK: - Dock Previews settings pane

@available(macOS 14.0, *)
struct DockPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var previewWallpaper: NSImage? = nil

    var body: some View {
        PaneContainer(section: .dock, headerToggle: Binding(
            get: { vm.dockPreviewEnabled },
            set: { vm.dockPreviewEnabled = $0; NotificationCenter.default.post(name: .dockPreviewChanged, object: nil) }
        )) {
            Section("Preview") {
                DockPreviewScene(
                    thumbHeight: vm.dockPreviewThumbHeight,
                    offset: vm.dockPreviewOffset,
                    hoverDelay: vm.dockPreviewHoverDelay,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("Behavior") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hover delay")
                        Spacer()
                        Text(String(format: "%.2fs", vm.dockPreviewHoverDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { vm.dockPreviewHoverDelay },
                        set: { vm.dockPreviewHoverDelay = $0 }
                    ), in: 0.10...1.0, step: 0.05)
                }
                Text("How long to rest the pointer on a Dock tile before the preview appears.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Preview size")
                        Spacer()
                        Text("\(Int(vm.dockPreviewThumbHeight)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { vm.dockPreviewThumbHeight },
                        set: { vm.dockPreviewThumbHeight = $0 }
                    ), in: 90...260, step: 10)
                }
                Text("How large each window thumbnail is drawn in the preview card.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Distance from Dock")
                        Spacer()
                        Text("\(Int(vm.dockPreviewOffset)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { vm.dockPreviewOffset },
                        set: { vm.dockPreviewOffset = $0 }
                    ), in: -40...120, step: 2)
                }
                Text("Adjusts the gap between the Dock tile and the preview card.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("App Switcher") {
                Toggle(isOn: Binding(
                    get: { vm.appSwitcherPreviewEnabled },
                    set: {
                        vm.appSwitcherPreviewEnabled = $0
                        NotificationCenter.default.post(name: .appSwitcherPreviewChanged, object: nil)
                    }
                )) {
                    Text("Preview in the app switcher")
                }
                Text("Hold ⌘ and rest the selection on an app in the ⌘-Tab switcher to see the same card. It layers over the switcher and never intercepts your keys or clicks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hold delay")
                        Spacer()
                        Text(String(format: "%.2fs", vm.appSwitcherPreviewDelay))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { vm.appSwitcherPreviewDelay },
                        set: { vm.appSwitcherPreviewDelay = $0 }
                    ), in: 0.10...1.5, step: 0.05)
                }
                .disabled(!vm.appSwitcherPreviewEnabled)
                Text("How long the selection must rest on one app before its preview appears. Once it's up, tabbing moves it instantly.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Distance from switcher")
                        Spacer()
                        Text("\(Int(vm.appSwitcherPreviewOffset)) pt")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { vm.appSwitcherPreviewOffset },
                        set: { vm.appSwitcherPreviewOffset = $0 }
                    ), in: -40...120, step: 2)
                }
                .disabled(!vm.appSwitcherPreviewEnabled)
                Text("Adjusts the gap between the switcher and the preview card. The card uses the Dock preview's thumbnail size.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                WallpaperEngine.shared.previewWallpaper(for: screen) { previewWallpaper = $0 }
            }
        }
    }
}

extension Notification.Name {
    static let dockPreviewChanged = Notification.Name("dockPreviewChanged")
    static let appSwitcherPreviewChanged = Notification.Name("appSwitcherPreviewChanged")
}

// MARK: - Settings preview scene

/// Mini desktop scene (bottom-of-screen crop, mirrors the other panes' scenes):
/// wallpaper, a mock Dock, and a 1:1 replica of the real hover card. Everything
/// is drawn at real point sizes on a 720pt-wide stage and scaled down to the
/// pane width, so radii/spacing/type stay faithful to `DockPreviewView`. The
/// loop mirrors the real controller: the cursor glides onto the Safari tile,
/// rests for the configured hover delay, the card fades in (0.14s), the cursor
/// hovers a window card, then leaves and the card fades out (0.10s). The size
/// and distance sliders reshape the card live, with the real panel's 0.22s morph.
@available(macOS 14.0, *)
struct DockPreviewScene: View {
    let thumbHeight: CGFloat
    let offset: CGFloat
    let hoverDelay: Double
    var wallpaperImage: NSImage? = nil

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return min(1.8, s.frame.width / s.frame.height)
    }

    var body: some View {
        let layout = DockSceneLayout(refH: DockSceneLayout.refW / screenRatio,
                                     thumbHeight: thumbHeight, offset: offset)
        GeometryReader { geo in
            stage(layout: layout)
                .frame(width: DockSceneLayout.refW, height: layout.refH)
                .scaleEffect(geo.size.width / DockSceneLayout.refW, anchor: .topLeading)
        }
        .aspectRatio(screenRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private func stage(layout: DockSceneLayout) -> some View {
        TimelineView(.animation) { timeline in
            let anim = sceneAnim(at: timeline.date, layout: layout)
            ZStack(alignment: .topLeading) {
                background(layout: layout)

                DockBarReplica()
                    .position(x: DockSceneLayout.refW / 2,
                              y: layout.dockTopY + DockSceneLayout.dockH / 2)

                DockCardReplica(thumbHeight: thumbHeight,
                                hoveredIndex: anim.cardHovered ? 0 : nil)
                    .opacity(anim.cardOpacity)
                    .position(x: layout.cardCenterX, y: layout.cardTopY + layout.cardH / 2)
                    .animation(.easeInOut(duration: 0.22), value: thumbHeight)
                    .animation(.easeInOut(duration: 0.22), value: offset)

                CursorSprite(point: anim.cursor)
            }
            .frame(width: DockSceneLayout.refW, height: layout.refH)
        }
    }

    @ViewBuilder private func background(layout: DockSceneLayout) -> some View {
        if let wp = wallpaperImage {
            // Zoomed bottom-center crop of the wallpaper — the scene shows the
            // strip of screen around the Dock.
            Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                .frame(width: DockSceneLayout.refW, height: layout.refH)
                .scaleEffect(1.7, anchor: .bottom)
        } else {
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x5b8def), location: 0),
                    .init(color: Color(hex: 0x8a6df3), location: 0.5),
                    .init(color: Color(hex: 0xd660b4), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(width: DockSceneLayout.refW, height: layout.refH)
        }
    }

    private struct SceneAnim {
        var cursor: CGPoint
        var cardOpacity: Double
        var cardHovered: Bool
    }

    private func sceneAnim(at date: Date, layout: DockSceneLayout) -> SceneAnim {
        let delay = max(0.05, hoverDelay)   // same floor as DockHoverController
        let arrive = 1.1
        let show = arrive + delay
        let toCardStart = show + 0.7
        let toCardEnd = toCardStart + 0.45
        let leave = show + 2.6
        let leaveEnd = leave + 0.6
        let fadeAt = leave + 0.35
        let cycle = leave + 1.4

        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)

        let start = CGPoint(x: DockSceneLayout.refW + 30, y: layout.refH - 24)
        let tile = CGPoint(x: layout.safariX, y: layout.dockTopY + DockSceneLayout.dockH * 0.5)
        let card = layout.firstThumbCenter
        let exit = CGPoint(x: DockSceneLayout.refW + 40, y: layout.refH - 70)

        func ease(_ x: Double) -> CGFloat {
            let c = max(0, min(1, x))
            return CGFloat(c < 0.5 ? 2 * c * c : 1 - pow(-2 * c + 2, 2) / 2)
        }
        func mix(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }

        let cursor: CGPoint
        switch t {
        case ..<0.5:         cursor = start
        case ..<arrive:      cursor = mix(start, tile, ease((t - 0.5) / 0.6))
        case ..<toCardStart: cursor = tile
        case ..<toCardEnd:   cursor = mix(tile, card, ease((t - toCardStart) / 0.45))
        case ..<leave:       cursor = card
        case ..<leaveEnd:    cursor = mix(card, exit, ease((t - leave) / 0.6))
        default:             cursor = exit
        }

        // Real panel timings: 0.14s ease-out fade-in, 0.10s ease-in fade-out.
        var opacity: Double = 0
        if t >= show && t < fadeAt {
            opacity = min(1, (t - show) / 0.14)
        } else if t >= fadeAt {
            opacity = max(0, 1 - (t - fadeAt) / 0.10)
        }

        let hovered = t >= toCardEnd - 0.05 && t < leave + 0.15 && opacity > 0.99
        return SceneAnim(cursor: cursor, cardOpacity: opacity, cardHovered: hovered)
    }
}

/// Shared scene geometry, in real points on the reference stage. Card metrics
/// mirror `DockPreviewView`/`DockWindowCard`; placement mirrors
/// `DockPreviewPanel.position(for:anchor:offset:)` (8pt base gap + user offset,
/// centered over the tile, clamped to the screen with 8pt margins).
private struct DockSceneLayout {
    static let refW: CGFloat = 720
    static let dockIconSize: CGFloat = 56
    static let dockIconSpacing: CGFloat = 12
    static let dockPadding: CGFloat = 8
    static let dockBottomMargin: CGFloat = 10
    static let dockH: CGFloat = dockIconSize + 2 * dockPadding
    static let safariIndex = 2

    static let dockApps: [(bundleID: String, running: Bool)] = [
        ("com.apple.finder", true),
        ("com.apple.MobileSMS", false),
        ("com.apple.Safari", true),
        ("com.apple.mail", false),
        ("com.apple.Photos", false),
        ("com.apple.Music", false),
        ("com.apple.systempreferences", false),
    ]

    /// Sample windows for the card: width follows aspect like real thumbnails.
    static let windows: [(title: String, aspect: CGFloat)] = [
        ("Apple — Start Page", 1.45),
        ("Swift.org", 0.9),
    ]

    let refH: CGFloat
    let thumbHeight: CGFloat
    let offset: CGFloat

    var dockW: CGFloat {
        let n = CGFloat(Self.dockApps.count)
        return n * Self.dockIconSize + (n - 1) * Self.dockIconSpacing + 2 * Self.dockPadding
    }
    var dockTopY: CGFloat { refH - Self.dockBottomMargin - Self.dockH }
    var safariX: CGFloat {
        (Self.refW - dockW) / 2 + Self.dockPadding
            + CGFloat(Self.safariIndex) * (Self.dockIconSize + Self.dockIconSpacing)
            + Self.dockIconSize / 2
    }

    func thumbWidth(_ aspect: CGFloat) -> CGFloat {
        min(thumbHeight * 1.9, max(80, thumbHeight * aspect))
    }
    /// 16pt padding ×2 + framed thumbs (+16 each) + 10pt card spacing.
    var cardW: CGFloat {
        let cards = Self.windows.reduce(CGFloat(0)) { $0 + thumbWidth($1.aspect) + 16 }
        return cards + 10 * CGFloat(Self.windows.count - 1) + 32
    }
    /// 16pt padding ×2 + 24pt header + 12pt gap + framed thumb + 10pt gap + ~16pt label.
    var cardH: CGFloat { thumbHeight + 110 }
    var cardCenterX: CGFloat {
        min(max(safariX, 8 + cardW / 2), Self.refW - 8 - cardW / 2)
    }
    var cardTopY: CGFloat { max(8, dockTopY - (8 + offset) - cardH) }
    /// Center of the first framed thumbnail — the cursor's hover target.
    var firstThumbCenter: CGPoint {
        CGPoint(x: cardCenterX - cardW / 2 + 16 + (thumbWidth(Self.windows[0].aspect) + 16) / 2,
                y: cardTopY + 16 + 24 + 12 + (thumbHeight + 16) / 2)
    }
}

/// 1:1 replica of the real hover card (`DockPreviewView`): same material, radii,
/// spacing, and type — only the thumbnails are drawn sample windows.
@available(macOS 14.0, *)
private struct DockCardReplica: View {
    let thumbHeight: CGFloat
    let hoveredIndex: Int?

    private static let appIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: "com.apple.Safari")
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon = Self.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                }
                Text("Safari")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)

            HStack(spacing: 10) {
                ForEach(Array(DockSceneLayout.windows.enumerated()), id: \.offset) { i, win in
                    ReplicaWindowCard(title: win.title,
                                      aspect: win.aspect,
                                      kind: i == 0 ? .startPage : .article,
                                      height: thumbHeight,
                                      hovering: hoveredIndex == i)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        // Stands in for the real NSPanel's window shadow.
        .shadow(color: .black.opacity(0.30), radius: 16, y: 6)
    }
}

/// Mirrors `DockWindowCard`: framed thumbnail (radius 10 inside the 8pt-padded
/// radius-16 frame) with the title below it, plus the hover treatment (accent
/// ring, lift, shadow, primary label).
@available(macOS 14.0, *)
private struct ReplicaWindowCard: View {
    let title: String
    let aspect: CGFloat
    let kind: SampleWindowThumb.Kind
    let height: CGFloat
    let hovering: Bool

    private var width: CGFloat { min(height * 1.9, max(80, height * aspect)) }

    var body: some View {
        VStack(spacing: 10) {
            SampleWindowThumb(kind: kind)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(hovering ? Color.accentColor : Color.white.opacity(0.12),
                                      lineWidth: hovering ? 2 : 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.30 : 0.0),
                        radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
                .scaleEffect(hovering ? 1.02 : 1.0)

            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(hovering ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: width + 16)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A plausible miniature Safari window standing in for a real screenshot:
/// toolbar with traffic lights + URL capsule, then page content per kind.
@available(macOS 14.0, *)
private struct SampleWindowThumb: View {
    enum Kind { case startPage, article }
    let kind: Kind

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            VStack(spacing: 0) {
                toolbar(w: w, h: h)
                switch kind {
                case .startPage: startPage(w: w, h: h)
                case .article:   article(w: w, h: h)
                }
                Spacer(minLength: 0)
            }
            .frame(width: w, height: h)
            .background(Color(hex: 0xf1f1f4))
        }
    }

    private func toolbar(w: CGFloat, h: CGFloat) -> some View {
        let d = max(3, h * 0.045)
        return ZStack {
            Color(hex: 0xe6e6ea)
            Capsule()
                .fill(Color.black.opacity(0.06))
                .frame(width: w * 0.38, height: max(4, h * 0.05))
            HStack(spacing: d * 0.55) {
                Circle().fill(Color(hex: 0xff5f57)).frame(width: d, height: d)
                Circle().fill(Color(hex: 0xfebc2e)).frame(width: d, height: d)
                Circle().fill(Color(hex: 0x28c840)).frame(width: d, height: d)
                Spacer(minLength: 0)
            }
            .padding(.leading, d)
        }
        .frame(height: max(10, h * 0.115))
        .overlay(alignment: .bottom) { Color.black.opacity(0.07).frame(height: 0.5) }
    }

    private func startPage(w: CGFloat, h: CGFloat) -> some View {
        let tile = w * 0.095
        return VStack(alignment: .leading, spacing: h * 0.045) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.12))
                .frame(width: w * 0.24, height: max(3, h * 0.032))
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: w * 0.038) {
                    ForEach(0..<6, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: tile * 0.3)
                            .fill(Color.black.opacity(0.07))
                            .frame(width: tile, height: tile)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, w * 0.08)
        .padding(.top, h * 0.09)
    }

    private func article(w: CGFloat, h: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: h * 0.032) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.08))
                .frame(width: w * 0.84, height: h * 0.26)
            textBar(width: w * 0.84, h: h)
            textBar(width: w * 0.72, h: h)
            textBar(width: w * 0.78, h: h)
            textBar(width: w * 0.46, h: h)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, w * 0.08)
        .padding(.top, h * 0.07)
    }

    private func textBar(width: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.black.opacity(0.10))
            .frame(width: width, height: max(2.5, h * 0.026))
    }
}

/// Mock Dock bar with real app icons and running dots.
@available(macOS 14.0, *)
private struct DockBarReplica: View {
    private static let icons: [NSImage?] = DockSceneLayout.dockApps.map {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    var body: some View {
        HStack(spacing: DockSceneLayout.dockIconSpacing) {
            ForEach(0..<DockSceneLayout.dockApps.count, id: \.self) { i in
                Group {
                    if let icon = Self.icons[i] {
                        Image(nsImage: icon).resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.15))
                    }
                }
                .frame(width: DockSceneLayout.dockIconSize, height: DockSceneLayout.dockIconSize)
                .overlay(alignment: .bottom) {
                    if DockSceneLayout.dockApps[i].running {
                        Circle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 3.5, height: 3.5)
                            .offset(y: 6)
                    }
                }
            }
        }
        .padding(DockSceneLayout.dockPadding)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

/// The real macOS arrow cursor, positioned by its hotspot.
@available(macOS 14.0, *)
private struct CursorSprite: View {
    private static let image = NSCursor.arrow.image
    private static let hotSpot = NSCursor.arrow.hotSpot
    let point: CGPoint

    var body: some View {
        Image(nsImage: Self.image)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .position(x: point.x - Self.hotSpot.x + Self.image.size.width / 2,
                      y: point.y - Self.hotSpot.y + Self.image.size.height / 2)
    }
}
