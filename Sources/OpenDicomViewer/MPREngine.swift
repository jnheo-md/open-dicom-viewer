// MPREngine.swift
// OpenDicomViewer
//
// CPU-based Multi-Planar Reconstruction (MPR) engine. Extracts oblique 2D
// slices from a 3D VolumeData by sampling along orthogonal planes (sagittal,
// coronal) using trilinear interpolation. Converts the sampled voxel values
// to grayscale NSImage via window/level tone mapping.
//
// This is the fallback rendering path; GPU-accelerated rendering is handled
// by MetalVolumeRenderer for MIP projections.
// Licensed under the MIT License. See LICENSE for details.

import Foundation
import AppKit
import simd
import DCMTKWrapper

// MARK: - Volume Builder

enum VolumeBuilderError: Error, CustomStringConvertible {
    case noImages
    case inconsistentDimensions
    case missingPixelData(url: URL)
    case missingSpatialMetadata
    case inconsistentOrientation
    case nonUniformSpacing(maxDeviation: Double)
    case memoryLimitExceeded(requiredMB: Int)

    var description: String {
        switch self {
        case .noImages: return "Series has no images"
        case .inconsistentDimensions: return "Images have different dimensions"
        case .missingPixelData(let url): return "Missing pixel data: \(url.lastPathComponent)"
        case .missingSpatialMetadata: return "Missing spatial metadata (position/orientation/spacing)"
        case .inconsistentOrientation: return "Images have different orientations"
        case .nonUniformSpacing(let dev): return "Non-uniform slice spacing (max deviation: \(String(format: "%.1f", dev))%)"
        case .memoryLimitExceeded(let mb): return "Volume exceeds memory limit (\(mb) MB)"
        }
    }
}

struct VolumeBuilder {
    /// Maximum volume memory in bytes (default 1 GB)
    static let maxMemoryBytes = 1_073_741_824

    /// Build a VolumeData from a DICOM series.
    /// Reads raw pixel data from the provided cache or loads from disk via DCMTK.
    static func build(
        series: DicomSeries,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>,
        progress: ((Double) -> Void)? = nil
    ) throws -> VolumeData {
        let images = series.images
        guard !images.isEmpty else { throw VolumeBuilderError.noImages }

        // Validate spatial metadata on first image
        guard let firstOrient = images.first?.imageOrientation, firstOrient.count == 6,
              let firstSpacing = images.first?.pixelSpacing,
              images.first?.imagePosition != nil
        else { throw VolumeBuilderError.missingSpatialMetadata }

        let rowDir = simd_normalize(SIMD3<Double>(firstOrient[0], firstOrient[1], firstOrient[2]))
        let colDir = simd_normalize(SIMD3<Double>(firstOrient[3], firstOrient[4], firstOrient[5]))
        let sliceNormal = simd_normalize(simd_cross(rowDir, colDir))

        // Sort images by projection along slice normal
        let sorted = images.compactMap { img -> (DicomImageContext, Double)? in
            guard let pos = img.imagePosition else { return nil }
            let proj = simd_dot(pos, sliceNormal)
            return (img, proj)
        }.sorted(by: { $0.1 < $1.1 })

        guard sorted.count >= 2 else { throw VolumeBuilderError.missingSpatialMetadata }

        // Determine consistent dimensions by loading first image's raw data
        let (firstW, firstH, firstBits, firstSigned) = try loadImageDimensions(sorted[0].0, rawDataCache: rawDataCache, dcmtkCache: dcmtkCache)

        // Compute slice spacing from positions
        var spacings: [Double] = []
        for i in 1..<sorted.count {
            spacings.append(sorted[i].1 - sorted[i - 1].1)
        }
        let avgSpacing = spacings.reduce(0, +) / Double(spacings.count)

        // Validate uniform spacing (10% tolerance)
        if avgSpacing > 0 {
            for s in spacings {
                let deviation = abs(s - avgSpacing) / avgSpacing * 100
                if deviation > 10 {
                    throw VolumeBuilderError.nonUniformSpacing(maxDeviation: deviation)
                }
            }
        }

        let depth = sorted.count
        let sliceSpacing = abs(avgSpacing) > 1e-6 ? abs(avgSpacing) : (series.images.first?.sliceThickness ?? 1.0)

        // Memory check
        let requiredBytes = firstW * firstH * depth * MemoryLayout<Int16>.stride
        if requiredBytes > maxMemoryBytes {
            throw VolumeBuilderError.memoryLimitExceeded(requiredMB: requiredBytes / (1024 * 1024))
        }

        // Allocate contiguous buffer
        let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: firstW * firstH * depth)
        buffer.initialize(repeating: 0)

