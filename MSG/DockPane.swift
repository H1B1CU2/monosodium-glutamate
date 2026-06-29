import SwiftUI
import AppKit

// MARK: - Dock Previews settings pane

@available(macOS 14.0, *)
struct DockPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        PaneContainer(section: .dock, headerToggle: Binding(
            get: { vm.dockPreviewEnabled },
            set: { vm.dockPreviewEnabled = $0; NotificationCenter.default.post(name: .dockPreviewChanged, object: nil) }
        )) {
            Section("Preview") {
                DockPreviewCardPreview()
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
        }
    }
}

extension Notification.Name {
    static let dockPreviewChanged = Notification.Name("dockPreviewChanged")
}

// MARK: - Settings preview

/// Scaled, sample-data rendition of the real Dock hover card, mirroring its
/// layered look (outer card 16 / window card 14 / thumbnail 10).
@available(macOS 14.0, *)
struct DockPreviewCardPreview: View {
    private let refW: CGFloat = 380
    private let refH: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            DockPreviewCardCanvas()
                .frame(width: refW, height: refH)
                .scaleEffect(geo.size.width / refW, anchor: .topLeading)
        }
        .aspectRatio(refW / refH, contentMode: .fit)
    }
}

@available(macOS 14.0, *)
private struct DockPreviewCardCanvas: View {
    private static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private let windows: [(title: String, hue: Double)] = [
        ("Apple — Start Page", 0.58),
        ("News", 0.02),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let img = Self.icon("com.apple.Safari") {
                    Image(nsImage: img).resizable().frame(width: 24, height: 24)
                }
                Text("Safari")
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 6)

            HStack(spacing: 10) {
                windowCard(windows[0], selected: true)
                windowCard(windows[1], selected: false)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    private func windowCard(_ win: (title: String, hue: Double), selected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(hue: win.hue, saturation: 0.35, brightness: 0.42),
                                 Color(hue: win.hue, saturation: 0.30, brightness: 0.22)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 4) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { c in
                        Circle().fill(c.opacity(0.85)).frame(width: 6, height: 6)
                    }
                }
                .padding(7)
            }
            .frame(width: 150, height: 96)

            Text(win.title)
                .font(.system(size: 11))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.10),
                              lineWidth: selected ? 2 : 1)
        )
    }
}
