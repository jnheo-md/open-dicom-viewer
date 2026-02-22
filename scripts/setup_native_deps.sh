#!/bin/bash
set -e

# Directory Setup
PROJECT_ROOT="$(pwd)"
LIBS_DIR="$PROJECT_ROOT/libs"
TEMP_DIR="$PROJECT_ROOT/temp_build"
CMAKE_DIR="$TEMP_DIR/cmake"
DCMTK_SRC_DIR="$TEMP_DIR/dcmtk-3.6.8"
INSTALL_DIR="$LIBS_DIR/dcmtk"

mkdir -p "$LIBS_DIR"
mkdir -p "$TEMP_DIR"

# 1. Install CMake (Local)
if [ ! -f "$CMAKE_DIR/CMake.app/Contents/bin/cmake" ]; then
    echo "Downloading CMake..."
    cd "$TEMP_DIR"
    curl -L -O https://github.com/Kitware/CMake/releases/download/v3.29.0/cmake-3.29.0-macos-universal.tar.gz
    tar xzf cmake-3.29.0-macos-universal.tar.gz
    mv cmake-3.29.0-macos-universal cmake
    rm cmake-3.29.0-macos-universal.tar.gz
fi

CMAKE_BIN="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
echo "Using CMake at: $CMAKE_BIN"

# 2. Build OpenJPEG (Required for JPEG 2000)
if [ ! -d "$TEMP_DIR/openjpeg-2.5.0" ]; then
    echo "Downloading OpenJPEG 2.5.0..."
    cd "$TEMP_DIR"
    curl -L -o openjpeg-2.5.0.tar.gz https://github.com/uclouvain/openjpeg/archive/v2.5.0.tar.gz
    tar xzf openjpeg-2.5.0.tar.gz
fi

echo "Building OpenJPEG..."
rm -rf "$TEMP_DIR/openjpeg-2.5.0/build"
mkdir -p "$TEMP_DIR/openjpeg-2.5.0/build"
cd "$TEMP_DIR/openjpeg-2.5.0/build"
"$CMAKE_BIN" .. \
    -DCMAKE_INSTALL_PREFIX="$LIBS_DIR/openjpeg" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DBUILD_CODEC=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_LCMS2=ON

"$CMAKE_BIN" --build . --target install --parallel 4

# 3. Download DCMTK
if [ ! -d "$DCMTK_SRC_DIR" ]; then
    echo "Downloading DCMTK 3.6.8..."
    cd "$TEMP_DIR"
    curl -L -O https://dicom.offis.de/download/dcmtk/dcmtk368/dcmtk-3.6.8.tar.gz
    tar xzf dcmtk-3.6.8.tar.gz
    rm dcmtk-3.6.8.tar.gz
fi

# 4. Build DCMTK
echo "Building DCMTK..."
rm -rf "$DCMTK_SRC_DIR/build"
mkdir -p "$DCMTK_SRC_DIR/build"
cd "$DCMTK_SRC_DIR/build"

# Configure
# We build STATIC libraries (.a) for easy linking
# We enable C++11 or higher
# Point to OpenJPEG
"$CMAKE_BIN" .. \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DDCMTK_WITH_TIFF=OFF \
    -DDCMTK_WITH_PNG=OFF \
    -DDCMTK_WITH_XML=OFF \
    -DDCMTK_WITH_OPENSSL=OFF \
    -DDCMTK_WITH_ICONV=OFF \
    -DDCMTK_ENABLE_CXX11=ON \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DDCMTK_WITH_OPENJPEG=ON \
    -DCMAKE_PREFIX_PATH="$LIBS_DIR/openjpeg"

# Build
"$CMAKE_BIN" --build . --target install --parallel 4

echo "DCMTK Installed to $INSTALL_DIR"

# Cleanup (Optional, keep for now for debugging)
# rm -rf "$TEMP_DIR"
