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
swiftc \
    main.swift \
    Settings.swift \
    SystemState.swift \
    SpaceWatcher.swift \
    Indicator.swift \
    IndicatorRenderer.swift \
    CornerWindow.swift \
    AppDelegate.swift \
    MissionControlDetector.swift \
    SettingsMenu.swift \
    MusicMonitor.swift \
    MusicPopover.swift \
    SettingsWindow.swift \
    WallpaperEngine.swift \
    -o "$MACOS/$APP_NAME" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework CoreVideo \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework IOKit \
    -framework ImageIO \
    -F/System/Library/PrivateFrameworks \
    -framework MediaRemote \
    -O

echo "▸ Copying Info.plist..."
cp Info.plist "$CONTENTS/Info.plist"
cp AppIcon.png "$RESOURCES/AppIcon.png"

echo ""
echo "✅  Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
