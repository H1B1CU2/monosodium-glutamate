import SwiftUI
import AppKit

// MARK: - Tray settings pane

@available(macOS 14.0, *)
struct TrayPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        PaneContainer(section: .tray) {
            Section("Preview") {
                TrayHUDPreview()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("Replace ⌘⇥ with Tray",
                       isOn: Binding(get: { vm.trayEnabled }, set: { vm.trayEnabled = $0 }))
                    .onChange(of: vm.trayEnabled) { _ in
                        NotificationCenter.default.post(name: .trayEnabledChanged, object: nil)
                    }
            } header: {
                Text("Switcher")
            } footer: {
                Text("When enabled, Tray intercepts ⌘⇥ system-wide and shows the HUD. Requires Accessibility permission.")
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
    private let refW: CGFloat = 660
    private let refH: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / refW
            TrayHUDCanvas()
                .frame(width: refW, height: refH)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: refH * scale, alignment: .topLeading)
        }
        .frame(height: previewHeight)
    }

    private var previewHeight: CGFloat {
        // Compute based on typical settings pane content width (~520pt)
        let availW: CGFloat = 520
        return refH * (availW / refW)
    }
}

// Fixed-size canvas drawn at refW × refH, then scaled by TrayHUDPreview
@available(macOS 14.0, *)
private struct TrayHUDCanvas: View {

    private let sampleActive = [
        ("Fo", "Finder",   false),
        ("Sa", "Safari",   false),
        ("VS", "VS Code",  false),
        ("Fg", "Figma",    false),
        ("#",  "Slack",    false),
        ("♪",  "Music",    true ),
    ]

    private let samplePinned = [
        ("N",  "Notes"  ),
        ("✓",  "Things" ),
        ("🔑", "1Pass"  ),
        ("L",  "Linear" ),
        ("R",  "Raycast"),
    ]

    var body: some View {
        ZStack {
            // HUD background
            RoundedRectangle(cornerRadius: 16)
                .fill(.thickMaterial)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)

            HStack(alignment: .top, spacing: 0) {
                leftColumn.padding(14)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 10)

                rightColumn
                    .frame(width: 184)
                    .padding(14)
            }
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    // MARK: Left column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Search pill
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("switch to…").font(.system(size: 10)).foregroundStyle(.quaternary)
                Spacer()
                Text("type to filter · ⎋ clear")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.quaternary)
            }
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))

            previewRowHeader("Active", count: "6 apps")

            // Active tiles
            HStack(spacing: 8) {
                ForEach(sampleActive.indices, id: \.self) { i in
                    let (abbr, name, playing) = sampleActive[i]
                    previewTile(abbr: abbr, name: name, highlighted: i == 1,
                                showName: false, playing: playing, size: 48)
                }
            }

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)

            previewRowHeader("Dock", count: "5 apps")

            // Dock tiles
            HStack(spacing: 6) {
                ForEach(samplePinned.indices, id: \.self) { i in
                    let (abbr, name) = samplePinned[i]
                    previewTile(abbr: abbr, name: name, highlighted: false,
                                showName: false, playing: false, size: 44)
                }
            }
        }
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PREVIEW")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(1).foregroundStyle(.tertiary)
            Text("Safari")
                .font(.system(size: 15, weight: .semibold))
            Text("apple.com · 2 windows")
                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)

            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                .frame(height: 100)

            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                        .frame(height: 46)
                }
            }

            HStack(spacing: 4) {
                previewChip("⏎ activate")
                previewChip("⌘W close")
            }
            previewChip("→ next win")

            nowPlayingPreviewCard
        }
    }

    private var nowPlayingPreviewCard: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text("Midnight City").font(.system(size: 9, weight: .semibold)).lineLimit(1)
                Text("M83").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("⏮").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("⏸").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("⏭").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    // MARK: Helpers

    private func previewRowHeader(_ title: String, count: String) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold))
            Text("· \(count)").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func previewTile(abbr: String, name: String, highlighted: Bool,
                              showName: Bool = true, playing: Bool, size: CGFloat) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: size, height: size)
                Text(abbr).font(.system(size: size * 0.3, weight: .medium)).lineLimit(1)

                if playing {
                    Circle().fill(Color.green)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: size - 8)
                }
            }
            .frame(width: size + 4, height: size + 4)
            .scaleEffect(highlighted ? 1.1 : 1.0)

            if showName {
                Text(name).font(.system(size: 8)).lineLimit(1).frame(maxWidth: size + 10)
            }
        }
    }

    private func previewChip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 7, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }
}
