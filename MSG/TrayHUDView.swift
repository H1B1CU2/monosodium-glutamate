import SwiftUI
import AppKit
import Combine

// MARK: - Root HUD view (V2.2 two-column layout)

@available(macOS 14.0, *)
struct TrayHUDView: View {
    @ObservedObject var state: TrayState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .frame(maxWidth: .infinity)
                .padding(20)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .padding(.vertical, 12)

            rightColumn
                .padding(20)
                .frame(width: 280, alignment: .topLeading)
                .clipped()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            rowHeader("Active", count: "\(state.filteredActive.count) apps")
            activeTiles
            if !state.filteredHidden.isEmpty {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .padding(.vertical, 2)
                rowHeader("Hidden", count: "\(state.filteredHidden.count) apps")
                hiddenTiles
            }
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.vertical, 2)
            rowHeader("Dock", count: "\(state.filteredPinned.count) apps")
            pinnedTiles
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("switch to…", text: $state.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            Spacer()
            if state.search.isEmpty {
                Text("type to filter · ⎋ clear")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Button { state.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: Active tiles

    private var activeTiles: some View {
        let apps = state.filteredActive
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 14)],
                         alignment: .leading, spacing: 10) {
            ForEach(0..<apps.count, id: \.self) { i in
                activeTile(apps[i], i: i)
            }
        }
    }

    private func activeTile(_ app: TrayApp, i: Int) -> some View {
        let sel = state.selection == .active(i)
        return TrayTileView(app: app,
                            selected: sel,
                            showPill: state.desktopAppIDs.contains(app.id),
                            size: 72,
                            showName: false,
                            onHover: { self.state.selection = .active(i) },
                            onActivate: { self.state.activateSelection() })
    }

    private var pinnedTiles: some View {
        let pins = state.filteredPinned
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                         alignment: .leading, spacing: 8) {
            ForEach(0..<pins.count, id: \.self) { i in
                TrayTileView(app: pins[i],
                             selected: false,
                             size: 72,
                             showName: false,
                             onActivate: {
                                 self.state.selection = .pinned(i)
                                 self.state.activateSelection()
                             })
            }
        }
    }

    private var hiddenTiles: some View {
        let apps = state.filteredHidden
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 14)],
                         alignment: .leading, spacing: 10) {
            ForEach(0..<apps.count, id: \.self) { i in
                TrayTileView(app: apps[i],
                             selected: state.selection == .hidden(i),
                             size: 72,
                             showName: false,
                             onHover: { self.state.selection = .hidden(i) },
                             onActivate: { self.state.activateSelection() })
            }
        }
    }

    // MARK: Now Playing card

    private var nowPlayingCard: some View {
        HStack(spacing: 10) {
            // Album art
            Group {
                if let art = state.albumArt {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .controlBackgroundColor)
                        .overlay(Image(systemName: "music.note")
                            .font(.system(size: 18)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.nowPlayingTitle ?? "Unknown Track")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(state.nowPlayingArtist ?? "")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()
            AudioVisualizer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    // MARK: Row header

    private func rowHeader(_ title: String, count: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("· \(count)").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Right column (preview pane)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1).foregroundStyle(.tertiary)

            if let app = state.previewedApp {
                Text(app.name)
                    .font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text("· \(state.previewImages.count) window\(state.previewImages.count == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)

                ScrollView(.vertical, showsIndicators: false) {
                    WindowPreviewGrid(
                        images: state.previewImages,
                        fallback: app.icon,
                        onTap: { state.activateWindowPreview(at: $0) }
                    )
                }
            } else {
                Spacer()
                Text("Nothing to show")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 13))
                Spacer()
            }

            if state.isNowPlaying {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .padding(.vertical, 4)
                nowPlayingCard
            }
            Spacer()
        }
    }

    private func chip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Tile view

@available(macOS 14.0, *)
struct TrayTileView: View {
    let app: TrayApp
    let selected: Bool
    var showPill: Bool = false
    var size: CGFloat = 52
    var showName: Bool = true
    var onHover: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil

    @State private var isHovered = false

    private var squircle: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 4) {
            iconView
                .overlay { if showPill || app.isPlaying { pillOverlay } }
                .shadow(color: (isHovered || selected) ? Color.white.opacity(0.9) : .clear, radius: 8, x: 0, y: 0)

            if showName {
                Text(app.name)
                    .font(.system(size: 12)).lineLimit(1)
                    .frame(maxWidth: size + 18)
            }
        }
        .scaleEffect((isHovered || selected) ? 1.15 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: selected)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHover?() }
        }
        .onTapGesture { onActivate?() }
    }

    private var iconView: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    Text(String(app.name.prefix(2)))
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) { badgeView }
    }

    @ViewBuilder private var badgeView: some View {
        if let badge = app.badge {
            Text(badge)
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.red, in: Capsule())
                .overlay(Capsule().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                .offset(x: 6, y: -6)
        }
    }

    private var pillOverlay: some View {
        VStack {
            Spacer()
            Capsule()
                .fill(app.isPlaying ? Color.green : .white.opacity(0.7))
                .frame(width: size * 0.22, height: 3)
                .padding(.bottom, 0)
        }
    }
}

