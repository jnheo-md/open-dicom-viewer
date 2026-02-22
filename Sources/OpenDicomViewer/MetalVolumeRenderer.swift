// MetalVolumeRenderer.swift
// OpenDicomViewer
//
// GPU-accelerated volume rendering using Metal compute shaders. Uploads a
// VolumeData's Int16 voxels into a 3D Metal texture and renders projections
// (MIP, MinIP, Average) via orthographic raycasting through the volume.
//
// The included Metal shader (`mip_kernel`) performs:
//   - Ray-AABB intersection against the volume bounding box
//   - Slab thickness clipping (in mm, converted to voxel-space)
//   - Per-ray accumulation (max, min, or average intensity)
//   - Window/level tone mapping to grayscale output
//
// Also provides VolumeRenderView, a SwiftUI MTKView wrapper (currently a
// placeholder for future interactive Metal rendering).

import Foundation
import Metal
import MetalKit
import AppKit
import SwiftUI
import simd

// MARK: - Metal Volume Renderer

/// GPU-accelerated volume rendering using Metal compute shaders.
/// Supports MIP, MinIP, Average projection, and basic raycasting.
final class MetalVolumeRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var mipPipeline: MTLComputePipelineState?
    private var volumeTexture: MTLTexture?
    private var outputTexture: MTLTexture?

    /// Current volume dimensions (for re-creating texture if needed)
    private var currentVolumeUID: String?
    private var outputWidth: Int = 0
    private var outputHeight: Int = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            print("MetalVolumeRenderer: Metal not available")
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // Compile shader
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "mip_kernel") else {
                print("MetalVolumeRenderer: Failed to find mip_kernel")
                return nil
            }
            mipPipeline = try device.makeComputePipelineState(function: function)
        } catch {
            print("MetalVolumeRenderer: Shader compilation failed: \(error)")
            return nil
        }
    }

    // MARK: - Volume Upload

    /// Upload VolumeData to a 3D Metal texture
    func uploadVolume(_ volume: VolumeData) {
        guard currentVolumeUID != volume.seriesUID else { return }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .r16Sint
        desc.width = volume.width
        desc.height = volume.height
        desc.depth = volume.depth
        desc.usage = [.shaderRead]
        desc.storageMode = .managed

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("MetalVolumeRenderer: Failed to create 3D texture")
            return
        }

        // Upload slice by slice
        let bytesPerRow = volume.width * MemoryLayout<Int16>.stride
        let bytesPerImage = bytesPerRow * volume.height

        for z in 0..<volume.depth {
            let offset = z * volume.width * volume.height
            let srcPtr = volume.voxels.baseAddress! + offset

            texture.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: z),
                    size: MTLSize(width: volume.width, height: volume.height, depth: 1)
                ),
                mipmapLevel: 0,
                slice: 0,
                withBytes: srcPtr,
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerImage
            )
        }

        self.volumeTexture = texture
        self.currentVolumeUID = volume.seriesUID
    }

    // MARK: - Rendering

    /// Render a MIP/MinIP/Average projection and return as NSImage
    func renderProjection(
        volume: VolumeData,
        mode: ProjectionMode,
        viewMatrix: simd_float4x4,
        outputWidth: Int,
        outputHeight: Int,
        windowWidth: Float,
        windowCenter: Float,
        slabThickness: Float,
        thresholdMin: Float = -Float.greatestFiniteMagnitude,
        thresholdMax: Float = Float.greatestFiniteMagnitude
    ) -> NSImage? {
        uploadVolume(volume)
        guard let volumeTex = volumeTexture, let pipeline = mipPipeline else { return nil }

        // Create/resize output texture
        if self.outputWidth != outputWidth || self.outputHeight != outputHeight || outputTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: outputWidth,
                height: outputHeight,
                mipmapped: false
            )
            desc.usage = [.shaderWrite, .shaderRead]
            desc.storageMode = .managed
            outputTexture = device.makeTexture(descriptor: desc)
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
        }

        guard let outputTex = outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(volumeTex, index: 0)
        encoder.setTexture(outputTex, index: 1)

        // Uniforms
        var uniforms = MIPUniforms(
            viewMatrix: viewMatrix,
            invViewMatrix: viewMatrix.inverse,
            volumeDims: SIMD3<Float>(Float(volume.width), Float(volume.height), Float(volume.depth)),
            voxelSpacing: SIMD3<Float>(Float(volume.spacingX), Float(volume.spacingY), Float(volume.spacingZ)),
            windowWidth: windowWidth,
            windowCenter: windowCenter,
            slabThickness: slabThickness,
            mode: Int32(modeToInt(mode)),
            thresholdMin: thresholdMin,
            thresholdMax: thresholdMax,
            outputSize: SIMD2<Float>(Float(outputWidth), Float(outputHeight))
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<MIPUniforms>.stride, index: 0)

        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let threadGroups = MTLSize(
            width: (outputWidth + 7) / 8,
            height: (outputHeight + 7) / 8,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        // Blit for managed textures
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: outputTex)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return textureToNSImage(outputTex, width: outputWidth, height: outputHeight)
    }

    // MARK: - Helpers

    private func modeToInt(_ mode: ProjectionMode) -> Int {
        switch mode {
        case .mip: return 0
        case .minip: return 1
        case .average: return 2
        }
    }

    private func textureToNSImage(_ texture: MTLTexture, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        texture.getBytes(
            &pixels,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                            size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

// MARK: - Uniform Struct (shared with Metal shader)

struct MIPUniforms {
    var viewMatrix: simd_float4x4
    var invViewMatrix: simd_float4x4
    var volumeDims: SIMD3<Float>
    var voxelSpacing: SIMD3<Float>
    var windowWidth: Float
    var windowCenter: Float
    var slabThickness: Float
    var mode: Int32       // 0=MIP, 1=MinIP, 2=Average
    var thresholdMin: Float
    var thresholdMax: Float
    var outputSize: SIMD2<Float>
}

// MARK: - Metal Shader Source

extension MetalVolumeRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MIPUniforms {
        float4x4 viewMatrix;
        float4x4 invViewMatrix;
        float3 volumeDims;
        float3 voxelSpacing;
        float windowWidth;
        float windowCenter;
        float slabThickness;
        int mode;        // 0=MIP, 1=MinIP, 2=Average
        float thresholdMin;
        float thresholdMax;
        float2 outputSize;
    };

    // Ray-AABB intersection
    bool intersectBox(float3 rayOrigin, float3 rayDir, float3 boxMin, float3 boxMax,
                      thread float &tNear, thread float &tFar) {
        float3 invDir = 1.0 / rayDir;
        float3 t0 = (boxMin - rayOrigin) * invDir;
        float3 t1 = (boxMax - rayOrigin) * invDir;
        float3 tmin = min(t0, t1);
        float3 tmax = max(t0, t1);
        tNear = max(max(tmin.x, tmin.y), tmin.z);
        tFar = min(min(tmax.x, tmax.y), tmax.z);
        return tNear <= tFar && tFar > 0;
    }

    kernel void mip_kernel(
        texture3d<short, access::read> volume [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant MIPUniforms &uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uint(uniforms.outputSize.x) || gid.y >= uint(uniforms.outputSize.y)) return;

        // Normalized device coordinates [-1, 1]
        float2 ndc = float2(gid) / uniforms.outputSize * 2.0 - 1.0;

        // Volume extent in voxel coordinates [0, dims]
        float3 dims = uniforms.volumeDims;
        float3 center = dims * 0.5;

        // Ray in view space: orthographic projection along -Z, centered at origin
        // After inverse view matrix transform, offset by volume center so rays
        // cover the full volume bounding box [0, dims]
        float diag = length(dims);
        float3 viewOrigin = float3(ndc.x * dims.x * 0.5, -ndc.y * dims.y * 0.5, diag);
        float3 viewDir = float3(0, 0, -1);

        // Transform ray by inverse view matrix (rotation around origin)
        float4 worldOrigin = uniforms.invViewMatrix * float4(viewOrigin, 1.0);
        float4 worldDir = uniforms.invViewMatrix * float4(viewDir, 0.0);

        // Offset to volume center so rotation is around the volume center
        float3 rayOrigin = worldOrigin.xyz + center;
        float3 rayDir = normalize(worldDir.xyz);

        // Intersect with volume bounding box [0, dims]
        float tNear, tFar;
        if (!intersectBox(rayOrigin, rayDir, float3(0), dims, tNear, tFar)) {
            output.write(float4(0, 0, 0, 1), gid);
            return;
        }

        tNear = max(tNear, 0.0);

        // Slab thickness clipping (slabThickness is in mm, convert to voxel-space t units)
        if (uniforms.slabThickness > 0) {
            // Convert mm to voxel-t: one unit of t along rayDir covers this many mm
            float3 rayMM = rayDir * uniforms.voxelSpacing;
            float mmPerT = length(rayMM);
            float slabT = (mmPerT > 0) ? uniforms.slabThickness / mmPerT : uniforms.slabThickness;

            if (slabT < (tFar - tNear)) {
                float mid = (tNear + tFar) * 0.5;
                tNear = mid - slabT * 0.5;
                tFar = mid + slabT * 0.5;
            }
        }

        // Step size: 0.5 voxels for quality
        float stepSize = 0.5;
        int numSteps = int(ceil((tFar - tNear) / stepSize));
        numSteps = min(numSteps, 2048);

        float result;
        if (uniforms.mode == 0) result = -32768.0; // MIP
        else if (uniforms.mode == 1) result = 32767.0; // MinIP
        else result = 0.0; // Average

        int sampleCount = 0;

        for (int i = 0; i < numSteps; i++) {
            float t = tNear + (float(i) + 0.5) * stepSize;
            float3 pos = rayOrigin + t * rayDir;

            // Clamp to volume bounds
            if (pos.x < 0 || pos.x >= dims.x - 1 ||
                pos.y < 0 || pos.y >= dims.y - 1 ||
                pos.z < 0 || pos.z >= dims.z - 1) continue;

            // Nearest-neighbor sampling (fast)
            int3 coord = int3(pos + 0.5);
            coord = clamp(coord, int3(0), int3(dims) - 1);

            short rawVal = volume.read(ushort3(coord)).r;
            float val = float(rawVal);

            // Threshold filtering
            if (val < uniforms.thresholdMin || val > uniforms.thresholdMax) continue;

            sampleCount++;

            if (uniforms.mode == 0) result = max(result, val);       // MIP
            else if (uniforms.mode == 1) result = min(result, val);  // MinIP
            else result += val;                                       // Average
        }

        if (uniforms.mode == 2 && sampleCount > 0) {
            result /= float(sampleCount);
        }
        if (sampleCount == 0) result = uniforms.windowCenter - uniforms.windowWidth * 0.5;

        // Window/Level
        float windowBottom = uniforms.windowCenter - uniforms.windowWidth * 0.5;
        float normalized = (result - windowBottom) / uniforms.windowWidth;
        normalized = clamp(normalized, 0.0, 1.0);

        output.write(float4(normalized, normalized, normalized, 1.0), gid);
    }
    """
}

// MARK: - Volume Render View (MTKView wrapper for SwiftUI)

/// SwiftUI wrapper for an MTKView that displays GPU-rendered volume projections
struct VolumeRenderView: NSViewRepresentable {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    let renderer: MetalVolumeRenderer

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView(frame: .zero, device: renderer.device)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Rendering is triggered externally and the result is set on panel.image
        // The MTKView here is a placeholder for future interactive Metal rendering
    }
}
