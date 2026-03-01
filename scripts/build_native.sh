#!/bin/bash
# build_native.sh — OpenDicomViewer
# Builds a release binary, creates the .app bundle, and optionally code-signs it.
# Licensed under the MIT License. See LICENSE for details.
set -e

# Configuration
APP_NAME="OpenDicomViewer"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP_NAME.app"

# Load Signing Config if available
if [ -f "scripts/build_config.sh" ]; then
    source "scripts/build_config.sh"
fi

echo "Building $APP_NAME (Native)..."
# We need to ensure we link against the local libs
# SwiftPM should handle it via Package.swift settings
swift build -c release --arch arm64

echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Create Info.plist if not exists (or copy)
if [ -f "scripts/Info.plist" ]; then
    cp "scripts/Info.plist" "$APP_BUNDLE/Contents/"
else
    # Generate minimal Info.plist
    cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF
fi

# Code Signing
if [ -n "$DEV_IDENTITY" ]; then
    echo "Signing with $DEV_IDENTITY..."
    codesign --force --options runtime --sign "$DEV_IDENTITY" --entitlements scripts/OpenDicomViewer.entitlements "$APP_BUNDLE"
else
    echo "DEV_IDENTITY not set. Skipping signing."
fi

echo "Done. App is at $APP_BUNDLE"
