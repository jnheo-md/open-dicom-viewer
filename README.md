# OpenDicomViewer

A native macOS DICOM medical image viewer built with SwiftUI. Designed for fast, lightweight viewing of DICOM studies with multi-panel layouts, MPR reconstruction, and GPU-accelerated volume rendering.

<!-- ![Screenshot](screenshot.png) -->

## Features

- **Fast DICOM Parsing** — Custom pure-Swift DICOM parser with incremental directory scanning; first image displays instantly while the rest of the study loads in the background
- **Multi-Panel Layouts** — Single, side-by-side (2x1), stacked (1x2), and quad (2x2) panel arrangements with drag-and-drop series assignment
- **MPR Reconstruction** — One-click multi-planar reformatting: axial, sagittal, coronal, and MIP views from a single series
- **GPU Volume Rendering** — Metal compute shader for real-time MIP, MinIP, and average intensity projections with slab thickness control
- **Synchronized Scrolling** — Link panels to scroll to the same spatial position across different series using z-location matching
- **Cross-Reference Lines** — Optional overlay showing where other panels' slice planes intersect the current view
- **Window/Level Controls** — Interactive mouse drag, auto W/L, ROI-based W/L, histogram display, and preset support
- **DICOM Tag Inspector** — Browse all DICOM metadata tags for the current image
- **Series Thumbnails** — Automatic thumbnail generation for the series list
- **Cursor Readout** — Real-time HU value and patient coordinate display under the cursor
- **Orientation Labels** — Anatomical direction labels (A/P/R/L/S/I) based on DICOM orientation metadata
- **JPEG 2000 Support** — Handles compressed transfer syntaxes via DCMTK + OpenJPEG

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `1` / `2` / `3` / `4` | Switch layout: single / side-by-side / stacked / quad |
| `L` | Toggle synchronized scrolling (link) |
| `X` | Toggle cross-reference lines |
| `T` | Toggle DICOM tag inspector |
| `R` | Reset view (zoom, pan, window/level) |
| `I` | Invert image |
| `F` | Fit image to window |
| `Shift+A` | Auto window/level |
| `Shift+R` | Toggle ROI window/level mode |
| `Tab` | Cycle active panel |
| `Up/Down` | Previous/next image in series |
| `Left/Right` | Previous/next series |
| `Page Up/Down` | Skip 10 images |
| `Home/End` | Jump to first/last image |
| `Cmd+1-4` | Layout switching (menu bar) |
| `Cmd+Shift+M` | MPR layout |

## Architecture

```
Sources/
├── OpenDicomViewer/          # Main application target
│   ├── App.swift                 # App entry point, menu bar commands
│   ├── ContentView.swift         # Root view: sidebar + detail split
│   ├── DICOMModel.swift          # Core model: loading, caching, panel management
│   ├── SimpleDICOM.swift         # Pure-Swift DICOM parser (no DCMTK dependency)
│   ├── MultiPanelContainer.swift # Multi-panel grid, per-panel overlays & gestures
│   ├── PanelState.swift          # Per-panel state: series, W/L, zoom, metadata
│   ├── LayoutToolbar.swift       # Floating layout/link/crossref toolbar
│   ├── CrossReferenceOverlay.swift # Slice intersection lines between panels
│   ├── MPREngine.swift           # CPU-based multi-planar reconstruction
│   ├── MetalVolumeRenderer.swift # GPU MIP/MinIP/Average via Metal compute
│   ├── VolumeData.swift          # 3D voxel buffer with affine transforms
│   ├── VolumeToolbar.swift       # MPR/MIP mode controls per panel
│   ├── TagView.swift             # DICOM tag list view
│   ├── Extensions.swift          # Collection safe-subscript helper
│   └── WindowAccessor.swift      # NSWindow customization (hidden titlebar)
└── DCMTKWrapper/             # Objective-C++ bridge to DCMTK
    ├── DCMTKHelper.mm            # DCMTK image decoding + JPEG2000 fallback
    └── include/
        └── DCMTKHelper.h         # Public C/ObjC interface
```

### Key Design Decisions

- **Dual Parser Strategy**: A fast pure-Swift parser (`SimpleDICOM.swift`) handles tag reading and metadata extraction during directory scanning, while the DCMTK wrapper handles pixel data decoding for complex transfer syntaxes.
- **Panel-Based Architecture**: Each panel (`PanelState`) owns its own image, W/L, zoom, and metadata state. The model (`DICOMModel`) manages shared resources (series data, caches, queues) and coordinates between panels.
- **Spatial Synchronization**: Linked scrolling uses physical z-location matching rather than proportional index matching, so panels showing different series display the same anatomical position.

## Building

### Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode 15+ (or Swift 5.9+ toolchain)
- Apple Silicon Mac (arm64) — Intel support requires rebuilding the native libraries

### 1. Build Native Dependencies

The pre-built static libraries for DCMTK and OpenJPEG are included in `libs/`. If you need to rebuild them (e.g., for a different architecture):

```bash
./scripts/setup_native_deps.sh
```

This downloads and compiles DCMTK 3.6.8 and OpenJPEG 2.5.0 as static libraries.

### 2. Build the App

```bash
swift build -c release
```

### 3. Package as .app Bundle

```bash
./scripts/package_app.sh
```

This creates `OpenDicomViewer.app` in the project root. To install:

```bash
cp -r OpenDicomViewer.app /Applications/
```

### First Run on Another Mac

Since the app is not notarized, macOS will block it. Right-click the app and select **Open**, then click **Open** in the dialog. You only need to do this once.

## Project Structure

```
OpenDicomViewer/
├── Sources/                  # All Swift + ObjC++ source code
├── libs/                     # Pre-built static libraries
│   ├── dcmtk/               #   DCMTK 3.6.8 (headers, libs, dicom.dic)
│   └── openjpeg/             #   OpenJPEG 2.5.0 (headers, libopenjp2.a)
├── scripts/
│   ├── setup_native_deps.sh  # Download & build DCMTK + OpenJPEG
│   ├── build_native.sh       # Build + sign + package (with code signing)
│   ├── package_app.sh        # Build + package (without signing)
│   └── OpenDicomViewer.entitlements
├── Package.swift             # Swift Package Manager manifest
├── AppIcon.icns              # Application icon
├── LICENSE                   # MIT License
└── README.md                 # This file
```

## Dependencies

| Library | Version | Purpose | License |
|---------|---------|---------|---------|
| [DCMTK](https://dicom.offis.de/dcmtk.php.en) | 3.6.8 | DICOM image decoding, JPEG/JPEG-LS decompression | BSD |
| [OpenJPEG](https://www.openjpeg.org/) | 2.5.0 | JPEG 2000 decompression | BSD-2-Clause |

Both are included as pre-built static libraries (`libs/`) and linked at compile time via Swift Package Manager.

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

DCMTK is licensed under the BSD license. OpenJPEG is licensed under BSD-2-Clause. See their respective documentation in `libs/` for details.
