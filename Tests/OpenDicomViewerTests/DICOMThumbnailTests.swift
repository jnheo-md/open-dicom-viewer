import AppKit
import Foundation
import Testing
@testable import OpenDicomViewer

private func thumbnailContext(_ name: String, instance: Int = 1, url: URL? = nil) -> DicomImageContext {
    DicomImageContext(url: url ?? URL(fileURLWithPath: "/synthetic/\(name).dcm"), sopInstanceUID: "1.2.3.\(instance)",
                      seriesUID: "thumbnail-series", seriesDescription: "Synthetic", instanceNumber: instance,
                      seriesNumber: 1, zLocation: nil, imagePosition: nil, imageOrientation: nil,
                      pixelSpacing: nil, sliceThickness: nil, spacingBetweenSlices: nil,
                      frameOfReferenceUID: nil, studyInstanceUID: nil, numberOfFrames: 1)
}

private func thumbnailSeries(_ images: [DicomImageContext]) -> DicomSeries {
    DicomSeries(id: "thumbnail-series", seriesNumber: 1, seriesDescription: "Synthetic", images: images)
}

private func thumbnailText(_ element: UInt16, _ text: String) -> DicomElement {
    DicomElement(tag: DicomTag(group: 0x0028, element: element), vr: .DS,
                 length: text.utf8.count, data: Data(text.utf8))
}

private func thumbnailWords(_ values: [UInt16]) -> Data {
    Data(values.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
}

private func thumbnailPixels(_ image: NSImage) throws -> [UInt8] {
    let source = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let bitmap = try #require(CGContext(data: nil, width: source.width, height: source.height,
        bitsPerComponent: 8, bytesPerRow: source.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    bitmap.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    let bytes = try #require(bitmap.data)
    return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: source.width * source.height * 4))
}

private final class ThumbnailProbe {
    private let lock = NSLock()
    private var capturedURLs: [URL] = []
    let gate: DispatchSemaphore?
    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return capturedURLs
    }

    init(blocked: Bool = false) { gate = blocked ? DispatchSemaphore(value: 0) : nil }

    func render(_ context: DicomImageContext) -> NSImage? {
        lock.lock()
        capturedURLs.append(context.url)
        lock.unlock()
        gate?.wait()
        return NSImage(size: NSSize(width: 20, height: 20))
    }
}

@Suite(.serialized)
@MainActor
struct DICOMThumbnailTests {
    private func eventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            if Date() >= deadline {
                Issue.record("Timed out waiting for thumbnail state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test
    func storedCTUsesRescaleAndFirstWindowBeforeEightBitConversion() throws {
        let metadata = DICOMThumbnailRenderer.Metadata(elements: [
            thumbnailText(0x1050, "40\\600"), thumbnailText(0x1051, "80\\2800"),
            thumbnailText(0x1052, "-1024"), thumbnailText(0x1053, "1")
        ])
        #expect(metadata.window?.width == 80)
        #expect(metadata.window?.center == 40)
        let image = try #require(DICOMThumbnailRenderer.renderStoredPixels(
            data: thumbnailWords([0, 1024, 1064, 1104, 65535]), width: 5, height: 1,
            bitDepth: 16, samples: 1, signed: false, metadata: metadata))
        let pixels = try thumbnailPixels(image)
        #expect(pixels[0] == 0)
        // 40 HU must remain visibly mid-gray despite air and high-valued outliers.
        #expect(pixels[8] > 90 && pixels[8] < 240)
        #expect(pixels[12] == 255)
        #expect(pixels[16] == 255)
    }

