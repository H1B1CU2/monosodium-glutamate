#!/usr/bin/env bash
set -e

APP_NAME="MSG"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/MSG"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "▸ Cleaning previous build..."
rm -rf "$APP_BUNDLE"

echo "▸ Creating bundle structure..."
mkdir -p "$MACOS" "$RESOURCES"

echo "▸ Compiling Swift sources..."
swiftc \
    "$SRC_DIR/main.swift" \
    "$SRC_DIR/Settings.swift" \
    "$SRC_DIR/SystemState.swift" \
    "$SRC_DIR/SpaceWatcher.swift" \
    "$SRC_DIR/Indicator.swift" \
    "$SRC_DIR/IndicatorRenderer.swift" \
    "$SRC_DIR/CornerWindow.swift" \
    "$SRC_DIR/AppDelegate.swift" \
    "$SRC_DIR/SettingsMenu.swift" \
    -o "$MACOS/$APP_NAME" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macos12.0 \
    -framework AppKit \
    -O

echo "▸ Copying Info.plist..."
cp "$SRC_DIR/Info.plist" "$CONTENTS/Info.plist"

echo "✅  Built: $APP_BUNDLE"
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
