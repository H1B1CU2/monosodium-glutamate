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

