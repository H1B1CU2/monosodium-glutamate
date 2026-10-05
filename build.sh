#!/usr/bin/env bash
set -e

# CommandLineTools lacks the SwiftUI macro plugin and its SDK mismatches the
# compiler — pin the full Xcode toolchain or the @State macro fails to expand.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MSG"
# Keep the running build untouched when compiling a preview in build/preview.
MSG_BUILD_SUBDIR="${MSG_BUILD_SUBDIR:-build}"
if [[ ! "$MSG_BUILD_SUBDIR" =~ ^build(/[a-zA-Z0-9_-]+)?$ ]]; then
    echo "Invalid MSG_BUILD_SUBDIR" >&2
    exit 1
fi
BUILD_DIR="$SCRIPT_DIR/$MSG_BUILD_SUBDIR"
SRC_DIR="$SCRIPT_DIR/MSG"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Cleaning previous build..."
mkdir -p "$BUILD_DIR"
rm -rf "$APP_BUNDLE"

echo "▸ Creating bundle structure..."
mkdir -p "$MACOS" "$RESOURCES"

SPACE_JUMP_O="${TMPDIR:-/tmp}/SpaceJump_$$.o"
trap 'rm -f "$SPACE_JUMP_O"' EXIT

echo "▸ Building native Space-jump bridge..."
xcrun -sdk macosx clang -c "$SRC_DIR/SpaceJump.c" \
    -o "$SPACE_JUMP_O" \
    -target arm64-apple-macos13.0 \
    -O2

echo "▸ Compiling Swift sources..."
cd "$SRC_DIR"
xcrun -sdk macosx swiftc \
    main.swift \
    Settings.swift \
    SystemState.swift \
    SpaceWatcher.swift \
    Indicator.swift \
    IndicatorRenderer.swift \
    SystemHUDMonitor.swift \
    SystemHUDStatusItem.swift \
    InputSourceMonitor.swift \
    AudioSpectrumTap.swift \
    CornerWindow.swift \
    LockScreenTouchID.swift \
    AudioDeviceRouting.swift \
    CloudflareWARP.swift \
    ChargerNotchNotice.swift \
    SystemEventNotchNotice.swift \
    SystemNotificationNotch.swift \
    KeyEdgeHUD.swift \
    MusicEdgeHUD.swift \
    EdgeKeyAppKeys.swift \
    PlayerExtras.swift \
    CalendarFeed.swift \
    CalendarStatusItem.swift \
    KeyboardCleaner.swift \
    AIUsageFeed.swift \
    AIUsageCap.swift \
    EdgeKeyStrip.swift \
    WeatherMonitor.swift \
    AppDelegate.swift \
    HardwareMonitor.swift \
    HardwareStatusItem.swift \
    HardwareCardLayout.swift \
    HardwarePopoverEditor.swift \
    MissionControlDetector.swift \
    SettingsMenu.swift \
    Displaplacer.swift \
    DisplayInput.swift \
    BrightnessSync.swift \
    AgentLockScreen.swift \
    AgentNotchCard.swift \
    AgentNotchDashboard.swift \
    NotchPanes.swift \
    NotchDropZone.swift \
    NotchHUD.swift \
    LimitResetNotice.swift \
    AgentDoneNotice.swift \
    CortexActivityPill.swift \
    MusicMonitor.swift \
    MediaRemoteAdapter.swift \
    MusicPopover.swift \
    SettingsWindow.swift \
    WallpaperEngine.swift \
    Shared.swift \
    DockPane.swift \
    DockPreview.swift \
    NotchPreview.swift \
    AppSwitcherPreview.swift \
    WindowPreviewCapture.swift \
    WindowPreviewDragController.swift \
    TilingLayout.swift \
    TilingFramePipeline.swift \
    TilingDisplayClock.swift \
    TilingMenuBar.swift \
    NetworkStatusMonitor.swift \
    WiFiMenu.swift \
    TilingControlBar.swift \
    TilingBarPreview.swift \
    TilingSpacePreview.swift \
    TilingSpaceSwitcher.swift \
    TrackpadSwipeMonitor.swift \
    TilingTabSwitcher.swift \
    TilingResizeOverlay.swift \
    TilingController.swift \
    TilingPane.swift \
    SettingsPanes.swift \
    SettingsPreviews.swift \
    FanHelperShared.swift \
    FanControlClient.swift \
    "$SPACE_JUMP_O" \
    -o "$MACOS/$APP_NAME" \
    -module-cache-path "$BUILD_DIR/SwiftModuleCache" \
    -sdk "$(xcrun -sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework CoreAudio \
    -framework Carbon \
    -framework CoreVideo \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework IOKit \
    -framework CoreWLAN \
    -framework CoreLocation \
    -framework EventKit \
    -framework ImageIO \
    -F/System/Library/PrivateFrameworks \
    -framework MediaRemote \
    -framework SkyLight \
    -O

