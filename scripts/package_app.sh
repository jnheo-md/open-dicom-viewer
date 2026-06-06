#!/bin/bash
# package_app.sh — OpenDicomViewer
# Builds a release binary and creates the .app bundle + DMG for distribution.
# Use --notarize to sign with Developer ID and notarize with Apple.
# Licensed under the MIT License. See LICENSE for details.
set -e

APP_NAME="OpenDicomViewer"
SIGNING_IDENTITY="Developer ID Application: Joon Heo (KCRAUWJ5MM)"
NOTARY_PROFILE="OpenDicomViewer"
NOTARIZE=false
UNIVERSAL=false
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-13.0}"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            NOTARIZE=true
            ;;
        --universal)
            UNIVERSAL=true
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--universal] [--notarize]" >&2
            exit 1
            ;;
    esac
    shift
done

# Ensure we are in project root
cd "$(dirname "$0")/.."

BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"

if $UNIVERSAL; then
    BUILD_DIR=".build/universal/release"
    APP_BUNDLE="${APP_NAME}-universal.app"
    DMG_NAME="${APP_NAME}-universal.dmg"

    echo "Building ${APP_NAME} (Universal Release, macOS ${MACOS_DEPLOYMENT_TARGET}+)..."
    swift build -c release --arch arm64
    swift build -c release --arch x86_64

    mkdir -p "${BUILD_DIR}"
    lipo -create \
        ".build/arm64-apple-macosx/release/${APP_NAME}" \
        ".build/x86_64-apple-macosx/release/${APP_NAME}" \
        -output "${BUILD_DIR}/${APP_NAME}"
    lipo -info "${BUILD_DIR}/${APP_NAME}"
else
    echo "Building ${APP_NAME} (Release, macOS ${MACOS_DEPLOYMENT_TARGET}+)..."
    swift build -c release --arch arm64
    BUILD_DIR=".build/arm64-apple-macosx/release"
fi

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
    <string>1.5.0</string>
    <key>CFBundleVersion</key>
    <string>6</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MACOS_DEPLOYMENT_TARGET}</string>
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

if $NOTARIZE; then
    echo "Code signing with Developer ID..."
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${APP_NAME}"
    codesign --force --options runtime --sign "${SIGNING_IDENTITY}" "${APP_BUNDLE}"
    codesign --verify --deep --strict "${APP_BUNDLE}"
    echo "Signature OK"
else
    echo "Ad-hoc code signing (use --notarize for Developer ID signing)..."
    codesign --force --deep -s - "${APP_BUNDLE}"
fi

echo "Successfully created ${APP_BUNDLE}"

# --- Create DMG for distribution ---
DMG_TEMP="dmg_tmp"

echo "Creating DMG at ${DMG_NAME}..."
rm -rf "${DMG_TEMP}" "${DMG_NAME}"
mkdir -p "${DMG_TEMP}"

cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
ln -s /Applications "${DMG_TEMP}/Applications"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_NAME}" \
    -quiet

rm -rf "${DMG_TEMP}"

if $NOTARIZE; then
    echo "Submitting ${DMG_NAME} for notarization..."
    xcrun notarytool submit "${DMG_NAME}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "${DMG_NAME}"

    echo ""
    echo "Successfully created and notarized ${DMG_NAME}"
else
    echo ""
    echo "Successfully created ${DMG_NAME} (not notarized)"
fi
echo "To install: open ${DMG_NAME} and drag ${APP_NAME} to Applications"
