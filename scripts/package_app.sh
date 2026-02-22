#!/bin/bash
set -e

APP_NAME="OpenDicomViewer"
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

# Add an empty icon file or similar if needed, but default is fine for MVP.

echo "Successfully created ${APP_BUNDLE}"
echo "To install: mv ${APP_BUNDLE} /Applications/"