echo "▸ Building MediaRemote helper dylib..."
clang -dynamiclib MediaRemoteHelper.m \
    -o "$RESOURCES/libMSGMediaRemote.dylib" \
    -framework Foundation -fobjc-arc -O2

echo "▸ Building privileged fan helper (XPC daemon)..."
# Compiled from the same FanHelperShared.swift the app uses, so the mach service
# name and the code requirement can never drift apart between the two sides.
xcrun -sdk macosx swiftc \
    FanHelper/main.swift \
    FanHelperShared.swift \
    FanControlClient.swift \
    -o "$MACOS/MSGFanHelper" \
    -sdk "$(xcrun -sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos13.0 \
    -framework Foundation \
    -framework IOKit \
    -O

echo "▸ Installing LaunchDaemon plist..."
mkdir -p "$CONTENTS/Library/LaunchDaemons"
cp FanHelper.plist "$CONTENTS/Library/LaunchDaemons/H1D3S1GN.MSG.fan-helper.plist"

echo "▸ Building legacy fan control helper..."
clang FanControlHelper.c \
    -o "$RESOURCES/MSGFanControlHelper" \
    -framework CoreFoundation \
    -framework IOKit \
    -O2

echo "▸ Copying Info.plist..."
cp Info.plist "$CONTENTS/Info.plist"
# Xcode normally supplies these; the standalone compiler does not.
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string MSG' "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string MSG' "$CONTENTS/Info.plist"
cp -R "$SCRIPT_DIR/ThirdParty" "$RESOURCES/ThirdParty"
cp AppIcon.png "$RESOURCES/AppIcon.png"
cp AppIcon-Dark.png "$RESOURCES/AppIcon-Dark.png"
cp AppIcon.icns "$RESOURCES/AppIcon.icns"

# Sign with a stable identity so TCC grants (Accessibility etc.) survive
# rebuilds — ad-hoc signatures change cdhash every build and macOS treats
# each one as a brand-new app. Plain dev signing only: no entitlements, no
# hardened runtime (restricted entitlements get the binary AMFI-killed).
echo "▸ Codesigning..."
IDENTITY="${CODESIGN_ID:-Apple Development}"
# This tree lives on a file-provider volume (iCloud Drive), which re-stamps
# com.apple.FinderInfo onto the .app in the moments after anything inside it is
# written — including the nested signings just above. codesign rejects that as
# "resource fork, Finder information, or similar detritus", so a single clear
# before signing loses the race. Clear and sign together, and retry.
# (com.apple.macl survives every clear and is tolerated; FinderInfo is not.)
sign_bundle() {
    local STAGE_DIR="/tmp/msg_codesign_$$"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    ditto "$APP_BUNDLE" "$STAGE_DIR/$APP_NAME.app"
    xattr -cr "$STAGE_DIR/$APP_NAME.app"
    if codesign --force --sign "$@" "$STAGE_DIR/$APP_NAME.app"; then
        rm -rf "$APP_BUNDLE"
        ditto "$STAGE_DIR/$APP_NAME.app" "$APP_BUNDLE"
        rm -rf "$STAGE_DIR"
        return 0
    fi
    rm -rf "$STAGE_DIR"
    echo "❌  Codesigning failed"
    return 1
}

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$RESOURCES/libMSGMediaRemote.dylib"
    codesign --force --sign "$IDENTITY" "$RESOURCES/MSGFanControlHelper"
    # The daemon is signed with its own identifier: the XPC requirement the
    # helper enforces names the app, and SMAppService checks the helper's.
    codesign --force --sign "$IDENTITY" --identifier H1D3S1GN.MSG.fan-helper \
        --options runtime "$MACOS/MSGFanHelper"
    sign_bundle "$IDENTITY" --identifier H1D3S1GN.MSG
else
    echo "⚠️  No '$IDENTITY' cert found — ad-hoc signing (Accessibility grant will NOT persist across builds)"
    sign_bundle -
fi

echo ""
echo "✅  Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