        let sliceStride = firstW * firstH

        // Extract RescaleSlope/Intercept from first image tags
        let (slope, intercept) = extractRescaleParams(sorted[0].0, rawDataCache: rawDataCache, dcmtkCache: dcmtkCache)

        // Fill volume slice by slice (using per-slice bit depth/signedness)
        for (sliceIdx, (img, _)) in sorted.enumerated() {
            progress?(Double(sliceIdx) / Double(depth))

            guard let info = loadRawDataWithInfo(img, rawDataCache: rawDataCache, dcmtkCache: dcmtkCache) else {
                // Zero-fill this slice (already initialized to 0)
                continue
            }

            let offset = sliceIdx * sliceStride
            fillSlice(
                buffer: buffer,
                offset: offset,
                rawData: info.data,
                width: firstW,
                height: firstH,
                bits: info.bits,
                isSigned: info.isSigned
            )
        }

        progress?(1.0)

        let origin = sorted[0].0.imagePosition!

        return VolumeData(
            voxels: buffer,
            width: firstW,
            height: firstH,
            depth: depth,
            spacingX: firstSpacing.x,
            spacingY: firstSpacing.y,
            spacingZ: sliceSpacing,
            origin: origin,
            rowDirection: rowDir,
            colDirection: colDir,
            rescaleSlope: slope,
            rescaleIntercept: intercept,
            seriesUID: series.id
        )
    }

    // MARK: - Private Helpers

    private static func loadImageDimensions(
        _ img: DicomImageContext,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>
    ) throws -> (width: Int, height: Int, bits: Int, isSigned: Bool) {
        // Try DCMTK object first
        if let dcmObj = dcmtkCache.object(forKey: img.url as NSURL) ?? DCMTKImageObject(path: img.url.path) {
            var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
            var signed: ObjCBool = false
            if dcmObj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) != nil {
                return (w, h, d, signed.boolValue)
            }
        }
        throw VolumeBuilderError.missingPixelData(url: img.url)
    }

    /// Load raw pixel data along with per-slice representation info
    private static func loadRawDataWithInfo(
        _ img: DicomImageContext,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>
    ) -> (data: Data, bits: Int, isSigned: Bool)? {
        // Load via DCMTK (always query for per-slice bit depth)
        let dcmObj = dcmtkCache.object(forKey: img.url as NSURL) ?? DCMTKImageObject(path: img.url.path)
        guard let dcmObj = dcmObj else { return nil }
        var w: Int = 0, h: Int = 0, d: Int = 0, s: Int = 0
        var signed: ObjCBool = false
        guard let raw = dcmObj.getRawDataWidth(&w, height: &h, bitDepth: &d, samples: &s, isSigned: &signed) else {
            return nil
        }
        rawDataCache.setObject(raw as NSData, forKey: img.url as NSURL)
        dcmtkCache.setObject(dcmObj, forKey: img.url as NSURL)
        return (raw as Data, d, signed.boolValue)
    }

    private static func fillSlice(
        buffer: UnsafeMutableBufferPointer<Int16>,
        offset: Int,
        rawData: Data,
        width: Int,
        height: Int,
        bits: Int,
        isSigned: Bool
    ) {
        let pixelCount = width * height

        rawData.withUnsafeBytes { rawBuf in
            if bits >= 32 {
                // 32-bit data (DCMTK can return this after Modality LUT on some series)
                if isSigned {
                    guard rawData.count >= pixelCount * 4 else { return }
                    let src = rawBuf.baseAddress!.assumingMemoryBound(to: Int32.self)
                    for i in 0..<pixelCount {
                        buffer[offset + i] = Int16(clamping: src[i])
                    }
                } else {
                    guard rawData.count >= pixelCount * 4 else { return }
                    let src = rawBuf.baseAddress!.assumingMemoryBound(to: UInt32.self)
                    for i in 0..<pixelCount {
                        buffer[offset + i] = Int16(clamping: Int32(min(UInt32(Int32.max), src[i])))
                    }
                }
            } else if bits > 8 {
                // 16-bit data
                guard rawData.count >= pixelCount * 2 else { return }
                if isSigned {
                    let src = rawBuf.baseAddress!.assumingMemoryBound(to: Int16.self)
                    for i in 0..<pixelCount {
                        buffer[offset + i] = src[i]
                    }
                } else {
                    let src = rawBuf.baseAddress!.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<pixelCount {
                        buffer[offset + i] = Int16(clamping: Int32(src[i]))
                    }
                }
            } else {
                // 8-bit data — upcast to Int16
                guard rawData.count >= pixelCount else { return }
                let src = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<pixelCount {
                    buffer[offset + i] = Int16(src[i])
                }
            }
        }
    }

    private static func extractRescaleParams(
        _ img: DicomImageContext,
        rawDataCache: NSCache<NSURL, NSData>,
        dcmtkCache: NSCache<NSURL, DCMTKImageObject>
    ) -> (slope: Double, intercept: Double) {
        // Try parsing DICOM tags for RescaleSlope (0028,1053) and RescaleIntercept (0028,1052)
        guard let data = try? Data(contentsOf: img.url, options: .mappedIfSafe) else {
            return (1.0, 0.0)
        }
        let parser = SimpleDicomParser(data: data)
        guard let (elements, _, _) = try? parser.parse(stopAtPixelData: true) else {
            return (1.0, 0.0)
        }

        var slope = 1.0
        var intercept = 0.0

        if let slopeStr = elements.first(where: { $0.tag == DicomTag(group: 0x0028, element: 0x1053) })?.stringValue,
           let s = Double(slopeStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            slope = s
        }
        if let interceptStr = elements.first(where: { $0.tag == DicomTag(group: 0x0028, element: 0x1052) })?.stringValue,
           let i = Double(interceptStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            intercept = i
        }

        return (slope, intercept)
    }
}

