// VolumeData.swift
// OpenDicomViewer
//
// Represents a consolidated 3D volume reconstructed from a DICOM series.
// Stores voxels as Int16 in a contiguous buffer in [z][y][x] (slice-major)
// order. Provides:
//   - Voxel access (raw and calibrated HU values)
//   - Coordinate transforms between voxel indices and patient-space (mm)
//     via 4x4 affine matrices built from DICOM spatial metadata
//   - Trilinear interpolation for sub-voxel sampling (used by MPR)
//   - World-space bounding box computation
//
// Memory is manually allocated via UnsafeMutableBufferPointer and freed
// in deinit to avoid Swift Array overhead for large volumes.

import Foundation
import simd

/// Consolidated 3D volume from a DICOM series.
/// Stores voxels as Int16 in a contiguous buffer [z][y][x] order (slice-major).
final class VolumeData {
    let voxels: UnsafeMutableBufferPointer<Int16>
    let width: Int       // columns (X)
    let height: Int      // rows (Y)
    let depth: Int       // slices (Z)
    let spacingX: Double // mm per pixel along row direction
    let spacingY: Double // mm per pixel along column direction
    let spacingZ: Double // mm between slices

    let origin: SIMD3<Double>          // ImagePositionPatient of first slice
    let rowDirection: SIMD3<Double>    // Normalized row direction cosine
    let colDirection: SIMD3<Double>    // Normalized column direction cosine
    let sliceDirection: SIMD3<Double>  // cross(row, col), normalized — slice stacking direction

    let rescaleSlope: Double
    let rescaleIntercept: Double

    /// 4×4 affine: voxel (i,j,k) → world (x,y,z) in mm
    let voxelToWorldMatrix: simd_double4x4
    /// Inverse: world → voxel
    let worldToVoxelMatrix: simd_double4x4

    let seriesUID: String
    let sliceCount: Int  // alias for depth

    private let sliceStride: Int  // width * height

    init(
        voxels: UnsafeMutableBufferPointer<Int16>,
        width: Int, height: Int, depth: Int,
        spacingX: Double, spacingY: Double, spacingZ: Double,
        origin: SIMD3<Double>,
        rowDirection: SIMD3<Double>,
        colDirection: SIMD3<Double>,
        rescaleSlope: Double,
        rescaleIntercept: Double,
        seriesUID: String
    ) {
        self.voxels = voxels
        self.width = width
        self.height = height
        self.depth = depth
        self.spacingX = spacingX
        self.spacingY = spacingY
        self.spacingZ = spacingZ
        self.origin = origin
        self.rowDirection = rowDirection
        self.colDirection = colDirection
        self.sliceDirection = simd_normalize(simd_cross(rowDirection, colDirection))
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.seriesUID = seriesUID
        self.sliceCount = depth
        self.sliceStride = width * height

        // Build voxel-to-world matrix:
        // world = origin + i * spacingX * rowDir + j * spacingY * colDir + k * spacingZ * sliceDir
        let r = rowDirection * spacingX
        let c = colDirection * spacingY
        let s = self.sliceDirection * spacingZ
        self.voxelToWorldMatrix = simd_double4x4(columns: (
            SIMD4<Double>(r.x, r.y, r.z, 0),
            SIMD4<Double>(c.x, c.y, c.z, 0),
            SIMD4<Double>(s.x, s.y, s.z, 0),
            SIMD4<Double>(origin.x, origin.y, origin.z, 1)
        ))
        self.worldToVoxelMatrix = voxelToWorldMatrix.inverse
    }

    deinit {
        voxels.deallocate()
    }

    // MARK: - Voxel Access

    /// Raw voxel value at integer coordinates. Returns 0 if out of bounds.
    @inline(__always)
    func voxelAt(x: Int, y: Int, z: Int) -> Int16 {
        guard x >= 0, x < width, y >= 0, y < height, z >= 0, z < depth else { return 0 }
        return voxels[z * sliceStride + y * width + x]
    }

    /// Voxel value converted to calibrated units (HU for CT)
    @inline(__always)
    func calibratedValue(x: Int, y: Int, z: Int) -> Double {
        Double(voxelAt(x: x, y: y, z: z)) * rescaleSlope + rescaleIntercept
    }

