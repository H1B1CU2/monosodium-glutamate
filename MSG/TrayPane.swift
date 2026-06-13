import SwiftUI
import AppKit

// MARK: - Tray settings pane

@available(macOS 14.0, *)
struct TrayPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        PaneContainer(section: .tray, headerToggle: Binding(
            get: { vm.trayEnabled },
            set: { vm.trayEnabled = $0; NotificationCenter.default.post(name: .trayEnabledChanged, object: nil) }
        )) {
            Section("Preview") {
                TrayHUDPreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section {
                Text("When enabled, Tray intercepts ⌘⇥ system-wide and shows the HUD. Requires Accessibility permission.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Switcher")
            }

            Section("Pinned Apps") {
                Toggle("Mirror my Dock",
                       isOn: Binding(get: { vm.trayDockSync }, set: { vm.trayDockSync = $0 }))
                Text("Reads pinned apps from your Dock and keeps them in sync automatically.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section("Now Playing") {
                Toggle("Show Now Playing card",
                       isOn: Binding(get: { vm.trayShowNowPlaying }, set: { vm.trayShowNowPlaying = $0 }))
                if vm.trayShowNowPlaying {
                    Picker("Source", selection: Binding(
                        get: { vm.musicSource },
                        set: { vm.musicSource = $0 }
                    )) {
                        ForEach(MusicSource.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let trayEnabledChanged = Notification.Name("trayEnabledChanged")
}

// MARK: - Scaled V2.2 HUD preview

@available(macOS 14.0, *)
struct TrayHUDPreview: View {
    private let refW: CGFloat = 700
    private let refH: CGFloat = 430

    var body: some View {
        // aspectRatio reserves exactly the scaled canvas height at any pane
        // width (the old hardcoded-520pt math clipped or gapped the layout).
        GeometryReader { geo in
            TrayHUDCanvas()
                .frame(width: refW, height: refH)
                .scaleEffect(geo.size.width / refW, anchor: .topLeading)
        }
        .aspectRatio(refW / refH, contentMode: .fit)
    }
}

// Fixed-size canvas drawn at refW × refH, then scaled by TrayHUDPreview.
// Mirrors TrayHUDView's real layout (same tiles, metrics and dark scheme)
// with sample data, so the preview stays honest about what ⌘⇥ shows.
@available(macOS 14.0, *)
private struct TrayHUDCanvas: View {

    private static func sampleApp(_ bundleID: String, _ name: String, playing: Bool = false) -> TrayApp {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        return TrayApp(id: bundleID, name: name, icon: icon, pid: 0, badge: nil, isPlaying: playing)
    }

    private let active: [TrayApp] = [
        sampleApp("com.apple.finder", "Finder"),
        sampleApp("com.apple.Safari", "Safari"),
        sampleApp("com.apple.Notes", "Notes"),
        sampleApp("com.apple.Music", "Music", playing: true),
    ]
    private let hidden: [TrayApp] = [
        sampleApp("com.apple.Terminal", "Terminal"),
        sampleApp("com.apple.Preview", "Preview"),
    ]
    private let pinned: [TrayApp] = [
        sampleApp("com.apple.mail", "Mail"),
        sampleApp("com.apple.iCal", "Calendar"),
        sampleApp("com.apple.Photos", "Photos"),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(.thickMaterial)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)

            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .padding(.vertical, 12)

                rightColumn
                    .padding(20)
                    .frame(width: 280, alignment: .topLeading)
            }
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    // MARK: Left column (matches TrayHUDView.leftColumn)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchPill
            rowHeader("Active", count: "\(active.count) apps")
            tileRow(active, selectedIndex: 1)
            divider
            rowHeader("Hidden", count: "\(hidden.count) apps")
            tileRow(hidden, selectedIndex: nil)
            divider
            rowHeader("Dock", count: "\(pinned.count) apps")
            tileRow(pinned, selectedIndex: nil)
        }
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text("switch to…")
                .font(.system(size: 13)).foregroundStyle(.tertiary)
            Spacer()
            Text("type to filter · ⎋ clear")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func tileRow(_ apps: [TrayApp], selectedIndex: Int?) -> some View {
        HStack(spacing: 14) {
            ForEach(apps.indices, id: \.self) { i in
                TrayTileView(app: apps[i],
                             selected: i == selectedIndex,
                             size: 72,
                             showName: false)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    private func rowHeader(_ title: String, count: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text("· \(count)").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Right column (matches TrayHUDView.rightColumn)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1).foregroundStyle(.tertiary)
            Text("Safari")
                .font(.system(size: 20, weight: .semibold))
            Text("· 2 windows")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)

            windowThumb(height: 140, radius: 7, icon: active[1].icon)
            HStack(spacing: 4) {
                windowThumb(height: 70, radius: 5)
                windowThumb(height: 70, radius: 5)
            }

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.vertical, 4)

            nowPlayingCard
        }
    }

    private func windowThumb(height: CGFloat, radius: CGFloat, icon: NSImage? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Color(nsColor: .controlBackgroundColor)
            .overlay(
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48).opacity(0.3)
                    }
                }
            )
            .frame(height: height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = active[3].icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .controlBackgroundColor)
                        .overlay(Image(systemName: "music.note")
                            .font(.system(size: 18)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Midnight City")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("M83")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            HStack(spacing: 2) {
                ForEach([8, 12, 6, 10], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: CGFloat(h))
                }
            }
            .frame(height: 14)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}