    @Test
    func nativeDICOMThumbnailAppliesHeaderWindowToRescaledCT() throws {
        func element(_ group: UInt16, _ tag: UInt16, _ vr: String, _ content: Data) -> Data {
            var result = thumbnailWords([group, tag]) + Data(vr.utf8)
            if vr == "OW" {
                result += thumbnailWords([0])
                var length = UInt32(content.count).littleEndian
                result += withUnsafeBytes(of: &length) { Data($0) }
            } else { result += thumbnailWords([UInt16(content.count)]) }
            return result + content
        }
        func text(_ content: String) -> Data {
            var data = Data(content.utf8)
            if data.count % 2 != 0 { data.append(32) }
            return data
        }
        var file = Data(count: 128) + Data("DICM".utf8)
        file += element(0x0002, 0x0010, "UI", text("1.2.840.10008.1.2.1"))
        file += element(0x0008, 0x0016, "UI", text("1.2.840.10008.5.1.4.1.1.2"))
        file += element(0x0028, 0x0002, "US", thumbnailWords([1]))
        file += element(0x0028, 0x0004, "CS", text("MONOCHROME2"))
        file += element(0x0028, 0x0010, "US", thumbnailWords([1]))
        file += element(0x0028, 0x0011, "US", thumbnailWords([5]))
        let pixelFormat: [(UInt16, UInt16)] = [(0x0100, 16), (0x0101, 16), (0x0102, 15), (0x0103, 0)]
        for (tag, value) in pixelFormat {
            file += element(0x0028, tag, "US", thumbnailWords([value]))
        }
        file += element(0x0028, 0x1050, "DS", text("40"))
        file += element(0x0028, 0x1051, "DS", text("80"))
        file += element(0x0028, 0x1052, "DS", text("-1024"))
        file += element(0x0028, 0x1053, "DS", text("1"))
        file += element(0x7fe0, 0x0010, "OW", thumbnailWords([0, 1024, 1064, 1104, 65535]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(DICOMThumbnailRenderer.render(thumbnailContext("ct", url: url)))
        let pixels = try thumbnailPixels(image)
        #expect(pixels[0] == 0)
        #expect(pixels[8] > 90 && pixels[8] < 240)
        #expect(pixels[12] == 255)
    }

    @Test
    func percentileFallbackExcludesPaddingAndIsolatedHotPixels() {
        let data = thumbnailWords(Array(repeating: 0, count: 500) + Array(repeating: 40, count: 99)
                                  + Array(repeating: 80, count: 99) + [65535])
        let window = DICOMThumbnailRenderer.robustWindow(data: data, bitDepth: 16, signed: false, padding: 0)
        #expect(window.width == 40)
        #expect(window.center == 60)
    }

    @Test
    func colorSurvivesThumbnailRenderingAndResize() throws {
        let metadata = DICOMThumbnailRenderer.Metadata(elements: [])
        let image = try #require(DICOMThumbnailRenderer.renderStoredPixels(
            data: Data([255, 0, 0, 0, 255, 0]), width: 2, height: 1, bitDepth: 8,
            samples: 3, signed: false, metadata: metadata))
        let resized = try #require(DICOMThumbnailRenderer.resized(image, maximumPixelSize: 96))
        let pixels = try thumbnailPixels(resized)
        #expect(Array(pixels[0..<3]) == [255, 0, 0])
        #expect(Array(pixels[4..<7]) == [0, 255, 0])
        #expect(resized.size == NSSize(width: 2, height: 1))
    }