// MARK: - MPR Engine

/// Result of an MPR slice generation
struct MPRSlice {
    let pixelData: Data     // Raw Int16 values
    let width: Int
    let height: Int
    let planeOrigin: SIMD3<Double>
    let planeRowDir: SIMD3<Double>
    let planeColDir: SIMD3<Double>
    let pixelSpacingX: Double
    let pixelSpacingY: Double
}

class MPREngine {
    let volume: VolumeData

    init(volume: VolumeData) {
        self.volume = volume
    }

    // MARK: - Orthogonal Slices

    /// Generate an axial slice at a given Z voxel index (fast path, no interpolation needed)
    func axialSlice(at zIndex: Int) -> MPRSlice? {
        guard zIndex >= 0, zIndex < volume.depth else { return nil }
        let w = volume.width
        let h = volume.height
        let sliceStride = w * h

        var data = Data(count: sliceStride * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let offset = zIndex * sliceStride
            for i in 0..<sliceStride {
                dst[i] = volume.voxels[offset + i]
            }
        }

        let origin = volume.voxelToWorld(SIMD3<Double>(0, 0, Double(zIndex)))

        return MPRSlice(
            pixelData: data,
            width: w,
            height: h,
            planeOrigin: origin,
            planeRowDir: volume.rowDirection,
            planeColDir: volume.colDirection,
            pixelSpacingX: volume.spacingX,
            pixelSpacingY: volume.spacingY
        )
    }