    // MARK: - Coordinate Transforms

    /// Convert voxel indices (continuous) to world coordinates (mm)
    func voxelToWorld(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let h = SIMD4<Double>(v.x, v.y, v.z, 1)
        let w = voxelToWorldMatrix * h
        return SIMD3<Double>(w.x, w.y, w.z)
    }

    /// Convert world coordinates (mm) to voxel indices (continuous)
    func worldToVoxel(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let h = SIMD4<Double>(p.x, p.y, p.z, 1)
        let v = worldToVoxelMatrix * h
        return SIMD3<Double>(v.x, v.y, v.z)
    }

    // MARK: - Trilinear Interpolation

    /// Sample the volume at continuous voxel coordinates using trilinear interpolation.
    /// Returns the interpolated raw voxel value (apply rescale externally if needed).
    func sampleTrilinear(vx: Double, vy: Double, vz: Double) -> Double {
        let x0 = Int(floor(vx))
        let y0 = Int(floor(vy))
        let z0 = Int(floor(vz))

        let fx = vx - Double(x0)
        let fy = vy - Double(y0)
        let fz = vz - Double(z0)

        let x1 = x0 + 1
        let y1 = y0 + 1
        let z1 = z0 + 1

        // 8 corner samples
        let c000 = Double(voxelAt(x: x0, y: y0, z: z0))
        let c100 = Double(voxelAt(x: x1, y: y0, z: z0))
        let c010 = Double(voxelAt(x: x0, y: y1, z: z0))
        let c110 = Double(voxelAt(x: x1, y: y1, z: z0))
        let c001 = Double(voxelAt(x: x0, y: y0, z: z1))
        let c101 = Double(voxelAt(x: x1, y: y0, z: z1))
        let c011 = Double(voxelAt(x: x0, y: y1, z: z1))
        let c111 = Double(voxelAt(x: x1, y: y1, z: z1))

        // Interpolate along X
        let c00 = c000 * (1 - fx) + c100 * fx
        let c10 = c010 * (1 - fx) + c110 * fx
        let c01 = c001 * (1 - fx) + c101 * fx
        let c11 = c011 * (1 - fx) + c111 * fx

        // Interpolate along Y
        let c0 = c00 * (1 - fy) + c10 * fy
        let c1 = c01 * (1 - fy) + c11 * fy

        // Interpolate along Z
        return c0 * (1 - fz) + c1 * fz
    }

    /// Sample at world coordinates (mm) using trilinear interpolation
    func sampleAtWorld(_ point: SIMD3<Double>) -> Double {
        let v = worldToVoxel(point)
        return sampleTrilinear(vx: v.x, vy: v.y, vz: v.z)
    }

    // MARK: - Bounds

    /// Volume bounding box in world coordinates (8 corners)
    var worldBounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        let corners = [
            voxelToWorld(SIMD3<Double>(0, 0, 0)),
            voxelToWorld(SIMD3<Double>(Double(width - 1), 0, 0)),
            voxelToWorld(SIMD3<Double>(0, Double(height - 1), 0)),
            voxelToWorld(SIMD3<Double>(Double(width - 1), Double(height - 1), 0)),
            voxelToWorld(SIMD3<Double>(0, 0, Double(depth - 1))),
            voxelToWorld(SIMD3<Double>(Double(width - 1), 0, Double(depth - 1))),
            voxelToWorld(SIMD3<Double>(0, Double(height - 1), Double(depth - 1))),
            voxelToWorld(SIMD3<Double>(Double(width - 1), Double(height - 1), Double(depth - 1)))
        ]
        var lo = corners[0]
        var hi = corners[0]
        for c in corners {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        return (lo, hi)
    }

    /// Center of the volume in world coordinates
    var worldCenter: SIMD3<Double> {
        voxelToWorld(SIMD3<Double>(Double(width) / 2, Double(height) / 2, Double(depth) / 2))
    }

    /// Approximate memory usage in bytes
    var memoryBytes: Int {
        voxels.count * MemoryLayout<Int16>.stride
    }
}
