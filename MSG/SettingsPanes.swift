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

            Section {
                Toggle("Replace macOS volume & brightness HUD",
                       isOn: Binding(get: { vm.systemHUDEnabled }, set: { vm.systemHUDEnabled = $0 }))
                if vm.systemHUDEnabled {
                    Toggle("Volume",
                           isOn: Binding(get: { vm.systemHUDVolume }, set: { vm.systemHUDVolume = $0 }))
                    Toggle("Brightness (built-in display)",
                           isOn: Binding(get: { vm.systemHUDBrightness }, set: { vm.systemHUDBrightness = $0 }))
                }
            } header: {
                Text("Volume & Brightness HUD")
            } footer: {
                Text("The indicator morphs into a level bar when you press the volume or brightness keys, replacing the native macOS popup. Requires Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility); relaunch MSG after granting it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
        PaneContainer(section: .corner,
                      headerToggle: Binding(get: { vm.cornersEnabled }, set: { vm.cornersEnabled = $0 })) {
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

            Section(MacModel.name) {
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
        }
        .onAppear {
            WallpaperEngine.shared.isEditing = true
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
            WallpaperEngine.shared.isEditing = false
            WallpaperEngine.shared.onExternalChange = nil
            // showBaseline() was called on appear; sync() re-bakes (covering any
            // pending edits, including the header toggle) or restores the
            // baseline if corners are now disabled. An unresolved external
            // change is left alone — the poll adopts it now that editing ended.
            if !WallpaperEngine.shared.externalChangePending {
                WallpaperEngine.shared.sync()
            }
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
                    .onChange(of: vm.musicLingerDuration) { _, newVal in
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
    @State private var stats = HardwareStats()
    @State private var timer: Timer?

    var body: some View {
        PaneContainer(section: .hardware,
                      headerToggle: Binding(get: { vm.hardwareStatsEnabled },
                                            set: { vm.hardwareStatsEnabled = $0 })) {
            Section("Preview") {
                previewCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if vm.hardwareStatsEnabled {
                Section("Modules") {
                    Toggle("CPU", isOn: $vm.hardwareStatsShowCPU)
                    Toggle("GPU", isOn: $vm.hardwareStatsShowGPU)
                    Toggle("Memory", isOn: $vm.hardwareStatsShowMemory)
                    Toggle("Temperature", isOn: $vm.hardwareStatsShowTemp)
                    Toggle("FPS", isOn: $vm.hardwareStatsShowFPS)
                    Toggle("Fan", isOn: $vm.hardwareStatsShowFan)
                }

                Section("Appearance") {
                    Picker("Bar style", selection: $vm.hardwareStatsBarStyle) {
                        Text("Vertical").tag("vertical")
                        Text("Circular").tag("circular")
                    }
                    .pickerStyle(.segmented)
                    Picker("Label position", selection: $vm.hardwareStatsLabelPos) {
                        Text("Vertical").tag("vertical")
                        Text("Horizontal").tag("horizontal")
                    }
                    .pickerStyle(.segmented)
                    Picker("Temp sensor", selection: $vm.hardwareStatsTempSensor) {
                        Text("Auto").tag("auto")
                        Text("CPU").tag("cpu")
                        Text("GPU").tag("gpu")
                    }
                    if vm.hardwareStatsShowTemp {
                        HStack {
                            Text("Temp Min")
                            Slider(value: $vm.hardwareStatsTempMin, in: 0...80, step: 5)
                            Text("\(Int(vm.hardwareStatsTempMin))°C")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        HStack {
                            Text("Temp Max")
                            Slider(value: $vm.hardwareStatsTempMax, in: 60...120, step: 5)
                            Text("\(Int(vm.hardwareStatsTempMax))°C")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    Picker("Memory mode", selection: $vm.hardwareStatsMemMode) {
                        Text("Pressure").tag("pressure")
                        Text("Usage %").tag("usage")
                    }
                    HStack {
                        Text("Update every")
                        Slider(value: $vm.hardwareStatsInterval, in: 1...10, step: 1)
                        Text("\(Int(vm.hardwareStatsInterval))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }

                Section("Current Values") {
                    LabeledContent("CPU") {
                        Text(String(format: "%.1f%%", stats.cpuPercent))
                            .foregroundStyle(barColor(ratio: stats.cpuPercent / 100.0))
                            .monospacedDigit()
                    }
                    LabeledContent("GPU") {
                        Text(String(format: "%.1f%%", stats.gpuPercent))
                            .foregroundStyle(barColor(ratio: stats.gpuPercent / 100.0))
                            .monospacedDigit()
                    }
                    LabeledContent("Memory") {
                        HStack(spacing: 4) {
                            Circle().fill(pressureColor(stats.memoryPressure))
                                .frame(width: 8, height: 8)
                            Text(String(format: "%.1f GB", stats.memoryUsedGB))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                    }
                    if let t = stats.cpuTemp {
                        LabeledContent("CPU Temp") {
                            Text(String(format: "%.0f°C", t))
                                .foregroundStyle(barColor(ratio: (t - 30) / 70.0))
                                .monospacedDigit()
                        }
                    }
                    if let t = stats.gpuTemp {
                        LabeledContent("GPU Temp") {
                            Text(String(format: "%.0f°C", t))
                                .foregroundStyle(barColor(ratio: (t - 30) / 70.0))
                                .monospacedDigit()
                        }
                    }
                    if stats.fps > 0 {
                        LabeledContent("FPS") {
                            Text("\(stats.fps) Hz")
                                .foregroundStyle(barColor(ratio: Double(stats.fps) / 144.0))
                                .monospacedDigit()
                        }
                    }
                }

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
                            Text("Full Blast").tag("fullBlast")
                        }
                        .pickerStyle(.menu)
                        .onChange(of: vm.hardwareStatsFanPreset) { _, newVal in
                            if newVal == "fullBlast" {
                                HardwareMonitor.shared.fanFullBlast()
                            } else if newVal == "default" {
                                HardwareMonitor.shared.fanReset()
                            }
                        }

                        if vm.hardwareStatsFanPreset != "default",
                           vm.hardwareStatsFanPreset != "fullBlast",
                           let curve = vm.hardwareStatsFanCurves[vm.hardwareStatsFanPreset] {
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
        }
        .onAppear {
            stats = HardwareMonitor.shared.stats
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                DispatchQueue.main.async { stats = HardwareMonitor.shared.stats }
            }
            if let t = timer { RunLoop.current.add(t, forMode: .common) }
        }
        .onDisappear {
            timer?.invalidate(); timer = nil
        }
    }

    // MARK: - Preview card

    /// Mirrors the actual menu bar rendering using SwiftUI shapes.
    private var previewCard: some View {
        let mods = previewModules()
        guard !mods.isEmpty else {
            return AnyView(
                Text("Enable at least one module above")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            )
        }

        let isCircular = vm.hardwareStatsBarStyle == "circular"
        let isHorizontal = vm.hardwareStatsLabelPos == "horizontal"
        let barH: CGFloat = isCircular ? 28 : 36

        return AnyView(
            HStack(alignment: .bottom, spacing: isHorizontal ? 10 : 12) {
                ForEach(Array(mods.enumerated()), id: \.offset) { _, mod in
                    VStack(spacing: 4) {
                        if mod.isValue {
                            Text(mod.valueText)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text(mod.label)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else if isCircular {
                            ZStack {
                                Circle()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                                    .frame(width: 20, height: 20)
                                if mod.ratio > 0 {
                                    Circle()
                                        .trim(from: 0, to: max(0.01, mod.ratio))
                                        .stroke(previewColor(mod), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                        .frame(width: 20, height: 20)
                                        .rotationEffect(.degrees(-90))
                                }
                            }
                            if isHorizontal {
                                Text(mod.label)
                                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 0) {
                                    ForEach(Array(mod.label.enumerated()), id: \.offset) { _, ch in
                                        Text(String(ch))
                                            .font(.system(size: 5.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            // Vertical bar (matches menu bar)
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 8, height: barH)
                                if mod.ratio > 0 {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(previewColor(mod))
                                        .frame(width: 8, height: max(3, barH * mod.ratio))
                                }
                            }
                            if isHorizontal {
                                Text(mod.label)
                                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 0) {
                                    ForEach(Array(mod.label.enumerated()), id: \.offset) { _, ch in
                                        Text(String(ch))
                                            .font(.system(size: 5.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        )
    }

    private struct PreviewMod {
        let label: String
        let ratio: CGFloat
        var isValue: Bool = false
        var valueText: String = ""
    }

    private func previewModules() -> [PreviewMod] {
        var mods: [PreviewMod] = []
        if vm.hardwareStatsShowCPU {
            mods.append(PreviewMod(label: "CPU", ratio: CGFloat(stats.cpuPercent / 100.0)))
        }
        if vm.hardwareStatsShowGPU {
            mods.append(PreviewMod(label: "GPU", ratio: CGFloat(stats.gpuPercent / 100.0)))
        }
        if vm.hardwareStatsShowMemory {
            let r: CGFloat
            if vm.hardwareStatsMemMode == "usage" {
                r = stats.memoryTotalGB > 0
                    ? CGFloat(min(1.0, stats.memoryUsedGB / stats.memoryTotalGB))
                    : 0
            } else {
                r = {
                    switch stats.memoryPressure {
                    case .normal: return 0.25
                    case .warning: return 0.60
                    case .critical: return 0.90
                    }
                }()
            }
            mods.append(PreviewMod(label: "MEM", ratio: r))
        }
        if vm.hardwareStatsShowTemp {
            let sensor = vm.hardwareStatsTempSensor
            let t: Double
            switch sensor {
            case "cpu": t = stats.cpuTemp ?? 30
            case "gpu": t = stats.gpuTemp ?? 30
            default:    t = stats.cpuTemp ?? stats.gpuTemp ?? 30
            }
            let minT = vm.hardwareStatsTempMin
            let maxT = vm.hardwareStatsTempMax
            let range = max(1.0, maxT - minT)
            mods.append(PreviewMod(label: "TMP", ratio: CGFloat((t - minT) / range)))
        }
        if vm.hardwareStatsShowFPS {
            mods.append(PreviewMod(label: "FPS", ratio: 0,
                                   isValue: true, valueText: "\(stats.fps)"))
        }
        if vm.hardwareStatsShowFan, let fan = stats.fans.first {
            let r = CGFloat(fan.current) / CGFloat(max(1, fan.max))
            mods.append(PreviewMod(label: "FAN", ratio: r))
        }
        return mods
    }

    /// Matches the barColor logic in HardwareBarView: white ≤50%, yellow 50%+, orange 65%+, red 80%+.
    private func previewColor(_ mod: PreviewMod) -> Color {
        if mod.isValue { return .white }
        let r = max(0, min(1, mod.ratio))
        if r < 0.5 { return .white }
        let hue: Double
        if r < 0.65 {
            let t = (r - 0.5) / 0.15
            hue = 0.15 - 0.05 * t
        } else if r < 0.8 {
            let t = (r - 0.65) / 0.15
            hue = 0.10 * (1.0 - t)
        } else {
            hue = 0.0
        }
        return Color(hue: hue, saturation: 0.9, brightness: 0.95)
    }

    // MARK: - Colors (used by Current Values section)

    private func barColor(ratio: Double) -> Color {
        let r = max(0, min(1, ratio))
        if r < 0.5 { return .white }
        let hue: Double
        if r < 0.65 {
            let t = (r - 0.5) / 0.15
            hue = 0.15 - 0.05 * t
        } else if r < 0.8 {
            let t = (r - 0.65) / 0.15
            hue = 0.10 * (1.0 - t)
        } else {
            hue = 0.0
        }
        return Color(hue: hue, saturation: 0.9, brightness: 0.95)
    }

    private func fanColor(_ fan: FanInfo) -> Color {
        let r = Double(fan.current) / Double(max(1, fan.max))
        if r < 0.5 { return .white }
        let hue: Double
        if r < 0.65 {
            let t = (r - 0.5) / 0.15
            hue = 0.15 - 0.05 * t
        } else if r < 0.8 {
            let t = (r - 0.65) / 0.15
            hue = 0.10 * (1.0 - t)
        } else {
            hue = 0.0
        }
        return Color(hue: hue, saturation: 0.9, brightness: 0.95)
    }

    private func pressureColor(_ p: HardwareStats.MemoryPressure) -> Color {
        switch p {
        case .normal: return .gray
        case .warning: return .orange
        case .critical: return .red
        }
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
                Text("Tightens the gap and click area around every menu bar icon, system-wide. macOS reads this value when each item launches, so a logout or restart may be required for all icons to update.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Section {
                Button("Apply") {
                    MenuBarSpacingManager.applyAndOfferLogout(spacing: vm.menuBarSpacing, padding: vm.menuBarSpacingPadding)
                }
                Button("Reset to Default") {
                    vm.menuBarSpacing = MenuBarSpacingManager.systemDefault
                    vm.menuBarSpacingPadding = MenuBarSpacingManager.systemDefault
                    MenuBarSpacingManager.reset()
                    MenuBarSpacingManager.restartMenuBar()
                }
                .foregroundStyle(.secondary)
            }
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
                    if let img = NSApp.effectiveAppearance.name == .darkAqua ? (NSImage(named: "AppIcon-Dark") ?? NSImage(named: "AppIcon")) : NSImage(named: "AppIcon") {
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
            .listRowBackground(Color.clear)

            Section("Behavior") {
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
                Toggle("Show in Dock",
                       isOn: Binding(get: { vm.dockIcon }, set: { vm.dockIcon = $0 }))
                Toggle("Show Developer section",
                       isOn: Binding(get: { vm.showDeveloper }, set: { vm.showDeveloper = $0 }))
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

}

// MARK: - Displaplacer pane

@available(macOS 14.0, *)
struct DisplaplacerPane: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var externalDisplays: [DisplaplacerEngine.DisplayInfo] = []

    var body: some View {
        PaneContainer(section: .displaplacer,
                      headerToggle: Binding(get: { vm.displaplacerEnabled }, set: { vm.displaplacerEnabled = $0 })) {
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
                    Text("No presets saved. Tap \u{201C}Save Current Layout\u{201D} above to create one.")
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
        .onAppear { refreshDisplays() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            // Refresh now so an unplugged monitor drops instantly; the screen-params
            // notification fires after CGGetOnlineDisplayList has already updated.
            // The delayed second pass catches any late settling (resolution/arrangement).
            refreshDisplays()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refreshDisplays() }
        }
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

