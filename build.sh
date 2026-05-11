#!/usr/bin/env bash
set -e

APP_NAME="MSG"
BUILD_DIR="$(dirname "$0")/build"
SRC_DIR="$(dirname "$0")/MSG"
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
    Diagnostics.swift \
    Indicator.swift \
    IndicatorRenderer.swift \
    CornerWindow.swift \
    AppDelegate.swift \
    SettingsMenu.swift \
    -o "$MACOS/$APP_NAME" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target arm64-apple-macos12.0 \
    -framework AppKit \
    -O

echo "▸ Copying Info.plist..."
cp Info.plist "$CONTENTS/Info.plist"

echo ""
echo "✅  Built: $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"
echo "Or:      $MACOS/$APP_NAME"
