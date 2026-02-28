// PanelState.swift
// OpenDicomViewer
//
// Defines the per-panel state model and supporting enums for the multi-panel
// viewer architecture.
//
// Key types:
//   ViewerLayout       — Layout configuration (1x1, 2x1, 1x2, 2x2)
//   NavigationDirection — Arrow key navigation actions
//   PanelMode          — Display mode per panel (2D slice, MPR sagittal/coronal, MIP)
//   PanelState         — Observable state for a single viewer panel, including:
//                         series/image assignment, window/level, zoom/pan,
//                         spatial metadata, histogram, cursor readout, and
//                         display modifiers (invert, rotate, flip)
//
// PanelState is a reference type (class) so multiple views can observe the
// same panel instance. Shared resources (caches, series data) live in DICOMModel.

import SwiftUI
import DCMTKWrapper

// MARK: - Layout Configuration
enum ViewerLayout: String, CaseIterable, Identifiable {
    case single = "1×1"
    case twoHorizontal = "2×1"
    case twoVertical = "1×2"
    case quad = "2×2"

    var id: String { rawValue }

    var rows: Int {
        switch self {
        case .single, .twoHorizontal: return 1
        case .twoVertical, .quad: return 2
        }
    }

    var columns: Int {
        switch self {
        case .single, .twoVertical: return 1
        case .twoHorizontal, .quad: return 2
        }
    }

    var panelCount: Int { rows * columns }

    var iconName: String {
        switch self {
        case .single:          return "rectangle"
        case .twoHorizontal:   return "rectangle.split.2x1"
        case .twoVertical:     return "rectangle.split.1x2"
        case .quad:            return "rectangle.split.2x2"
        }
    }
}

// MARK: - Navigation Direction
enum NavigationDirection {
    case nextImage, prevImage, nextSeries, prevSeries
}

// MARK: - Panel Display Mode
enum PanelMode: String, CaseIterable, Identifiable {
    case slice2D = "Slice"
    case mprSagittal = "Sagittal"
    case mprCoronal = "Coronal"
    case mip = "MIP"

    var id: String { rawValue }
}

// MARK: - Active Tool
enum ActiveTool: String, CaseIterable, Identifiable {
    case pan = "Pan"
    case windowLevel = "W/L"
    case roiWL = "ROI W/L"
    case roiStats = "ROI Stats"
    case ruler = "Ruler"
    case angle = "Angle"
    case eraser = "Eraser"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pan: return "hand.point.up.left"
        case .windowLevel: return "sun.max"
        case .roiWL: return "rectangle.dashed"
        case .roiStats: return "chart.bar.xaxis"
        case .ruler: return "ruler"
        case .angle: return "angle"
        case .eraser: return "eraser"
        }
    }

    var shortcutHint: String {
        switch self {
        case .pan: return "V"
        case .windowLevel: return "W"
        case .roiWL: return "O"
        case .roiStats: return "S"
        case .ruler: return "D"
        case .angle: return "N"
        case .eraser: return "E"
        }
    }
}

// MARK: - Annotations
enum AnnotationType {
    case ruler(start: CGPoint, end: CGPoint, distanceMM: Double)
    case angle(vertex: CGPoint, arm1: CGPoint, arm2: CGPoint, degrees: Double)
    case roiStats(rect: CGRect, mean: Double, max: Double, min: Double, stdDev: Double, count: Int)
}

struct Annotation: Identifiable {
    let id = UUID()
    let type: AnnotationType
}

// MARK: - Panel State
/// Per-panel observable state. Each panel in the multi-panel viewer gets its own instance.
/// Shared resources (caches, queues, series data) remain in DICOMModel.
class PanelState: ObservableObject, Identifiable {
    let id: UUID = UUID()

    // Series/Image Assignment
    @Published var seriesIndex: Int = -1
    @Published var imageIndex: Int = -1

    // Panel display mode
    @Published var panelMode: PanelMode = .slice2D

    // MPR position (voxel index for orthogonal slices)
    @Published var mprSliceIndex: Int = 0

    // MIP slab projection
    @Published var mipSlabPosition: Int = 0    // center slice index (scrollable)
    @Published var mipSlabThickness: Int = 10  // number of slices in the slab

    // Rendered Image
    @Published var image: NSImage? = nil