    /// Generate a sagittal slice at a given X voxel index
    func sagittalSlice(at xIndex: Int) -> MPRSlice? {
        guard xIndex >= 0, xIndex < volume.width else { return nil }
        // Sagittal: rows = Z (depth, reversed so superior is at top), cols = Y (height)
        let w = volume.height   // output width = Y dimension
        let h = volume.depth    // output height = Z dimension

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = volume.depth - 1 - z  // Flip Z so superior is at top
                for y in 0..<volume.height {
                    dst[outRow * w + y] = volume.voxelAt(x: xIndex, y: y, z: z)
                }
            }
        }

        let origin = volume.voxelToWorld(SIMD3<Double>(Double(xIndex), 0, 0))

        return MPRSlice(
            pixelData: data,
            width: w,
            height: h,
            planeOrigin: origin,
            planeRowDir: volume.colDirection,              // Y direction
            planeColDir: volume.sliceDirection,             // Z direction
            pixelSpacingX: volume.spacingY,
            pixelSpacingY: volume.spacingZ
        )
    }

    /// Generate a coronal slice at a given Y voxel index
    func coronalSlice(at yIndex: Int) -> MPRSlice? {
        guard yIndex >= 0, yIndex < volume.height else { return nil }
        // Coronal: rows = Z (depth, reversed so superior is at top), cols = X (width)
        let w = volume.width    // output width = X dimension
        let h = volume.depth    // output height = Z dimension

        var data = Data(count: w * h * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for z in 0..<volume.depth {
                let outRow = volume.depth - 1 - z  // Flip Z so superior is at top
                for x in 0..<volume.width {
                    dst[outRow * w + x] = volume.voxelAt(x: x, y: yIndex, z: z)
                }
            }
        }

        let origin = volume.voxelToWorld(SIMD3<Double>(0, Double(yIndex), 0))

        return MPRSlice(
            pixelData: data,
            width: w,
            height: h,
            planeOrigin: origin,
            planeRowDir: volume.rowDirection,               // X direction
            planeColDir: volume.sliceDirection,              // Z direction
            pixelSpacingX: volume.spacingX,
            pixelSpacingY: volume.spacingZ
        )
    }

    // MARK: - Arbitrary Oblique Slice

    /// Generate an oblique slice through the volume defined by origin, row/col direction, and dimensions
    func obliqueSlice(
        origin: SIMD3<Double>,   // World coordinates of top-left corner
        rowDir: SIMD3<Double>,   // Normalized row direction
        colDir: SIMD3<Double>,   // Normalized column direction
        width: Int,
        height: Int,
        spacing: Double          // Output pixel spacing in mm
    ) -> MPRSlice {
        var data = Data(count: width * height * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<height {
                for col in 0..<width {
                    let worldPt = origin
                        + Double(col) * spacing * rowDir
                        + Double(row) * spacing * colDir

                    let voxel = volume.worldToVoxel(worldPt)
                    let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                    dst[row * width + col] = Int16(clamping: Int(val.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: width,
            height: height,
            planeOrigin: origin,
            planeRowDir: rowDir,
            planeColDir: colDir,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing
        )
    }

    // MARK: - Rendering MPR to NSImage

    /// Render an MPR slice to a displayable image with Window/Level
    /// The NSImage size reflects physical dimensions (mm) so non-isotropic pixels display correctly
    static func renderSlice(_ slice: MPRSlice, ww: Double, wc: Double, invert: Bool = false) -> NSImage? {
        let totalPixels = slice.width * slice.height
        guard totalPixels > 0, ww > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: slice.width,
            height: slice.height,
            bitsPerComponent: 8,
            bytesPerRow: slice.width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let destData = context.data else { return nil }
        let destBuffer = destData.bindMemory(to: UInt8.self, capacity: totalPixels)

        let windowBottom = wc - (ww / 2.0)

        slice.pixelData.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: Int16.self),
                  slice.pixelData.count >= totalPixels * 2 else { return }

            for i in 0..<totalPixels {
                let val = Double(src[i])
                var norm = (val - windowBottom) / ww * 255.0
                if invert { norm = 255.0 - norm }
                destBuffer[i] = UInt8(max(0, min(255, norm)))
            }
        }

        guard let cgImage = context.makeImage() else { return nil }

        // Scale NSImage size to reflect physical dimensions so non-isotropic
        // pixels (e.g., sagittal/coronal with thick slices) display correctly.
        // Use the ratio of spacingY/spacingX to determine the aspect correction.
        let physicalWidth = Double(slice.width) * slice.pixelSpacingX
        let physicalHeight = Double(slice.height) * slice.pixelSpacingY
        let aspectRatio = physicalHeight / physicalWidth

        // Set display size: keep width as pixel width, scale height by aspect ratio
        let displayWidth = CGFloat(slice.width)
        let displayHeight = CGFloat(Double(slice.width) * aspectRatio)

        return NSImage(cgImage: cgImage, size: NSSize(width: displayWidth, height: displayHeight))
    }
}

// MARK: - Axial Slab Projection (Clinical MIP)

enum ProjectionMode: String, CaseIterable, Identifiable {
    case mip = "MIP"
    case minip = "MinIP"
    case average = "Average"

    var id: String { rawValue }
}

extension MPREngine {
    /// Generate an axial slab MIP/MinIP/Average by projecting consecutive axial slices.
    /// This is the clinical slab-MIP workflow used in CTA/MRA angiography:
    /// take N slices centered at `slabCenter`, max-project them into one 2D image.
    /// Output has the same width×height as a native axial slice.
    func axialSlabProjection(
        mode: ProjectionMode,
        slabCenter: Int,
        slabThickness: Int
    ) -> MPRSlice? {
        let halfSlab = slabThickness / 2
        let zStart = max(0, slabCenter - halfSlab)
        let zEnd = min(volume.depth - 1, slabCenter + halfSlab)
        guard zStart <= zEnd else { return nil }

        let w = volume.width
        let h = volume.height
        let pixelCount = w * h
        var data = Data(count: pixelCount * MemoryLayout<Int16>.stride)

        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            // Initialize based on projection mode
            for i in 0..<pixelCount {
                switch mode {
                case .mip:     dst[i] = Int16.min
                case .minip:   dst[i] = Int16.max
                case .average: dst[i] = 0
                }
            }

            // Project slices through the slab
            for z in zStart...zEnd {
                let sliceOffset = z * pixelCount
                for i in 0..<pixelCount {
                    let val = volume.voxels[sliceOffset + i]
                    switch mode {
                    case .mip:     if val > dst[i] { dst[i] = val }
                    case .minip:   if val < dst[i] { dst[i] = val }
                    case .average: dst[i] = Int16(clamping: Int32(dst[i]) + Int32(val))
                    }
                }
            }

            // Finalize average
            if mode == .average {
                let count = Int32(zEnd - zStart + 1)
                if count > 1 {
                    for i in 0..<pixelCount {
                        dst[i] = Int16(clamping: Int32(dst[i]) / count)
                    }
                }
            }
        }

        let origin = volume.voxelToWorld(SIMD3<Double>(0, 0, Double(slabCenter)))

        return MPRSlice(
            pixelData: data,
            width: w,
            height: h,
            planeOrigin: origin,
            planeRowDir: volume.rowDirection,
            planeColDir: volume.colDirection,
            pixelSpacingX: volume.spacingX,
            pixelSpacingY: volume.spacingY
        )
    }
}