// MARK: - Window preview grid

@available(macOS 14.0, *)
private struct WindowPreviewGrid: View {
    let images: [NSImage]
    let fallback: NSImage?
    let onTap: (Int) -> Void

    @State private var hoveredIndex: Int? = nil

    // column frame(280) minus padding(20)×2
    private let cw: CGFloat = 240
    private let gap: CGFloat = 4

    private func ar(_ img: NSImage) -> CGFloat {
        img.size.height > 0 ? img.size.width / img.size.height : 16.0 / 9.0
    }

    var body: some View {
        if images.isEmpty {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: gap) {
                thumb(images[0], index: 0, w: cw, radius: 7)

                let rest = Array(images.dropFirst().prefix(4))
                if !rest.isEmpty {
                    secondaryRows(rest)
                }
            }
        }
    }

    @ViewBuilder private func secondaryRows(_ imgs: [NSImage]) -> some View {
        let rowCount = (imgs.count + 1) / 2
        ForEach(0..<rowCount, id: \.self) { row in
            HStack(alignment: .top, spacing: gap) {
                let i0 = row * 2
                let i1 = i0 + 1
                let tw: CGFloat = i1 < imgs.count ? (cw - gap) / 2 : cw
                thumb(imgs[i0], index: i0 + 1, w: tw, radius: 5)
                if i1 < imgs.count {
                    thumb(imgs[i1], index: i1 + 1, w: tw, radius: 5)
                }
            }
        }
    }

    // Always fits the image perfectly to its natural aspect ratio at width w.
    private func thumb(_ img: NSImage, index: Int, w: CGFloat, radius: CGFloat) -> some View {
        let h = w / ar(img)
        let isHovered = hoveredIndex == index
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: w, height: h)
            .clipShape(shape)
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(shape.strokeBorder(
                isHovered ? Color.white.opacity(0.75) : Color(nsColor: .separatorColor),
                lineWidth: 1
            ))
            .onHover { hovering in hoveredIndex = hovering ? index : nil }
            .onTapGesture { onTap(index) }
    }

    @ViewBuilder private var placeholder: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Color(nsColor: .controlBackgroundColor)
            .overlay(
                Group {
                    if let icon = fallback {
                        Image(nsImage: icon).resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48).opacity(0.3)
                    }
                }
            )
            .frame(width: cw, height: 120)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Audio visualizer (same engine as menu bar)

@available(macOS 14.0, *)
private final class VisualizerModel: ObservableObject {
    @Published var heights: [CGFloat] = [0.4, 0.7, 0.5, 0.9]
    private var targets: [CGFloat] = [0.4, 0.7, 0.5, 0.9]
    private var tick = 0
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] t in
            guard let self else { return }
            if self.tick % 15 == 0 {
                for i in 0..<4 {
                    self.targets[i] = CGFloat.random(in: 0.3...1.0)
                }
            }
            for i in 0..<4 {
                self.heights[i] += (self.targets[i] - self.heights[i]) * 0.4
            }
            self.tick += 1
        }
        if let t = timer { RunLoop.current.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

@available(macOS 14.0, *)
private struct AudioVisualizer: View {
    @StateObject private var model = VisualizerModel()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: 4 + model.heights[i] * 10)
            }
        }
        .frame(height: 14)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
