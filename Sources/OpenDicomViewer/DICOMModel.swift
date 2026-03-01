// DICOMModel.swift
// OpenDicomViewer
//
// Central model for the DICOM viewer. This is the largest file in the project
// and serves as the single source of truth for all viewer state.
//
// Responsibilities:
//   - Directory scanning with incremental UI updates (background thread)
//   - Series/image loading with multi-level caching (memory + disk)
//   - Multi-panel management: create, resize, assign series, navigate
//   - Window/level computation (auto, ROI-based, histogram generation)
//   - MPR volume building and slice extraction
//   - MIP rendering (CPU fallback + Metal GPU path)
//   - Synchronized scrolling with spatial z-location matching
//   - Series thumbnail generation
//   - DICOM tag extraction and panel info string formatting
//
// Threading model:
//   - Directory scanning runs on a background DispatchQueue
//   - Image loading uses an OperationQueue (serial, for cancellation)
//   - All @Published state updates dispatch to MainActor
//   - Volume building runs on a dedicated background queue
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import Combine
import DCMTKWrapper
import AppKit
import simd
import UniformTypeIdentifiers

// MARK: - Data Structures
struct DicomImageContext: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let seriesUID: String
    let seriesDescription: String
    let instanceNumber: Int
    let seriesNumber: Int
    let zLocation: Double?

    // Spatial metadata for 3D/MPR/cross-reference
    let imagePosition: SIMD3<Double>?         // Full ImagePositionPatient (x,y,z)
    let imageOrientation: [Double]?           // 6 direction cosines from ImageOrientationPatient
    let pixelSpacing: SIMD2<Double>?          // Row, Column spacing in mm
    let sliceThickness: Double?               // (0018,0050)
    let spacingBetweenSlices: Double?          // (0018,0088)
    let frameOfReferenceUID: String?          // (0020,0052) - gates cross-referencing
    let studyInstanceUID: String?             // (0020,000D)

    static func == (lhs: DicomImageContext, rhs: DicomImageContext) -> Bool {
        return lhs.url == rhs.url
    }
}

struct DicomSeries: Identifiable, Equatable {
    let id: String // SeriesUID
    let seriesNumber: Int
    let seriesDescription: String
    var images: [DicomImageContext]

    /// Computed: dominant axis of this series (axial/sagittal/coronal) based on ImageOrientationPatient
    var dominantAxis: SliceAxis? {
        guard let orient = images.first?.imageOrientation, orient.count == 6 else { return nil }
        // The slice normal = cross product of row and column direction cosines
        let rowDir = SIMD3<Double>(orient[0], orient[1], orient[2])
        let colDir = SIMD3<Double>(orient[3], orient[4], orient[5])
        let normal = cross(rowDir, colDir)

        let absX = abs(normal.x)
        let absY = abs(normal.y)
        let absZ = abs(normal.z)

        if absZ >= absX && absZ >= absY { return .axial }
        if absY >= absX && absY >= absZ { return .coronal }
        return .sagittal
    }
}

enum SliceAxis: String, CaseIterable {
    case axial, sagittal, coronal
}

// SIMD3 cross product helper
func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    return SIMD3<Double>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}

// MARK: - Model
class DICOMModel: ObservableObject {
    // Current State
    @Published var image: NSImage?
    @Published var tags: [DicomElement] = []
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    // Active tool selection
    @Published var activeTool: ActiveTool = .select
    
    // Series Management
    @Published var allSeries: [DicomSeries] = []
    @Published var currentSeriesIndex: Int = -1 {
        didSet {
             if currentSeriesIndex != -1 {
                 // 1. Start Caching (Background)
                 self.startSeriesCaching(seriesIndex: currentSeriesIndex)

                 // 2. Sync active panel
                 if let panel = activePanel {
                     panel.seriesIndex = currentSeriesIndex
                 }

                 // 3. Load First Image Immediately (Foreground)
                 if self.isValidIndex() {
                     // Already valid, maybe just an update?
                 } else if !self.allSeries[currentSeriesIndex].images.isEmpty {
                     self.currentImageIndex = 0
                     self.loadSingleFile(self.allSeries[currentSeriesIndex].images[0].url)
                 }
             }
        }
    }
    @Published var currentImageIndex: Int = -1
    
    // Metadata State
    @Published var currentSeriesInfo: String = ""
    @Published var currentImageInfo: String = ""
    @Published var windowWidth: Double = 0
    @Published var windowCenter: Double = 0
    
    // Baseline W/L for Reference (Needed for Filter-based W/L on compressed images)
    var initialWindowWidth: Double = 0
    var initialWindowCenter: Double = 0
    
    // Raw Data for Re-rendering
    private var rawPixelData: Data?
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0
    private var bitDepth: Int = 8
    private var samples: Int = 1
    private var isMonochrome1: Bool = false
    private var isSigned: Bool = false // PixelRepresentation (0028,0103)

    // State Persistence
    struct SeriesViewState {
        var windowWidth: Double?
        var windowCenter: Double?
        var scale: CGFloat = 1.0
        var translation: CGPoint = .zero
    }
    
    @Published var seriesStates: [String: SeriesViewState] = [:] // Key: SeriesUID
    
    // Histogram Data (Normalized 0-1 for 256 bins)
    @Published var histogramData: [Double] = []
    @Published var minPixelValue: Double = 0.0
    @Published var maxPixelValue: Double = 1.0

    // MARK: - Multi-Panel State
    @Published var layout: ViewerLayout = .single
    @Published var panels: [PanelState] = []
    @Published var activePanelID: UUID = UUID()
    @Published var showCrossReference: Bool = false
    @Published var showTags: Bool = false
    @Published var showHelp: Bool = false
    @Published var synchronizedScrolling: Bool = false {
        didSet {
            guard synchronizedScrolling, let source = activePanel else { return }

            // If single-panel, auto-expand to 2-panel and assign a same-axis series
            if layout == .single && allSeries.count > 1 {
                let sourceIdx = source.seriesIndex
                let sourceAxis = sourceIdx >= 0 && sourceIdx < allSeries.count
                    ? allSeries[sourceIdx].dominantAxis : nil

                // Find a different series with the same dominant axis (or just the next series)
                var bestIdx: Int? = nil
                for (i, s) in allSeries.enumerated() where i != sourceIdx {
                    if sourceAxis != nil && s.dominantAxis == sourceAxis {
                        bestIdx = i
                        break
                    }
                }
                // Fallback: just pick the next available series
                if bestIdx == nil {
                    bestIdx = allSeries.indices.first(where: { $0 != sourceIdx })
                }

                if let idx = bestIdx {
                    setLayout(.twoHorizontal)
                    if panels.count > 1 {
                        assignSeriesToPanel(panels[1], seriesIndex: idx)
                    }
                }
            }

            syncScrollFromPanel(source)
        }
    }

    /// The currently active panel (receives keyboard input, sidebar selections)
    var activePanel: PanelState? {
        panels.first(where: { $0.id == activePanelID })
    }

    /// When non-nil, the given panel fills the entire view (double-click toggle)
    @Published var fullscreenPanelID: UUID? = nil

    /// Toggle fullscreen for a panel (double-click behavior)
    func toggleFullscreen(for panel: PanelState) {
        if fullscreenPanelID == panel.id {
            fullscreenPanelID = nil  // Exit fullscreen
        } else {
            fullscreenPanelID = panel.id
            activePanelID = panel.id
        }
    }

