import Foundation
import Testing
@testable import OpenDicomViewer

/// Synthetic 2×2 CT images keep opening and cancellation tests independent of
/// patient datasets, mounted drives, and external fixture generators.
private struct OpeningFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dicom-opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func image(_ path: String, series: Int = 1, instance: Int = 1, pixel: UInt16 = 100) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func word(_ value: UInt16) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        func text(_ value: String, nul: Bool = false) -> Data {
            var data = Data(value.utf8)
            if data.count % 2 != 0 { data.append(nul ? 0 : 32) }
            return data
        }
        func element(_ group: UInt16, _ tag: UInt16, _ vr: String, _ value: Data) -> Data {
            var data = word(group) + word(tag) + Data(vr.utf8)
            if vr == "OW" {
                data += word(0)
                var length = UInt32(value.count).littleEndian
                data += withUnsafeBytes(of: &length) { Data($0) }
            } else {
                data += word(UInt16(value.count))
            }
            return data + value
        }
        var data = Data(count: 128) + Data("DICM".utf8)
        data += element(0x0002, 0x0010, "UI", text("1.2.840.10008.1.2.1", nul: true))
        data += element(0x0008, 0x0016, "UI", text("1.2.840.10008.5.1.4.1.1.2", nul: true))
        data += element(0x0008, 0x0018, "UI", text("1.2.826.0.1.3680043.10.99.\(series).\(instance)", nul: true))
        data += element(0x0008, 0x0060, "CS", text("CT"))
        data += element(0x0008, 0x103e, "LO", text("Synthetic series \(series)"))
        data += element(0x0020, 0x000e, "UI", text("1.2.826.0.1.3680043.10.99.\(series)", nul: true))
        data += element(0x0020, 0x0011, "IS", text("\(series)"))
        data += element(0x0020, 0x0013, "IS", text("\(instance)"))
        data += element(0x0028, 0x0002, "US", word(1))
        data += element(0x0028, 0x0004, "CS", text("MONOCHROME2"))
        data += element(0x0028, 0x0010, "US", word(2))
        data += element(0x0028, 0x0011, "US", word(2))
        data += element(0x0028, 0x0100, "US", word(16))
        data += element(0x0028, 0x0101, "US", word(16))
        data += element(0x0028, 0x0102, "US", word(15))
        data += element(0x0028, 0x0103, "US", word(0))
        data += element(0x0028, 0x1050, "DS", text("200"))
        data += element(0x0028, 0x1051, "DS", text("400"))
        data += element(0x7fe0, 0x0010, "OW", word(pixel) + word(pixel + 1) + word(pixel + 2) + word(pixel + 3))
        try data.write(to: url)
        return url.standardizedFileURL
    }
}

@Suite(.serialized)
@MainActor
struct DICOMOpeningTests {
    private func model() -> DICOMModel {
        let defaults = UserDefaults(suiteName: "DICOMOpeningTests.\(UUID().uuidString)")!
        return DICOMModel(recentHistory: RecentOpenHistory(defaults: defaults), recordsSystemRecentDocuments: false)
    }

