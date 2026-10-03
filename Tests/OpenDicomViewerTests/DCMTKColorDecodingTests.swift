import XCTest
import AppKit
import DCMTKWrapper
@testable import OpenDicomViewer

final class DCMTKColorDecodingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        setenv("DCMDICTPATH", root.appendingPathComponent("libs/dcmtk/share/dcmtk-3.6.8/dicom.dic").path, 1)
    }

    private func words(_ values: [UInt16]) -> Data {
        Data(values.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
    }

    private func element(_ group: UInt16, _ tag: UInt16, _ vr: String, _ value: Data) -> Data {
        var result = words([group, tag])
        result.append(contentsOf: vr.utf8)
        if ["OB", "OW"].contains(vr) {
            result.append(words([0]))
            var length = UInt32(value.count).littleEndian
            result.append(Data(bytes: &length, count: 4))
        } else {
            result.append(words([UInt16(value.count)]))
        }
        result.append(value)
        return result
    }

    private func text(_ value: String, nullPadding: Bool = false) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 { data.append(nullPadding ? 0 : 32) }
        return data
    }

    /// Synthetic image only: no patient data or external mounted fixtures.
    private func fixture(photo: String, samples: UInt16, pixels: Data,
                         bits: UInt16 = 8, planar: UInt16 = 0, columns: UInt16 = 2,
                         rows: UInt16 = 1,
                         frames: Int = 1, signed: Bool = false,
                         slope: String? = nil, intercept: String? = nil,
                         extra: Data = Data()) throws -> URL {
        var file = Data(repeating: 0, count: 128)
        file.append(contentsOf: "DICM".utf8)
        file.append(element(0x0002, 0x0010, "UI", text("1.2.840.10008.1.2.1", nullPadding: true)))
        file.append(element(0x0008, 0x0016, "UI", text("1.2.840.10008.5.1.4.1.1.7", nullPadding: true)))
        file.append(element(0x0028, 0x0002, "US", words([samples])))
        file.append(element(0x0028, 0x0004, "CS", text(photo)))
        if samples > 1 { file.append(element(0x0028, 0x0006, "US", words([planar]))) }
        if frames > 1 { file.append(element(0x0028, 0x0008, "IS", text(String(frames)))) }
        file.append(element(0x0028, 0x0010, "US", words([rows])))
        file.append(element(0x0028, 0x0011, "US", words([columns])))
        file.append(element(0x0028, 0x0100, "US", words([bits])))
        file.append(element(0x0028, 0x0101, "US", words([bits])))
        file.append(element(0x0028, 0x0102, "US", words([bits - 1])))
        file.append(element(0x0028, 0x0103, "US", words([signed ? 1 : 0])))
        if let intercept { file.append(element(0x0028, 0x1052, "DS", text(intercept))) }
        if let slope { file.append(element(0x0028, 0x1053, "DS", text(slope))) }
        file.append(extra)
        file.append(element(0x7fe0, 0x0010, bits > 8 ? "OW" : "OB", pixels))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dcm")
        try file.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertRGB(_ url: URL, expected: [UInt8], width: Int = 2, tolerance: Int = 0,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(DCMTKImageObject(path: url.path), file: file, line: line)
        var w = 0, h = 0, bits = 0, samples = 0
        var signed: ObjCBool = true
        let data = try XCTUnwrap(object.getRawDataWidth(&w, height: &h, bitDepth: &bits,
                                                       samples: &samples, isSigned: &signed), file: file, line: line)
        XCTAssertEqual(w, width, file: file, line: line)
        XCTAssertEqual(h, 1, file: file, line: line)
        XCTAssertEqual(bits, 8, file: file, line: line)
        XCTAssertEqual(samples, 3, file: file, line: line)
        XCTAssertFalse(signed.boolValue, file: file, line: line)
        XCTAssertEqual(data.count, expected.count, file: file, line: line)
        for (actual, target) in zip(data, expected) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - Int(target)), tolerance, file: file, line: line)
        }
        let helperData = DCMTKHelper.getRawPixelData(url.path, width: &w, height: &h,
                                                   bitDepth: &bits, samples: &samples, isSigned: &signed)
        XCTAssertEqual(helperData, data, file: file, line: line)
        XCTAssertNotNil(object.renderImage(withWidth: 0, height: 0, ww: 400, wc: 40), file: file, line: line)
        XCTAssertNotNil(DCMTKHelper.convertDICOM(toNSImage: url.path), file: file, line: line)
        XCTAssertNil(DCMTKHelper.lastError(forPath: url.path), file: file, line: line)
    }

    func testInterleavedRGBAndPlanarRGBArePackedForDisplay() throws {
        let expected: [UInt8] = [255, 0, 0, 0, 255, 0]
        let interleaved = try fixture(photo: "RGB", samples: 3, pixels: Data(expected))
        try assertRGB(interleaved, expected: expected)
        let planar = try fixture(photo: "RGB", samples: 3, pixels: Data([255, 0, 0, 255, 0, 0]), planar: 1)
        try assertRGB(planar, expected: expected)
    }

    func testYBRFullIsConvertedToRGB() throws {
        let url = try fixture(photo: "YBR_FULL", samples: 3, pixels: Data([0, 128, 128, 255, 128, 128]))
        // Integer YBR conversion can differ from ideal RGB by one level.
        try assertRGB(url, expected: [0, 0, 0, 255, 255, 255], tolerance: 1)
    }

    func testPaletteIndicesAreExpandedToRGB() throws {
        var palette = Data()
        for tag: UInt16 in [0x1101, 0x1102, 0x1103] {
            palette.append(element(0x0028, tag, "US", words([2, 0, 8])))
        }
        palette.append(element(0x0028, 0x1201, "OW", words([255, 0])))
        palette.append(element(0x0028, 0x1202, "OW", words([0, 255])))
        palette.append(element(0x0028, 0x1203, "OW", words([0, 0])))
        let url = try fixture(photo: "PALETTE COLOR", samples: 1, pixels: Data([0, 1]), extra: palette)
        try assertRGB(url, expected: [255, 0, 0, 0, 255, 0])
    }

    func testSixteenBitColorIsScaledToEightBitRGB() throws {
        let url = try fixture(photo: "RGB", samples: 3, pixels: words([65535, 0, 0, 0, 65535, 0]), bits: 16)
        try assertRGB(url, expected: [255, 0, 0, 0, 255, 0])
    }

    func testColorFramesRetainFrameOrder() throws {
        let expected: [UInt8] = [255, 0, 0, 0, 255, 0]
        let url = try fixture(photo: "RGB", samples: 3, pixels: Data(expected), columns: 1, frames: 2)
        try assertRGB(url, expected: expected, width: 1)
    }

    func testCachedColorObjectSupportsConcurrentRawReadsAndRendering() throws {
        let expected = Data((0..<(64 * 64 * 3)).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let url = try fixture(photo: "RGB", samples: 3, pixels: expected, columns: 64, rows: 64)
        let object = try XCTUnwrap(DCMTKImageObject(path: url.path))
        let lock = NSLock()
        var failures: [String] = []

        // Prefetch reads and foreground rendering share cached decoder objects.
        // Both operations use DCMTK's mutable output buffer for color images.
        DispatchQueue.concurrentPerform(iterations: 128) { iteration in
            autoreleasepool {
                var width = 0, height = 0, depth = 0, samples = 0
                var signed: ObjCBool = false
                let raw = object.getRawDataWidth(&width, height: &height, bitDepth: &depth,
                                                samples: &samples, isSigned: &signed)
                let image = object.renderImage(withWidth: 0, height: 0,
                                               ww: Double(128 + iteration), wc: Double(iteration))
                let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let rendered = cgImage?.dataProvider?.data as Data?
                _ = object.getWindowWidth()
                _ = object.getWindowCenter()
                if raw != expected || rendered != expected || width != 64 || height != 64 || depth != 8 || samples != 3 {
                    lock.lock()
                    failures.append("Concurrent decode/render \(iteration) changed the RGB pixels")
                    lock.unlock()
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testGrayscaleRetainsSignedModalityValuesAndThirtyTwoBitRange() throws {
        let url = try fixture(photo: "MONOCHROME2", samples: 1, pixels: words([0, 65535]),
                              bits: 16, slope: "2", intercept: "-1024")
        let object = try XCTUnwrap(DCMTKImageObject(path: url.path))
        var w = 0, h = 0, bits = 0, samples = 0
        var signed: ObjCBool = false
        let raw = try XCTUnwrap(object.getRawDataWidth(&w, height: &h, bitDepth: &bits,
                                                      samples: &samples, isSigned: &signed))
        XCTAssertEqual(bits, 32)
        XCTAssertEqual(samples, 1)
        XCTAssertTrue(signed.boolValue)
        XCTAssertEqual(raw.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }, [-1024, 130046])
        XCTAssertEqual(DCMTKHelper.getRawPixelData(url.path, width: &w, height: &h,
                                                  bitDepth: &bits, samples: &samples, isSigned: &signed), raw)
    }

    func testMPRRejectsColorAndMixedGrayscaleColorVolumes() throws {
        let gray = try fixture(photo: "MONOCHROME2", samples: 1, pixels: words([100, 200]), bits: 16)
        let color = try fixture(photo: "RGB", samples: 3, pixels: Data([255, 0, 0, 0, 255, 0]))
        func context(_ url: URL, z: Double) -> DicomImageContext {
            DicomImageContext(url: url, sopInstanceUID: "1.2.3.\(Int(z))", seriesUID: "test",
                              seriesDescription: "Synthetic", instanceNumber: Int(z), seriesNumber: 1,
                              zLocation: z, imagePosition: SIMD3<Double>(0, 0, z),
                              imageOrientation: [1, 0, 0, 0, 1, 0], pixelSpacing: SIMD2<Double>(1, 1),
                              sliceThickness: 1, spacingBetweenSlices: 1, frameOfReferenceUID: "1.2.3",
                              studyInstanceUID: "1.2.4", numberOfFrames: 1)
        }
        for first in [gray, color] {
            let series = DicomSeries(id: "test", seriesNumber: 1, seriesDescription: "Synthetic",
                                     images: [context(first, z: 0), context(color, z: 1)])
            XCTAssertThrowsError(try VolumeBuilder.build(series: series, rawDataCache: NSCache(), dcmtkCache: NSCache())) { error in
                guard case VolumeBuilderError.unsupportedColorImages = error else {
                    XCTFail("Expected an explicit color-volume rejection, got \(error)")
                    return
                }
            }
        }
    }
}