// MARK: - 3D Ray-March Projection (Legacy)

extension MPREngine {
    /// Generate a projection (MIP/MinIP/Average) through the volume along a given view direction
    func generateProjection(
        mode: ProjectionMode,
        viewDirection: SIMD3<Double>,
        upDirection: SIMD3<Double>,
        slabThickness: Double?,      // nil = full volume
        outputWidth: Int,
        outputHeight: Int,
        spacing: Double
    ) -> MPRSlice {
        let viewDir = simd_normalize(viewDirection)
        let right = simd_normalize(simd_cross(viewDir, upDirection))
        let up = simd_normalize(simd_cross(right, viewDir))

        let center = volume.worldCenter
        let bounds = volume.worldBounds

        // Compute ray length through volume (diagonal)
        let diagonal = simd_length(bounds.max - bounds.min)
        let halfLen = (slabThickness != nil) ? slabThickness! / 2.0 : diagonal / 2.0

        // Step size: half the minimum voxel spacing for quality
        let minSpacing = min(volume.spacingX, min(volume.spacingY, volume.spacingZ))
        let stepSize = minSpacing * 0.5
        let numSteps = Int(2.0 * halfLen / stepSize) + 1

        let halfW = Double(outputWidth) / 2.0
        let halfH = Double(outputHeight) / 2.0

        var data = Data(count: outputWidth * outputHeight * MemoryLayout<Int16>.stride)
        data.withUnsafeMutableBytes { buf in
            guard let dst = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }

            for row in 0..<outputHeight {
                for col in 0..<outputWidth {
                    let u = (Double(col) - halfW) * spacing
                    let v = (Double(row) - halfH) * spacing

                    let rayOrigin = center + u * right + v * up - halfLen * viewDir

                    var result: Double
                    switch mode {
                    case .mip:   result = -Double.greatestFiniteMagnitude
                    case .minip: result = Double.greatestFiniteMagnitude
                    case .average: result = 0
                    }

                    var sampleCount = 0

                    for step in 0..<numSteps {
                        let t = Double(step) * stepSize
                        let worldPt = rayOrigin + t * viewDir
                        let voxel = volume.worldToVoxel(worldPt)

                        // Bounds check (with small margin)
                        guard voxel.x >= -0.5, voxel.x < Double(volume.width) - 0.5,
                              voxel.y >= -0.5, voxel.y < Double(volume.height) - 0.5,
                              voxel.z >= -0.5, voxel.z < Double(volume.depth) - 0.5 else { continue }

                        let val = volume.sampleTrilinear(vx: voxel.x, vy: voxel.y, vz: voxel.z)
                        sampleCount += 1

                        switch mode {
                        case .mip:     result = max(result, val)
                        case .minip:   result = min(result, val)
                        case .average: result += val
                        }
                    }

                    if mode == .average && sampleCount > 0 {
                        result /= Double(sampleCount)
                    }
                    if sampleCount == 0 { result = 0 }

                    dst[row * outputWidth + col] = Int16(clamping: Int(result.rounded()))
                }
            }
        }

        return MPRSlice(
            pixelData: data,
            width: outputWidth,
            height: outputHeight,
            planeOrigin: center - halfW * spacing * right - halfH * spacing * up,
            planeRowDir: right,
            planeColDir: up,
            pixelSpacingX: spacing,
            pixelSpacingY: spacing
        )
    }
}