    @Test
    func twelveBitColorUsesStoredPrecisionWithinSixteenBitBuffer() throws {
        let metadata = DICOMThumbnailRenderer.Metadata(elements: [
            DicomElement(tag: DicomTag(group: 0x0028, element: 0x0101), vr: .US,
                         length: 2, data: thumbnailWords([12]))
        ])
        let image = try #require(DICOMThumbnailRenderer.renderStoredPixels(
            data: thumbnailWords([4095, 0, 0, 0, 4095, 0]), width: 2, height: 1,
            bitDepth: 16, samples: 3, signed: false, metadata: metadata))
        let pixels = try thumbnailPixels(image)
        #expect(Array(pixels[0..<3]) == [255, 0, 0])
        #expect(Array(pixels[4..<7]) == [0, 255, 0])
    }

    @Test
    func signedPixelPaddingIsDecodedAsSigned() {
        let metadata = DICOMThumbnailRenderer.Metadata(elements: [
            DicomElement(tag: DicomTag(group: 0x0028, element: 0x0120), vr: .SS,
                         length: 2, data: thumbnailWords([UInt16(bitPattern: -2000)]))
        ])
        #expect(metadata.paddingValue == -2000)
    }

    @Test
    func missingOrTruncatedPixelBuffersFailExplicitly() {
        let metadata = DICOMThumbnailRenderer.Metadata(elements: [])
        #expect(DICOMThumbnailRenderer.renderStoredPixels(data: Data([0, 1]), width: 2, height: 2,
            bitDepth: 16, samples: 1, signed: false, metadata: metadata) == nil)
    }

    @Test
    func pendingThumbnailRequestsAreDeduplicated() async throws {
        let probe = ThumbnailProbe(blocked: true)
        defer { probe.gate?.signal() }
        let model = DICOMModel(recordsSystemRecentDocuments: false, thumbnailRenderer: probe.render)
        let series = thumbnailSeries([thumbnailContext("one")])
        model.allSeries = [series]
        model.requestSeriesThumbnail(for: series)
        model.requestSeriesThumbnail(for: series)
        #expect(model.seriesThumbnailStates[series.id] == .loading)
        try await eventually { probe.urls.count == 1 }
        probe.gate?.signal()
        try await eventually { model.seriesThumbnailStates[series.id] == .ready }
        #expect(probe.urls.count == 1)
        #expect(model.seriesThumbnails[series.id] != nil)
    }

    @Test
    func failedThumbnailRequiresExplicitRetry() async throws {
        let model = DICOMModel(recordsSystemRecentDocuments: false, thumbnailRenderer: { _ in nil })
        let series = thumbnailSeries([thumbnailContext("missing")])
        model.allSeries = [series]
        model.requestSeriesThumbnail(for: series)
        try await eventually { model.seriesThumbnailStates[series.id] == .failed }
        model.requestSeriesThumbnail(for: series)
        #expect(model.seriesThumbnailStates[series.id] == .failed)
        model.requestSeriesThumbnail(for: series, retry: true)
        #expect(model.seriesThumbnailStates[series.id] == .loading)
        try await eventually { model.seriesThumbnailStates[series.id] == .failed }
        #expect(model.seriesThumbnails[series.id] == nil)
    }

    @Test
    func provisionalThumbnailIsRefreshedOnlyAfterScanningFinishes() async throws {
        let probe = ThumbnailProbe()
        let model = DICOMModel(recordsSystemRecentDocuments: false, thumbnailRenderer: probe.render)
        let first = thumbnailContext("first", instance: 1)
        let middle = thumbnailContext("middle", instance: 2)
        let last = thumbnailContext("last", instance: 3)
        model.isScanning = true
        model.allSeries = [thumbnailSeries([first])]
        model.requestSeriesThumbnail(for: model.allSeries[0])
        try await eventually { model.seriesThumbnailStates["thumbnail-series"] == .ready }
        model.allSeries = [thumbnailSeries([first, middle, last])]
        model.requestSeriesThumbnail(for: model.allSeries[0])
        #expect(probe.urls == [first.url])
        model.isScanning = false
        model.requestSeriesThumbnail(for: model.allSeries[0])
        try await eventually { model.seriesThumbnailStates["thumbnail-series"] == .ready && probe.urls.count == 2 }
        #expect(probe.urls == [first.url, middle.url])
    }

    @Test
    func oldThumbnailCompletionCannotRepopulateANewSession() async throws {
        let probe = ThumbnailProbe(blocked: true)
        defer { probe.gate?.signal() }
        let model = DICOMModel(recordsSystemRecentDocuments: false, thumbnailRenderer: probe.render)
        let series = thumbnailSeries([thumbnailContext("old")])
        model.allSeries = [series]
        model.requestSeriesThumbnail(for: series)
        try await eventually { probe.urls.count == 1 }
        model.load(url: URL(fileURLWithPath: "/missing/\(UUID().uuidString)"))
        probe.gate?.signal()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.seriesThumbnailStates.isEmpty)
        #expect(model.seriesThumbnails.isEmpty)
    }
}
