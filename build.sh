#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  build.sh — compile Ricer into a .app bundle
#  Usage:  ./build.sh
#  Output: ./build/Ricer.app
# ─────────────────────────────────────────────────────────────────
set -e

APP_NAME="Ricer"
BUILD_DIR="./build"
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
    main.swift \
    AppDelegate.swift \
    SpaceWatcher.swift \
    OverlayWindow.swift \
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
