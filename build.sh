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


echo ""
echo "✅  Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
