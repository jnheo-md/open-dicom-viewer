#!/bin/bash
# package_app.sh — OpenDicomViewer
# Builds a release binary and creates the .app bundle + DMG for distribution.
# Licensed under the MIT License. See LICENSE for details.
set -e

APP_NAME="OpenDicomViewer"
SIGNING_IDENTITY="Developer ID Application: Joon Heo (KCRAUWJ5MM)"
NOTARY_PROFILE="OpenDicomViewer"

# Ensure we are in project root
cd "$(dirname "$0")/.."

echo "Building ${APP_NAME} (Release)..."
swift build -c release --arch arm64

BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Creating App Bundle at ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "Copying Executable..."
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS_DIR}/"

echo "Copying App Icon..."
cp "AppIcon.icns" "${RESOURCES_DIR}/"

echo "Copying DCMTK Dictionary..."
# Adjust path if your local dcmtk build differs, but this matches the "find" result
cp "libs/dcmtk/share/dcmtk-3.6.8/dicom.dic" "${RESOURCES_DIR}/"

echo "Creating Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.opendicomviewer.app</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>OpenDicomViewer needs access to open DICOM files.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>OpenDicomViewer needs access to open DICOM files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>OpenDicomViewer needs access to open DICOM files.</string>
</dict>
</plist>
EOF

echo "Code signing with Developer ID..."
codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${APP_NAME}"
codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"

echo "Verifying signature..."
codesign --verify --deep --strict "${APP_BUNDLE}"
echo "Signature OK"

echo "Successfully created ${APP_BUNDLE}"

# --- Create DMG for distribution ---
DMG_NAME="${APP_NAME}.dmg"
DMG_TEMP="dmg_tmp"

echo "Creating DMG at ${DMG_NAME}..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

# Copy app bundle into staging dir
cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"

# Add Applications symlink for drag-to-install
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" \
    -quiet

rm -rf "${DMG_TEMP}"

# --- Notarize ---
echo "Submitting ${DMG_NAME} for notarization..."
xcrun notarytool submit "${DMG_NAME}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "${DMG_NAME}"

echo ""
echo "Successfully created and notarized ${DMG_NAME}"
echo "To install: open ${DMG_NAME} and drag ${APP_NAME} to Applications"