    private func waitForOpen(_ model: DICOMModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning || model.activePanel?.isLoading == true {
            if Date() >= deadline {
                Issue.record("Timed out opening synthetic DICOM files")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func selectedURL(_ model: DICOMModel) -> URL? {
        guard let panel = model.activePanel,
              model.allSeries.indices.contains(panel.seriesIndex),
              model.allSeries[panel.seriesIndex].images.indices.contains(panel.imageIndex) else { return nil }
        return model.allSeries[panel.seriesIndex].images[panel.imageIndex].url
    }

    private func firstPixelValue(_ optionalPanel: PanelState?) throws -> Double {
        let panel = try #require(optionalPanel)
        let data = try #require(panel.rawPixelData)
        #expect(panel.samples == 1)
        #expect(panel.imageWidth == 2)
        #expect(panel.imageHeight == 2)
        let bytesPerPixel = panel.bitDepth / 8
        #expect([1, 2, 4].contains(bytesPerPixel))
        #expect(data.count == 4 * bytesPerPixel)
        // DCMTK may choose 8-bit intermediate storage for small scalar values,
        // even when the source uses 16 allocated bits. Validate decoded values
        // against the returned format rather than the on-disk allocation.
        switch panel.bitDepth {
        case 8:
            let value = try #require(data.first)
            return panel.isSigned ? Double(Int8(bitPattern: value)) : Double(value)
        case 16:
            let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
            return panel.isSigned ? Double(Int16(bitPattern: value)) : Double(value)
        case 32:
            let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            return panel.isSigned ? Double(Int32(bitPattern: value)) : Double(value)
        default:
            Issue.record("Unsupported decoded scalar depth: \(panel.bitDepth)")
            return .nan
        }
    }

    private func expectRecentFile(_ model: DICOMModel, equals expectedURL: URL) throws {
        let urls = try #require(model.recentHistory.entries.first?.urls)
        #expect(urls.count == 1)
        let recentURL = try #require(urls.first)
        let recentID = try #require(recentURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
        let expectedID = try #require(expectedURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
        #expect(recentID.isEqual(expectedID))
    }

    private func finishQueuedDecode(_ panel: PanelState) {
        panel.loadingQueue.waitUntilAllOperationsAreFinished()
    }

    @Test
    func singleFileStaysSelectedWhileParentAndSubfoldersAreIndexed() async throws {
        let fixture = try OpeningFixture()
        defer { fixture.remove() }
        let chosen = try fixture.image("chosen.dcm", series: 9, instance: 250, pixel: 250)
        for index in 1...205 {
            _ = try fixture.image("nested/\(index).dcm", series: 9, instance: index)
        }
        _ = try fixture.image("earlier-series.dicom", series: 1)
        _ = try fixture.image("nested/deeper/extensionless", series: 2)
        let model = model()
        model.load(url: chosen)
        try await waitForOpen(model)

        #expect(model.allSeries.flatMap(\.images).count == 208)
        #expect(model.allSeries.count == 3)
        #expect(selectedURL(model) == chosen)
        #expect(model.activePanel?.imageIndex == 205)
        #expect(model.currentImageIndex == model.activePanel?.imageIndex)
        #expect(model.currentSeriesIndex == model.activePanel?.seriesIndex)
        #expect(model.activePanel?.image != nil)
        #expect(model.activePanel?.errorMessage == nil)
        #expect(try firstPixelValue(model.activePanel) == 250)
        try expectRecentFile(model, equals: chosen)
    }

    @Test
    func batchCombinesDisjointAndOverlappingRootsWithoutDuplicates() async throws {
        let fixture = try OpeningFixture()
        defer { fixture.remove() }
        let first = try fixture.image("one/chosen.dcm", series: 9, instance: 20, pixel: 200)
        _ = try fixture.image("one/sibling.dcm", series: 9, instance: 1)
        _ = try fixture.image("one/sub/deep.dcm", series: 2)
        let second = try fixture.image("two/image.dcm", series: 3)
        let model = model()
        model.load(urls: [first, fixture.root.appendingPathComponent("one"), second,
                          fixture.root.appendingPathComponent("one/sub"), first])
        try await waitForOpen(model)

        let images = model.allSeries.flatMap(\.images)
        #expect(images.count == 4)
        #expect(Set(images.map(\.url)).count == 4)
        #expect(selectedURL(model) == first)
        #expect(model.activePanel?.imageIndex == 1)
        #expect(try firstPixelValue(model.activePanel) == 200)
        #expect(model.recentHistory.entries.count == 1)
    }

    @Test
    func newOpenInvalidatesAnOlderScan() async throws {
        let old = try OpeningFixture()
        let current = try OpeningFixture()
        defer { old.remove(); current.remove() }
        for index in 1...205 { _ = try old.image("\(index).dcm", series: 1, instance: index) }
        let chosen = try current.image("current.dcm", series: 7, pixel: 222)
        let model = model()
        model.load(url: old.root)
        model.load(url: chosen)
        try await waitForOpen(model)
        try await Task.sleep(for: .milliseconds(100))

        #expect(model.allSeries.flatMap(\.images).map(\.url) == [chosen])
        #expect(selectedURL(model) == chosen)
        #expect(try firstPixelValue(model.activePanel) == 222)
        #expect(model.activePanel?.errorMessage == nil)
        #expect(model.recentHistory.entries.count == 1)
        try expectRecentFile(model, equals: chosen)
    }

    @Test
    func completedOldDecodeCannotPublishItsQueuedErrorOverANewImage() async throws {
        let fixture = try OpeningFixture()
        defer { fixture.remove() }
        let chosen = try fixture.image("current.dcm", pixel: 123)
        let model = model()
        let panel = try #require(model.activePanel)
        model.loadSingleFileForPanel(fixture.root.appendingPathComponent("missing.dcm"), panel: panel)
        // Finish the old operation while the main actor cannot yet consume its
        // queued error. A subsequent request must invalidate that callback too.
        finishQueuedDecode(panel)
        model.loadSingleFileForPanel(chosen, panel: panel)
        try await waitForOpen(model)

        #expect(panel.image != nil)
        #expect(panel.errorMessage == nil)
        #expect(try firstPixelValue(panel) == 123)
    }

    @Test
    func unavailableAndEmptyLocationsShowAnErrorInTheViewer() async throws {
        let fixture = try OpeningFixture()
        defer { fixture.remove() }
        let model = model()
        model.load(url: fixture.root.appendingPathComponent("missing"))
        #expect(model.activePanel?.errorMessage == "File not accessible or does not exist.")
        #expect(!model.isLoading)
        #expect(!model.isScanning)
        model.load(url: fixture.root)
        try await waitForOpen(model)
        #expect(model.activePanel?.errorMessage == "No DICOM series found.")
        #expect(model.recentHistory.entries.isEmpty)
    }

    @Test
    func colorPixelsAreNotInterpretedAsQuantitativeMonochromeValues() {
        let model = model()
        let panel = PanelState()
        panel.samples = 3
        panel.bitDepth = 8
        panel.imageWidth = 2
        panel.imageHeight = 2
        panel.rawPixelData = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
        panel.windowWidth = 400
        panel.windowCenter = 40
        let rect = CGRect(x: 0, y: 0, width: 2, height: 2)
        #expect(model.computeROIStats(panel: panel, rect: rect) == nil)
        model.autoWindowLevelForPanelROI(panel, rect: rect)
        model.autoWindowLevelForPanel(panel)
        #expect(panel.windowWidth == 400)
        #expect(panel.windowCenter == 40)
    }

}
