import SwiftUI

@available(macOS 14.0, *)
struct TilingPane: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        PaneContainer(section: .tiling, headerToggle: Binding(
            get: { vm.tilingEnabled },
            set: { vm.tilingEnabled = $0 }
        )) {
            Section {
                SettingsToggleRow("Top control bar",
                                  detail: "Show the tiling bar with Space indicators and window controls at the top of each display.",
                                  isOn: Binding(
                                      get: { vm.tilingShowControlBar },
                                      set: { vm.tilingShowControlBar = $0 }
                                  ))
                Picker("Control bar mode", selection: $vm.tilingControlBarMode) {
                    ForEach(TilingControlBarMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                SettingsToggleRow("Hover previews",
                                  detail: "Rest the pointer on a window icon to preview it, or on the Deskspace dots to see every Deskspace at once. Drag a window preview onto the desktop to bring it here, or onto a Deskspace dot to send it there.",
                                  isOn: $vm.tilingControlBarPreviews)
                SettingsToggleRow("Duo Battery & Wi-Fi indicator",
                                  detail: "Show an iPhone Duo-style merged battery gauge and Wi-Fi indicator on the control bar in front of the space indicator. The icon changes when you're on a Personal Hotspot. Click it for the Wi-Fi menu.",
                                  isOn: $vm.tilingControlBarDuoBatteryWifi)
                Picker("App icons", selection: $vm.tilingControlBarScope) {
                    ForEach(TilingControlBarScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                Picker("Shown-window pill", selection: $vm.tilingPillScope) {
                    ForEach(TilingPillScope.allCases, id: \.self) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                SettingsToggleRow("Swipe to switch tabs",
                                  detail: "Swipe up or down with three fingers to flip through the tabbed windows on the display under the pointer: up goes forward, down goes back. Keep moving to go further, then lift to switch. Uses four fingers when three-finger drag is on.",
                                  isOn: $vm.tilingSwipeCyclesTabs)
                if vm.tilingSwipeCyclesTabs && TrackpadSwipeMonitor.systemClaimsVerticalSwipe {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Mission Control or App Exposé also uses this swipe, so both will run. Turn them off in Trackpad settings → More Gestures.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Open Trackpad Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                SettingsToggleRow("Swipe to switch Deskspaces",
                                  detail: "Rest your fingers on the trackpad for a moment to open a centered Deskspace preview, then slide left or right to pick one and lift to switch. A quick swipe does nothing. On an empty Deskspace, pull down and hold to delete it.",
                                  isOn: $vm.tilingSwipeSwitchesSpaces)
                if vm.tilingSwipeSwitchesSpaces {
                    Picker("Deskspace swipe fingers", selection: $vm.tilingSpaceSwipeFingers) {
                        Text("3 fingers").tag(3)
                        Text("4 fingers").tag(4)
                    }
                }
                if vm.tilingSwipeSwitchesSpaces
                    && TrackpadSwipeMonitor.systemClaimsHorizontalSwipe(fingers: vm.tilingSpaceSwipeFingers) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("macOS also swipes between full-screen apps with \(vm.tilingSpaceSwipeFingers) fingers, so both will run. Pick the other finger count, or turn it off in Trackpad settings → More Gestures.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Open Trackpad Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                SettingsToggleRow(
                    "One app per Deskspace",
                    detail: "A newly opened app uses the current Deskspace when it is empty. Otherwise MSG creates a new Deskspace and moves that app there. Moving apps by hand is left unchanged; empty Deskspaces are removed automatically.",
                    isOn: $vm.tilingOneAppPerDeskspace
                )
                SettingsToggleRow(
                    "Remove empty Deskspaces",
                    detail: "After leaving an empty Deskspace, wait 5 seconds and keep checking periodically. The active, fullscreen, and only remaining Deskspace on each display are never removed.",
                    isOn: $vm.tilingAutoDeleteEmptySpaces
                )
            }

            Section {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Window padding")
                        Spacer()
                        Text("\(Int(vm.tilingPadding.rounded())) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(vm.tilingPadding) },
                        set: { vm.tilingPadding = CGFloat($0) }
                    ), in: 0...32, step: 1)
                }
                SettingsToggleRow("Stable preview resize",
                                  detail: "Alternative mode: move preview borders while dragging, then resize the real windows once on release.",
                                  isOn: $vm.tilingStablePreviewResize)
            } header: {
                Text("Layout")
            } footer: {
                Text("The same value is used between windows and around the usable display area. Default: 4 px.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Section {
                Button("Retile Windows") { TilingController.shared.retile() }
                Button("Move Focused Window to Left Column") {
                    TilingController.shared.makeFocusedWindowMain()
                }
                Button("Toggle Focused Window Floating") {
                    TilingController.shared.toggleFloatingForFocusedWindow()
                }
                Button("Pause / Resume This Space") {
                    TilingController.shared.togglePauseCurrentSpace()
                }
            } header: {
                Text("Current Space")
            }

            Section {
                Text(vm.tilingControlBarMode == .hybridNotch
                     ? "Hybrid Notch keeps the native macOS menu bar visible and covers only its left side up to the notch. Native status items remain visible on the right."
                     : "Full Width hides the macOS menu bar automatically while Tiling is enabled. Move the pointer to the top edge to reveal it. MSG restores your previous setting when Tiling is turned off or MSG quits.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("The left and right columns are independent tab stacks. The first window starts on the left and new windows start on the right. Click an app icon to switch only that column, or use its menu to move it between columns. Drag the divider to resize both columns; MSG remembers the width for each display.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Finder utility windows such as Get Info, progress, and confirmation dialogs always float. Fullscreen windows, hidden Spaces, and windows that cannot be resized are left alone.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
