#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MSG"
BUILD_DIR="$SCRIPT_DIR/build"
SRC_DIR="$SCRIPT_DIR/MSG"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Cleaning previous build..."
rm -rf "$APP_BUNDLE"

echo "▸ Creating bundle structure..."
mkdir -p "$MACOS" "$RESOURCES"

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
    AppDelegate.swift \
    HardwareMonitor.swift \
    HardwareStatusItem.swift \
    MissionControlDetector.swift \
    SettingsMenu.swift \
    Displaplacer.swift \
    MusicMonitor.swift \
    MediaRemoteAdapter.swift \
    MusicPopover.swift \
    SettingsWindow.swift \
    WallpaperEngine.swift \
    TrayState.swift \
    TrayPanel.swift \
    TrayHUDView.swift \
    TrayPane.swift \
    Shared.swift \
    DockPane.swift \
    DockPreview.swift \
    WindowPreviewCapture.swift \
    SettingsPanes.swift \
    SettingsPreviews.swift \
    -o "$MACOS/$APP_NAME" \
    -sdk "$(xcrun -sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework CoreAudio \
    -framework Carbon \
    -framework CoreVideo \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework IOKit \
    -framework ImageIO \
    -F/System/Library/PrivateFrameworks \
    -framework MediaRemote \
    -framework SkyLight \
    -O

echo "▸ Building MediaRemote helper dylib..."
clang -dynamiclib MediaRemoteHelper.m \
    -o "$RESOURCES/libMSGMediaRemote.dylib" \
    -framework Foundation -fobjc-arc -O2

echo "▸ Building fan control helper..."
clang FanControlHelper.c \
    -o "$RESOURCES/MSGFanControlHelper" \
    -framework CoreFoundation \
    -framework IOKit \
    -O2

echo "▸ Copying Info.plist..."
cp Info.plist "$CONTENTS/Info.plist"
cp AppIcon.png "$RESOURCES/AppIcon.png"
cp AppIcon-Dark.png "$RESOURCES/AppIcon-Dark.png"

# Sign with a stable identity so TCC grants (Accessibility etc.) survive
# rebuilds — ad-hoc signatures change cdhash every build and macOS treats
# each one as a brand-new app. Plain dev signing only: no entitlements, no
# hardened runtime (restricted entitlements get the binary AMFI-killed).
xattr -cr "$APP_BUNDLE"

echo "▸ Codesigning..."
IDENTITY="${CODESIGN_ID:-Apple Development}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$RESOURCES/libMSGMediaRemote.dylib"
    codesign --force --sign "$IDENTITY" "$RESOURCES/MSGFanControlHelper"
    codesign --force --sign "$IDENTITY" --identifier H1D3S1GN.MSG "$APP_BUNDLE"
else
    echo "⚠️  No '$IDENTITY' cert found — ad-hoc signing (Accessibility grant will NOT persist across builds)"
    codesign --force --sign - "$APP_BUNDLE"
fi

echo ""
echo "✅  Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
