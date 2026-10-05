import SwiftUI
import AppKit
import ServiceManagement
import Combine

// MARK: - Spacer pane

@available(macOS 14.0, *)
struct SpacerPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var previewWallpaper: NSImage? = nil

    private var effectiveScreenCount: Int { screens.count + vm.fakeDisplays.count }
    private var stackVisible: Bool { effectiveScreenCount > 1 }
    var body: some View {
        PaneContainer(section: .spacer,
                      headerToggle: Binding(get: { vm.spacerEnabled }, set: { vm.spacerEnabled = $0 })) {
            Section("Preview") {
                SpacerPreviewScene(
                    stackMode: vm.stackMode,
                    screenCount: effectiveScreenCount,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("Appearance") {
                Picker("Animation", selection: Binding(get: { vm.animationStyle }, set: { vm.animationStyle = $0 })) {
                    ForEach(AnimationStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if stackVisible {
                    Picker("Display layout", selection: Binding(get: { vm.stackMode }, set: { vm.stackMode = $0 })) {
                        ForEach(StackMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Picker("Display order", selection: Binding(get: { vm.displayOrderMode }, set: { vm.displayOrderMode = $0 })) {
                    ForEach(DisplayOrderMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Behavior") {
                Picker("Follow active display", selection: Binding(get: { vm.focusDetectionMode }, set: { vm.focusDetectionMode = $0 })) {
                    ForEach(FocusDetectionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }

            }

        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                WallpaperEngine.shared.previewWallpaper(for: screen) { previewWallpaper = $0 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }
}

// MARK: - HUD Replacer pane

@available(macOS 14.0, *)
struct HUDReplacerPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var previewWallpaper: NSImage? = nil

    var body: some View {
        PaneContainer(section: .hud,
                      headerToggle: Binding(get: { vm.systemHUDEnabled }, set: { vm.systemHUDEnabled = $0 })) {
            Section("Preview") {
                SystemHUDPreviewScene(
                    presentationMode: vm.systemHUDPresentationMode,
                    volumeEnabled: vm.systemHUDVolume,
                    brightnessEnabled: vm.systemHUDBrightness,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                SettingsSegmentedPicker(title: "Show HUD As", selection: Binding(get: { vm.systemHUDPresentationMode }, set: { vm.systemHUDPresentationMode = $0 }),
                    options: SystemHUDPresentationMode.allCases.map { SettingsSegment($0.rawValue, $0) })
                if vm.systemHUDPresentationMode != .separate {
                    SettingsToggleRow("Use tiling bar Space Indicator",
                        detail: "While the tiling control bar is showing, its Space Indicator changes into the HUD and back, instead of the menu bar's.",
                        isOn: Binding(get: { vm.systemHUDInTilingBar }, set: { vm.systemHUDInTilingBar = $0 }))
                }
            } header: {
                Text("Presentation")
            } footer: {
                Text("Dynamic uses the Space Indicator. Separate Menu Bar uses its own icon. Notch grows out of the notch like the TokenBar card: drag the bar, click the speaker to mute, rest the pointer on it to switch sound output, or pick a language. Without a notch (lid closed) it falls back to Dynamic.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("Dynamic uses the Space Indicator. Separate Menu Bar uses its own icon. In Notch mode, drag to adjust, click the speaker to mute, hover to choose an output, or pick a language. Screens without a notch use Dynamic.")
            }

            Section("Volume & brightness") {
                SettingsToggleRow("Volume", detail: "Show a HUD when you adjust sound volume.",
                    isOn: Binding(get: { vm.systemHUDVolume }, set: { vm.systemHUDVolume = $0 }))
                if vm.systemHUDVolume {
                    Toggle("Match icon to sound device",
                        isOn: Binding(get: { vm.systemHUDDeviceIcons }, set: { vm.systemHUDDeviceIcons = $0 }))
                }
                SettingsToggleRow("Built-in brightness", detail: "Show a HUD when you adjust the built-in display.",
                    isOn: Binding(get: { vm.systemHUDBrightness }, set: { vm.systemHUDBrightness = $0 }))
            }

            Section("Keyboard") {
                SettingsToggleRow("Show input language", detail: "Briefly show TH or ENG in the Space Indicator (or the notch, with Notch presentation) when switching languages. Works independently of the HUD switch.",
                    isOn: Binding(get: { vm.inputSourceHUDEnabled }, set: { vm.inputSourceHUDEnabled = $0 }))
            }

            Section {
                Button("Manage Accessibility permission…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Volume and brightness controls need Accessibility access. Relaunch MSG after granting it.")
            }
        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                WallpaperEngine.shared.previewWallpaper(for: screen) { previewWallpaper = $0 }
            }
        }
    }
}

// MARK: - Cornermizer pane

@available(macOS 14.0, *)
struct CornermizerPane: View {
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
        PaneContainer(section: .corner,
                      headerToggle: Binding(get: { vm.cornersEnabled }, set: { vm.cornersEnabled = $0 })) {
            Section("Preview") {
                CornerPreviewView(
                    radius: vm.cornerRadius,
                    topEnabled: vm.topCornersEnabled,
                    bottomEnabled: vm.bottomCornersEnabled,
                    // Fullscreen-only corners never sit below a menu bar — there
                    // isn't one on a fullscreen space — so preview them where
                    // they will actually appear: at the screen edge.
                    underBar: vm.topCornersUnderMenuBar && !vm.topCornersFullscreenOnly,
                    curve: vm.cornerCurve,
                    wallpaperImage: previewWallpaper
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)

                statusCard
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }

            Section(MacModel.name) {
                if hasExternals {
                    SettingsToggleRow("Use the same corners on every display", detail: "External displays follow the settings below.",
                           isOn: bind({ vm.mirrorMainDisplay }, { vm.mirrorMainDisplay = $0 }))
                }
                Toggle("Top Corners",
                       isOn: bind({ vm.topCornersEnabled }, { vm.topCornersEnabled = $0 }))
                if vm.topCornersEnabled {
                    SettingsSegmentedPicker(title: "Position", selection: bind({ vm.topCornersUnderMenuBar },
                                                                           { vm.topCornersUnderMenuBar = $0 }),
                        options: [SettingsSegment("At Screen Edge", false), SettingsSegment("Below Menu Bar", true)])
                    SettingsToggleRow("Only in full screen", detail: "Show top corners only while an app is full screen.",
                           isOn: bind({ vm.topCornersFullscreenOnly }, { vm.topCornersFullscreenOnly = $0 }))
                }
                Toggle("Bottom Corners",
                       isOn: bind({ vm.bottomCornersEnabled }, { vm.bottomCornersEnabled = $0 }))
                if radiusVisible {
                    radiusSlider(value: bind({ Double(vm.cornerRadius) },
                                             { vm.cornerRadius = CGFloat($0) }))
                    SettingsSegmentedPicker(title: "Curve", selection: bind({ vm.cornerCurve },
                                                                        { vm.cornerCurve = $0 }),
                        options: [SettingsSegment("G1 (Circular)", CornerCurve.g1), SettingsSegment("G2 (Continuous)", CornerCurve.g2)])
                }
            }

            ForEach(externals, id: \.self) { screen in
                if let uuid = screen.uuid {
                    let pos = screens.first.map { displayPosition(for: screen, relativeTo: $0) } ?? ""
                    let label = pos.isEmpty ? screen.localizedName : "\(screen.localizedName) (\(pos))"
                    Section(label) {
                        externalControls(uuid: uuid, vm: vm)
                            .disabled(vm.mirrorMainDisplay)
                            .opacity(vm.mirrorMainDisplay ? 0.4 : 1)
                            .animation(.easeInOut(duration: 0.2), value: vm.mirrorMainDisplay)
                    }
                }
            }

            Section("Animation") {
                SettingsToggleRow("Animate corners", detail: "Ease corners into view when they appear.",
                       isOn: bind({ vm.cornerGrowEnabled }, { vm.cornerGrowEnabled = $0 }))
            }
        }
        .onAppear {
            WallpaperEngine.shared.beginEditing()
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
            // showBaseline() was called on appear; endEditing() sync()s, which
            // re-bakes (covering any pending edits, including the header toggle)
            // or restores the baseline if corners are now disabled.
            // Note this only fires on pane switches — closing the settings window
            // leaves the hosting view in place, so the poll's liveness check is
            // what releases editing in that case.
            WallpaperEngine.shared.endEditing()
            hasPendingChanges = false
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
                    WallpaperEngine.shared.sync()
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
                    WallpaperEngine.shared.sync()
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
        WallpaperEngine.shared.previewWallpaper(for: screen) { previewWallpaper = $0 }
    }

    @ViewBuilder
    private func externalControls(uuid: String, vm: SettingsViewModel) -> some View {
        Toggle("Top Corners", isOn: bind(
            { AppSettings.shared.extTopCornersEnabled(for: uuid) },
            { AppSettings.shared.setExtTopCornersEnabled($0, for: uuid); vm.objectWillChange.send() }
        ))
        if AppSettings.shared.extTopCornersEnabled(for: uuid) {
            SettingsSegmentedPicker(title: "Position", selection: bind(
                            { AppSettings.shared.extTopCornersUnderMenuBar(for: uuid) },
                            { AppSettings.shared.setExtTopCornersUnderMenuBar($0, for: uuid); vm.objectWillChange.send() }
                        ),
                options: [SettingsSegment("At Screen Edge", false), SettingsSegment("Below Menu Bar", true)])
            SettingsToggleRow("Only in full screen", detail: "Show top corners only while an app is full screen.", isOn: bind(
                { AppSettings.shared.extTopCornersFullscreenOnly(for: uuid) },
                { AppSettings.shared.setExtTopCornersFullscreenOnly($0, for: uuid); vm.objectWillChange.send() }
            ))
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
            SettingsSegmentedPicker(title: "Curve", selection: bind(
                            { AppSettings.shared.extCornerCurve(for: uuid) },
                            { AppSettings.shared.setExtCornerCurve($0, for: uuid); vm.objectWillChange.send() }
                        ),
                options: [SettingsSegment("G1 (Circular)", CornerCurve.g1), SettingsSegment("G2 (Continuous)", CornerCurve.g2)])
        }
    }

    @ViewBuilder
    private func radiusSlider(value: Binding<Double>) -> some View {
        HStack {
            Text("Radius")
            Slider(value: value, in: 0...30, step: 1)
                .onChange(of: value.wrappedValue) { _, newVal in
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
        PaneContainer(section: .music,
                      headerToggle: Binding(get: { vm.musicEnabled }, set: { vm.musicEnabled = $0 })) {
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

            Section("Playback") {
                Picker("Source", selection: Binding(
                    get: { vm.musicSource },
                    set: { vm.musicSource = $0 }
                )) {
                    ForEach(MusicSource.allCases, id: \.self) { source in
                        Text(source.displayLabel).tag(source).disabled(!source.isAvailable)
                    }
                }
            }

            Section("Appearance") {
                Picker("Display", selection: Binding(
                    get: { vm.musicDisplayMode },
                    set: { vm.musicDisplayMode = $0 }
                )) {
                    ForEach(MusicDisplayMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if vm.musicDisplayMode == .dynamic {
                HStack {
                    Text("Keep visible after pausing")
                    Slider(value: Binding(
                        get: { vm.musicLingerDuration },
                        set: { vm.musicLingerDuration = $0 }
                    ), in: 0...60)
                    .onChange(of: vm.musicLingerDuration) { _, newVal in
                        let i = Int(newVal)
                        if i != lastHaptic {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            lastHaptic = i
                        }
                    }
                    Text("\(Int(vm.musicLingerDuration))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                }

            }

            Section {
                SettingsToggleRow("Prefer Apple Music", detail: "Keep keyboard playback controls on Music while it is playing.",
                       isOn: Binding(get: { vm.mediaKeyPriorityMusic }, set: { vm.mediaKeyPriorityMusic = $0 }))
            } header: {
                Text("Media Keys")
            } footer: {
                Text("While Apple Music plays, keyboard media keys control it instead of browser videos. Requires Accessibility. Headphone buttons still follow macOS.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                WallpaperEngine.shared.previewWallpaper(for: screen) { previewWallpaper = $0 }
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
                        isDragging ? Color.accentColor :
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
            .shadow(color: isDragging ? Color.accentColor.opacity(0.4) : .clear, radius: 12, y: 4)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Hardware Stats pane

@available(macOS 14.0, *)
struct HardwarePane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selectedTab = 0
    @State private var stats = HardwareStats()
    @State private var timer: Timer?
    @State private var previewMode: String = "menubar"
    /// Row the dragged module is currently hovering, for the insertion line.
    /// `orderEndTarget` marks the drop zone that sends a module to the end.
    @State private var dropTargetID: String?
    private let orderEndTarget = "__end__"

    var body: some View {
        PaneContainer(section: .hardware, headerToggle: $vm.hardwareStatsEnabled,
                      tabs: ["Layout", "Modules", "Appearance", "Fans"], tabSelection: $selectedTab) {
            if selectedTab == 0 {
                Section {
                    if previewMode == "menubar" {
                        previewCard
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                    } else {
                        popoverPreviewCard
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("Preview")
                        Spacer()
                        SettingsSegmentedPicker(title: "Preview Mode", selection: $previewMode,
                            options: [SettingsSegment("Menu Bar", "menubar"), SettingsSegment("Popover", "popover")], navigation: true, showsLabel: false)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 170)
                    }
                }
                if vm.hardwareStatsEnabled {
                    Section {
                        orderColumnHeader
                        ForEach(vm.hardwareStatsModuleOrder, id: \.self) { id in
                            orderRow(id)
                        }
                        orderEndZone
                    } header: {
                        Text("Modules")
                    } footer: {
                        Text("Drag ≡ or use ▲▼ to reorder. Menu controls the menu bar; Card controls the popover. Both share the same order.")
                    }
                }
            } else if vm.hardwareStatsEnabled {
                switch selectedTab {
                case 1:
                    Section("Module settings") {
                        ForEach(AppSettings.hardwareModuleIDs, id: \.self) { id in
                            DisclosureGroup(moduleTitle(id)) {
                                moduleGroup(for: id)
                            }
                        }
                    }
                case 2:
                    Section("Appearance") {
                        SettingsSegmentedPicker(title: "Bar style", selection: $vm.hardwareStatsBarStyle,
                            options: [SettingsSegment("Vertical", "vertical"), SettingsSegment("Horizontal", "horizontal"), SettingsSegment("Circular", "circular"), SettingsSegment("Dot", "dot")])
                        SettingsSegmentedPicker(title: "Label position", selection: $vm.hardwareStatsLabelPos,
                            options: [SettingsSegment("Vertical", "vertical"), SettingsSegment("Horizontal", "horizontal")])
                        SettingsSegmentedPicker(title: "Dot color", selection: $vm.hardwareStatsColorScale,
                            options: [SettingsSegment("White", "white"), SettingsSegment("Green", "green")])

                    }
                    Section {
                        HStack {
                            Text("Update every")
                            Slider(value: $vm.hardwareStatsInterval, in: 1...10, step: 1)
                            Text("\(Int(vm.hardwareStatsInterval))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                    } header: {
                        Text("Refresh")
                    } footer: {
                        Text("Longer intervals reduce background work.")
                    }
                default:
                    Section("Fans") {
                        if stats.fans.isEmpty {
                            Text("No fan data available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(stats.fans) { fan in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(fan.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text("\(fan.current) RPM")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                    // Bar showing fan speed relative to max
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.white.opacity(0.1))
                                                .frame(height: 4)
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(fanColor(fan))
                                                .frame(width: geo.size.width * CGFloat(fan.current) / CGFloat(max(1, fan.max)), height: 4)
                                        }
                                    }
                                    .frame(height: 4)
                                    Text("Min: \(fan.min)  Max: \(fan.max)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                                .padding(.vertical, 2)
                            }

                            Picker("Fan Preset", selection: $vm.hardwareStatsFanPreset) {
                                Text("Silent").tag("silent")
                                Text("Default").tag("default")
                                Text("Performance").tag("performance")
                            }
                            .pickerStyle(.menu)
                            .onChange(of: vm.hardwareStatsFanPreset) { _, newVal in
                                HardwareMonitor.shared.applySelectedFanPresetFromUser()
                            }

                            if vm.hardwareStatsFanPreset != "default",
                               vm.hardwareStatsFanCurves[vm.hardwareStatsFanPreset] != nil {
                                let presetName = vm.hardwareStatsFanPreset.capitalized
                                let curveBinding = vm.fanCurveBinding(for: vm.hardwareStatsFanPreset)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(presetName) Curve")
                                        .font(.system(size: 11, weight: .semibold))
                                    ForEach(0..<min(curveBinding.wrappedValue.count, 8), id: \.self) { i in
                                        HStack(spacing: 8) {
                                            Text("\(Int(curveBinding.wrappedValue[i][0]))°C")
                                                .font(.system(size: 10, design: .monospaced))
                                                .frame(width: 32, alignment: .trailing)
                                            Slider(value: Binding(
                                                get: { curveBinding.wrappedValue[i][1] },
                                                set: { newVal in
                                                    var updated = curveBinding.wrappedValue
                                                    updated[i][1] = newVal
                                                    curveBinding.wrappedValue = updated
                                                }
                                            ), in: 0...100, step: 5)
                                            Text("\(Int(curveBinding.wrappedValue[i][1]))%")
                                                .font(.system(size: 10, design: .monospaced))
                                                .frame(width: 28, alignment: .trailing)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    }
                }
            } else {
                Section { Text("Turn on Hardware to customize its modules, appearance and fans.").foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            HardwareMonitor.shared.retainPolling()
            stats = HardwareMonitor.shared.stats
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                DispatchQueue.main.async { stats = HardwareMonitor.shared.stats }
            }
            timer?.tolerance = 0.3
            if let t = timer { RunLoop.current.add(t, forMode: .common) }
        }
        .onDisappear {
            HardwareMonitor.shared.releasePolling()
            timer?.invalidate(); timer = nil
        }
    }

    // MARK: - Module rows

    /// One row per module: name + live reading on the left, gauge/number
    /// style picker and the enable switch on the right.
    private func moduleRow(_ title: String,
                           live: String,
                           liveColor: Color? = nil,
                           liveDot: Color? = nil,
                           isOn: Binding<Bool>,
                           raw: Binding<Bool>?,
                           style: Binding<String>? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    if let liveDot {
                        Circle().fill(liveDot).frame(width: 6, height: 6)
                    }
                    Text(live)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(liveColor ?? Color.secondary)
                }
            }
            Spacer()
            if let style, isOn.wrappedValue {
                SettingsSegmentedPicker(title: "Display style", selection: style,
                    options: [SettingsSegment("Bar", "bar"), SettingsSegment("Number", "number"), SettingsSegment("Icon", "icon")], showsLabel: false)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            } else if let raw, isOn.wrappedValue {
                SettingsSegmentedPicker(title: "Display style", selection: raw,
                    options: [SettingsSegment("Bar", false), SettingsSegment("Number", true)], showsLabel: false)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func rangeEditor(title: String,
                             minVal: Binding<Double>,
                             maxVal: Binding<Double>,
                             bounds: ClosedRange<Double>,
                             unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(minVal.wrappedValue))\(unit) – \(Int(maxVal.wrappedValue))\(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            TemperatureRangeSlider(minVal: minVal, maxVal: maxVal, bounds: bounds)
                .frame(height: 24)
                .padding(.vertical, 4)

            HStack {
                Text("\(Int(bounds.lowerBound))\(unit)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int((bounds.lowerBound + bounds.upperBound) / 2))\(unit)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(bounds.upperBound))\(unit)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Live readings

    private var tempLive: String {
        switch (stats.cpuTemp, stats.gpuTemp) {
        case let (c?, g?): return String(format: "CPU %.0f° · GPU %.0f°", c, g)
        case let (c?, nil): return String(format: "%.0f°C", c)
        case let (nil, g?): return String(format: "%.0f°C", g)
        default: return "—"
        }
    }

    private var fanLive: String {
        guard !stats.fans.isEmpty else { return "—" }
        return stats.fans.map { "\($0.current)" }.joined(separator: " / ") + " RPM"
    }

    private var powerLive: String {
        guard let w = stats.powerWatts else { return "—" }
        let suffix = stats.isCharging == true ? " · charging" : ""
        return String(format: "%.1f W%@", w, suffix)
    }

    private var batteryLive: String {
        stats.batteryPercentText() ?? "—"
    }

    /// Threshold color for a live reading, or nil (secondary) while it's in
    /// the calm range — so the row list isn't a wall of colored numbers.
    private func warnColor(_ ratio: Double) -> Color? {
        loadWarningColor(ratio)
    }

    // MARK: - Preview card

    /// True when the battery module renders in its own dedicated status item
    /// instead of the combined hardware bar.
    private var batterySeparate: Bool {
        vm.hardwareStatsShowBattery && vm.hardwareStatsBatterySeparate
    }

    /// The toggle row (and any sub-settings) for one module id, shown in the
    /// Modules section. Arrangement lives in the separate Order section.
    private func moduleTitle(_ id: String) -> String {
        switch id {
        case "cpu": return "CPU"
        case "gpu": return "GPU"
        case "memory": return "Memory"
        case "temp": return "Temperature"
        case "fan": return "Fans"
        case "battery": return "Battery & Power"
        default: return id.capitalized
        }
    }

    @ViewBuilder
    private func moduleGroup(for id: String) -> some View {
        switch id {
        case "cpu":
            moduleRow("CPU", live: String(format: "%.1f%%", stats.cpuPercent),
                      liveColor: warnColor(stats.cpuPercent / 100.0),
                      isOn: $vm.hardwareStatsShowCPU, raw: $vm.hardwareStatsCPURaw)
        case "gpu":
            moduleRow("GPU", live: String(format: "%.1f%%", stats.gpuPercent),
                      liveColor: warnColor(stats.gpuPercent / 100.0),
                      isOn: $vm.hardwareStatsShowGPU, raw: $vm.hardwareStatsGPURaw)
        case "memory":
            moduleRow("Memory", live: String(format: "%.1f GB", stats.memoryUsedGB),
                      liveDot: pressureColor(stats.memoryPressure),
                      isOn: $vm.hardwareStatsShowMemory, raw: $vm.hardwareStatsMemoryRaw)
            if vm.hardwareStatsShowMemory {
                Picker("Show as", selection: $vm.hardwareStatsMemMode) {
                    Text("Pressure").tag("pressure")
                    Text("Usage %").tag("usage")
                }
            }
        case "temp":
            moduleRow("Temperature", live: tempLive,
                      isOn: $vm.hardwareStatsShowTemp, raw: $vm.hardwareStatsTempRaw)
            if vm.hardwareStatsShowTemp {
                Picker("Sensor", selection: $vm.hardwareStatsTempSensor) {
                    Text("Auto").tag("auto")
                    Text("CPU").tag("cpu")
                    Text("GPU").tag("gpu")
                }
                rangeEditor(title: "Bar range",
                            minVal: $vm.hardwareStatsTempMin,
                            maxVal: $vm.hardwareStatsTempMax,
                            bounds: 0...120, unit: "°C")
            }
        case "fan":
            moduleRow("Fan", live: fanLive,
                      isOn: $vm.hardwareStatsShowFan, raw: $vm.hardwareStatsFanRaw)
        case "battery":
            let pwrSuffix = powerLive != "—" ? " · \(powerLive)" : ""
            moduleRow("Battery & Power", live: "\(batteryLive)\(pwrSuffix)",
                      isOn: $vm.hardwareStatsShowBattery, raw: nil,
                      style: $vm.hardwareStatsBatteryStyle)
            if vm.hardwareStatsShowBattery {
                SettingsSegmentedPicker(title: "Menu Bar Display", selection: $vm.hardwareStatsBatteryStyle,
                    options: [SettingsSegment("Bar", "bar"), SettingsSegment("Percent", "number"), SettingsSegment("Icon", "icon"), SettingsSegment("Watts", "watts")])


                HStack {
                    Text("Power samples")
                    Slider(value: $vm.hardwareStatsPowerSamples, in: 20...300, step: 10)
                    Text("\(Int(vm.hardwareStatsPowerSamples))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                Toggle("Separate menu bar item", isOn: $vm.hardwareStatsBatterySeparate)
                if vm.hardwareStatsBatterySeparate {
                    Text("Shows battery status in its own menu bar item, with input watts in a ring while plugged in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show decimals while charging", isOn: $vm.hardwareStatsBatteryChargingDecimals)
            }
        case "fps":
            moduleRow("FPS", live: "\(stats.fps) fps",
                      isOn: $vm.hardwareStatsShowFPS, raw: nil)
        default:
            EmptyView()
        }
    }

    private var cardLayout: HardwareCardLayout {
        HardwareCardLayout(columns: vm.hardwareStatsCardColumns, order: vm.hardwareStatsModuleOrder,
                           batterySpan: vm.hardwareStatsBatteryCardSpan, batterySide: vm.hardwareStatsBatteryCardSide)
    }

    private func applyModuleOrder(_ order: [String]) {
        var layout = cardLayout
        layout.setModuleOrder(order)
        vm.applyHardwareLayout(layout)
    }

    // MARK: - Order (drag to reorder)

    @ViewBuilder
    private func orderRow(_ id: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)

            Text(moduleDisplayName(id))
                .fontWeight(.medium)

            Spacer(minLength: 8)

            Button(action: { moveModuleUp(id) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(vm.hardwareStatsModuleOrder.first == id)
            .help("Move Up")

            Button(action: { moveModuleDown(id) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(vm.hardwareStatsModuleOrder.last == id)
            .help("Move Down")
            .padding(.trailing, 4)

            Toggle("", isOn: menuBarBinding(id))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .frame(width: orderToggleColumn)
            Toggle("", isOn: cardBinding(id))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .frame(width: orderToggleColumn)
        }
        .contentShape(Rectangle())
        .draggable(id) {
            Label(moduleDisplayName(id), systemImage: "line.3.horizontal").padding(6)
        }
        .overlay(alignment: .top) { insertionLine(for: id) }
        .dropDestination(for: String.self) { items, _ in
            dropTargetID = nil
            guard let dragged = items.first else { return false }
            return moveModule(dragged, before: id)
        } isTargeted: { hovering in
            if hovering { dropTargetID = id }
            else if dropTargetID == id { dropTargetID = nil }
        }
        .contextMenu {
            Button("Move Up") { moveModuleUp(id) }
            Button("Move Down") { moveModuleDown(id) }
        }
    }

    private var orderColumnHeader: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("Menu").font(.caption2).foregroundStyle(.secondary)
                .frame(width: orderToggleColumn)
            Text("Card").font(.caption2).foregroundStyle(.secondary)
                .frame(width: orderToggleColumn)
        }
    }

    private let orderToggleColumn: CGFloat = 46

    /// Menu-bar visibility flag for a module (drives the same show-flags as
    /// before, just relocated into the Order section).
    private func menuBarBinding(_ id: String) -> Binding<Bool> {
        switch id {
        case "cpu":     return $vm.hardwareStatsShowCPU
        case "gpu":     return $vm.hardwareStatsShowGPU
        case "memory":  return $vm.hardwareStatsShowMemory
        case "temp":    return $vm.hardwareStatsShowTemp
        case "fan":     return $vm.hardwareStatsShowFan
        case "battery": return $vm.hardwareStatsShowBattery
        case "fps":     return $vm.hardwareStatsShowFPS
        default:        return .constant(false)
        }
    }

    /// Popover-card visibility for a module, backed by the hidden-cards set.
    private func cardBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !vm.hardwareStatsHiddenCards.contains(id) },
            set: { visible in
                var hidden = Set(vm.hardwareStatsHiddenCards)
                if visible { hidden.remove(id) } else { hidden.insert(id) }
                vm.hardwareStatsHiddenCards = AppSettings.hardwareModuleIDs.filter { hidden.contains($0) }
            }
        )
    }

    /// Trailing drop zone that sends a module to the very end of the order.
    private var orderEndZone: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 10)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { insertionLine(for: orderEndTarget) }
            .dropDestination(for: String.self) { items, _ in
                dropTargetID = nil
                guard let dragged = items.first else { return false }
                return moveModuleToEnd(dragged)
            } isTargeted: { hovering in
                if hovering { dropTargetID = orderEndTarget }
                else if dropTargetID == orderEndTarget { dropTargetID = nil }
            }
    }

    @ViewBuilder
    private func insertionLine(for target: String) -> some View {
        if dropTargetID == target {
            Capsule().fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, -4)
        }
    }

    /// Moves `dragged` so it sits just before `target` in the module order.
    @discardableResult
    private func moveModule(_ dragged: String, before target: String) -> Bool {
        guard dragged != target else { return false }
        var order = vm.hardwareStatsModuleOrder
        guard let from = order.firstIndex(of: dragged) else { return false }
        order.remove(at: from)
        let insertAt = order.firstIndex(of: target) ?? order.count
        order.insert(dragged, at: insertAt)
        applyModuleOrder(order)
        return true
    }

    @discardableResult
    private func moveModuleToEnd(_ dragged: String) -> Bool {
        var order = vm.hardwareStatsModuleOrder
        guard let from = order.firstIndex(of: dragged), from != order.count - 1 else { return false }
        order.remove(at: from)
        order.append(dragged)
        applyModuleOrder(order)
        return true
    }

    @discardableResult
    private func moveModuleToTop(_ dragged: String) -> Bool {
        var order = vm.hardwareStatsModuleOrder
        guard let from = order.firstIndex(of: dragged), from != 0 else { return false }
        order.remove(at: from)
        order.insert(dragged, at: 0)
        applyModuleOrder(order)
        return true
    }

    private func moveModuleUp(_ id: String) {
        var order = vm.hardwareStatsModuleOrder
        guard let idx = order.firstIndex(of: id), idx > 0 else { return }
        order.swapAt(idx, idx - 1)
        applyModuleOrder(order)
    }

    private func moveModuleDown(_ id: String) {
        var order = vm.hardwareStatsModuleOrder
        guard let idx = order.firstIndex(of: id), idx < order.count - 1 else { return }
        order.swapAt(idx, idx + 1)
        applyModuleOrder(order)
    }

    private func moduleDisplayName(_ id: String) -> String {
        switch id {
        case "cpu": return "CPU"
        case "gpu": return "GPU"
        case "memory": return "Memory"
        case "temp": return "Temperature"
        case "fan": return "Fan"
        case "battery": return "Battery & Power"
        case "fps": return "FPS"
        default: return id.uppercased()
        }
    }

    /// Uses the same AppKit view as the real menu bar item, so the preview stays exact.
    private var previewCard: some View {
        let size = hardwarePreviewSize
        let scale: CGFloat = 2.0

        return HStack(spacing: 10) {
            HardwareStatsBarPreview(
                stats: stats,
                showCPU: vm.hardwareStatsShowCPU,
                showGPU: vm.hardwareStatsShowGPU,
                showMemory: vm.hardwareStatsShowMemory,
                showTemp: vm.hardwareStatsShowTemp,
                showFPS: vm.hardwareStatsShowFPS,
                showFan: vm.hardwareStatsShowFan,
                showPower: false,
                showBattery: vm.hardwareStatsShowBattery && !batterySeparate,
                cpuRaw: vm.hardwareStatsCPURaw,
                gpuRaw: vm.hardwareStatsGPURaw,
                memoryRaw: vm.hardwareStatsMemoryRaw,
                tempRaw: vm.hardwareStatsTempRaw,
                fanRaw: vm.hardwareStatsFanRaw,
                powerRaw: vm.hardwareStatsPowerRaw,
                batteryStyle: vm.hardwareStatsBatteryStyle,
                batteryIconScale: 1.0,
                barStyle: vm.hardwareStatsBarStyle,
                labelPosition: vm.hardwareStatsLabelPos,
                colorScale: vm.hardwareStatsColorScale,
                moduleOrder: vm.hardwareStatsModuleOrder
            )
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .opacity(vm.hardwareStatsEnabled ? 1.0 : 0.45)

            if batterySeparate {
                let batterySize = separateBatteryPreviewSize
                HardwareStatsBarPreview(
                    stats: stats,
                    showCPU: false, showGPU: false, showMemory: false, showTemp: false,
                    showFPS: false, showFan: false, showPower: false, showBattery: true,
                    cpuRaw: false, gpuRaw: false, memoryRaw: false, tempRaw: false,
                    fanRaw: false, powerRaw: false,
                    batteryStyle: vm.hardwareStatsBatteryStyle,
                    batteryIconScale: 1.15,
                    barStyle: vm.hardwareStatsBarStyle,
                    labelPosition: vm.hardwareStatsLabelPos,
                    colorScale: vm.hardwareStatsColorScale,
                    moduleOrder: ["battery"]
                )
                .frame(width: batterySize.width, height: batterySize.height)
                .scaleEffect(scale)
                .frame(width: batterySize.width * scale, height: batterySize.height * scale)
                .opacity(vm.hardwareStatsEnabled ? 1.0 : 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    @State private var popoverPreviewHeight: CGFloat = 420

    private var popoverPreviewCard: some View {
        VStack(spacing: 12) {
            HardwarePopoverEditor(stats: stats, layout: cardLayout,
                                  hiddenCards: Set(vm.hardwareStatsHiddenCards),
                                  onMove: { vm.applyHardwareLayout($0) },
                                  onHeightChange: { popoverPreviewHeight = $0 })
                .frame(width: cardLayout.columns.count >= 3 ? 368 : 248,
                       height: popoverPreviewHeight)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("Drag above or below a card to reorder. Drag to a side edge to add a column or place Battery beside the statistics. The blue line marks the drop position.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Picker("Columns", selection: Binding(
                    get: { cardLayout.columns.count },
                    set: { count in
                        var layout = cardLayout
                        layout.setColumnCount(count)
                        vm.applyHardwareLayout(layout)
                    })) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                    }
                Picker("Battery", selection: Binding(
                    get: { cardLayout.batterySpan },
                    set: { span in
                        var layout = cardLayout
                        layout.batterySpan = span
                        if span == "2x2" { layout.setColumnCount(3) }
                        vm.applyHardwareLayout(layout)
                    })) {
                        Text("Full width").tag("full")
                        Text("Beside statistics").tag("2x2")
                    }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Size of the standalone battery status item's larger icon, mirroring
    /// HardwareBarView.intrinsicContentSize's solo-battery-icon branch.
    private var separateBatteryPreviewSize: CGSize {
        guard vm.hardwareStatsBatteryStyle == "icon" else { return hardwarePreviewSize(count: 1) }
        let s: CGFloat = 1.15
        let bodyCap = 22.5 * s
        let nubW = 2.0 * s
        let nubGap = 1.0 * s
        return CGSize(width: bodyCap + nubGap + nubW + 6 + 8, height: 22)
    }

    private var hardwarePreviewSize: CGSize {
        let count = max(1, [
            vm.hardwareStatsShowCPU,
            vm.hardwareStatsShowGPU,
            vm.hardwareStatsShowMemory,
            vm.hardwareStatsShowTemp,
            vm.hardwareStatsShowFPS,
            vm.hardwareStatsShowFan,
            vm.hardwareStatsShowBattery && !batterySeparate,
        ].filter { $0 }.count)
        return hardwarePreviewSize(count: count)
    }

    private func hardwarePreviewSize(count: Int) -> CGSize {
        let perModule: CGFloat
        switch vm.hardwareStatsBarStyle {
        case "circular":
            perModule = vm.hardwareStatsLabelPos == "horizontal" ? 24 : 30
        case "horizontal":
            perModule = vm.hardwareStatsLabelPos == "horizontal" ? 36 : 46
        case "dot":
            perModule = vm.hardwareStatsLabelPos == "horizontal" ? 18 : 24
        default:
            perModule = vm.hardwareStatsLabelPos == "horizontal" ? 16 : 20
        }
        return CGSize(width: perModule * CGFloat(count) + 8, height: 22)
    }

    private struct HardwareStatsBarPreview: NSViewRepresentable {
        let stats: HardwareStats
        let showCPU: Bool
        let showGPU: Bool
        let showMemory: Bool
        let showTemp: Bool
        let showFPS: Bool
        let showFan: Bool
        let showPower: Bool
        let showBattery: Bool
        let cpuRaw: Bool
        let gpuRaw: Bool
        let memoryRaw: Bool
        let tempRaw: Bool
        let fanRaw: Bool
        let powerRaw: Bool
        let batteryStyle: String
        let batteryIconScale: CGFloat
        let barStyle: String
        let labelPosition: String
        let colorScale: String
        let moduleOrder: [String]

        func makeNSView(context: Context) -> HardwareBarView {
            let view = HardwareBarView(frame: NSRect(x: 0, y: 0, width: 88, height: 22))
            view.autoresizingMask = []
            return view
        }

        func updateNSView(_ view: HardwareBarView, context: Context) {
            view.stats = stats
            view.showCPU = showCPU
            view.showGPU = showGPU
            view.showMemory = showMemory
            view.showTemp = showTemp
            view.showFPS = showFPS
            view.showFan = showFan
            view.showPower = showPower
            view.showBattery = showBattery
            view.batteryIconScale = batteryIconScale
            view.cpuRaw = cpuRaw
            view.gpuRaw = gpuRaw
            view.memoryRaw = memoryRaw
            view.tempRaw = tempRaw
            view.fanRaw = fanRaw
            view.powerRaw = powerRaw
            view.batteryStyle = batteryStyle
            view.moduleOrder = moduleOrder
            view.barStyle = barStyle
            view.labelPosition = labelPosition
            view.colorScale = colorScale
            view.updateSize()
            view.needsDisplay = true
        }
    }

    // MARK: - Colors (used by Current Values section)

    /// Load-warning ramp matching the menu-bar gauges: neutral below 80%, then
    /// yellow (0.80) → orange (0.90) → red (1.00), interpolated continuously.
    /// Returns nil below the threshold so callers fall back to a calm color.
    private func loadWarningColor(_ ratio: Double) -> Color? {
        let r = max(0, min(1, ratio))
        guard r >= 0.8 else { return nil }
        let yellow = 0.15, orange = 0.083, red = 0.0
        let hue = r < 0.9
            ? yellow + (orange - yellow) * (r - 0.8) / 0.1
            : orange + (red - orange) * (r - 0.9) / 0.1
        return Color(hue: hue, saturation: 0.9, brightness: 0.95)
    }

    private func fanColor(_ fan: FanInfo) -> Color {
        loadWarningColor(Double(fan.current) / Double(max(1, fan.max))) ?? .white
    }

    private func pressureColor(_ p: HardwareStats.MemoryPressure) -> Color {
        // Run each pressure level's nominal ratio through the same ramp, so the
        // dot stays neutral until pressure is genuinely high.
        let ratio: Double
        switch p {
        case .normal:   ratio = 0.25
        case .warning:  ratio = 0.60
        case .critical: ratio = 0.90
        }
        return loadWarningColor(ratio) ?? .gray
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
            Section("Simulated displays") {
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

            Section("Active display opacity") {
                opacitySlider(label: "Bright",
                              value: Binding(get: { Double(vm.brightFocusAlpha) },
                                             set: { vm.brightFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticBF)
                opacitySlider(label: "Dim",
                              value: Binding(get: { Double(vm.dimFocusAlpha) },
                                             set: { vm.dimFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticDF)
            }
            Section {
                opacitySlider(label: "Bright",
                              value: Binding(get: { Double(vm.brightNonFocusAlpha) },
                                             set: { vm.brightNonFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticBN)
                opacitySlider(label: "Dim",
                              value: Binding(get: { Double(vm.dimNonFocusAlpha) },
                                             set: { vm.dimNonFocusAlpha = CGFloat($0) }),
                              haptic: $lastHapticDN)
            } header: {
                Text("Other displays opacity")
            } footer: {
                Text("Adjust indicator opacity for active and inactive displays.")
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
                .onChange(of: value.wrappedValue) { _, newVal in
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

// MARK: - Menu Bar pane

@available(macOS 14.0, *)
struct MenuBarPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        PaneContainer(section: .menubar) {
            Section {
                // One control drives both the gap between icons (spacing) and
                // the click/highlight padding inside each icon (padding).
                let densityBinding = Binding(
                    get: { Double(vm.menuBarSpacing) },
                    set: {
                        let v = Int($0.rounded())
                        vm.menuBarSpacing = v
                        vm.menuBarSpacingPadding = v
                    })

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Icon spacing")
                        Spacer()
                        Text("\(vm.menuBarSpacing) px").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: densityBinding,
                           in: Double(MenuBarSpacingManager.paddingRange.lowerBound)...Double(MenuBarSpacingManager.paddingRange.upperBound),
                           step: 1)
                }
            } header: {
                Text("Spacing")
            } footer: {
                Text("Applies to all menu bar icons. Some icons update only after logging out or restarting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Section("Calendar") {
                SettingsToggleRow("Next event or reminder", detail: "Show what's coming up next from Calendar or Reminders, with the time until it starts, like \"Meeting - 2 hr 14 min\".",
                                  isOn: Binding(get: { vm.calendarStatusItem }, set: { vm.calendarStatusItem = $0 }))
                if vm.calendarStatusItem {
                    Picker("Maximum title length", selection: Binding(get: { vm.calendarMaxTitleLength }, set: { vm.calendarMaxTitleLength = $0 })) {
                        Text("No limit (full text)").tag(0)
                        Text("20 characters").tag(20)
                        Text("28 characters").tag(28)
                        Text("40 characters").tag(40)
                        Text("60 characters").tag(60)
                        Text("80 characters").tag(80)
                        Text("100 characters").tag(100)
                    }
                }
            }

            Section("Apply changes") {
                HStack {
                Button("Apply spacing") {
                    MenuBarSpacingManager.applyAndOfferLogout(spacing: vm.menuBarSpacing, padding: vm.menuBarSpacingPadding)
                }
                .buttonStyle(.borderedProminent)
                Button("Reset to Default") {
                    vm.menuBarSpacing = MenuBarSpacingManager.systemDefault
                    vm.menuBarSpacingPadding = MenuBarSpacingManager.systemDefault
                    MenuBarSpacingManager.reset()
                    MenuBarSpacingManager.restartMenuBar()
                }
                .foregroundStyle(.secondary)
                Spacer()
                }
            }
        }
    }
}

// MARK: - General pane

@available(macOS 14.0, *)
struct GeneralPane: View {
    @ObservedObject var vm: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }()
    @State private var showResetConfirm = false
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

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
            Section("Startup") {
                if #available(macOS 13.0, *) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            if #available(macOS 13.0, *) {
                                do {
                                    if on { try SMAppService.mainApp.register() }
                                    else  { try SMAppService.mainApp.unregister() }
                                } catch { NSLog("SMAppService: \(error)") }
                            }
                        }
                }
                SettingsToggleRow("Show MSG in Dock", detail: "Keep the app icon in the Dock while MSG is running.",
                       isOn: Binding(get: { vm.dockIcon }, set: { vm.dockIcon = $0 }))

            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    permissionView(granted: accessibilityGranted, urlKey: "Privacy_Accessibility")
                }
                LabeledContent("Screen Recording") {
                    permissionView(granted: screenRecordingGranted, urlKey: "Privacy_ScreenCapture")
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
                DisclosureGroup("About MSG") {
                VStack(spacing: 8) {
                    if let img = colorScheme == .dark
                        ? (NSImage(named: "AppIcon-Dark") ?? NSImage(named: NSImage.applicationIconName))
                        : (NSImage(named: NSImage.applicationIconName) ?? NSImage(named: "AppIcon")) {
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
            }
            .listRowBackground(Color.clear)

            Section("Advanced") {
                    Toggle("Show Developer section",
                           isOn: Binding(get: { vm.showDeveloper }, set: { vm.showDeveloper = $0 }))
            }

            Section("Maintenance") {
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
                        Text("Close Settings")
                        Spacer()
                        (Text("No added ") + Text("MSG").font(.system(.body, design: .monospaced)))
                            .foregroundStyle(.secondary)
                        Text("⌘Q").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: [.command])

                Button {
                    (NSApp.delegate as? AppDelegate)?.requestQuit()
                } label: {
                    Text("Quit MSG")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
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

}

// MARK: - Displaplacer pane

@available(macOS 14.0, *)
struct DisplaplacerPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selectedTab = 0
    @State private var externalDisplays: [DisplaplacerEngine.DisplayInfo] = []
    @State private var inputMonitors: [DisplayInputEngine.Monitor] = []
    @State private var scanningInputs = false
    /// Which input row is being renamed, keyed "<monitor key>#<code>".
    @State private var editingInputID: String?
    @State private var editingInputName = ""

    var body: some View {
        PaneContainer(section: .displaplacer, headerToggle: $vm.displaplacerEnabled,
                      tabs: ["Displays", "Notch & AI", "Presets"], tabSelection: $selectedTab) {
            switch selectedTab {
            case 0:
                Section {
                    if externalDisplays.isEmpty {
                        Text("No external displays connected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(externalDisplays, id: \.uuid) { info in
                            displayRow(info)
                        }
                    }
                } header: {
                    Text("External Displays")
                } footer: {
                    Text("Eject removes the display from your workspace. Reconnect restores it.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    monitorInputContent
                } header: {
                    HStack {
                        Text("Monitor Input")
                        Spacer()
                        if scanningInputs {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Rescan") { refreshInputs(probe: true) }
                                .font(.caption)
                        }
                    }
                } footer: {
                    Text("Choose which device the monitor displays. Switching away hands the screen to that device.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    SettingsToggleRow("Wake up a newly plugged display", detail: "Some monitors stay dark the first time they're plugged in until they're disconnected and reconnected. MSG does that once for you, a moment after you plug one in.",
                           isOn: Binding(get: { vm.displayResyncOnPlug },
                                         set: { vm.displayResyncOnPlug = $0 }))
                }

                if !inputMonitors.isEmpty {
                    Section {
                        SettingsToggleRow("Match the MacBook's brightness", detail: "External monitors follow the built-in display's brightness, auto-brightness included, so the brightness keys set every screen at once.",
                               isOn: Binding(get: { vm.externalBrightnessSync },
                                             set: { vm.externalBrightnessSync = $0 }))
                    }

                    Section {
                        SettingsToggleRow("Move windows back to this Mac", detail: "Disconnect the display when you switch its input to another device.",
                               isOn: Binding(get: { vm.monitorInputAutoEject },
                                             set: { vm.monitorInputAutoEject = $0 }))
                        .disabled(!hasMacInputMarked)
                    } footer: {
                        Text(hasMacInputMarked
                             ? "Windows move back to this Mac. Use the monitor's input button to return; MSG reconnects it automatically."
                             : "First mark which monitor input is connected to this Mac.")
                            .foregroundStyle(.secondary)
                    }
                }
            case 1:
                Section {
                    SettingsToggleRow("Show AI activity on the lock screen", detail: "While Claude, Codex or Antigravity is working and the Mac is locked, the MacBook's display stays on with a card saying what they're doing, and other displays go black. When they finish, the card says so for as long as you choose, then the displays can sleep. Uses TokenBar.",
                           isOn: Binding(get: { vm.lockScreenAgentActivity },
                                         set: { vm.lockScreenAgentActivity = $0 }))
                    SettingsToggleRow("Show the notch dashboard", detail: "Point at the notch to see AI usage and tasks, Music, Calendar, Clipboard, Tray and Audio. Off while Notch previews is on, since both answer the same pointer.",
                           isOn: Binding(get: { vm.notchAgentCard },
                                         set: { vm.notchAgentCard = $0 }))
                    if vm.notchAgentCard {
                        DisclosureGroup("Dashboard panes") {
                            ForEach(AgentNotchDashboardView.Page.allCases, id: \.rawValue) { page in
                                SettingsToggleRow(page.title, detail: page.detail,
                                                  isOn: Binding(get: { vm.notchPaneEnabled(page) },
                                                                set: { vm.setNotchPane(page, enabled: $0) }))
                            }
                        }
                    }
                    SettingsToggleRow("Drop files on the notch", detail: "Drag a file, picture or video to the notch and it opens into Tray and AirDrop. Tray keeps it in the notch card's Tray page to drag out later; AirDrop sends it.",
                           isOn: Binding(get: { vm.notchDropTray },
                                         set: { vm.notchDropTray = $0 }))
                    SettingsToggleRow("Say in the notch when an AI finishes", detail: "When a Claude, Codex or Antigravity session that worked for 15 seconds or more stops, the notch shows its name and how long it ran. Uses TokenBar.",
                           isOn: Binding(get: { vm.notchAgentDoneNotice },
                                         set: { vm.notchAgentDoneNotice = $0 }))
                    SettingsToggleRow("Show power connection changes", detail: "Shows adapter wattage when you plug in power and battery percentage when you unplug it.",
                           isOn: Binding(get: { vm.notchChargerNotice },
                                         set: { vm.notchChargerNotice = $0 }))
                    SettingsToggleRow("Show Amphetamine session changes", detail: "Shows when an Amphetamine keep-awake session starts or ends.",
                           isOn: Binding(get: { vm.notchAmphetamineNotice },
                                         set: { vm.notchAmphetamineNotice = $0 }))
                    SettingsToggleRow("Show display connection changes", detail: "Shows the external display's name when it connects or disconnects.",
                           isOn: Binding(get: { vm.notchDisplayNotice },
                                         set: { vm.notchDisplayNotice = $0 }))
                    SettingsToggleRow("Show Cloudflare WARP changes", detail: "Shows when Cloudflare WARP (1.1.1.1) connects or disconnects.",
                           isOn: Binding(get: { vm.notchWARPNotice },
                                         set: { vm.notchWARPNotice = $0 }))
                    NotchNotificationSettings(vm: vm)
                    SettingsToggleRow("Say in the notch when an AI limit resets", detail: "When a Claude, ChatGPT or Antigravity usage window you've used comes round (5-hour or weekly), the notch says so for a few seconds. Missed while the Mac was locked, it shows when you're back within the hour. Uses TokenBar.",
                           isOn: Binding(get: { vm.notchLimitResetNotice },
                                         set: { vm.notchLimitResetNotice = $0 }))
                    if vm.notchAgentDoneNotice || vm.notchLimitResetNotice {
                        SettingsToggleRow("Ding with them", detail: "Plays the sound Codex in the ChatGPT app plays when a task is done (macOS's Glass without it) as either one appears, at your alert volume.",
                               isOn: Binding(get: { vm.notchNoticeSound },
                                             set: { vm.notchNoticeSound = $0 }))
                    }
                    if vm.lockScreenAgentActivity {
                        Picker("After they finish, keep the display on", selection: Binding(get: { vm.lockScreenAgentStay },
                                                                                            set: { vm.lockScreenAgentStay = $0 })) {
                            ForEach(LockScreenStay.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    }
                }
            default:
                Section {
                    ForEach($vm.displaplacerPresets) { $preset in
                        HStack(spacing: 10) {
                            TextField("Preset name", text: $preset.name)
                            Button("Apply") {
                                DisplaplacerEngine.apply(preset)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { refreshDisplays() }
                            }
                            .buttonStyle(.bordered)
                            Button(role: .destructive) {
                                vm.displaplacerPresets.removeAll { $0.id == preset.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                    if vm.displaplacerPresets.isEmpty {
                        Text("Save your current layout to restore it later.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Presets")
                        Spacer()
                        Button("Save Current Layout") {
                            let preset = DisplaplacerPreset(
                                name: "New Preset",
                                layouts: DisplaplacerEngine.captureCurrentLayout()
                            )
                            vm.displaplacerPresets.append(preset)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            refreshDisplays()
            // Show whatever the launch scan already found, and only pay for a new
            // scan if it came up empty (no monitor plugged in at launch).
            inputMonitors = DisplayInputEngine.monitors
            if inputMonitors.isEmpty && !DisplayInputEngine.hasScanned { refreshInputs() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            // Refresh now so an unplugged monitor drops instantly; the screen-params
            // notification fires after CGGetOnlineDisplayList has already updated.
            // The delayed second pass catches any late settling (resolution/arrangement).
            refreshDisplays()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshDisplays() }
            // AppDelegate relists monitors on the same notification (and probes a
            // new one once the link settles); pick up its result rather than
            // starting a second pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                inputMonitors = DisplayInputEngine.monitors
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                inputMonitors = DisplayInputEngine.monitors
            }
        }
    }

    // MARK: Monitor input

    /// Auto-eject is meaningless until MSG knows which input is this Mac, so the
    /// toggle stays disabled rather than silently doing nothing.
    private var hasMacInputMarked: Bool {
        inputMonitors.contains { $0.inputs.contains(where: \.isMac) }
    }

    @ViewBuilder
    private var monitorInputContent: some View {
        if inputMonitors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(scanningInputs
                     ? "Checking what your monitors support…"
                     : "No monitor here supports switching inputs over its cable.")
                // A monitor currently showing another machine is indistinguishable
                // from one that can't do this at all — its DDC bus is silent either
                // way — so say what to do rather than leaving it a dead end.
                if !scanningInputs {
                    Text("If your monitor is showing another device right now, switch "
                         + "it back with its own input button and press Rescan.")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        } else {
            ForEach(inputMonitors) { monitor in
                VStack(alignment: .leading, spacing: 6) {
                    if inputMonitors.count > 1 {
                        Text(monitor.name).font(.subheadline)
                    }
                    if monitor.reachable {
                        ForEach(monitor.inputs) { input in
                            inputRow(monitor: monitor, input: input)
                        }
                        if monitor.inputs.contains(where: { !$0.advertised }) {
                            Text("This monitor didn't list its inputs, so these are the "
                                 + "common ones. An input it doesn't have simply won't do anything.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        unreachableRow(monitor: monitor)
                    }
                }
            }
        }
    }

    /// Shown while the panel is displaying another machine. Its DDC bus is silent
    /// then, so MSG cannot switch it back — only the monitor's own input button
    /// can. Reconnecting the display is pure CoreGraphics and still works.
    @ViewBuilder
    private func unreachableRow(monitor: DisplayInputEngine.Monitor) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Showing another device")
                Text("Press the monitor's input button to bring it back")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if DisplayInputEngine.isHandoverEjected(monitorKey: monitor.key) {
                Button("Reconnect") {
                    DisplayInputEngine.reconnectDisplay(monitorKey: monitor.key)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        inputMonitors = DisplayInputEngine.monitors
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func inputRow(monitor: DisplayInputEngine.Monitor,
                          input: DisplayInputEngine.Input) -> some View {
        let rowID = "\(monitor.key)#\(String(format: "%02X", input.code))"
        let isEditing = editingInputID == rowID

        return HStack(spacing: 10) {
            if isEditing {
                TextField("Name this input", text: $editingInputName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(monitor: monitor, input: input) }
                Button("Save") { commitRename(monitor: monitor, input: input) }
                    .buttonStyle(.bordered)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(input.label)
                    // Keep the real port visible when renamed, so "PC" still tells
                    // you which cable it is.
                    if input.customName?.isEmpty == false {
                        Text(input.standardName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Marking is a toggle: tapping the marked input clears it, which
                // is also how you switch the mark off entirely.
                Button(input.isMac ? "✓ This Mac" : "This Mac") {
                    DisplayInputEngine.setMacInput(input.isMac ? nil : input.code,
                                                   monitorKey: monitor.key)
                    inputMonitors = DisplayInputEngine.monitors
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(input.isMac ? Color.accentColor : .secondary)
                Button("Rename") {
                    editingInputName = input.customName ?? ""
                    editingInputID = rowID
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Switch") {
                    DisplayInputEngine.selectInput(monitorKey: monitor.key,
                                                   code: input.code,
                                                   autoEject: vm.monitorInputAutoEject)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func commitRename(monitor: DisplayInputEngine.Monitor,
                              input: DisplayInputEngine.Input) {
        DisplayInputEngine.setCustomName(editingInputName, monitorKey: monitor.key, code: input.code)
        inputMonitors = DisplayInputEngine.monitors
        editingInputID = nil
        editingInputName = ""
    }

    /// `probe` re-reads the monitors over DDC; without it this only relists
    /// them. Probing is left to the Rescan button because on some links the
    /// probing itself can wedge DDC until the adapter is replugged.
    private func refreshInputs(probe: Bool = false) {
        scanningInputs = true
        let done = {
            inputMonitors = DisplayInputEngine.monitors
            scanningInputs = false
        }
        if probe { DisplayInputEngine.rescan(completion: done) } else { DisplayInputEngine.refresh(completion: done) }
    }

    private func displayRow(_ info: DisplaplacerEngine.DisplayInfo) -> some View {
        // Count ALL active displays (incl. built-in) so the last external can
        // still be ejected while the built-in remains.
        let totalActive = DisplaplacerEngine.allOnlineDisplays().filter { $0.enabled }.count
        let canToggle = info.enabled ? totalActive > 1 : true

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                Text(info.enabled ? "Connected" : "Ejected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { info.enabled },
                set: { enabled in
                    DisplaplacerEngine.setEnabled(info.uuid, enabled: enabled)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refreshDisplays() }
                }
            ))
            .disabled(!canToggle)
            .labelsHidden()
        }
    }

    private func refreshDisplays() {
        externalDisplays = DisplaplacerEngine.externalDisplays()
    }
}

// MARK: - Temperature Range Slider Helper

@available(macOS 14.0, *)
struct TemperatureRangeSlider: View {
    @Binding var minVal: Double
    @Binding var maxVal: Double
    var bounds: ClosedRange<Double> = 0...120

    private let step: Double = 1.0
    
    @State private var isHoveringMin = false
    @State private var isHoveringMax = false
    @State private var isDraggingMin = false
    @State private var isDraggingMax = false
    
    @State private var activeThumb: ActiveThumb? = nil
    enum ActiveThumb { case min, max }

    private func xOffset(for value: Double, width: CGFloat, thumbSize: CGFloat) -> CGFloat {
        let pct = (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        let usableWidth = width - thumbSize
        return pct * usableWidth + (thumbSize / 2)
    }
    
    private func value(for x: CGFloat, width: CGFloat, thumbSize: CGFloat) -> Double {
        let usableWidth = width - thumbSize
        let pct = max(0, min(1, (x - thumbSize / 2) / usableWidth))
        let rawVal = bounds.lowerBound + pct * (bounds.upperBound - bounds.lowerBound)
        return (rawVal / step).rounded() * step
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = 6
            let thumbSize: CGFloat = 16
            
            let xMin = xOffset(for: minVal, width: width, thumbSize: thumbSize)
            let xMax = xOffset(for: maxVal, width: width, thumbSize: thumbSize)
            
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)
                
                // Active range track (gradient)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.85),
                                Color.cyan.opacity(0.85),
                                Color.yellow.opacity(0.85),
                                Color.orange.opacity(0.9),
                                Color.red.opacity(0.95)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, xMax - xMin), height: trackHeight)
                    .offset(x: xMin)
                
                // Left Thumb (Min)
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1.5)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
                .scaleEffect((isHoveringMin || isDraggingMin) ? 1.25 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHoveringMin || isDraggingMin)
                .position(x: xMin, y: geo.size.height / 2)
                .contentShape(Circle())
                .onHover { hovering in
                    isHoveringMin = hovering
                }
                
                // Right Thumb (Max)
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1.5)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                }
                .scaleEffect((isHoveringMax || isDraggingMax) ? 1.25 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHoveringMax || isDraggingMax)
                .position(x: xMax, y: geo.size.height / 2)
                .contentShape(Circle())
                .onHover { hovering in
                    isHoveringMax = hovering
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let x = gesture.location.x
                        let val = value(for: x, width: width, thumbSize: thumbSize)
                        
                        if activeThumb == nil {
                            if abs(val - minVal) < abs(val - maxVal) {
                                activeThumb = .min
                                isDraggingMin = true
                            } else {
                                activeThumb = .max
                                isDraggingMax = true
                            }
                        }
                        
                        if activeThumb == .min {
                            let finalVal = max(bounds.lowerBound, min(val, maxVal - 5))
                            if finalVal != minVal {
                                minVal = finalVal
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        } else {
                            let finalVal = min(bounds.upperBound, max(val, minVal + 5))
                            if finalVal != maxVal {
                                maxVal = finalVal
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                    }
                    .onEnded { _ in
                        activeThumb = nil
                        isDraggingMin = false
                        isDraggingMax = false
                    }
            )
        }
        .frame(height: 22)
    }
}