    // Caching
    private let imageCache = NSCache<NSURL, NSImage>()
    private let rawDataCache = NSCache<NSURL, NSData>()
    private let dcmtkCache = NSCache<NSURL, DCMTKImageObject>()
    // Track W/L params for cached images: [URL: (WW, WC)]
    private var imageCacheParams: [NSURL: (Double, Double)] = [:]
    private let imageCacheParamsLock = NSLock()
    // Track pixel metadata for cached images so cache-hit path can restore panel state
    private struct PixelMeta {
        let width: Int; let height: Int; let bitDepth: Int; let samples: Int
        let isSigned: Bool; let isMonochrome1: Bool
    }
    private var imagePixelMeta: [NSURL: PixelMeta] = [:]
    // Queue for Series Caching
    private let cachingQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 2 // Limit concurrency
        return q
    }()
    
    @Published var isScanning: Bool = false
    @Published var cacheProgress: Double = 0.0
    
    // Request Token to prevent stale background loads from overriding current view
    private var currentLoadRequestID: UUID = UUID()
    private var lastPrecachedSeriesIndex: Int = -1
    
    // Series Thumbnails
    @Published var seriesThumbnails: [String: NSImage] = [:]
    private let thumbnailQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()
    
    // Main Loading Queue (Serial) to allow cancellation of stale requests
    private let loadingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated 
        return q
    }()
    
    // Background Pre-caching Queue
    private let precachingQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()
    

    
    // Native DCMTK Object (keeps DicomImage alive for W/L)
    private var dcmtkImage: DCMTKImageObject?

    var isRawDataAvailable: Bool { rawPixelData != nil }

    // MARK: - Volume / MPR
    /// Cached volumes keyed by series UID
    private var volumeCache: [String: VolumeData] = [:]
    /// Background queue for volume building
    private let volumeBuildQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    @Published var isVolumeBuildingInProgress: Bool = false
    @Published var volumeBuildProgress: Double = 0.0
    /// GPU renderer for MIP and volume rendering (lazy init)
    lazy var metalRenderer: MetalVolumeRenderer? = MetalVolumeRenderer()

    // Shift-key state for group selection overlay
    @Published var isShiftHeld: Bool = false
    private var flagsMonitor: Any?

    // MARK: - Initialization
    init() {
        let firstPanel = PanelState()
        self.panels = [firstPanel]
        self.activePanelID = firstPanel.id

        // Monitor Shift key globally for group selection overlay
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            let shiftDown = event.modifierFlags.contains(.shift)
            self.isShiftHeld = shiftDown
            // When Shift is released, clear group if ≤1 panel selected
            if !shiftDown {
                let selectedCount = self.panels.filter(\.isGroupSelected).count
                if selectedCount <= 1 {
                    self.clearGroupSelection()
                }
            }
            return event
        }
    }

    deinit {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    // Helper for Thumbnail Preview
    func getCachedImage(at index: Int) -> NSImage? {
        guard isValidIndex() else { return nil }
        // Use current series
        let images = allSeries[currentSeriesIndex].images
        guard index >= 0 && index < images.count else { return nil }
        
        let url = images[index].url
        
        // 1. Prefer generating fresh thumbnail from Raw Data with Auto W/L
        // This ensures visibility even if the cached PNG (from python) is black/low-contrast.
        if let raw = rawDataCache.object(forKey: url as NSURL) as Data? {
            // Heuristic context: Use current series dimensions
            // (Assuming uniform series, which is standard)
            let w = self.imageWidth > 0 ? self.imageWidth : 512
            let h = self.imageHeight > 0 ? self.imageHeight : 512
            
            // Auto-calculate Contrast (Min/Max) for this specific slice
            // We use 'isSigned' and 'bitDepth' from current model context.
            let (minVal, maxVal) = computeMinMax(data: raw, isSigned: self.isSigned, bits: self.bitDepth)
            let autoWW = maxVal - minVal
            let autoWC = minVal + (autoWW / 2.0)
            
            // Render
            // Passing a small width/height would require a new scaler. 
            // renderImage generates full size, but NSImage handles scaling in UI.
            // Performance: 512x512 render is fast (~ms).
            if let rendered = renderImage(width: w, height: h, pixelData: raw, ww: autoWW, wc: autoWC) {
                return rendered
            }
        }
        
        // 2. Fallback to pre-cached image (if any)
        return imageCache.object(forKey: url as NSURL)
    }
    
    // Asynchronous Series Thumbnail
    func requestSeriesThumbnail(for series: DicomSeries) {
        if seriesThumbnails[series.id] != nil { return }
        // Pick middle image
        guard !series.images.isEmpty else { return }
        let midIndex = series.images.count / 2
        let url = series.images[midIndex].url
        
        thumbnailQueue.addOperation { [weak self] in
            guard let self = self else { return }
            if self.seriesThumbnails[series.id] != nil { return }
            
            do {
                // Parse Header & Data for this specific file
                let data = try Data(contentsOf: url)
                let parser = SimpleDicomParser(data: data)
                let (elements, pixelData, syntax) = try parser.parse()
                guard let pd = pixelData else { return }

                // Extract tags needed for rendering
                func getInt(_ g: UInt16, _ e: UInt16) -> Int? { 
                    return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.intValue ?? 
                           Int(elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.stringValue ?? "")
                }
                
                let w = getInt(0x0028, 0x0011) ?? 512
                let h = getInt(0x0028, 0x0010) ?? 512
                let bits = getInt(0x0028, 0x0100) ?? 8 
                let samples = getInt(0x0028, 0x0002) ?? 1
                let signed = (getInt(0x0028, 0x0103) ?? 0) == 1
                let photo = elements.first(where: { $0.tag == DicomTag(group: 0x0028, element: 0x0004) })?.stringValue ?? "MONOCHROME2"
                
                // Compression Check: compares File Size vs Expected Raw Size OR Transfer Syntax OR Encapsulation
                let bytesPerPixel = (bits > 8 ? 2 : 1) * samples
                let expectedSize = w * h * bytesPerPixel
                // 1. Check Explicit UID (JPEG families start with 1.2.840.10008.1.2.4)
                let isCompressedUID = syntax?.contains("1.2.840.10008.1.2.4") ?? false
                // 2. Check Size Mismatch (Backup heuristic)
                let isSizeCompressed = (Double(pd.count) < Double(expectedSize) * 0.95)
                // 3. Check for Encapsulation Item Tag (FFFE,E000) -> LE: FE FF 00 E0
                // If present at start, it is definitely encapsulated (compressed)
                let startsWithItemTag = pd.count > 4 && pd[0] == 0xFE && pd[1] == 0xFF && pd[2] == 0x00 && pd[3] == 0xE0
                
                let isCompressed = isCompressedUID || isSizeCompressed || startsWithItemTag

                if isCompressed {
                    // Attempt native decode (JPEG/JPEG-LS/JPEG2000 embedded in DICOM)
                    // Encapsulated data usually starts with an Item Tag, then invalid bytes, then the image.
                    // We must find the Start of Image (SOI) marker.
                    
                    var compressedData: Data? = nil
                    let searchLimit = min(pd.count, 65536) // Search first 64KB (sufficient for Offset Table)
                    
                    // 1. JPEG / JPEG-LS (FF D8)
                    if let start = pd.range(of: Data([0xFF, 0xD8]), options: [], in: 0..<searchLimit) {
                        compressedData = pd.subdata(in: start.lowerBound..<pd.count)
                    } 
                    // 2. JPEG 2000 (FF 4F FF 51)
                    else if let start = pd.range(of: Data([0xFF, 0x4F, 0xFF, 0x51]), options: [], in: 0..<searchLimit) {
                        compressedData = pd.subdata(in: start.lowerBound..<pd.count)
                    }
                    else {
                        // 3. Last Resort: Try the whole blob (e.g. RLE or other formats)
                        compressedData = pd
                    }
                    
                    if let cData = compressedData, let rawImg = NSImage(data: cData) {
                         // Apply Auto-Leveling to raw compressed image
                         // Because typically these are raw captures (dark)
                         let leveledImg = self.autoLevelImage(rawImg) ?? rawImg
                         
                         DispatchQueue.main.async {
                             self.seriesThumbnails[series.id] = leveledImg
                         }
                         return
                    } else {
                        if let img = DCMTKHelper.convertDICOM(toNSImage: url.path) {
                             let leveledImg = self.autoLevelImage(img) ?? img
                             DispatchQueue.main.async {
                                 self.seriesThumbnails[series.id] = leveledImg
                             }
                        }
                        return
                    }
                }
                
                // Raw Render PATH
                
                // Auto W/L
                let (minVal, maxVal) = self.computeMinMax(data: pd, isSigned: signed, bits: bits)
                var ww = maxVal - minVal
                if ww == 0 { ww = 1 }
                let wc = minVal + (ww / 2.0)
                let winBottom = wc - (ww / 2.0)
                
                // Render (Stateless Logic)
                let totalPixels = w * h
                
                var buffer = [UInt8](repeating: 0, count: totalPixels)
                
                if bits > 8 {
                     pd.withUnsafeBytes { raw in
                         if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                             let count = min(totalPixels, pd.count/2)
                             for i in 0..<count {
                                 var val: Double = 0
                                 if signed { val = Double(Int16(bitPattern: ptr[i])) }
                                 else { val = Double(ptr[i]) }
                                 
                                 var norm = (val - winBottom) / ww
                                 if norm < 0 { norm = 0 }
                                 if norm > 1 { norm = 1 }
                                 if photo == "MONOCHROME1" { norm = 1.0 - norm }
                                 buffer[i] = UInt8(norm * 255.0)
                             }
                         }
                     }
                } else {
                     pd.withUnsafeBytes { raw in
                         if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                             let count = min(totalPixels, pd.count)
                             for i in 0..<count {
                                 let val = Double(ptr[i])
                                 var norm = (val - winBottom) / ww
                                 if norm < 0 { norm = 0 }
                                 if norm > 1 { norm = 1 }
                                 if photo == "MONOCHROME1" { norm = 1.0 - norm }
                                 buffer[i] = UInt8(norm * 255.0)
                             }
                         }
                     }
                }
                
                let colorSpace = CGColorSpaceCreateDeviceGray()
                if let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue),
                   let cg = ctx.makeImage() {
                    let rawImg = NSImage(cgImage: cg, size: NSSize(width: Double(w), height: Double(h)))
                    // Apply Auto-Leveling to raw render as well (handles outliers/padding)
                    let leveledImg = self.autoLevelImage(rawImg) ?? rawImg
                    
                    DispatchQueue.main.async {
                        self.seriesThumbnails[series.id] = leveledImg
                    }
                }
            } catch {
                // Thumbnail generation failed — skip silently
            }
        }
    }
    
    // Legacy generatePythonThumbnail removed


    // Helper: Auto-Level an NSImage (Contrast Stretch)
    private func autoLevelImage(_ input: NSImage) -> NSImage? {
        guard let cgImg = input.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let width = cgImg.width
        let height = cgImg.height
        let colorSpace = CGColorSpaceCreateDeviceGray()
        
        // Draw into 8-bit grayscale context to standardize
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let dataPtr = ctx.data else { return nil }
        let totalBytes = width * height
        let buffer = dataPtr.bindMemory(to: UInt8.self, capacity: totalBytes)
        
        // 1. Find Min/Max
        var minVal: UInt8 = 255
        var maxVal: UInt8 = 0
        
        // Optimization: Sample stride if huge? For thumbnail, full scan is fast enough (512x512 = 256k items)
        for i in 0..<totalBytes {
            let val = buffer[i]
            if val < minVal { minVal = val }
            if val > maxVal { maxVal = val }
        }
        
        // If contrast is already maxed or flat, return original
        if minVal == 0 && maxVal == 255 { return input }
        if minVal == maxVal { return input } // Flat image
        
        // 2. Apply Stretch
        // NewVal = (OldVal - Min) * 255 / (Max - Min)
        let range = Double(maxVal - minVal)
        
        for i in 0..<totalBytes {
            let oldVal = Double(buffer[i])
            var norm = (oldVal - Double(minVal)) / range
            if norm < 0 { norm = 0 }
            if norm > 1 { norm = 1 }
            buffer[i] = UInt8(norm * 255.0)
        }
        
        // 3. Create Image
        if let newCG = ctx.makeImage() {
            return NSImage(cgImage: newCG, size: input.size)
        }
        return nil
    }
    
    // MARK: - Load Methods

    /// Show an Open panel and load the selected DICOM file or folder.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "dcm")!,
            .folder
        ]
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        
        // Cancel any pending background work
        cachingQueue.cancelAllOperations()
        
        DispatchQueue.main.async {
            // Reset State completely
            self.errorMessage = nil
            self.isLoading = true
            self.image = nil
            self.rawPixelData = nil
            self.allSeries = []
            self.currentSeriesIndex = -1
            self.currentImageIndex = -1
            self.tags = []
            self.currentSeriesInfo = ""
            self.currentImageInfo = ""
            self.resetAllPanels()

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // Directory: Background scan
                    self.isScanning = true
                    self.scanDirectory(url)
                } else {
                    // File: Load immediately, then scan parent for context
                    self.loadSingleFile(url)
                    let parent = url.deletingLastPathComponent()
                    self.isScanning = true
                    self.scanDirectory(parent, selecting: url)
                }
            } else {
                 self.errorMessage = "File not accessible or does not exist."
                 self.isLoading = false
             }
        }
    }



    // MARK: - Image Loading
    func loadSingleFile(_ url: URL) {
        isLoading = true
        errorMessage = nil
        
        loadingQueue.cancelAllOperations()
        
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self = self, let op = op, !op.isCancelled else { return }
            
            // Trigger Pre-caching if new series
            if self.currentSeriesIndex != self.lastPrecachedSeriesIndex {
                self.lastPrecachedSeriesIndex = self.currentSeriesIndex
                self.precacheCurrentSeries()
            }
            
            // 1. Check Cache
            // Determine Target W/L (Persistent State)
            var targetWW: Double = 0
            var targetWC: Double = 0
            var hasTargetWL = false
            
            // We need to peek at seriesUID to get persistent state.
            // But we don't have seriesUID yet if we just have URL.
            // However, if we are in the same series context (navigating), we might know it.
            // For now, let's rely on the fact that if we are navigating, we likely have seriesStates populated.
            // But we can't know the SeriesUID of the file without parsing it or having it passed.
            // Optimization: If we are navigating the CURRENT series, we know the UID.
            
            if self.currentSeriesIndex >= 0 && self.currentSeriesIndex < self.allSeries.count {
                let currentSeriesUID = self.allSeries[self.currentSeriesIndex].id
                if let state = self.seriesStates[currentSeriesUID] {
                    if let sw = state.windowWidth, let sc = state.windowCenter {
                         targetWW = sw
                         targetWC = sc
                         hasTargetWL = true
                    }
                }
            }

            if let cachedImage = self.imageCache.object(forKey: url as NSURL) {
                let cachedRaw = self.rawDataCache.object(forKey: url as NSURL) as Data?
                let cachedDCMTK = self.dcmtkCache.object(forKey: url as NSURL)
                
                // Check W/L Mismatch
                var wlMismatch = false
                if hasTargetWL {
                    self.imageCacheParamsLock.lock()
                    let params = self.imageCacheParams[url as NSURL]
                    self.imageCacheParamsLock.unlock()
                    if let params = params {
                        // Allow small float diff
                        if abs(params.0 - targetWW) > 0.1 || abs(params.1 - targetWC) > 0.1 {
                            wlMismatch = true
                        }
                    } else {
                        // No params recorded (legacy cache?), assume mismatch to be safe or update?
                        // If we assume mismatch, we re-render. Safer.
                        wlMismatch = true
                    }
                }
                
                if !wlMismatch {
                    if let dcmtk = cachedDCMTK {
                        // Full Hit & W/L Match
                        DispatchQueue.main.async {
                            self.image = cachedImage
                            self.rawPixelData = cachedRaw
                            self.dcmtkImage = dcmtk
                            self.isLoading = false
                            self.syncLegacyStateToActivePanel()
                        }
                        return
                    } else {
                        // Partial Hit (Image OK, DCMTK missing)
                        // If W/L matches, show image, but reload DCMTK
                        DispatchQueue.main.async {
                            self.image = cachedImage
                        }
                    }
                } else {
                     // W/L Mismatch: Ignore cached image, fall through to re-render using cachedDCMTK if available
                     // If we have cachedDCMTK, we can fast-path re-render here!
                     if let dcmObj = cachedDCMTK {
                         if let newImg = dcmObj.renderImage(withWidth: 0, height: 0, ww: targetWW, wc: targetWC) {
                             DispatchQueue.main.async {
                                 self.image = newImg
                                 self.rawPixelData = cachedRaw
                                 self.dcmtkImage = dcmObj
                                 self.isLoading = false
                                 // Update Cache Params
                                 self.imageCache.setObject(newImg, forKey: url as NSURL)
                                 self.imageCacheParamsLock.lock()
                                 self.imageCacheParams[url as NSURL] = (targetWW, targetWC)
                                 self.imageCacheParamsLock.unlock()
                                 self.syncLegacyStateToActivePanel()
                             }
                             return
                         }
                     }
                }
            }
            
            // 2. Parse DICOM (Metadata)
            var seriesUID = "Unknown"
            do {
                let data = try Data(contentsOf: url)
                let parser = SimpleDicomParser(data: data)
                let (elements, _, _) = try parser.parse()
                
                if let uid = elements.first(where: { $0.tag == DicomTag(group: 0x0020, element: 0x000E) })?.stringValue {
                    seriesUID = uid
                }
                
                DispatchQueue.main.async {
                    self.tags = elements
                }
            } catch {
                print("Metadata parse error: \(error)")
            }
            
            // 3. Decode Image (Native DCMTK)
            let dcmObj = DCMTKImageObject(path: url.path)
            
            if let dcmObj = dcmObj {
                // 4. Get Raw Data (Needed for Auto W/L and Histogram)
                var width: Int = 0
                var height: Int = 0
                var depth: Int = 0
                var samples: Int = 0
                var isSigned: ObjCBool = false
                
                guard let rawData = dcmObj.getRawDataWidth(&width, height: &height, bitDepth: &depth, samples: &samples, isSigned: &isSigned) else {
                     DispatchQueue.main.async {
                         self.errorMessage = "Failed to get raw data"
                         self.isLoading = false
                     }
                     return
                }
                
                // 5. Determine Window/Level
                var ww: Double = 0
                var wc: Double = 0
                
                // Check Persistent State (Thread-safe access)
                var savedState: SeriesViewState?
                DispatchQueue.main.sync {
                    savedState = self.seriesStates[seriesUID]
                }
                
                if let state = savedState, let sw = state.windowWidth, let sc = state.windowCenter {
                    ww = sw
                    wc = sc
                } else {
                    // Try File Defaults
                    ww = dcmObj.getWindowWidth()
                    wc = dcmObj.getWindowCenter()
                    
                    // If invalid/missing, Auto-Calculate from Min/Max
                    if ww <= 0 {
                        let (minVal, maxVal) = self.computeMinMax(data: rawData as Data, isSigned: isSigned.boolValue, bits: depth)
                        ww = maxVal - minVal
                        wc = minVal + (ww / 2.0)
                    }
                }
                
                // 6. Render
                if let nsImage = dcmObj.renderImage(withWidth: 0, height: 0, ww: ww, wc: wc) {
                    self.imageCache.setObject(nsImage, forKey: url as NSURL)
                    self.dcmtkCache.setObject(dcmObj, forKey: url as NSURL)
                    self.imageCacheParamsLock.lock()
                    self.imageCacheParams[url as NSURL] = (ww, wc)
                    self.imagePixelMeta[url as NSURL] = PixelMeta(width: width, height: height, bitDepth: depth, samples: samples, isSigned: isSigned.boolValue, isMonochrome1: false)
                    self.imageCacheParamsLock.unlock()
                    self.rawDataCache.setObject(rawData as NSData, forKey: url as NSURL)

                    DispatchQueue.main.async {
                        self.dcmtkImage = dcmObj
                        self.image = nsImage
                        self.rawPixelData = rawData
                        self.imageWidth = width
                        self.imageHeight = height
                        self.bitDepth = depth
                        self.samples = samples
                        self.isSigned = isSigned.boolValue
                        
                        // Update W/L State
                        self.windowWidth = ww
                        self.windowCenter = wc
                        
                        // Save initial state if new
                        if self.seriesStates[seriesUID] == nil {
                            var newState = SeriesViewState()
                            newState.windowWidth = ww
                            newState.windowCenter = wc
                            self.seriesStates[seriesUID] = newState
                        }
                        
                        self.computeHistogram(data: rawData, isSigned: isSigned.boolValue, bits: depth)
                        self.isLoading = false
                        self.syncLegacyStateToActivePanel()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to render image"
                        self.isLoading = false
                    }
                }
            } else {
                // DCMTK failed — try JPEG2000 fallback via OpenJPEG
                var j2kWidth: Int = 0
                var j2kHeight: Int = 0
                var j2kDepth: Int = 0
                var j2kSamples: Int = 0
                var j2kSigned: ObjCBool = false

                if let j2kData = DCMTKHelper.decodeJPEG2000DICOM(
                    url.path,
                    width: &j2kWidth,
                    height: &j2kHeight,
                    bitDepth: &j2kDepth,
                    samples: &j2kSamples,
                    isSigned: &j2kSigned
                ) {
                    // Successfully decoded JPEG2000 — render using raw data path
                    let (minVal, maxVal) = self.computeMinMax(data: j2kData, isSigned: j2kSigned.boolValue, bits: j2kDepth)
                    let autoWW = maxVal - minVal
                    let autoWC = minVal + (autoWW / 2.0)

                    self.rawDataCache.setObject(j2kData as NSData, forKey: url as NSURL)

                    DispatchQueue.main.async {
                        self.rawPixelData = j2kData
                        self.imageWidth = j2kWidth
                        self.imageHeight = j2kHeight
                        self.bitDepth = j2kDepth
                        self.samples = j2kSamples
                        self.isSigned = j2kSigned.boolValue
                        self.windowWidth = autoWW
                        self.windowCenter = autoWC

                        if let rendered = self.renderImage(width: j2kWidth, height: j2kHeight, pixelData: j2kData, ww: autoWW, wc: autoWC) {
                            self.image = rendered
                            self.imageCache.setObject(rendered, forKey: url as NSURL)
                            self.imageCacheParamsLock.lock()
                            self.imageCacheParams[url as NSURL] = (autoWW, autoWC)
                            self.imageCacheParamsLock.unlock()
                        }

                        self.computeHistogram(data: j2kData, isSigned: j2kSigned.boolValue, bits: j2kDepth)
                        self.isLoading = false
                        self.syncLegacyStateToActivePanel()
                    }
                } else {
                    // Both DCMTK and JPEG2000 fallback failed
                    let errorDetail = DCMTKHelper.lastError(forPath: url.path) ?? "Unknown error"
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to load image: \(errorDetail)"
                        self.isLoading = false
                    }
                }
            }
        }
        loadingQueue.addOperation(op)
    }

    // ...

    // MARK: - Python/External Logic (REPLACED)
    // Kept empty or removed to clean up
    
    // Legacy stubs removed

    
    private func precacheCurrentSeries() {
        guard isValidIndex() else { return }
        let images = allSeries[currentSeriesIndex].images
        let seriesUID = allSeries[currentSeriesIndex].id
        
        // Determine Target W/L
        var targetWW: Double = 0
        var targetWC: Double = 0
        
        if let state = self.seriesStates[seriesUID] {
            if let sw = state.windowWidth, let sc = state.windowCenter {
                targetWW = sw
                targetWC = sc
            }
        }
        
        // Cancel previous precaching if any (optional, but good for switching series)
        precachingQueue.cancelAllOperations()
        
        for (index, imageFile) in images.enumerated() {
            // Skip if already cached AND W/L matches
            imageCacheParamsLock.lock()
            let params = imageCacheParams[imageFile.url as NSURL]
            imageCacheParamsLock.unlock()
            if let params = params {
                if abs(params.0 - targetWW) < 0.1 && abs(params.1 - targetWC) < 0.1 {
                    if imageCache.object(forKey: imageFile.url as NSURL) != nil &&
                       dcmtkCache.object(forKey: imageFile.url as NSURL) != nil {
                        continue
                    }
                }
            }
            
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self = self, let op = op, !op.isCancelled else { return }
                
                // Double check cache inside operation
                self.imageCacheParamsLock.lock()
                let cachedParams = self.imageCacheParams[imageFile.url as NSURL]
                self.imageCacheParamsLock.unlock()
                if let params = cachedParams {
                    if abs(params.0 - targetWW) < 0.1 && abs(params.1 - targetWC) < 0.1 {
                        if self.imageCache.object(forKey: imageFile.url as NSURL) != nil &&
                           self.dcmtkCache.object(forKey: imageFile.url as NSURL) != nil {
                            return
                        }
                    }
                }
                
                // Load DCMTK Object
                if let dcmObj = DCMTKImageObject(path: imageFile.url.path) {
                    // Use Target W/L if set, otherwise file defaults
                    var renderWW = targetWW
                    var renderWC = targetWC
                    
                    if renderWW == 0 {
                        renderWW = dcmObj.getWindowWidth()
                        renderWC = dcmObj.getWindowCenter()
                    }
                    
                    // Render
                    if let nsImage = dcmObj.renderImage(withWidth: 0, height: 0, ww: renderWW, wc: renderWC) {
                        self.imageCache.setObject(nsImage, forKey: imageFile.url as NSURL)
                        self.dcmtkCache.setObject(dcmObj, forKey: imageFile.url as NSURL)
                        self.imageCacheParamsLock.lock()
                        self.imageCacheParams[imageFile.url as NSURL] = (renderWW, renderWC)
                        self.imageCacheParamsLock.unlock()
                        
                        // Also cache raw data? Maybe too heavy. 
                        // Let's stick to image + dcmtk object for now.
                        // If user needs histogram, we can load raw data on demand.
                        // Or we can load it here too.
                        var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
                        var isSigned: ObjCBool = false
                        if let raw = dcmObj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &isSigned) {
                            self.rawDataCache.setObject(raw as NSData, forKey: imageFile.url as NSURL)
                            self.imageCacheParamsLock.lock()
                            self.imagePixelMeta[imageFile.url as NSURL] = PixelMeta(width: w, height: h, bitDepth: d, samples: s, isSigned: isSigned.boolValue, isMonochrome1: false)
                            self.imageCacheParamsLock.unlock()
                        }
                    }
                }
                
                // Update progress occasionally
                DispatchQueue.main.async {
                    if self.currentSeriesIndex < self.allSeries.count {
                        let total = Double(self.allSeries[self.currentSeriesIndex].images.count)
                        let done = Double(index + 1)
                        self.cacheProgress = done / total
                    }
                }
            }
            precachingQueue.addOperation(op)
        }
    }

    private func extractEncapsulatedData(_ data: Data) -> [Data]? {
        // Parse Sequence of Items from raw data block
        // Format: (Tag: FF FE E0 00) (Len: 4 bytes) (Value) ...
        var offset = 0
        var fragments: [Data] = []
        
        while offset + 8 <= data.count {
            let tag1 = data[offset]
            let tag2 = data[offset+1]
            let tag3 = data[offset+2]
            let tag4 = data[offset+3]
            
            // Check for Item Tag (FF FE E0 00)
            if tag1 == 0xFE && tag2 == 0xFF && tag3 == 0x00 && tag4 == 0xE0 {
                offset += 4
                // Length
                guard offset + 4 <= data.count else { break }
                let lenData = data.subdata(in: offset..<offset+4)
                let length = Int(lenData.withUnsafeBytes { $0.load(as: UInt32.self) }) // Assumes LE usually for fragments
                offset += 4
                
                if length > 0 {
                    if offset + length <= data.count {
                        fragments.append(data.subdata(in: offset..<offset+length))
                        offset += length
                    } else {
                        break // Truncated
                    }
                }
            } else if tag1 == 0xFE && tag2 == 0xFF && tag3 == 0xDD && tag4 == 0xE0 {
                 // Sequence Delimitation Item
                 break
            } else {
                // Garbage or alignment padding? Skim forward?
                // For now, strict check. If we lose alignment, abort.
                // Could just be simple valid data if not encapsulated, but we assume encapsulated here.
                offset += 1
            }
        }
        
        return fragments.isEmpty ? nil : fragments
    }

    // Legacy fallbackToExternalConverter removed

    
    // MARK: - State Management
    private func isValidIndex() -> Bool {
        return currentSeriesIndex >= 0 && currentSeriesIndex < allSeries.count &&
               currentImageIndex >= 0 && currentImageIndex < allSeries[currentSeriesIndex].images.count
    }

    private func getCurrentSeriesUID() -> String {
        guard isValidIndex() else { return "Unknown" }
        return allSeries[currentSeriesIndex].id
    }
    
    func saveViewState(scale: CGFloat, translation: CGPoint) {
        let uid = getCurrentSeriesUID()
        var state = seriesStates[uid] ?? SeriesViewState()
        state.scale = scale
        state.translation = translation
        // Preserve W/L if already set
        if let w = state.windowWidth { state.windowWidth = w }
        if let c = state.windowCenter { state.windowCenter = c }
        seriesStates[uid] = state
    }
    
    func getViewState() -> (CGFloat, CGPoint) {
        let uid = getCurrentSeriesUID()
        if let state = seriesStates[uid] {
            return (state.scale, state.translation)
        }
        return (1.0, .zero)
    }

    // MARK: - Presets
    func applyPreset(ww: Double, wc: Double) {
        self.adjustWindowLevel(deltaWidth: ww - self.windowWidth, deltaCenter: wc - self.windowCenter)
    }
    
    func autoWindowLevel() {
         // Re-calculate min-max strictly
        if let data = rawPixelData {
            let (minVal, maxVal) = computeMinMax(data: data, isSigned: isSigned, bits: bitDepth)
            // Just set full range
            let newWW = maxVal - minVal
            let newWC = minVal + (newWW / 2.0)
            applyPreset(ww: newWW, wc: newWC)
        }
    }

    private func computeHistogram(data: Data, isSigned: Bool, bits: Int) {
        // Run on background
        DispatchQueue.global(qos: .userInitiated).async {
            var bins = [Int](repeating: 0, count: 256)
            var totalCount = 0
            
            // Simplified Histogram: Downsample or Estimate range
            // For true W/L, we want distribution of actual pixel values.
            // But usually we map them to 0-255 buckets or calculate range.
            
            // 1. First get Min/Max to determine range size
            let (minVal, maxVal) = self.computeMinMax(data: data, isSigned: isSigned, bits: bits)
            let range = maxVal - minVal
            if range <= 0 { return }
            
            if bits > 16 { // 32-bit
                 data.withUnsafeBytes { rawBuffer in
                     if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) {
                         let count = data.count / 4
                         let stride = max(1, count / 50000)
                         
                         var i = 0
                         while i < count {
                             var v: Double = 0
                             if isSigned {
                                 v = Double(Int32(bitPattern: ptr[i]))
                             } else {
                                 v = Double(ptr[i])
                             }
                             
                             let bin = Int((v - minVal) / range * 255.0)
                             if bin >= 0 && bin < 256 {
                                 bins[bin] += 1
                                 totalCount += 1
                             }
                             i += stride
                         }
                     }
                 }
            } else if bits > 8 { // 16-bit
                 data.withUnsafeBytes { rawBuffer in
                     if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                         let count = data.count / 2
                         // Optimization: Skip pixels for speed? e.g. stride 4
                         let stride = max(1, count / 50000) // Target ~50k samples
                         
                         var i = 0
                         while i < count {
                             var v: Double = 0
                             if isSigned {
                                 v = Double(Int16(bitPattern: ptr[i]))
                             } else {
                                 v = Double(ptr[i])
                             }
                             
                             let bin = Int((v - minVal) / range * 255.0)
                             if bin >= 0 && bin < 256 {
                                 bins[bin] += 1
                                 totalCount += 1
                             }
                             i += stride
                         }
                     }
                 }
            } else {
                // 8-bit
                // ... same logic
                 data.withUnsafeBytes { rawBuffer in
                     if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                         let count = data.count
                         let stride = max(1, count / 50000)
                         var i = 0
                         while i < count {
                             let v = Double(ptr[i])
                             let bin = Int((v - minVal) / range * 255.0)
                             if bin >= 0 && bin < 256 {
                                 bins[bin] += 1
                                 totalCount += 1
                             }
                             i += stride
                         }
                     }
                 }
            }
            
            // Use log scale so the dominant bin (e.g. air in CT) doesn't flatten everything else
            let logBins = bins.map { log(1.0 + Double($0)) }
            let maxLog = logBins.max() ?? 1.0
            let normalized = maxLog > 0 ? logBins.map { $0 / maxLog } : logBins

            DispatchQueue.main.async {
                self.histogramData = normalized
                self.minPixelValue = minVal
                self.maxPixelValue = maxVal
            }
        }
    }
    
    // MARK: - Rendering
    func adjustWindowLevel(deltaWidth: Double, deltaCenter: Double) {
        self.windowWidth = max(1.0, self.windowWidth + deltaWidth)
        self.windowCenter += deltaCenter
        
        // Save Persistent State
        let uid = getCurrentSeriesUID()
        var state = seriesStates[uid] ?? SeriesViewState()
        state.windowWidth = self.windowWidth
        state.windowCenter = self.windowCenter
        seriesStates[uid] = state
        
        // Use DCMTK Object for rendering if available
        if let dcmObj = self.dcmtkImage {
             // print("DEBUG: Adjusting W/L - WW: \(self.windowWidth), WC: \(self.windowCenter)")
             if let newImg = dcmObj.renderImage(withWidth: 0, height: 0, ww: self.windowWidth, wc: self.windowCenter) {
                 self.image = newImg
             }
        } else if let data = self.rawPixelData {
            // Fallback to manual rendering (should not happen if dcmtkImage is set)
            if let newImg = renderImage(width: self.imageWidth, height: self.imageHeight, pixelData: data, ww: self.windowWidth, wc: self.windowCenter) {
                self.image = newImg
            }
        }
        
        // Update Cache Params for current image
        if isValidIndex() {
            let url = allSeries[currentSeriesIndex].images[currentImageIndex].url
            self.imageCacheParamsLock.lock()
            self.imageCacheParams[url as NSURL] = (self.windowWidth, self.windowCenter)
            self.imageCacheParamsLock.unlock()
            // Also update the image in cache with the new one?
            // Yes, if we rendered it, we should update the cache so scrolling back is instant with new W/L
            if let img = self.image {
                self.imageCache.setObject(img, forKey: url as NSURL)
            }
        }
    }
    
    /// Extract raw pixel data from an uncompressed DICOM file using SimpleDicomParser.
    /// Returns nil if the file uses encapsulated (compressed) transfer syntax or has no pixel data.
    private struct RawPixelResult {
        let pixelData: Data
        let width: Int
        let height: Int
        let bitDepth: Int
        let samples: Int
        let isSigned: Bool
        let isMonochrome1: Bool
    }

    private func extractRawPixelData(from url: URL) -> RawPixelResult? {
        guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let parser = SimpleDicomParser(data: fileData)
        guard let (elements, pixelData, transferSyntax) = try? parser.parse(stopAtPixelData: false),
              let pixelData = pixelData else { return nil }

        // Only handle uncompressed transfer syntaxes
        let uncompressedTS: Set<String> = [
            "1.2.840.10008.1.2",      // Implicit VR Little Endian
            "1.2.840.10008.1.2.1",    // Explicit VR Little Endian
            "1.2.840.10008.1.2.2",    // Explicit VR Big Endian
        ]
        let ts = (transferSyntax ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ts.isEmpty || uncompressedTS.contains(ts) else { return nil }

        func getStr(g: UInt16, e: UInt16) -> String? {
            return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func getInt(g: UInt16, e: UInt16) -> Int? {
            if let str = getStr(g: g, e: e), let val = Int(str) { return val }
            return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.intValue
        }

        guard let width = getInt(g: 0x0028, e: 0x0011),   // Columns
              let height = getInt(g: 0x0028, e: 0x0010),   // Rows
              width > 0, height > 0 else { return nil }

        let bitsAllocated = getInt(g: 0x0028, e: 0x0100) ?? 16   // BitsAllocated
        let bitsStored = getInt(g: 0x0028, e: 0x0101) ?? bitsAllocated  // BitsStored
        let samplesPerPixel = getInt(g: 0x0028, e: 0x0002) ?? 1  // SamplesPerPixel
        let pixelRepresentation = getInt(g: 0x0028, e: 0x0103) ?? 0  // 0=unsigned, 1=signed
        let photometric = getStr(g: 0x0028, e: 0x0004) ?? "MONOCHROME2"

        let isSigned = pixelRepresentation == 1
        let isMonochrome1 = photometric.uppercased().contains("MONOCHROME1")

        // Validate pixel data size
        let bytesPerPixel = (bitsAllocated / 8) * samplesPerPixel
        let expectedSize = width * height * bytesPerPixel
        guard pixelData.count >= expectedSize else { return nil }

        return RawPixelResult(
            pixelData: pixelData,
            width: width,
            height: height,
            bitDepth: bitsStored,
            samples: samplesPerPixel,
            isSigned: isSigned,
            isMonochrome1: isMonochrome1
        )
    }

    private func computeMinMax(data: Data, isSigned: Bool, bits: Int) -> (Double, Double) {
        var minVal: Double = Double.greatestFiniteMagnitude
        var maxVal: Double = -Double.greatestFiniteMagnitude
        
        if bits > 16 { // 32-bit
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) {
                     let count = data.count / 4
                     for i in 0..<count {
                         var v: Double = 0
                         if isSigned {
                             v = Double(Int32(bitPattern: ptr[i]))
                         } else {
                             v = Double(ptr[i])
                         }
                         
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        } else if bits > 8 { // 16-bit
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                     let count = data.count / 2
                     for i in 0..<count {
                         var v: Double = 0
                         if isSigned {
                             v = Double(Int16(bitPattern: ptr[i]))
                         } else {
                             v = Double(ptr[i])
                         }
                         
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        } else {
             data.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                     let count = data.count
                     for i in 0..<count {
                         let v = Double(ptr[i])
                         if v < minVal { minVal = v }
                         if v > maxVal { maxVal = v }
                     }
                 }
             }
        }
        
        if maxVal == minVal { maxVal = minVal + 1 }
        return (minVal, maxVal)
    }
    
    /// Render raw pixel data to an NSImage with window/level tone mapping.
    /// All pixel-format parameters are explicit to avoid stale model-level state.
    private func renderImage(width: Int, height: Int, pixelData: Data, ww: Double, wc: Double,
                             bits: Int, spp: Int, signed: Bool, mono1: Bool) -> NSImage? {
        guard width > 0, height > 0 else { return nil }

        // Handle RGB Protocol
        if spp == 3 {
             let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
             let totalBytes = width * height * 3
             guard pixelData.count >= totalBytes else { return nil }
             let provider = CGDataProvider(data: pixelData as CFData)
             if let p = provider,
                let cgImg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: rgbColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: p, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                 return NSImage(cgImage: cgImg, size: NSSize(width: Double(width), height: Double(height)))
             }
             return nil
        }

        let totalPixels = width * height
        let colorSpace = CGColorSpaceCreateDeviceGray()

        // Create context with internal memory management
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let destData = context.data else { return nil }
        let destBuffer = destData.bindMemory(to: UInt8.self, capacity: totalPixels)

        // VOI LUT function (Linear)
        let w = ww
        let c = wc
        let windowBottom = c - (w / 2.0)

        if bits > 16 {
             // 32-bit
             pixelData.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) {
                     if pixelData.count >= totalPixels * 4 {
                         for i in 0..<totalPixels {
                             var val: Double = 0
                             if signed {
                                 val = Double(Int32(bitPattern: ptr[i]))
                             } else {
                                 val = Double(ptr[i])
                             }

                             var norm = (val - windowBottom) / w * 255.0
                             if mono1 { norm = 255.0 - norm }

                             destBuffer[i] = UInt8(max(0, min(255, norm)))
                         }
                     }
                 }
             }
        } else if bits > 8 {
             // 16-bit
             pixelData.withUnsafeBytes { rawBuffer in
                 if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                     // Check if buffer size matches
                     if pixelData.count >= totalPixels * 2 {
                         for i in 0..<totalPixels {
                             var val: Double = 0
                             if signed {
                                 val = Double(Int16(bitPattern: ptr[i]))
                             } else {
                                 val = Double(ptr[i])
                             }

                             var norm = (val - windowBottom) / w * 255.0
                             if mono1 { norm = 255.0 - norm }

                             destBuffer[i] = UInt8(max(0, min(255, norm)))
                         }
                     }
                 }
             }
        } else {
            // 8-bit
            pixelData.withUnsafeBytes { rawBuffer in
                if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                     for i in 0..<totalPixels {
                         let val = Double(ptr[i])
                         var norm = (val - windowBottom) / w * 255.0
                         if mono1 { norm = 255.0 - norm }
                         destBuffer[i] = UInt8(max(0, min(255, norm)))
                     }
                }
            }
        }

        if let cgImage = context.makeImage() {
            return NSImage(cgImage: cgImage, size: NSSize(width: Double(width), height: Double(height)))
        }
        return nil
    }

    /// Convenience: render using model-level pixel format state (for legacy single-panel paths)
    private func renderImage(width: Int, height: Int, pixelData: Data, ww: Double, wc: Double) -> NSImage? {
        return renderImage(width: width, height: height, pixelData: pixelData, ww: ww, wc: wc,
                           bits: self.bitDepth, spp: self.samples, signed: self.isSigned, mono1: self.isMonochrome1)
    }
    
    // Track currently caching series to avoid redundant cancellations
    private var currentCachingSeriesUID: String? = nil

    // MARK: - Caching Logic
    // Starts caching the entire series in background, prioritized by distance from cursor
    private func startSeriesCaching(seriesIndex: Int) {
        // 1. Pause Caching during Directory Scan to prevent resource starvation
        // The "First Image" is loaded explicitly by loadSingleFile, so we don't need background caching yet.
        if isScanning { return }

        guard seriesIndex >= 0 && seriesIndex < allSeries.count else { return }
        let series = allSeries[seriesIndex]
        
        // If same series, we generally want to keep going, but since we paused during scan,
        // we might need to restart or update. 
        // For simplicity: If we are here, it means scanning is DONE or we switched series.
        // We can safely cancel old stuff and start fresh to ensure priority is correct.
        
        cachingQueue.cancelAllOperations()
        currentCachingSeriesUID = series.id
        
        let images = series.images
        guard !images.isEmpty else { return }
        let total = Double(images.count)
        
        // Recalculate Progress base on what's ALREADY cached
        let alreadyCachedCount = images.filter { 
            imageCache.object(forKey: $0.url as NSURL) != nil || rawDataCache.object(forKey: $0.url as NSURL) != nil 
        }.count
        
        // Update progress safely
        self.cacheProgress = Double(alreadyCachedCount) / total
        
        let centerIndex = max(0, currentImageIndex < images.count ? currentImageIndex : 0)
        let indices = Array(0..<images.count).sorted { abs($0 - centerIndex) < abs($1 - centerIndex) }
        
        for idx in indices {
            let context = images[idx]
            let url = context.url
            
            // Skip if cached
            if imageCache.object(forKey: url as NSURL) != nil || rawDataCache.object(forKey: url as NSURL) != nil {
                continue
            }
            
            let op = BlockOperation()
            op.addExecutionBlock { [weak self, weak op] in
                guard let self = self, let op = op, !op.isCancelled else { return }
                
                // Double check cache inside op
                if self.imageCache.object(forKey: context.url as NSURL) == nil
                    && self.rawDataCache.object(forKey: context.url as NSURL) == nil {
                     
                     self.cacheImageBackground(url: context.url)
                     
                     // Increment Progress on Main Thread
                     if !op.isCancelled {
                         DispatchQueue.main.async {
                             if self.currentCachingSeriesUID == series.id {
                                 // Safely increment
                                 self.cacheProgress += (1.0 / total)
                                 if self.cacheProgress > 1.0 { self.cacheProgress = 1.0 }
                             }
                         }
                     }
                }
            }
            cachingQueue.addOperation(op)
        }
    }
    
    // Clean up legacy calls
    private func prefetchAdjacentImages() {
         // No-op or trigger re-prioritization if we implemented it.
         // Calling startSeriesCaching here would trigger the "Same Series" check and return immediately.
         startSeriesCaching(seriesIndex: self.currentSeriesIndex)
    }
    
    private func cacheImageBackground(url: URL) {
        // Reduced version of loading just to populate cache
        do {
             let data = try Data(contentsOf: url)
             let parser = SimpleDicomParser(data: data)
             let (_, pixelData, syntax) = try parser.parse()
             
             // Check syntax/compression
             // Explicitly check for known uncompressed syntaxes
             let isUncompressed = syntax == "1.2.840.10008.1.2" ||
                                  syntax == "1.2.840.10008.1.2.1" ||
                                  syntax == "1.2.840.10008.1.2.2" ||
                                  syntax == nil
             
             var finalRaw: Data?
             
             if isUncompressed, let pd = pixelData {
                 finalRaw = pd
             } 
             // Determine if we need to attempt JPEG encapsulated extraction
             else if let pd = pixelData, pd.count > 8, let fragments = extractEncapsulatedData(pd), !fragments.isEmpty {
                 let combined = fragments.reduce(Data(), +)
                 // NOTE: We can only cache the combined stream here, but we can't easily turn it into RAW without proper decoding.
                 // For now, if we have a JPEG stream, let's treat it as needing rendering or external conv if NSImage fails.
                 if let _ = NSImage(data: combined) {
                     // Native NSImage supports it. We can cache the NSImage?
                     // Or just leave it. loadSingleFile is fast for native NSImage.
                     // But user wants "NO LOADING". So we should cache the NSImage.
                     if let img = NSImage(data: combined) {
                         self.imageCache.setObject(img, forKey: url as NSURL)
                     }
                 } else {
                     // Native failed? External convert.
                 }
             }
             
             if let r = finalRaw {
                 self.rawDataCache.setObject(r as NSData, forKey: url as NSURL)
             } else {
                 // Compressed / Native failed -> Use DCMTK
                 if let img = DCMTKHelper.convertDICOM(toNSImage: url.path) {
                      self.imageCache.setObject(img, forKey: url as NSURL)
                 } else {
                     // DCMTK failed -> try JPEG2000 fallback via OpenJPEG
                     var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
                     var signed: ObjCBool = false
                     if let j2kData = DCMTKHelper.decodeJPEG2000DICOM(
                         url.path, width: &w, height: &h,
                         bitDepth: &d, samples: &s, isSigned: &signed) {
                         self.rawDataCache.setObject(j2kData as NSData, forKey: url as NSURL)
                     }
                 }
             }
        } catch { }
    }
    
    // Synchronous version of fallbackToExternalConverter for background queue usage
    // Legacy runExternalConverterSynchronous removed


    // MARK: - Directory
    private func scanDirectory(_ url: URL, selecting targetUrl: URL? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            var contexts: [DicomImageContext] = []
            
            // Helper to update UI safely
            func updateUI(isFinal: Bool) {
                // Group & Sort (Heavy work on BG thread)
                let grouped = Dictionary(grouping: contexts, by: { $0.seriesUID })
                var seriesList: [DicomSeries] = []
                for (uid, images) in grouped {
                    var sortedImages = images
                    let zLocations = images.compactMap { $0.zLocation }
                    let uniqueZ = Set(zLocations).count
                    let instanceNumbers = images.map { $0.instanceNumber }
                    let uniqueInst = Set(instanceNumbers).count
                    
                    // Priority 1: Instance Number (Logical Sequence)
                    if uniqueInst > 1 {
                         // print("Sorting Series \(uid) by Instance Number (\(uniqueInst) unique)")
                         sortedImages.sort { $0.instanceNumber < $1.instanceNumber }
                    } 
                    // Priority 2: Z-Location (Spatial Sequence)
                    else if uniqueZ > 1 {
                        // print("Sorting Series \(uid) by Z-Location (Fallback) (\(uniqueZ) unique)")
                        sortedImages.sort { ($0.zLocation ?? 0) < ($1.zLocation ?? 0) }
                    } else {
                        // print("Sorting Series \(uid) by Default (Instance)")
                        sortedImages.sort { $0.instanceNumber < $1.instanceNumber }
                    }
                    
                    let sNum = sortedImages.first?.seriesNumber ?? 0
                    let sDesc = sortedImages.first?.seriesDescription ?? "No Description"
                    seriesList.append(DicomSeries(id: uid, seriesNumber: sNum, seriesDescription: sDesc, images: sortedImages))
                }
                seriesList.sort { $0.seriesNumber < $1.seriesNumber }
                
                DispatchQueue.main.async {
                    // Capture current selection UID before replacing list
                    let currentUID = (self.currentSeriesIndex >= 0 && self.currentSeriesIndex < self.allSeries.count) ? self.allSeries[self.currentSeriesIndex].id : nil
                    let currentImgURL = (self.currentSeriesIndex >= 0 && self.currentSeriesIndex < self.allSeries.count && self.currentImageIndex >= 0 && self.currentImageIndex < self.allSeries[self.currentSeriesIndex].images.count) ? self.allSeries[self.currentSeriesIndex].images[self.currentImageIndex].url : nil
                    
                    self.allSeries = seriesList
                    
                    if isFinal { self.isScanning = false }
                    
                    // Restore Selection or Initialize
                    if let uid = currentUID, let newParams = seriesList.enumerated().first(where: { $0.element.id == uid }) {
                        self.currentSeriesIndex = newParams.offset
                        
                        // Decision: Stick to Start (Index 0) OR Track File?
                        // If user opened folder (no target) and is at start, keep them at start as list fills.
                        // This fixes the issue where Fast Load shows a random file (Index 0) and we get stuck with it mid-series.
                        if targetUrl == nil && self.currentImageIndex == 0 {
                            self.currentImageIndex = 0
                            // Force reload of new first image content
                             if let first = self.allSeries[self.currentSeriesIndex].images.first {
                                 // Only reload if url changed to avoid redundant processing
                                 if first.url != currentImgURL {
                                     if let panel = self.activePanel {
                                         self.loadSingleFileForPanel(first.url, panel: panel)
                                     } else {
                                         self.loadSingleFile(first.url)
                                     }
                                 }
                             }
                        } else {
                            // Restore Image Selection within the series (Track File)
                            if let imgURL = currentImgURL {
                                 let images = self.allSeries[self.currentSeriesIndex].images
                                 if let imgIdx = images.firstIndex(where: { $0.url == imgURL }) {
                                     self.currentImageIndex = imgIdx
                                 }
                            }
                        }
                    }
                    else if self.currentSeriesIndex == -1 && !self.allSeries.isEmpty {
                        // Robust First Load Selection
                         var found = false
                         if let target = targetUrl {
                             let targetPath = target.path
                             // Search for exact file match (using path string to avoid URL discrepancies)
                             for (sIdx, series) in self.allSeries.enumerated() {
                                 if let imgIdx = series.images.firstIndex(where: { $0.url.path == targetPath }) {
                                     self.currentSeriesIndex = sIdx
                                     self.currentImageIndex = imgIdx
                                     found = true
                                     break
                                 }
                             }
                         }
                         
                         // Fallback: Default to First Series, First Image
                         if !found {
                             self.currentSeriesIndex = 0
                             self.currentImageIndex = 0
                             // Trigger load for the very first image found
                             if let first = self.allSeries.first?.images.first {
                                 if let panel = self.activePanel {
                                     self.assignSeriesToPanel(panel, seriesIndex: 0)
                                 } else {
                                     self.loadSingleFile(first.url)
                                 }
                             }
                         }
                    } else if self.allSeries.isEmpty && isFinal {
                        self.errorMessage = "No DICOM series found."
                        self.isLoading = false
                    }
                }
            }

            // Process
            var firstFound = false
            var counter = 0
            
            for case let fileURL as URL in enumerator {
                // Check directory
                if let resources = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]), resources.isDirectory == true { continue }
                
                // Check Extension
                let ext = fileURL.pathExtension.lowercased()
                if ext != "dcm" && ext != "" { continue }
                
                // Process File
                if let context = self.quickParse(fileURL) { 
                    contexts.append(context) 
                    
                    // FAST LOAD: First Image
                    if !firstFound && targetUrl == nil {
                        firstFound = true
                        DispatchQueue.main.async {
                            // Only set if we are still empty (avoid race conditions)
                            if self.allSeries.isEmpty {
                                let tempSeries = DicomSeries(id: context.seriesUID, seriesNumber: context.seriesNumber, seriesDescription: context.seriesDescription, images: [context])
                                self.allSeries = [tempSeries]
                                self.currentSeriesIndex = 0
                                self.currentImageIndex = 0 // Explicitly set 0
                                // Use the panel-specific loading path (not the legacy loadSingleFile)
                                // to avoid race conditions with scan-time updateUI re-loads
                                if let panel = self.activePanel {
                                    self.assignSeriesToPanel(panel, seriesIndex: 0)
                                } else {
                                    self.loadSingleFile(context.url)
                                }
                            }
                        }
                    }
                    
                    // Continuous Update (Every 100 files for faster feedback)
                    counter += 1
                    if counter % 100 == 0 {
                        updateUI(isFinal: false)
                    }
                }
            }
            
            // Final Update
            updateUI(isFinal: true)

            // Auto-assign series to panels when in multi-panel mode
            if self.panels.count > 1 {
                DispatchQueue.main.async {
                    self.autoAssignSeriesToPanels()
                }
            }
        }
    }
    
    private func quickParse(_ url: URL) -> DicomImageContext? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let parser = SimpleDicomParser(data: data)
            let (elements, _, _) = try parser.parse(stopAtPixelData: true)
            
            func getStr(g: UInt16, e: UInt16) -> String? {
                return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func getInt(g: UInt16, e: UInt16) -> Int? {
                if let str = elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.stringValue,
                   let val = Int(str) { return val }
                return elements.first(where: { $0.tag == DicomTag(group: g, element: e) })?.intValue
            }
            
            // Filter out non-image DICOM objects (Structured Reports, Key Objects,
            // Presentation States, etc.) by checking SOP Class UID and Modality.
            let sopClassUID = getStr(g: 0x0008, e: 0x0016) ?? parser.findTagRaw(DicomTag(group: 0x0008, element: 0x0016)) ?? ""
            let modality = getStr(g: 0x0008, e: 0x0060) ?? parser.findTagRaw(DicomTag(group: 0x0008, element: 0x0060)) ?? ""

            // Non-image SOP Class UID prefixes/values to exclude
            let nonImageSOPClasses: Set<String> = [
                "1.2.840.10008.5.1.4.1.1.88.11",  // Basic Text SR
                "1.2.840.10008.5.1.4.1.1.88.22",  // Enhanced SR
                "1.2.840.10008.5.1.4.1.1.88.33",  // Comprehensive SR
                "1.2.840.10008.5.1.4.1.1.88.34",  // Comprehensive 3D SR
                "1.2.840.10008.5.1.4.1.1.88.35",  // Extensible SR
                "1.2.840.10008.5.1.4.1.1.88.40",  // Procedure Log
                "1.2.840.10008.5.1.4.1.1.88.50",  // Mammography CAD SR
                "1.2.840.10008.5.1.4.1.1.88.59",  // Key Object Selection
                "1.2.840.10008.5.1.4.1.1.88.65",  // Chest CAD SR
                "1.2.840.10008.5.1.4.1.1.88.67",  // X-Ray Radiation Dose SR
                "1.2.840.10008.5.1.4.1.1.88.68",  // Radiopharmaceutical Radiation Dose SR
                "1.2.840.10008.5.1.4.1.1.88.69",  // Colon CAD SR
                "1.2.840.10008.5.1.4.1.1.88.70",  // Implantation Plan SR
                "1.2.840.10008.5.1.4.1.1.88.71",  // Acquisition Context SR
                "1.2.840.10008.5.1.4.1.1.88.72",  // Simplified Adult Echo SR
                "1.2.840.10008.5.1.4.1.1.88.73",  // Patient Radiation Dose SR
                "1.2.840.10008.5.1.4.1.1.11.1",   // Grayscale Softcopy Presentation State
                "1.2.840.10008.5.1.4.1.1.11.2",   // Color Softcopy Presentation State
                "1.2.840.10008.5.1.4.1.1.11.3",   // Pseudo-Color Softcopy Presentation State
                "1.2.840.10008.5.1.4.1.1.11.4",   // Blending Softcopy Presentation State
                "1.2.840.10008.3.1.2.3.3",         // Modality Performed Procedure Step
                "1.2.840.10008.5.1.4.1.1.104.1",  // Encapsulated PDF
                "1.2.840.10008.5.1.4.1.1.104.2",  // Encapsulated CDA
            ]
            let nonImageModalities: Set<String> = ["SR", "KO", "PR"]

            let trimmedSOP = sopClassUID.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModality = modality.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

            if nonImageSOPClasses.contains(trimmedSOP) || nonImageModalities.contains(trimmedModality) {
                return nil
            }

            var seriesUID = getStr(g: 0x0020, e: 0x000E) ?? "UnknownSeries"
            // Fallback for Series UID
            if seriesUID == "UnknownSeries" || seriesUID == "-" {
                if let raw = parser.findTagRaw(DicomTag(group: 0x0020, element: 0x000E)) {
                    seriesUID = raw
                }
            }
            
            let seriesDescription = getStr(g: 0x0008, e: 0x103E) ?? "No Description"
            let instanceNumber = getInt(g: 0x0020, e: 0x0013) ?? 0
            
            // Fallback for Instance Number (using raw string parse)
            var finalInstanceNumber = instanceNumber
            if finalInstanceNumber == 0 {
                if let raw = parser.findTagRaw(DicomTag(group: 0x0020, element: 0x0013)), let val = Int(raw) {
                    finalInstanceNumber = val
                }
            }
            
            let seriesNumber = getInt(g: 0x0020, e: 0x0011) ?? 0
            
            // Extract full ImagePositionPatient (0020,0032) — x, y, z
            var zLoc: Double? = nil
            var imagePosition: SIMD3<Double>? = nil

            func parseIPP(_ str: String) -> (SIMD3<Double>?, Double?) {
                let parts = str.components(separatedBy: "\\").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 3,
                   let x = Double(parts[0]), let y = Double(parts[1]), let z = Double(parts[2]) {
                    return (SIMD3<Double>(x, y, z), z)
                }
                return (nil, nil)
            }

            if let posStr = getStr(g: 0x0020, e: 0x0032) {
                let (pos, z) = parseIPP(posStr)
                imagePosition = pos
                zLoc = z
            }
            // Fallback for IPP
            if imagePosition == nil {
                if let raw = parser.findTagRaw(DicomTag(group: 0x0020, element: 0x0032)) {
                    let (pos, z) = parseIPP(raw)
                    imagePosition = pos
                    zLoc = z
                }
            }

            // ImageOrientationPatient (0020,0037) — 6 direction cosines
            var imageOrientation: [Double]? = nil
            if let orientStr = getStr(g: 0x0020, e: 0x0037) ?? parser.findTagRaw(DicomTag(group: 0x0020, element: 0x0037)) {
                let parts = orientStr.components(separatedBy: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 6 {
                    imageOrientation = parts
                }
            }

            // PixelSpacing (0028,0030) — row\column in mm
            var pixelSpacing: SIMD2<Double>? = nil
            if let spacingStr = getStr(g: 0x0028, e: 0x0030) ?? parser.findTagRaw(DicomTag(group: 0x0028, element: 0x0030)) {
                let parts = spacingStr.components(separatedBy: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 2 {
                    pixelSpacing = SIMD2<Double>(parts[0], parts[1])
                }
            }
            // Fallback: ImagerPixelSpacing (0018,1164)
            if pixelSpacing == nil {
                if let spacingStr = getStr(g: 0x0018, e: 0x1164) ?? parser.findTagRaw(DicomTag(group: 0x0018, element: 0x1164)) {
                    let parts = spacingStr.components(separatedBy: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parts.count == 2 {
                        pixelSpacing = SIMD2<Double>(parts[0], parts[1])
                    }
                }
            }

            // SliceThickness (0018,0050)
            var sliceThickness: Double? = nil
            if let thickStr = getStr(g: 0x0018, e: 0x0050) ?? parser.findTagRaw(DicomTag(group: 0x0018, element: 0x0050)) {
                sliceThickness = Double(thickStr)
            }

            // SpacingBetweenSlices (0018,0088)
            var spacingBetweenSlices: Double? = nil
            if let sbsStr = getStr(g: 0x0018, e: 0x0088) ?? parser.findTagRaw(DicomTag(group: 0x0018, element: 0x0088)) {
                spacingBetweenSlices = Double(sbsStr)
            }

            // FrameOfReferenceUID (0020,0052) — gates cross-referencing
            let frameOfReferenceUID = getStr(g: 0x0020, e: 0x0052) ?? parser.findTagRaw(DicomTag(group: 0x0020, element: 0x0052))

            // StudyInstanceUID (0020,000D)
            let studyInstanceUID = getStr(g: 0x0020, e: 0x000D) ?? parser.findTagRaw(DicomTag(group: 0x0020, element: 0x000D))

            return DicomImageContext(
                url: url,
                seriesUID: seriesUID,
                seriesDescription: seriesDescription,
                instanceNumber: finalInstanceNumber,
                seriesNumber: seriesNumber,
                zLocation: zLoc,
                imagePosition: imagePosition,
                imageOrientation: imageOrientation,
                pixelSpacing: pixelSpacing,
                sliceThickness: sliceThickness,
                spacingBetweenSlices: spacingBetweenSlices,
                frameOfReferenceUID: frameOfReferenceUID,
                studyInstanceUID: studyInstanceUID
            )
        } catch { return nil }
    }
    
    private func selectImage(url: URL) {
        // Find series and image index
        for (sIdx, series) in allSeries.enumerated() {
            if let iIdx = series.images.firstIndex(where: { $0.url == url }) {
                self.currentSeriesIndex = sIdx
                self.currentImageIndex = iIdx
                return
            }
        }
    }
    
    // MARK: - Navigation helpers
    func nextImage() {
        guard isValidIndex() else { return }
        if currentImageIndex < allSeries[currentSeriesIndex].images.count - 1 {
            currentImageIndex += 1
            loadCurrent()
        }
    }
    
    func prevImage() {
        guard isValidIndex() else { return }
        if currentImageIndex > 0 {
            currentImageIndex -= 1
            loadCurrent()
        }
    }
    
    func nextSeries() {
        if currentSeriesIndex < allSeries.count - 1 {
            currentSeriesIndex += 1
            currentImageIndex = 0
            loadCurrent()
        }
    }

    func prevSeries() {
        if currentSeriesIndex > 0 {
            currentSeriesIndex -= 1
            currentImageIndex = 0
            loadCurrent()
        }
    }
    private func loadCurrent() {
        guard isValidIndex() else { return }
        let ctx = allSeries[currentSeriesIndex].images[currentImageIndex]
        loadSingleFile(ctx.url)
    }
    
    // MARK: - Info Update
    private func updateInfoStrings() {
        if isValidIndex() {
            let s = allSeries[currentSeriesIndex]
            let i = s.images[currentImageIndex]
            self.currentSeriesInfo = "Series \(currentSeriesIndex + 1)/\(allSeries.count)"
            self.currentImageInfo = "Image \(i.instanceNumber) (\(currentImageIndex + 1)/\(s.images.count))"
        } else {
            self.currentSeriesInfo = ""; self.currentImageInfo = ""
        }
    }

    // MARK: - Legacy-to-Panel Sync

    /// Sync DICOMModel's legacy single-view state to the active panel.
    /// Called after loadSingleFile completes so that the active panel mirrors legacy state.
    private func syncLegacyStateToActivePanel() {
        guard let panel = activePanel else { return }
        if let img = self.image {
            panel.setDisplayImage(img)
        } else {
            panel.image = nil
        }
        panel.rawPixelData = self.rawPixelData
        panel.dcmtkImage = self.dcmtkImage
        panel.imageWidth = self.imageWidth
        panel.imageHeight = self.imageHeight
        panel.bitDepth = self.bitDepth
        panel.samples = self.samples
        panel.isSigned = self.isSigned
        panel.windowWidth = self.windowWidth
        panel.windowCenter = self.windowCenter
        panel.tags = self.tags
        panel.isLoading = self.isLoading
        panel.errorMessage = self.errorMessage
        panel.seriesIndex = self.currentSeriesIndex
        panel.imageIndex = self.currentImageIndex
        panel.histogramData = self.histogramData

        // Spatial metadata
        if currentSeriesIndex >= 0, currentSeriesIndex < allSeries.count,
           let ctx = allSeries[currentSeriesIndex].images[safe: currentImageIndex] {
            if let pos = ctx.imagePosition {
                panel.imagePositionPatient = (pos.x, pos.y, pos.z)
            }
            panel.imageOrientationPatient = ctx.imageOrientation
            if let ps = ctx.pixelSpacing {
                panel.pixelSpacing = (ps.x, ps.y)
            }
        }

        updatePanelInfoStrings(panel)
    }

    /// Assign a series to a specific panel and load its first image
    func assignSeriesToPanel(_ panel: PanelState, seriesIndex: Int) {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return }
        panel.seriesIndex = seriesIndex
        panel.imageIndex = 0
        panel.panelMode = .slice2D
        panel.windowWidth = 0  // Reset W/L for new series assignment
        panel.windowCenter = 0
        if let first = allSeries[seriesIndex].images.first {
            loadSingleFileForPanel(first.url, panel: panel)
        }
        updatePanelInfoStrings(panel)
    }

    // MARK: - W/L Helpers

    /// Navigate panel by an offset (positive = forward, negative = backward)
    func navigatePanelByOffset(_ panel: PanelState, offset: Int) {
        // If panel is group-selected, scroll all group members by the same offset
        if panel.isGroupSelected {
            let groupPanels = groupSelectedPanels
            if groupPanels.count > 1 {
                for p in groupPanels {
                    navigatePanelByOffsetDirect(p, offset: offset)
                }
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }
        navigatePanelByOffsetDirect(panel, offset: offset)
        if synchronizedScrolling { syncScrollFromPanel(panel) }
    }

    private func navigatePanelByOffsetDirect(_ panel: PanelState, offset: Int) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let series = allSeries[panel.seriesIndex]
        let newIndex = max(0, min(series.images.count - 1, panel.imageIndex + offset))
        if newIndex != panel.imageIndex {
            panel.imageIndex = newIndex
            updateSpatialMetadataFromSeries(panel)
            loadSingleFileForPanel(series.images[newIndex].url, panel: panel)
        }
    }

    /// Navigate panel to first or last image
    func navigatePanelToEdge(_ panel: PanelState, toFirst: Bool) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let series = allSeries[panel.seriesIndex]
        guard !series.images.isEmpty else { return }
        let newIndex = toFirst ? 0 : series.images.count - 1
        if newIndex != panel.imageIndex {
            panel.imageIndex = newIndex
            updateSpatialMetadataFromSeries(panel)
            loadSingleFileForPanel(series.images[newIndex].url, panel: panel)
            if synchronizedScrolling { syncScrollFromPanel(panel) }
        }
    }

    /// Reset view: zoom/pan to default and auto W/L
    func resetViewForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.scale = 1.0
        panel.translation = .zero
        autoWindowLevelForPanel(panel)
    }

    /// Fit image to window (reset zoom/pan only, keep W/L)
    func fitToWindowForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.scale = 1.0
        panel.translation = .zero
    }

    /// Toggle image inversion
    func invertForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.isInverted.toggle()
    }

    /// Rotate image 90° clockwise
    func rotateClockwiseForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.rotationSteps = (panel.rotationSteps + 1) % 4
    }

    /// Rotate image 90° counter-clockwise
    func rotateCounterClockwiseForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.rotationSteps = (panel.rotationSteps + 3) % 4
    }

    /// Flip image horizontally
    func flipHorizontalForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.isFlippedH.toggle()
    }

    /// Flip image vertically
    func flipVerticalForPanel(_ panel: PanelState?) {
        guard let panel = panel else { return }
        panel.isFlippedV.toggle()
    }

    // MARK: - Multi-Panel Management

    /// Initialize panels array on first use
    func ensurePanelsInitialized() {
        if panels.isEmpty {
            let panel = PanelState()
            panels = [panel]
            activePanelID = panel.id
        }
    }

    /// Reset all panels to their default state (used when loading a new directory)
    func resetAllPanels() {
        for panel in panels {
            panel.reset()
        }
    }

    /// Auto-assign series to panels (one series per panel, in order)
    func autoAssignSeriesToPanels() {
        for i in 0..<panels.count {
            guard i < allSeries.count else { break }
            // Skip panel[0] if it already has a valid series (set by fast-load path)
            if i == 0 && panels[0].seriesIndex >= 0 && panels[0].seriesIndex < allSeries.count {
                continue
            }
            assignSeriesToPanel(panels[i], seriesIndex: i)
        }
    }

    /// Set the viewer layout and resize the panels array accordingly
    func setLayout(_ newLayout: ViewerLayout) {
        let oldCount = panels.count
        let newCount = newLayout.panelCount
        layout = newLayout

        if newCount > oldCount {
            for i in oldCount..<newCount {
                let newPanel = PanelState()
                panels.append(newPanel)
                // Auto-assign series to newly created panels
                if i < allSeries.count {
                    assignSeriesToPanel(newPanel, seriesIndex: i)
                }
            }
        } else if newCount < oldCount {
            // Keep the first N panels, reset and remove the rest
            let removed = panels.suffix(from: newCount)
            for panel in removed { panel.reset() }
            panels = Array(panels.prefix(newCount))
        }

        // Ensure active panel is still valid
        if !panels.contains(where: { $0.id == activePanelID }) {
            activePanelID = panels.first?.id ?? UUID()
        }
    }

    /// One-click MPR layout: switches to 2x2 and configures panels as Axial + Sagittal + Coronal + MIP.
    /// Uses the active panel's series (or first available series) for all four panels.
    func setupMPRLayout() {
        setLayout(.quad)

        // Determine series to use (active panel's series or first available)
        let seriesIdx: Int
        if let active = activePanel, active.seriesIndex >= 0 {
            seriesIdx = active.seriesIndex
        } else if !allSeries.isEmpty {
            seriesIdx = 0
        } else {
            return
        }

        guard panels.count == 4 else { return }

        // Panel 0: Axial (standard 2D slice view)
        assignSeriesToPanel(panels[0], seriesIndex: seriesIdx)
        panels[0].panelMode = .slice2D

        // Panel 1: Sagittal MPR
        assignSeriesToPanel(panels[1], seriesIndex: seriesIdx)
        setPanelMode(panels[1], mode: .mprSagittal)

        // Panel 2: Coronal MPR
        assignSeriesToPanel(panels[2], seriesIndex: seriesIdx)
        setPanelMode(panels[2], mode: .mprCoronal)

        // Panel 3: MIP
        assignSeriesToPanel(panels[3], seriesIndex: seriesIdx)
        setPanelMode(panels[3], mode: .mip)

        // Set active panel to axial
        activePanelID = panels[0].id
        synchronizedScrolling = true
    }

    // MARK: - Panel Group Selection (simultaneous scrolling)

    /// Toggle group selection for a panel
    func toggleGroupSelection(for panel: PanelState) {
        panel.isGroupSelected.toggle()
    }

    /// Select all panels in a range (for drag-to-select across panels)
    func setGroupSelection(panelIDs: Set<UUID>) {
        for panel in panels {
            panel.isGroupSelected = panelIDs.contains(panel.id)
        }
    }

    /// Clear all group selections
    func clearGroupSelection() {
        for panel in panels {
            panel.isGroupSelected = false
        }
    }

    /// The set of panels currently group-selected
    var groupSelectedPanels: [PanelState] {
        panels.filter { $0.isGroupSelected }
    }

    /// Navigate a panel, and if it's group-selected, also scroll all other
    /// group-selected panels by the same relative offset (not spatial matching).
    func navigatePanelWithGroup(_ panel: PanelState, direction: NavigationDirection) {
        // If the panel is group-selected, scroll all group members simultaneously
        if panel.isGroupSelected {
            let groupPanels = groupSelectedPanels
            if groupPanels.count > 1 {
                for p in groupPanels {
                    navigatePanelDirect(p, direction: direction)
                }
                // Still do spatial sync for linked mode on the source panel
                if synchronizedScrolling {
                    syncScrollFromPanel(panel)
                }
                return
            }
        }
        // Not in a group — use normal navigation (which handles sync)
        navigatePanel(panel, direction: direction)
    }

    /// Navigate a single panel without triggering sync or group logic (used by group scroll)
    private func navigatePanelDirect(_ panel: PanelState, direction: NavigationDirection) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        if panel.panelMode == .mprSagittal || panel.panelMode == .mprCoronal {
            switch direction {
            case .nextImage: navigateMPRPanel(panel, delta: 1)
            case .prevImage: navigateMPRPanel(panel, delta: -1)
            default: break
            }
            if direction == .nextImage || direction == .prevImage { return }
        }

        if panel.panelMode == .mip {
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCache[seriesID] {
                switch direction {
                case .nextImage:
                    if panel.mipSlabPosition < vol.depth - 1 {
                        panel.mipSlabPosition += 1
                        loadMIPForPanel(panel)
                    }
                case .prevImage:
                    if panel.mipSlabPosition > 0 {
                        panel.mipSlabPosition -= 1
                        loadMIPForPanel(panel)
                    }
                default: break
                }
            }
            if direction == .nextImage || direction == .prevImage { return }
        }

        let currentSeries = allSeries[panel.seriesIndex]
        guard !currentSeries.images.isEmpty else { return }
        panel.imageIndex = min(panel.imageIndex, currentSeries.images.count - 1)

        switch direction {
        case .nextImage:
            if panel.imageIndex < currentSeries.images.count - 1 {
                panel.imageIndex += 1
                updateSpatialMetadataFromSeries(panel)
                loadSingleFileForPanel(currentSeries.images[panel.imageIndex].url, panel: panel)
            }
        case .prevImage:
            if panel.imageIndex > 0 {
                panel.imageIndex -= 1
                updateSpatialMetadataFromSeries(panel)
                loadSingleFileForPanel(currentSeries.images[panel.imageIndex].url, panel: panel)
            }
        case .nextSeries, .prevSeries:
            break  // Series switching not done in group scroll
        }
    }

    /// Navigate within a specific panel
    func navigatePanel(_ panel: PanelState, direction: NavigationDirection) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        // MPR mode: navigate slice index instead of image index
        if panel.panelMode == .mprSagittal || panel.panelMode == .mprCoronal {
            switch direction {
            case .nextImage: navigateMPRPanel(panel, delta: 1)
            case .prevImage: navigateMPRPanel(panel, delta: -1)
            case .nextSeries, .prevSeries: break  // Series switching still works normally
            }
            if direction == .nextSeries || direction == .prevSeries {
                // Fall through to series navigation below
            } else {
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }

        // MIP mode: scroll moves slab position through volume
        if panel.panelMode == .mip {
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCache[seriesID] {
                switch direction {
                case .nextImage:
                    if panel.mipSlabPosition < vol.depth - 1 {
                        panel.mipSlabPosition += 1
                        loadMIPForPanel(panel)
                    }
                case .prevImage:
                    if panel.mipSlabPosition > 0 {
                        panel.mipSlabPosition -= 1
                        loadMIPForPanel(panel)
                    }
                case .nextSeries, .prevSeries: break
                }
            }
            if direction == .nextSeries || direction == .prevSeries {
                // Fall through to series navigation below
            } else {
                if synchronizedScrolling { syncScrollFromPanel(panel) }
                return
            }
        }

        let currentSeries = allSeries[panel.seriesIndex]
        guard !currentSeries.images.isEmpty else { return }
        // Clamp imageIndex to valid range (may be stale after series changes)
        panel.imageIndex = min(panel.imageIndex, currentSeries.images.count - 1)

        switch direction {
        case .nextImage:
            if panel.imageIndex < currentSeries.images.count - 1 {
                panel.imageIndex += 1
                updateSpatialMetadataFromSeries(panel)
                loadSingleFileForPanel(currentSeries.images[panel.imageIndex].url, panel: panel)
                if synchronizedScrolling { syncScrollFromPanel(panel) }
            }
        case .prevImage:
            if panel.imageIndex > 0 {
                panel.imageIndex -= 1
                updateSpatialMetadataFromSeries(panel)
                loadSingleFileForPanel(currentSeries.images[panel.imageIndex].url, panel: panel)
                if synchronizedScrolling { syncScrollFromPanel(panel) }
            }
        case .nextSeries:
            if panel.seriesIndex < allSeries.count - 1 {
                panel.seriesIndex += 1
                panel.imageIndex = 0
                panel.panelMode = .slice2D
                panel.windowWidth = 0  // Reset W/L for new series
                panel.windowCenter = 0
                let series = allSeries[panel.seriesIndex]
                if let first = series.images.first {
                    loadSingleFileForPanel(first.url, panel: panel)
                }
                updatePanelInfoStrings(panel)
            }
        case .prevSeries:
            if panel.seriesIndex > 0 {
                panel.seriesIndex -= 1
                panel.imageIndex = 0
                panel.panelMode = .slice2D
                panel.windowWidth = 0  // Reset W/L for new series
                panel.windowCenter = 0
                let series = allSeries[panel.seriesIndex]
                if let first = series.images.first {
                    loadSingleFileForPanel(first.url, panel: panel)
                }
                updatePanelInfoStrings(panel)
            }
        }
    }

    /// Synchronized scrolling: when one panel scrolls, sync others to the same spatial position.
    /// Uses z-location matching when available, falls back to proportional matching.
    private func syncScrollFromPanel(_ source: PanelState) {
        guard source.seriesIndex >= 0, source.seriesIndex < allSeries.count else { return }
        let sourceSeries = allSeries[source.seriesIndex]

        // Determine the source z-location for spatial matching
        let sourceZ: Double? = {
            switch source.panelMode {
            case .slice2D:
                guard source.imageIndex >= 0, source.imageIndex < sourceSeries.images.count else { return nil }
                return sourceSeries.images[source.imageIndex].zLocation
            case .mprSagittal, .mprCoronal, .mip:
                // For MPR/MIP, use imagePositionPatient z if available
                return source.imagePositionPatient?.2
            }
        }()

        for panel in panels where panel.id != source.id {
            guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { continue }
            let targetSeries = allSeries[panel.seriesIndex]

            switch panel.panelMode {
            case .slice2D:
                guard !targetSeries.images.isEmpty else { continue }
                let targetIndex = closestImageIndex(inSeries: targetSeries, toZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                if targetIndex != panel.imageIndex {
                    panel.imageIndex = targetIndex
                    updateSpatialMetadataFromSeries(panel)
                    loadSingleFileForPanel(targetSeries.images[targetIndex].url, panel: panel)
                }
            case .mip:
                if let vol = volumeCache[targetSeries.id], vol.depth > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.depth, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mipSlabPosition {
                        panel.mipSlabPosition = targetIdx
                        loadMIPForPanel(panel)
                    }
                }
            case .mprSagittal:
                if let vol = volumeCache[targetSeries.id], vol.width > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.width, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            case .mprCoronal:
                if let vol = volumeCache[targetSeries.id], vol.height > 1 {
                    let targetIdx = closestVolumeIndex(dimension: vol.height, targetSeries: targetSeries, sourceZ: sourceZ, fallbackSource: source, sourceSeries: sourceSeries)
                    if targetIdx != panel.mprSliceIndex {
                        panel.mprSliceIndex = targetIdx
                        updateMPRSpatialMetadata(panel, volume: vol)
                        loadMPRSlice(for: panel)
                    }
                }
            }
        }
    }

    /// Synchronized zoom/pan: when one panel zooms or pans, sync others to the same transform.
    func syncZoomFromPanel(_ source: PanelState) {
        guard synchronizedScrolling else { return }
        let targetScale = source.scale
        let targetTranslation = source.translation
        for panel in panels where panel.id != source.id {
            panel.scale = targetScale
            panel.translation = targetTranslation
        }
    }

    /// Find the image index in a target series whose z-location is closest to the given z.
    /// Falls back to proportional matching if z-location data is unavailable.
    private func closestImageIndex(inSeries target: DicomSeries, toZ sourceZ: Double?, fallbackSource source: PanelState, sourceSeries: DicomSeries) -> Int {
        let targetCount = target.images.count
        guard targetCount > 0 else { return 0 }

        // Spatial matching: find closest z-location
        if let z = sourceZ {
            let zValues = target.images.map { $0.zLocation }
            if zValues.compactMap({ $0 }).count == targetCount {
                // All images have z-location — find the closest
                var bestIdx = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (i, imgZ) in zValues.enumerated() {
                    let dist = abs((imgZ ?? 0) - z)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = i
                    }
                }
                return bestIdx
            }
        }

        // Fallback: proportional matching
        let sourceTotal = sourceSeries.images.count
        guard sourceTotal > 1, targetCount > 1 else { return 0 }
        let pct = Double(source.imageIndex) / Double(sourceTotal - 1)
        return max(0, min(targetCount - 1, Int(pct * Double(targetCount - 1))))
    }

    /// Find the closest volume slice index for MPR/MIP targets using spatial or proportional matching.
    private func closestVolumeIndex(dimension: Int, targetSeries: DicomSeries, sourceZ: Double?, fallbackSource source: PanelState, sourceSeries: DicomSeries) -> Int {
        guard dimension > 1 else { return 0 }

        // Spatial matching using target series z-range
        if let z = sourceZ {
            let zValues = targetSeries.images.compactMap { $0.zLocation }
            if zValues.count >= 2 {
                let minZ = zValues.min()!
                let maxZ = zValues.max()!
                let range = maxZ - minZ
                if range > 0 {
                    let fraction = (z - minZ) / range
                    return max(0, min(dimension - 1, Int(fraction * Double(dimension - 1))))
                }
            }
        }

        // Fallback: proportional
        let sourceTotal = sourceSeries.images.count
        guard sourceTotal > 1 else { return 0 }
        let pct = Double(source.imageIndex) / Double(sourceTotal - 1)
        return max(0, min(dimension - 1, Int(pct * Double(dimension - 1))))
    }

    /// Load image into a specific panel (uses shared caches)
    func loadSingleFileForPanel(_ url: URL, panel: PanelState) {
        panel.isLoading = true
        panel.errorMessage = nil

        // Capture current W/L before background work — if the panel already has
        // user-adjusted W/L (windowWidth > 0), we preserve it when scrolling
        // within the same series.  Series changes reset windowWidth to 0 first.
        let preservedWW = panel.windowWidth
        let preservedWC = panel.windowCenter

        // Use per-panel loading queue to avoid cross-panel cancellation
        panel.loadingQueue.cancelAllOperations()

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op, weak panel] in
            guard let self = self, let op = op, !op.isCancelled, let panel = panel else { return }

            // Check cache
            if let cachedImage = self.imageCache.object(forKey: url as NSURL) {
                let cachedRaw = self.rawDataCache.object(forKey: url as NSURL) as Data?
                let cachedDCMTK = self.dcmtkCache.object(forKey: url as NSURL)

                // Retrieve cached pixel metadata
                self.imageCacheParamsLock.lock()
                let meta = self.imagePixelMeta[url as NSURL]
                self.imageCacheParamsLock.unlock()

                DispatchQueue.main.async {
                    panel.rawPixelData = cachedRaw
                    panel.dcmtkImage = cachedDCMTK  // clear stale DCMTK if not cached

                    // Restore pixel metadata from cache
                    if let meta = meta {
                        panel.imageWidth = meta.width
                        panel.imageHeight = meta.height
                        panel.bitDepth = meta.bitDepth
                        panel.samples = meta.samples
                        panel.isSigned = meta.isSigned
                        panel.isMonochrome1 = meta.isMonochrome1
                    }

                    // Re-render with user's W/L if they have adjusted it
                    if preservedWW > 0 {
                        if let dcmtk = cachedDCMTK,
                           let rerendered = dcmtk.renderImage(withWidth: 0, height: 0, ww: preservedWW, wc: preservedWC) {
                            panel.setDisplayImage(rerendered)
                        } else if let raw = cachedRaw, panel.imageWidth > 0,
                                  let rerendered = self.renderImage(width: panel.imageWidth, height: panel.imageHeight, pixelData: raw, ww: preservedWW, wc: preservedWC,
                                                                    bits: panel.bitDepth, spp: panel.samples, signed: panel.isSigned, mono1: panel.isMonochrome1) {
                            // DCMTK object was evicted by NSCache; fall back to raw data rendering
                            panel.setDisplayImage(rerendered)
                        } else {
                            panel.setDisplayImage(cachedImage)
                        }
                    } else {
                        panel.setDisplayImage(cachedImage)
                        // Set W/L from cache params so right-drag sensitivity works properly.
                        // Without this, panel.windowWidth stays at 0 and drag adjustment
                        // produces extreme jumps on MR images without DICOM W/L headers.
                        if panel.windowWidth <= 0 {
                            self.imageCacheParamsLock.lock()
                            let params = self.imageCacheParams[url as NSURL]
                            self.imageCacheParamsLock.unlock()
                            if let (cachedWW, cachedWC) = params {
                                panel.windowWidth = cachedWW
                                panel.windowCenter = cachedWC
                            }
                        }
                    }

                    // Update spatial metadata for cross-reference lines
                    if panel.seriesIndex >= 0 && panel.seriesIndex < self.allSeries.count {
                        let ctx = self.allSeries[panel.seriesIndex].images[safe: panel.imageIndex]
                        if let pos = ctx?.imagePosition {
                            panel.imagePositionPatient = (pos.x, pos.y, pos.z)
                        }
                        panel.imageOrientationPatient = ctx?.imageOrientation
                        if let ps = ctx?.pixelSpacing {
                            panel.pixelSpacing = (ps.x, ps.y)
                        }
                    }

                    // Compute histogram (was missing for cache-hit path)
                    if let raw = cachedRaw, let meta = meta {
                        self.computeHistogramForPanel(data: raw, isSigned: meta.isSigned, bits: meta.bitDepth, panel: panel)
                    }

                    panel.isLoading = false
                    self.objectWillChange.send()
                    self.updatePanelInfoStrings(panel)
                }
                return
            }

            // Parse DICOM metadata
            do {
                let data = try Data(contentsOf: url)
                let parser = SimpleDicomParser(data: data)
                let (elements, _, _) = try parser.parse()
                DispatchQueue.main.async {
                    panel.tags = elements
                }
            } catch {
                print("Panel metadata parse error: \(error)")
            }

            // Decode via DCMTK
            let dcmObj = DCMTKImageObject(path: url.path)

            if let dcmObj = dcmObj {
                var width: Int = 0, height: Int = 0, depth: Int = 0, samples: Int = 0
                var isSigned: ObjCBool = false

                guard let rawData = dcmObj.getRawDataWidth(&width, height: &height, bitDepth: &depth, samples: &samples, isSigned: &isSigned) else {
                    DispatchQueue.main.async {
                        panel.errorMessage = "Failed to get raw data"
                        panel.isLoading = false
                    }
                    return
                }

                var ww = dcmObj.getWindowWidth()
                var wc = dcmObj.getWindowCenter()
                if ww <= 0 {
                    let (minVal, maxVal) = self.computeMinMax(data: rawData as Data, isSigned: isSigned.boolValue, bits: depth)
                    ww = maxVal - minVal
                    wc = minVal + (ww / 2.0)
                }

                if let nsImage = dcmObj.renderImage(withWidth: 0, height: 0, ww: ww, wc: wc) {
                    self.imageCache.setObject(nsImage, forKey: url as NSURL)
                    self.dcmtkCache.setObject(dcmObj, forKey: url as NSURL)
                    self.imageCacheParamsLock.lock()
                    self.imageCacheParams[url as NSURL] = (ww, wc)
                    self.imagePixelMeta[url as NSURL] = PixelMeta(width: width, height: height, bitDepth: depth, samples: samples, isSigned: isSigned.boolValue, isMonochrome1: false)
                    self.imageCacheParamsLock.unlock()
                    self.rawDataCache.setObject(rawData as NSData, forKey: url as NSURL)

                    DispatchQueue.main.async {
                        panel.dcmtkImage = dcmObj
                        panel.rawPixelData = rawData
                        panel.imageWidth = width
                        panel.imageHeight = height
                        panel.bitDepth = depth
                        panel.samples = samples
                        panel.isSigned = isSigned.boolValue

                        // Preserve user W/L when scrolling within same series
                        if preservedWW > 0 {
                            panel.windowWidth = preservedWW
                            panel.windowCenter = preservedWC
                            if let rerendered = dcmObj.renderImage(withWidth: 0, height: 0, ww: preservedWW, wc: preservedWC) {
                                panel.setDisplayImage(rerendered)
                            } else {
                                panel.setDisplayImage(nsImage)
                            }
                        } else {
                            panel.setDisplayImage(nsImage)
                            panel.windowWidth = ww
                            panel.windowCenter = wc
                        }

                        // Spatial metadata from current image
                        if panel.seriesIndex >= 0 && panel.seriesIndex < self.allSeries.count {
                            let ctx = self.allSeries[panel.seriesIndex].images[safe: panel.imageIndex]
                            if let pos = ctx?.imagePosition {
                                panel.imagePositionPatient = (pos.x, pos.y, pos.z)
                            }
                            panel.imageOrientationPatient = ctx?.imageOrientation
                            if let ps = ctx?.pixelSpacing {
                                panel.pixelSpacing = (ps.x, ps.y)
                            }
                        }

                        self.computeHistogramForPanel(data: rawData, isSigned: isSigned.boolValue, bits: depth, panel: panel)
                        panel.isLoading = false
                        // Trigger cross-reference overlay updates on other panels
                        self.objectWillChange.send()
                        self.updatePanelInfoStrings(panel)
                    }
                } else {
                    DispatchQueue.main.async {
                        panel.errorMessage = "Failed to render image"
                        panel.isLoading = false
                    }
                }
            } else {
                // Try JPEG2000 fallback
                var j2kW: Int = 0, j2kH: Int = 0, j2kD: Int = 0, j2kS: Int = 0
                var j2kSigned: ObjCBool = false
                if let j2kData = DCMTKHelper.decodeJPEG2000DICOM(url.path, width: &j2kW, height: &j2kH, bitDepth: &j2kD, samples: &j2kS, isSigned: &j2kSigned) {
                    let (minVal, maxVal) = self.computeMinMax(data: j2kData, isSigned: j2kSigned.boolValue, bits: j2kD)
                    let autoWW = maxVal - minVal
                    let autoWC = minVal + (autoWW / 2.0)
                    self.rawDataCache.setObject(j2kData as NSData, forKey: url as NSURL)
                    self.imageCacheParamsLock.lock()
                    self.imagePixelMeta[url as NSURL] = PixelMeta(width: j2kW, height: j2kH, bitDepth: j2kD, samples: j2kS, isSigned: j2kSigned.boolValue, isMonochrome1: false)
                    self.imageCacheParamsLock.unlock()

                    DispatchQueue.main.async {
                        panel.dcmtkImage = nil  // DCMTK failed; clear stale object
                        panel.rawPixelData = j2kData
                        panel.imageWidth = j2kW
                        panel.imageHeight = j2kH
                        panel.bitDepth = j2kD
                        panel.samples = j2kS
                        panel.isSigned = j2kSigned.boolValue

                        // Preserve user W/L when scrolling within same series
                        let renderWW = preservedWW > 0 ? preservedWW : autoWW
                        let renderWC = preservedWW > 0 ? preservedWC : autoWC
                        panel.windowWidth = renderWW
                        panel.windowCenter = renderWC

                        if let rendered = self.renderImage(width: j2kW, height: j2kH, pixelData: j2kData, ww: renderWW, wc: renderWC,
                                                           bits: j2kD, spp: j2kS, signed: j2kSigned.boolValue, mono1: false) {
                            panel.setDisplayImage(rendered)
                            if preservedWW <= 0 {
                                self.imageCache.setObject(rendered, forKey: url as NSURL)
                            }
                        }
                        // Update spatial metadata for cross-reference lines
                        if panel.seriesIndex >= 0 && panel.seriesIndex < self.allSeries.count {
                            let ctx = self.allSeries[panel.seriesIndex].images[safe: panel.imageIndex]
                            if let pos = ctx?.imagePosition {
                                panel.imagePositionPatient = (pos.x, pos.y, pos.z)
                            }
                            panel.imageOrientationPatient = ctx?.imageOrientation
                            if let ps = ctx?.pixelSpacing {
                                panel.pixelSpacing = (ps.x, ps.y)
                            }
                        }

                        self.computeHistogramForPanel(data: j2kData, isSigned: j2kSigned.boolValue, bits: j2kD, panel: panel)
                        panel.isLoading = false
                        self.updatePanelInfoStrings(panel)
                    }
                } else {
                    // Fallback: try reading raw uncompressed pixel data via SimpleDicomParser
                    // This handles uncompressed RGB (e.g. Secondary Capture) that DCMTK fails on
                    if let rawResult = self.extractRawPixelData(from: url) {
                        let rawW = rawResult.width
                        let rawH = rawResult.height
                        let rawD = rawResult.bitDepth
                        let rawS = rawResult.samples
                        let rawSigned = rawResult.isSigned
                        let rawMono1 = rawResult.isMonochrome1
                        let rawData = rawResult.pixelData

                        let (minVal, maxVal) = self.computeMinMax(data: rawData, isSigned: rawSigned, bits: rawD)
                        let autoWW = maxVal - minVal
                        let autoWC = minVal + (autoWW / 2.0)
                        self.rawDataCache.setObject(rawData as NSData, forKey: url as NSURL)
                        self.imageCacheParamsLock.lock()
                        self.imagePixelMeta[url as NSURL] = PixelMeta(width: rawW, height: rawH, bitDepth: rawD, samples: rawS, isSigned: rawSigned, isMonochrome1: rawMono1)
                        self.imageCacheParamsLock.unlock()

                        DispatchQueue.main.async {
                            panel.dcmtkImage = nil  // DCMTK failed; clear stale object
                            panel.rawPixelData = rawData
                            panel.imageWidth = rawW
                            panel.imageHeight = rawH
                            panel.bitDepth = rawD
                            panel.samples = rawS
                            panel.isSigned = rawSigned
                            panel.isMonochrome1 = rawMono1

                            let renderWW = preservedWW > 0 ? preservedWW : autoWW
                            let renderWC = preservedWW > 0 ? preservedWC : autoWC
                            panel.windowWidth = renderWW
                            panel.windowCenter = renderWC

                            if let rendered = self.renderImage(width: rawW, height: rawH, pixelData: rawData, ww: renderWW, wc: renderWC,
                                                               bits: rawD, spp: rawS, signed: rawSigned, mono1: rawMono1) {
                                panel.setDisplayImage(rendered)
                                if preservedWW <= 0 {
                                    self.imageCache.setObject(rendered, forKey: url as NSURL)
                                }
                            }

                            if panel.seriesIndex >= 0 && panel.seriesIndex < self.allSeries.count {
                                let ctx = self.allSeries[panel.seriesIndex].images[safe: panel.imageIndex]
                                if let pos = ctx?.imagePosition {
                                    panel.imagePositionPatient = (pos.x, pos.y, pos.z)
                                }
                                panel.imageOrientationPatient = ctx?.imageOrientation
                                if let ps = ctx?.pixelSpacing {
                                    panel.pixelSpacing = (ps.x, ps.y)
                                }
                            }

                            self.computeHistogramForPanel(data: rawData, isSigned: rawSigned, bits: rawD, panel: panel)
                            panel.isLoading = false
                            self.updatePanelInfoStrings(panel)
                        }
                    } else {
                        let errorDetail = DCMTKHelper.lastError(forPath: url.path) ?? "Unknown error"
                        DispatchQueue.main.async {
                            panel.errorMessage = "Failed to load: \(errorDetail)"
                            panel.isLoading = false
                        }
                    }
                }
            }
        }
        panel.loadingQueue.addOperation(op)
    }

    /// Adjust W/L for a specific panel
    func adjustWindowLevelForPanel(_ panel: PanelState, deltaWidth: Double, deltaCenter: Double) {
        panel.windowWidth = max(1.0, panel.windowWidth + deltaWidth)
        panel.windowCenter += deltaCenter

        // Persist to seriesStates so precaching & other images use the same W/L
        if panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count {
            let uid = allSeries[panel.seriesIndex].id
            var state = seriesStates[uid] ?? SeriesViewState()
            state.windowWidth = panel.windowWidth
            state.windowCenter = panel.windowCenter
            seriesStates[uid] = state
        }

        switch panel.panelMode {
        case .slice2D:
            if let dcmObj = panel.dcmtkImage {
                if let newImg = dcmObj.renderImage(withWidth: 0, height: 0, ww: panel.windowWidth, wc: panel.windowCenter) {
                    panel.setDisplayImage(newImg)
                }
            } else if let data = panel.rawPixelData {
                if let newImg = renderImage(width: panel.imageWidth, height: panel.imageHeight, pixelData: data, ww: panel.windowWidth, wc: panel.windowCenter,
                                            bits: panel.bitDepth, spp: panel.samples, signed: panel.isSigned, mono1: panel.isMonochrome1) {
                    panel.setDisplayImage(newImg)
                }
            }
        case .mprSagittal, .mprCoronal, .mip:
            // Re-render MPR/MIP slice with updated W/L
            // panel.pixelSpacing stores (row_spacing, col_spacing) per DICOM convention,
            // but MPRSlice expects (horizontal=X, vertical=Y), so swap .0↔.1
            if let data = panel.rawPixelData {
                let slice = MPRSlice(
                    pixelData: data, width: panel.imageWidth, height: panel.imageHeight,
                    planeOrigin: .zero,
                    planeRowDir: SIMD3<Double>(1, 0, 0),
                    planeColDir: SIMD3<Double>(0, 1, 0),
                    pixelSpacingX: panel.pixelSpacing?.1 ?? 1,
                    pixelSpacingY: panel.pixelSpacing?.0 ?? 1
                )
                if let newImg = MPREngine.renderSlice(slice, ww: panel.windowWidth, wc: panel.windowCenter, invert: panel.isInverted) {
                    panel.setDisplayImage(newImg)
                }
            }
        }
    }

    /// Auto W/L for a specific panel
    func autoWindowLevelForPanel(_ panel: PanelState) {
        if let data = panel.rawPixelData {
            let (minVal, maxVal) = computeMinMax(data: data, isSigned: panel.isSigned, bits: panel.bitDepth)
            let newWW = maxVal - minVal
            let newWC = minVal + (newWW / 2.0)
            adjustWindowLevelForPanel(panel, deltaWidth: newWW - panel.windowWidth, deltaCenter: newWC - panel.windowCenter)
        }
    }

    /// Compute min/max pixel values within a rectangular subregion of the image data.
    private func computeMinMaxInRect(data: Data, width: Int, rect: CGRect, isSigned: Bool, bits: Int) -> (Double, Double) {
        guard width > 0 else { return (0, 0) }
        var minVal: Double = Double.greatestFiniteMagnitude
        var maxVal: Double = -Double.greatestFiniteMagnitude

        let startCol = max(0, Int(rect.minX))
        let endCol = min(width, Int(ceil(rect.maxX)))
        let startRow = max(0, Int(rect.minY))
        guard endCol > startCol else { return (0, 0) }

        if bits > 16 { // 32-bit
            let bytesPerPixel = 4
            let totalPixels = data.count / bytesPerPixel
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v: Double = isSigned ? Double(Int32(bitPattern: ptr[i])) : Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        } else if bits > 8 { // 16-bit
            let bytesPerPixel = 2
            let totalPixels = data.count / bytesPerPixel
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v: Double = isSigned ? Double(Int16(bitPattern: ptr[i])) : Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        } else { // 8-bit
            let totalPixels = data.count
            let height = totalPixels / max(1, width)
            let endRow = min(height, Int(ceil(rect.maxY)))
            guard endRow > startRow else { return (0, 0) }
            data.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for row in startRow..<endRow {
                    for col in startCol..<endCol {
                        let i = row * width + col
                        guard i >= 0, i < totalPixels else { continue }
                        let v = Double(ptr[i])
                        if v < minVal { minVal = v }
                        if v > maxVal { maxVal = v }
                    }
                }
            }
        }

        if minVal > maxVal { return (0, 0) }
        return (minVal, maxVal)
    }

    /// Auto W/L from a rectangular ROI in pixel coordinates
    func autoWindowLevelForPanelROI(_ panel: PanelState, rect: CGRect) {
        guard let data = panel.rawPixelData, panel.imageWidth > 0 else { return }
        let (minVal, maxVal) = computeMinMaxInRect(data: data, width: panel.imageWidth, rect: rect, isSigned: panel.isSigned, bits: panel.bitDepth)
        let newWW = max(1.0, maxVal - minVal)
        let newWC = minVal + (newWW / 2.0)
        adjustWindowLevelForPanel(panel, deltaWidth: newWW - panel.windowWidth, deltaCenter: newWC - panel.windowCenter)
    }

    /// Compute HU statistics for a pixel-coordinate rectangle on a panel
    func computeROIStats(panel: PanelState, rect: CGRect) -> (mean: Double, max: Double, min: Double, stdDev: Double, count: Int)? {
        guard let data = panel.rawPixelData else { return nil }
        let w = panel.imageWidth
        let h = panel.imageHeight
        let minX = max(0, Int(rect.minX))
        let minY = max(0, Int(rect.minY))
        let maxX = min(w - 1, Int(rect.maxX))
        let maxY = min(h - 1, Int(rect.maxY))
        guard maxX > minX, maxY > minY else { return nil }

        var values: [Double] = []
        values.reserveCapacity((maxX - minX) * (maxY - minY))

        data.withUnsafeBytes { raw in
            for py in minY...maxY {
                for px in minX...maxX {
                    let index = py * w + px
                    var val: Double = 0
                    if panel.bitDepth > 8 {
                        let byteIndex = index * 2
                        if byteIndex + 1 < data.count {
                            if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                                if panel.isSigned {
                                    val = Double(Int16(bitPattern: ptr[index]))
                                } else {
                                    val = Double(ptr[index])
                                }
                            }
                        }
                    } else if index < data.count {
                        val = Double(raw[index])
                    }
                    values.append(val)
                }
            }
        }

        guard !values.isEmpty else { return nil }
        let count = values.count
        let sum = values.reduce(0, +)
        let mean = sum / Double(count)
        let maxVal = values.max() ?? 0
        let minVal = values.min() ?? 0
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        let stdDev = sqrt(variance)

        return (mean: mean, max: maxVal, min: minVal, stdDev: stdDev, count: count)
    }

    /// Save view state (zoom/pan) for a panel
    func saveViewStateForPanel(_ panel: PanelState, scale: CGFloat, translation: CGPoint) {
        panel.scale = scale
        panel.translation = translation
    }

    /// Get cached image for a panel's series at a given index (for thumbnail preview)
    func getCachedImageForPanel(_ panel: PanelState, at index: Int) -> NSImage? {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return nil }
        let images = allSeries[panel.seriesIndex].images
        guard index >= 0, index < images.count else { return nil }
        let url = images[index].url

        // Determine target W/L: use panel's current W/L so thumbnails match the active view
        let panelWW = panel.windowWidth
        let panelWC = panel.windowCenter
        let hasUserWL = panelWW > 0

        // Try DCMTK object cache first — best quality, can render with panel's W/L
        if hasUserWL, let dcmtk = dcmtkCache.object(forKey: url as NSURL) {
            if let rendered = dcmtk.renderImage(withWidth: 0, height: 0, ww: panelWW, wc: panelWC) {
                return rendered
            }
        }

        // Try raw data cache — can render with panel's W/L
        if hasUserWL, let raw = rawDataCache.object(forKey: url as NSURL) as Data? {
            let w = panel.imageWidth > 0 ? panel.imageWidth : 512
            let h = panel.imageHeight > 0 ? panel.imageHeight : 512
            if let rendered = renderImage(width: w, height: h, pixelData: raw, ww: panelWW, wc: panelWC,
                                          bits: panel.bitDepth, spp: panel.samples, signed: panel.isSigned, mono1: panel.isMonochrome1) {
                return rendered
            }
        }

        // No user W/L set — check if pre-rendered cache matches or use it as-is
        if let cached = imageCache.object(forKey: url as NSURL) {
            if !hasUserWL {
                return cached
            }
            // User has W/L but we couldn't re-render above (both dcmtk and raw evicted);
            // return stale image rather than nothing
            return cached
        }

        // Last resort: DCMTK with stored or default W/L
        if let dcmtk = dcmtkCache.object(forKey: url as NSURL) {
            imageCacheParamsLock.lock()
            let params = imageCacheParams[url as NSURL]
            imageCacheParamsLock.unlock()
            let ww = params?.0 ?? 400
            let wc = params?.1 ?? 200
            return dcmtk.renderImage(withWidth: 0, height: 0, ww: ww, wc: wc)
        }

        return nil
    }

    /// Update info strings for a specific panel
    func updatePanelInfoStrings(_ panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else {
            panel.currentSeriesInfo = ""
            panel.currentImageInfo = ""
            return
        }
        let s = allSeries[panel.seriesIndex]
        panel.currentSeriesInfo = "Series \(panel.seriesIndex + 1)/\(allSeries.count)"

        switch panel.panelMode {
        case .slice2D:
            if panel.imageIndex >= 0, panel.imageIndex < s.images.count {
                let img = s.images[panel.imageIndex]
                panel.currentImageInfo = "Image \(img.instanceNumber) (\(panel.imageIndex + 1)/\(s.images.count))"
            }
        case .mprSagittal:
            if let vol = volumeCache[s.id] {
                panel.currentImageInfo = "Sagittal \(panel.mprSliceIndex + 1)/\(vol.width)"
            }
        case .mprCoronal:
            if let vol = volumeCache[s.id] {
                panel.currentImageInfo = "Coronal \(panel.mprSliceIndex + 1)/\(vol.height)"
            }
        case .mip:
            if let vol = volumeCache[s.id] {
                let halfSlab = panel.mipSlabThickness / 2
                let zStart = max(0, panel.mipSlabPosition - halfSlab) + 1
                let zEnd = min(vol.depth, panel.mipSlabPosition + halfSlab)
                panel.currentImageInfo = "MIP \(zStart)-\(zEnd)/\(vol.depth) (\(panel.mipSlabThickness) slices)"
            } else {
                panel.currentImageInfo = "MIP"
            }
        }
    }

    /// Get total slice count for current panel mode (for scroller)
    func totalSliceCount(for panel: PanelState) -> Int {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return 0 }
        let s = allSeries[panel.seriesIndex]
        switch panel.panelMode {
        case .slice2D:
            return s.images.count
        case .mprSagittal:
            return volumeCache[s.id]?.width ?? 0
        case .mprCoronal:
            return volumeCache[s.id]?.height ?? 0
        case .mip:
            guard let seriesID = allSeries[safe: panel.seriesIndex]?.id else { return 0 }
            return volumeCache[seriesID]?.depth ?? 0
        }
    }

    /// Get current slice index for panel mode (for scroller)
    func currentSliceIndex(for panel: PanelState) -> Int {
        switch panel.panelMode {
        case .slice2D:
            return panel.imageIndex
        case .mprSagittal, .mprCoronal:
            return panel.mprSliceIndex
        case .mip:
            return panel.mipSlabPosition
        }
    }

    /// Navigate to a specific slice index in any mode (for scroller drag)
    func navigatePanelToSlice(_ panel: PanelState, index: Int) {
        switch panel.panelMode {
        case .slice2D:
            guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
            let series = allSeries[panel.seriesIndex]
            let idx = max(0, min(index, series.images.count - 1))
            if idx != panel.imageIndex {
                panel.imageIndex = idx
                updateSpatialMetadataFromSeries(panel)
                loadSingleFileForPanel(series.images[idx].url, panel: panel)
            }
        case .mprSagittal, .mprCoronal:
            let total = totalSliceCount(for: panel)
            let idx = max(0, min(index, total - 1))
            if idx != panel.mprSliceIndex {
                panel.mprSliceIndex = idx
                if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
                   let vol = volumeCache[seriesID] {
                    updateMPRSpatialMetadata(panel, volume: vol)
                }
                loadMPRSlice(for: panel)
            }
        case .mip:
            guard let seriesID = allSeries[safe: panel.seriesIndex]?.id,
                  let vol = volumeCache[seriesID] else { return }
            let idx = max(0, min(index, vol.depth - 1))
            if idx != panel.mipSlabPosition {
                panel.mipSlabPosition = idx
                loadMIPForPanel(panel)
            }
        }
        if synchronizedScrolling { syncScrollFromPanel(panel) }
    }

    /// Compute histogram for a panel
    private func computeHistogramForPanel(data: Data, isSigned: Bool, bits: Int, panel: PanelState) {
        // Skip histogram for RGB images — W/L doesn't apply
        if panel.samples == 3 {
            DispatchQueue.main.async { panel.histogramData = [] }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak panel] in
            guard let panel = panel else { return }
            var bins = [Int](repeating: 0, count: 256)
            let (minVal, maxVal) = self.computeMinMax(data: data, isSigned: isSigned, bits: bits)
            let range = maxVal - minVal
            if range <= 0 { return }

            if bits > 8 {
                data.withUnsafeBytes { rawBuffer in
                    if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                        let count = data.count / 2
                        let stride = max(1, count / 50000)
                        var i = 0
                        while i < count {
                            var v: Double
                            if isSigned { v = Double(Int16(bitPattern: ptr[i])) }
                            else { v = Double(ptr[i]) }
                            let bin = Int((v - minVal) / range * 255.0)
                            if bin >= 0 && bin < 256 { bins[bin] += 1 }
                            i += stride
                        }
                    }
                }
            } else {
                data.withUnsafeBytes { rawBuffer in
                    if let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        let count = data.count
                        let stride = max(1, count / 50000)
                        var i = 0
                        while i < count {
                            let v = Double(ptr[i])
                            let bin = Int((v - minVal) / range * 255.0)
                            if bin >= 0 && bin < 256 { bins[bin] += 1 }
                            i += stride
                        }
                    }
                }
            }

            // Use log scale so the dominant bin (e.g. air in CT) doesn't flatten everything else
            let logBins = bins.map { log(1.0 + Double($0)) }
            let maxLog = logBins.max() ?? 1.0
            let normalized = maxLog > 0 ? logBins.map { $0 / maxLog } : logBins

            DispatchQueue.main.async {
                panel.histogramData = normalized
                panel.minPixelValue = minVal
                panel.maxPixelValue = maxVal
            }
        }
    }

    /// Check if a series can form a 3D volume (enough slices with consistent orientation and varying Z positions)
    func isSeriesVolumetric(seriesIndex: Int) -> Bool {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return false }
        let series = allSeries[seriesIndex]

        // Need at least 10 images
        guard series.images.count >= 10 else { return false }

        // All images must have consistent ImageOrientationPatient
        guard let refOrientation = series.images.first?.imageOrientation,
              refOrientation.count == 6 else { return false }

        var zValues = Set<Double>()
        for img in series.images {
            guard let orient = img.imageOrientation, orient.count == 6 else { return false }
            // Check orientation consistency (tolerance for floating point)
            let orientMatch = zip(refOrientation, orient).allSatisfy { abs($0 - $1) < 0.01 }
            if !orientMatch { return false }

            if let pos = img.imagePosition {
                // Round to 0.1mm to avoid floating-point duplicates
                zValues.insert((pos.z * 10).rounded() / 10)
            }
        }

        // Need varying Z positions (at least 10 distinct values)
        return zValues.count >= 10
    }

    /// Total slice count of the cached volume (for slab thickness slider max)
    func volumeSliceCount(seriesIndex: Int) -> Int {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else { return 1 }
        let seriesID = allSeries[seriesIndex].id
        return volumeCache[seriesID]?.depth ?? 1
    }

    // MARK: - Volume Building & MPR

    /// Get or build a volume for the given series (returns cached if available)
    func getVolume(for seriesIndex: Int, completion: @escaping (VolumeData?, String?) -> Void) {
        guard seriesIndex >= 0, seriesIndex < allSeries.count else {
            completion(nil, nil)
            return
        }
        let series = allSeries[seriesIndex]

        // Return cached volume
        if let cached = volumeCache[series.id] {
            completion(cached, nil)
            return
        }

        // Build in background
        isVolumeBuildingInProgress = true
        volumeBuildProgress = 0.0

        volumeBuildQueue.addOperation { [weak self] in
            guard let self = self else { return }

            do {
                let volume = try VolumeBuilder.build(
                    series: series,
                    rawDataCache: self.rawDataCache,
                    dcmtkCache: self.dcmtkCache,
                    progress: { pct in
                        DispatchQueue.main.async {
                            self.volumeBuildProgress = pct
                        }
                    }
                )

                DispatchQueue.main.async {
                    self.volumeCache[series.id] = volume
                    self.isVolumeBuildingInProgress = false
                    self.volumeBuildProgress = 1.0
                    completion(volume, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isVolumeBuildingInProgress = false
                    let msg = "\(error)"
                    print("Volume build error: \(msg)")
                    completion(nil, msg)
                }
            }
        }
    }

    /// Load an MPR slice for a panel (sagittal or coronal reformat)
    func loadMPRSlice(for panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        panel.isLoading = true
        panel.errorMessage = nil

        getVolume(for: panel.seriesIndex) { [weak self, weak panel] volume, errorMsg in
            guard let self = self, let panel = panel else { return }

            guard let volume = volume else {
                panel.isLoading = false
                if self.isScanning {
                    panel.errorMessage = "Volume build failed — directory is still scanning. Please wait for scanning to complete and try again."
                } else {
                    panel.errorMessage = "Volume build failed — \(errorMsg ?? "unknown error")"
                }
                return
            }

            let engine = MPREngine(volume: volume)
            var slice: MPRSlice?

            switch panel.panelMode {
            case .mprSagittal:
                // Initialize slice index to center if not yet set
                if panel.mprSliceIndex <= 0 || panel.mprSliceIndex >= volume.width {
                    panel.mprSliceIndex = volume.width / 2
                }
                let maxIndex = volume.width - 1
                let idx = min(max(0, panel.mprSliceIndex), maxIndex)
                slice = engine.sagittalSlice(at: idx)

            case .mprCoronal:
                // Initialize slice index to center if not yet set
                if panel.mprSliceIndex <= 0 || panel.mprSliceIndex >= volume.height {
                    panel.mprSliceIndex = volume.height / 2
                }
                let maxIndex = volume.height - 1
                let idx = min(max(0, panel.mprSliceIndex), maxIndex)
                slice = engine.coronalSlice(at: idx)

            default:
                panel.isLoading = false
                return
            }

            guard let mprSlice = slice else {
                panel.isLoading = false
                panel.errorMessage = "MPR slice extraction failed"
                return
            }

            // Use panel's W/L, fall back to initial values from 2D slice, then hardcoded defaults
            let ww = panel.windowWidth > 0 ? panel.windowWidth : (panel.initialWindowWidth > 0 ? panel.initialWindowWidth : 2000)
            let wc = (panel.windowWidth > 0) ? panel.windowCenter : (panel.initialWindowWidth > 0 ? panel.initialWindowCenter : 500)

            if let image = MPREngine.renderSlice(mprSlice, ww: ww, wc: wc, invert: panel.isInverted) {
                panel.setDisplayImage(image)
                panel.imageWidth = mprSlice.width
                panel.imageHeight = mprSlice.height
                panel.rawPixelData = mprSlice.pixelData
                panel.bitDepth = 16
                panel.isSigned = true
                panel.samples = 1

                // Set spatial metadata for cross-reference lines.
                // MPR slices flip Z (superior at top), so adjust origin and column direction.
                switch panel.panelMode {
                case .mprSagittal:
                    let flippedOrigin = volume.voxelToWorld(SIMD3<Double>(Double(panel.mprSliceIndex), 0, Double(volume.depth - 1)))
                    panel.imagePositionPatient = (flippedOrigin.x, flippedOrigin.y, flippedOrigin.z)
                    panel.imageOrientationPatient = [
                        volume.colDirection.x, volume.colDirection.y, volume.colDirection.z,
                        -volume.sliceDirection.x, -volume.sliceDirection.y, -volume.sliceDirection.z
                    ]
                    panel.pixelSpacing = (volume.spacingZ, volume.spacingY)
                case .mprCoronal:
                    let flippedOrigin = volume.voxelToWorld(SIMD3<Double>(0, Double(panel.mprSliceIndex), Double(volume.depth - 1)))
                    panel.imagePositionPatient = (flippedOrigin.x, flippedOrigin.y, flippedOrigin.z)
                    panel.imageOrientationPatient = [
                        volume.rowDirection.x, volume.rowDirection.y, volume.rowDirection.z,
                        -volume.sliceDirection.x, -volume.sliceDirection.y, -volume.sliceDirection.z
                    ]
                    panel.pixelSpacing = (volume.spacingZ, volume.spacingX)
                default:
                    break
                }

                panel.isLoading = false
                // Trigger cross-reference overlay updates on all panels
                self.objectWillChange.send()
                self.updatePanelInfoStrings(panel)
            } else {
                panel.isLoading = false
                panel.errorMessage = "MPR rendering failed"
            }
        }
    }

    /// Update spatial metadata synchronously from series image data (for cross-reference lines).
    /// Called immediately when imageIndex changes, before async image loading,
    /// so cross-reference overlays update without waiting for the loading queue.
    private func updateSpatialMetadataFromSeries(_ panel: PanelState) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        let images = allSeries[panel.seriesIndex].images
        guard panel.imageIndex >= 0, panel.imageIndex < images.count else { return }
        let img = images[panel.imageIndex]
        if let pos = img.imagePosition {
            panel.imagePositionPatient = (pos.x, pos.y, pos.z)
        }
        panel.imageOrientationPatient = img.imageOrientation
        if let ps = img.pixelSpacing {
            panel.pixelSpacing = (ps.x, ps.y)
        }
    }

    /// Update spatial metadata synchronously for MPR panels (for cross-reference lines).
    /// Called immediately when mprSliceIndex changes, before async MPR rendering.
    private func updateMPRSpatialMetadata(_ panel: PanelState, volume: VolumeData) {
        switch panel.panelMode {
        case .mprSagittal:
            let origin = volume.voxelToWorld(SIMD3<Double>(Double(panel.mprSliceIndex), 0, Double(volume.depth - 1)))
            panel.imagePositionPatient = (origin.x, origin.y, origin.z)
            panel.imageOrientationPatient = [
                volume.colDirection.x, volume.colDirection.y, volume.colDirection.z,
                -volume.sliceDirection.x, -volume.sliceDirection.y, -volume.sliceDirection.z
            ]
            panel.pixelSpacing = (volume.spacingZ, volume.spacingY)
        case .mprCoronal:
            let origin = volume.voxelToWorld(SIMD3<Double>(0, Double(panel.mprSliceIndex), Double(volume.depth - 1)))
            panel.imagePositionPatient = (origin.x, origin.y, origin.z)
            panel.imageOrientationPatient = [
                volume.rowDirection.x, volume.rowDirection.y, volume.rowDirection.z,
                -volume.sliceDirection.x, -volume.sliceDirection.y, -volume.sliceDirection.z
            ]
            panel.pixelSpacing = (volume.spacingZ, volume.spacingX)
        default:
            break
        }
    }

    /// Navigate MPR slice position for a panel
    func navigateMPRPanel(_ panel: PanelState, delta: Int) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }

        let series = allSeries[panel.seriesIndex]
        if let volume = volumeCache[series.id] {
            let maxIndex: Int
            switch panel.panelMode {
            case .mprSagittal: maxIndex = volume.width - 1
            case .mprCoronal: maxIndex = volume.height - 1
            default: return
            }

            let newIndex = min(max(0, panel.mprSliceIndex + delta), maxIndex)
            if newIndex != panel.mprSliceIndex {
                panel.mprSliceIndex = newIndex
                updateMPRSpatialMetadata(panel, volume: volume)
                loadMPRSlice(for: panel)
            }
        }
    }

    /// Switch a panel's display mode (slice2D / sagittal / coronal / MIP)
    func setPanelMode(_ panel: PanelState, mode: PanelMode) {
        panel.panelMode = mode

        // Cancel any pending 2D loads to prevent them from overwriting MPR/MIP panel state
        panel.loadingQueue.cancelAllOperations()

        switch mode {
        case .slice2D:
            // Reload current 2D slice
            if panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count {
                let series = allSeries[panel.seriesIndex]
                let idx = max(0, min(panel.imageIndex, series.images.count - 1))
                panel.imageIndex = idx
                if idx < series.images.count {
                    loadSingleFileForPanel(series.images[idx].url, panel: panel)
                }
            }

        case .mprSagittal:
            panel.mprSliceIndex = 0  // Reset; loadMPRSlice will center after volume is ready
            loadMPRSlice(for: panel)

        case .mprCoronal:
            panel.mprSliceIndex = 0  // Reset; loadMPRSlice will center after volume is ready
            loadMPRSlice(for: panel)

        case .mip:
            if let seriesID = allSeries[safe: panel.seriesIndex]?.id,
               let vol = volumeCache[seriesID] {
                panel.mipSlabPosition = vol.depth / 2
                panel.mipSlabThickness = min(10, vol.depth)
            }
            loadMIPForPanel(panel)
        }
    }

    /// Generate a clinical axial slab-MIP for a panel.
    /// Projects N consecutive axial slices via max intensity, scroll moves the slab.
    func loadMIPForPanel(_ panel: PanelState, mode: ProjectionMode = .mip) {
        guard panel.seriesIndex >= 0, panel.seriesIndex < allSeries.count else { return }
        panel.isLoading = true
        panel.errorMessage = nil

        getVolume(for: panel.seriesIndex) { [weak self, weak panel] volume, errorMsg in
            guard let self = self, let panel = panel else { return }

            guard let volume = volume else {
                panel.isLoading = false
                if self.isScanning {
                    panel.errorMessage = "Volume build failed — directory is still scanning. Please wait for scanning to complete and try again."
                } else {
                    panel.errorMessage = "Volume build failed — \(errorMsg ?? "unknown error")"
                }
                return
            }

            // Initialize slab position to center if not set
            if panel.mipSlabPosition <= 0 || panel.mipSlabPosition >= volume.depth {
                panel.mipSlabPosition = volume.depth / 2
            }

            // Clamp slab thickness
            if panel.mipSlabThickness < 1 { panel.mipSlabThickness = 10 }
            if panel.mipSlabThickness > volume.depth { panel.mipSlabThickness = volume.depth }

            // Use panel's W/L (same as axial slices), fall back to initial values
            let ww = panel.windowWidth > 0 ? panel.windowWidth : (panel.initialWindowWidth > 0 ? panel.initialWindowWidth : 2000)
            let wc = (panel.windowWidth > 0) ? panel.windowCenter : (panel.initialWindowWidth > 0 ? panel.initialWindowCenter : 500)

            let engine = MPREngine(volume: volume)
            guard let slice = engine.axialSlabProjection(
                mode: mode,
                slabCenter: panel.mipSlabPosition,
                slabThickness: panel.mipSlabThickness
            ) else {
                panel.isLoading = false
                panel.errorMessage = "Slab MIP rendering failed"
                return
            }

            if let image = MPREngine.renderSlice(slice, ww: ww, wc: wc, invert: panel.isInverted) {
                panel.setDisplayImage(image)
                panel.imageWidth = slice.width
                panel.imageHeight = slice.height
                panel.rawPixelData = slice.pixelData
                panel.bitDepth = 16
                panel.isSigned = true
                panel.samples = 1
                panel.pixelSpacing = (volume.spacingY, volume.spacingX)

                // Set spatial metadata for cross-reference (axial plane at slab center)
                let origin = volume.voxelToWorld(SIMD3<Double>(0, 0, Double(panel.mipSlabPosition)))
                panel.imagePositionPatient = (origin.x, origin.y, origin.z)
                panel.imageOrientationPatient = [
                    volume.rowDirection.x, volume.rowDirection.y, volume.rowDirection.z,
                    volume.colDirection.x, volume.colDirection.y, volume.colDirection.z
                ]
            } else {
                panel.errorMessage = "Slab MIP rendering failed"
            }
            panel.isLoading = false
            self.objectWillChange.send()
            self.updatePanelInfoStrings(panel)
        }
    }
}

// Force update