    // Window/Level
    @Published var windowWidth: Double = 0
    @Published var windowCenter: Double = 0
    var initialWindowWidth: Double = 0
    var initialWindowCenter: Double = 0

    // View Transform (zoom/pan)
    @Published var scale: CGFloat = 1.0
    @Published var translation: CGPoint = .zero

    // Histogram
    @Published var histogramData: [Double] = []
    @Published var minPixelValue: Double = 0.0
    @Published var maxPixelValue: Double = 1.0

    // DICOM Tags
    @Published var tags: [DicomElement] = []

    // UI State
    @Published var currentSeriesInfo: String = ""
    @Published var currentImageInfo: String = ""
    @Published var errorMessage: String? = nil
    @Published var isLoading: Bool = false
    @Published var cacheProgress: Double = 0.0

    // Raw Data for Re-rendering (not published - internal use)
    var rawPixelData: Data? = nil
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var bitDepth: Int = 8
    var samples: Int = 1
    var isMonochrome1: Bool = false
    var isSigned: Bool = false
    var dcmtkImage: DCMTKImageObject? = nil

    /// Whether raw pixel data is available for CPU re-rendering
    var isRawDataAvailable: Bool { rawPixelData != nil }

    // Spatial Metadata (for cross-reference lines)
    @Published var imagePositionPatient: (Double, Double, Double)? = nil
    @Published var imageOrientationPatient: [Double]? = nil  // 6 values
    @Published var pixelSpacing: (Double, Double)? = nil

    // Cursor tracking (HU readout)
    @Published var showCursorInfo: Bool = false
    @Published var cursorPixelX: Int = 0
    @Published var cursorPixelY: Int = 0
    @Published var cursorHU: Double = 0
    @Published var cursorPatientX: Double = 0
    @Published var cursorPatientY: Double = 0
    @Published var cursorPatientZ: Double = 0
    @Published var hasCursorPatientPosition: Bool = false

    // ROI W/L tool
    @Published var isROIMode: Bool = false
    @Published var roiRect: CGRect? = nil  // in pixel coordinates, used during drag

    // Per-panel loading queue (prevents cross-panel cancellation)
    let loadingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    // Group selection for simultaneous scrolling
    @Published var isGroupSelected: Bool = false

    // Display modifiers
    @Published var isInverted: Bool = false
    @Published var rotationSteps: Int = 0       // 0=0°, 1=90°CW, 2=180°, 3=270°CW
    @Published var isFlippedH: Bool = false      // Horizontal flip (left-right)
    @Published var isFlippedV: Bool = false       // Vertical flip (up-down)

    // Annotations
    @Published var annotations: [Annotation] = []

    // In-progress annotation preview
    @Published var rulerPreviewStart: CGPoint? = nil
    @Published var rulerPreviewEnd: CGPoint? = nil
    @Published var anglePreviewPoints: [CGPoint] = []

    /// Reset panel to empty state
    func reset() {
        seriesIndex = -1
        imageIndex = -1
        panelMode = .slice2D
        mprSliceIndex = 0
        mipSlabPosition = 0
        mipSlabThickness = 10
        image = nil
        windowWidth = 0
        windowCenter = 0
        initialWindowWidth = 0
        initialWindowCenter = 0
        scale = 1.0
        translation = .zero
        histogramData = []
        minPixelValue = 0.0
        maxPixelValue = 1.0
        tags = []
        currentSeriesInfo = ""
        currentImageInfo = ""
        errorMessage = nil
        isLoading = false
        cacheProgress = 0.0
        rawPixelData = nil
        imageWidth = 0
        imageHeight = 0
        bitDepth = 8
        samples = 1
        isMonochrome1 = false
        isSigned = false
        dcmtkImage = nil
        imagePositionPatient = nil
        imageOrientationPatient = nil
        pixelSpacing = nil
        showCursorInfo = false
        cursorPixelX = 0
        cursorPixelY = 0
        cursorHU = 0
        cursorPatientX = 0
        cursorPatientY = 0
        cursorPatientZ = 0
        hasCursorPatientPosition = false
        isROIMode = false
        roiRect = nil
        isGroupSelected = false
        isInverted = false
        rotationSteps = 0
        isFlippedH = false
        isFlippedV = false
        annotations = []
        rulerPreviewStart = nil
        rulerPreviewEnd = nil
        anglePreviewPoints = []
    }
}
