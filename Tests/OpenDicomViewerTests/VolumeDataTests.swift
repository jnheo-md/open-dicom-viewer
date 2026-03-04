import Testing
import simd
@testable import OpenDicomViewer

private func makeTestVolume() -> VolumeData {
    let buffer = UnsafeMutableBufferPointer<Int16>.allocate(capacity: 8)
    buffer[0] = 0
    buffer[1] = 1
    buffer[2] = 2
    buffer[3] = 3
    buffer[4] = 4
    buffer[5] = 5
    buffer[6] = 6
    buffer[7] = 7

    return VolumeData(
        voxels: buffer,
        width: 2,
        height: 2,
        depth: 2,
        spacingX: 2.0,
        spacingY: 3.0,
        spacingZ: 4.0,
        origin: SIMD3<Double>(10, 20, 30),
        rowDirection: SIMD3<Double>(1, 0, 0),
        colDirection: SIMD3<Double>(0, 1, 0),
        rescaleSlope: 1.0,
        rescaleIntercept: 0.0,
        seriesUID: "test-series"
    )
}

@Test
func voxelAtReturnsStoredValueAndZeroOutOfBounds() {
    let volume = makeTestVolume()
    #expect(volume.voxelAt(x: 1, y: 1, z: 1) == 7)
    #expect(volume.voxelAt(x: -1, y: 0, z: 0) == 0)
    #expect(volume.voxelAt(x: 2, y: 0, z: 0) == 0)
}

@Test
func sampleTrilinearAtCenterAveragesEightCorners() {
    let volume = makeTestVolume()
    #expect(abs(volume.sampleTrilinear(vx: 0.5, vy: 0.5, vz: 0.5) - 3.5) < 1e-12)
}

@Test
func voxelWorldRoundTrip() {
    let volume = makeTestVolume()
    let voxel = SIMD3<Double>(1, 1, 1)
    let world = volume.voxelToWorld(voxel)
    #expect(abs(world.x - 12.0) < 1e-12)
    #expect(abs(world.y - 23.0) < 1e-12)
    #expect(abs(world.z - 34.0) < 1e-12)

    let restored = volume.worldToVoxel(world)
    #expect(abs(restored.x - voxel.x) < 1e-9)
    #expect(abs(restored.y - voxel.y) < 1e-9)
    #expect(abs(restored.z - voxel.z) < 1e-9)
}
