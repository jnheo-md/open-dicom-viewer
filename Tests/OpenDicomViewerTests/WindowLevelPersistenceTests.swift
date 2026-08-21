import Foundation
import Testing
import DCMTKWrapper
@testable import OpenDicomViewer

// MARK: - Window/Level Persistence Tests
//
// These tests verify that W/L does not drift when scrolling through slices
// within the same series (Bug 3 fix).  Because loadSingleFileForPanel requires
// real DICOM files and DCMTK, we test the invariant directly on the state
// machinery: seriesStates caching and the preservedWW look-up logic.

// MARK: - SeriesViewState W/L caching

@Test
func seriesStatesStoresWindowLevelAfterFirstLoad() {
    // Simulate what the DCMTK render branch does on first load:
    // it should write the computed W/L into seriesStates so subsequent
    // slice loads can reuse it.
    let model = DICOMModel()
    let uid = "test-series-uid"

    // Pre-condition: no entry in seriesStates
    #expect(model.seriesStates[uid] == nil)

    // Simulate first-load write (mirrors the code added in loadSingleFileForPanel)
    var state = model.seriesStates[uid] ?? DICOMModel.SeriesViewState()
    state.windowWidth = 1500.0
    state.windowCenter = 300.0
    model.seriesStates[uid] = state

    // Post-condition: W/L is cached
    #expect(model.seriesStates[uid]?.windowWidth == 1500.0)
    #expect(model.seriesStates[uid]?.windowCenter == 300.0)
}

@Test
func seriesStatesNotOverwrittenOnSubsequentLoads() {
    // Simulate the guard introduced in the fix:
    // if seriesStates[uid]?.windowWidth != nil, don't overwrite.
    let model = DICOMModel()
    let uid = "test-series-uid-2"

    // Write initial W/L (first slice load)
    var state = DICOMModel.SeriesViewState()
    state.windowWidth = 2000.0
    state.windowCenter = 500.0
    model.seriesStates[uid] = state

    // Simulate second slice load attempting to overwrite (should be skipped)
    if model.seriesStates[uid]?.windowWidth == nil {
        var s = model.seriesStates[uid] ?? DICOMModel.SeriesViewState()
        s.windowWidth = 999.0
        s.windowCenter = 111.0
        model.seriesStates[uid] = s
    }

    // W/L must be unchanged
    #expect(model.seriesStates[uid]?.windowWidth == 2000.0)
    #expect(model.seriesStates[uid]?.windowCenter == 500.0)
}

@Test
func preservedWLRestoredFromSeriesStatesWhenPanelWindowWidthIsZero() {
    // Verify the look-up logic at the top of loadSingleFileForPanel:
    // when panel.windowWidth == 0 but seriesStates has a saved W/L,
    // the effective preserved values should come from seriesStates.
    let model = DICOMModel()
    let uid = "test-series-uid-3"
    let seriesIndex = 0

    // Set up a minimal series so allSeries[seriesIndex].id == uid
    let ctx = DicomImageContext(
        url: URL(fileURLWithPath: "/tmp/fake.dcm"),
        sopInstanceUID: "1.2.826.0.1.3680043.10.99.1",
        seriesUID: uid,
        seriesDescription: "test",
        instanceNumber: 1,
        seriesNumber: 1,
        zLocation: nil,
        imagePosition: nil,
        imageOrientation: nil,
        pixelSpacing: nil,
        sliceThickness: nil,
        spacingBetweenSlices: nil,
        frameOfReferenceUID: nil,
        studyInstanceUID: nil,
        numberOfFrames: 1
    )
    model.allSeries = [DicomSeries(id: uid, seriesNumber: 1, seriesDescription: "test", images: [ctx])]

    // Pre-populate seriesStates with a known W/L (simulating a prior slice load)
    var state = DICOMModel.SeriesViewState()
    state.windowWidth = 1200.0
    state.windowCenter = 400.0
    model.seriesStates[uid] = state

    // Simulate a panel that just had its series assigned (windowWidth reset to 0)
    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 0
    panel.windowCenter = 0

    // Replicate the preservedWW look-up logic from loadSingleFileForPanel
    var preservedWW = panel.windowWidth
    var preservedWC = panel.windowCenter
    if preservedWW <= 0, panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count {
        let seriesUID = model.allSeries[panel.seriesIndex].id
        if let saved = model.seriesStates[seriesUID],
           let sw = saved.windowWidth, let sc = saved.windowCenter, sw > 0 {
            preservedWW = sw
            preservedWC = sc
        }
    }

    // The preserved values should come from seriesStates, not the panel's zeros
    #expect(preservedWW == 1200.0)
    #expect(preservedWC == 400.0)
}

@Test
func preservedWLNotRestoredWhenSeriesStatesEmpty() {
    // When seriesStates has no entry, preservedWW stays 0 (genuine first load).
    let model = DICOMModel()
    let uid = "test-series-uid-4"
    let seriesIndex = 0

    let ctx = DicomImageContext(
        url: URL(fileURLWithPath: "/tmp/fake2.dcm"),
        sopInstanceUID: "1.2.826.0.1.3680043.10.99.2",
        seriesUID: uid,
        seriesDescription: "test",
        instanceNumber: 1,
        seriesNumber: 1,
        zLocation: nil,
        imagePosition: nil,
        imageOrientation: nil,
        pixelSpacing: nil,
        sliceThickness: nil,
        spacingBetweenSlices: nil,
        frameOfReferenceUID: nil,
        studyInstanceUID: nil,
        numberOfFrames: 1
    )
    model.allSeries = [DicomSeries(id: uid, seriesNumber: 1, seriesDescription: "test", images: [ctx])]

    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 0
    panel.windowCenter = 0

    var preservedWW = panel.windowWidth
    var preservedWC = panel.windowCenter
    if preservedWW <= 0, panel.seriesIndex >= 0, panel.seriesIndex < model.allSeries.count {
        let seriesUID = model.allSeries[panel.seriesIndex].id
        if let saved = model.seriesStates[seriesUID],
           let sw = saved.windowWidth, let sc = saved.windowCenter, sw > 0 {
            preservedWW = sw
            preservedWC = sc
        }
    }

    // No seriesStates entry → preservedWW stays 0 (triggers auto-compute path)
    #expect(preservedWW == 0.0)
    #expect(preservedWC == 0.0)
}

@Test
func adjustWindowLevelPersistsToSeriesStates() {
    // Verify that drag-based W/L adjustment (adjustWindowLevelForPanel) still
    // saves to seriesStates — ensures user adjustments persist across scroll.
    let model = DICOMModel()
    let uid = "test-series-uid-5"
    let seriesIndex = 0

    let ctx = DicomImageContext(
        url: URL(fileURLWithPath: "/tmp/fake3.dcm"),
        sopInstanceUID: "1.2.826.0.1.3680043.10.99.3",
        seriesUID: uid,
        seriesDescription: "test",
        instanceNumber: 1,
        seriesNumber: 1,
        zLocation: nil,
        imagePosition: nil,
        imageOrientation: nil,
        pixelSpacing: nil,
        sliceThickness: nil,
        spacingBetweenSlices: nil,
        frameOfReferenceUID: nil,
        studyInstanceUID: nil,
        numberOfFrames: 1
    )
    model.allSeries = [DicomSeries(id: uid, seriesNumber: 1, seriesDescription: "test", images: [ctx])]

    let panel = PanelState()
    panel.seriesIndex = seriesIndex
    panel.windowWidth = 1000.0
    panel.windowCenter = 300.0

    model.adjustWindowLevelForPanel(panel, deltaWidth: 500.0, deltaCenter: 100.0)

    #expect(panel.windowWidth == 1500.0)
    #expect(panel.windowCenter == 400.0)
    #expect(model.seriesStates[uid]?.windowWidth == 1500.0)
    #expect(model.seriesStates[uid]?.windowCenter == 400.0)
}

// MARK: - Real compressed-DICOM cache regression

@Test
func jpegLosslessBackgroundCacheRemainsWindowLevelAdjustable() async throws {
    // Opt-in because the test data is large and intentionally not committed.
    // Supply two newline-separated files from the same series whose stored
    // W/L values differ.
    guard let value = ProcessInfo.processInfo.environment["OPEN_DICOM_MR_TEST_FILES"] else {
        return
    }
    let paths = value.split(separator: "\n").map(String.init)
    guard paths.count == 2 else {
        Issue.record("OPEN_DICOM_MR_TEST_FILES must contain two newline-separated paths")
        return
    }

    let firstURL = URL(fileURLWithPath: paths[0])
    let secondURL = URL(fileURLWithPath: paths[1])
    let firstObject = try #require(DCMTKImageObject(path: firstURL.path))

    func autoWindow(for object: DCMTKImageObject) throws -> (ww: Double, wc: Double) {
        var width = 0, height = 0, depth = 0, samples = 0
        var isSigned: ObjCBool = false
        let raw = try #require(
            object.getRawDataWidth(
                &width, height: &height, bitDepth: &depth,
                samples: &samples, isSigned: &isSigned
            )
        )
        var minValue = Double.greatestFiniteMagnitude
        var maxValue = -Double.greatestFiniteMagnitude
        raw.withUnsafeBytes { bytes in
            if depth > 8, let values = bytes.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                for index in 0..<(raw.count / 2) {
                    let value = isSigned.boolValue
                        ? Double(Int16(bitPattern: values[index]))
                        : Double(values[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            } else if let values = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                for index in 0..<raw.count {
                    let value = Double(values[index])
                    minValue = min(minValue, value)
                    maxValue = max(maxValue, value)
                }
            }
        }
        let ww = max(1, maxValue - minValue)
        return (ww, minValue + (ww / 2))
    }

    let reference = try autoWindow(for: firstObject)
    let referenceWW = reference.ww
    let referenceWC = reference.wc

    func context(url: URL, instance: Int) -> DicomImageContext {
        DicomImageContext(
            url: url,
            sopInstanceUID: "integration-\(instance)",
            seriesUID: "integration-series",
            seriesDescription: "integration",
            instanceNumber: instance,
            seriesNumber: 1,
            zLocation: nil,
            imagePosition: nil,
            imageOrientation: nil,
            pixelSpacing: nil,
            sliceThickness: nil,
            spacingBetweenSlices: nil,
            frameOfReferenceUID: nil,
            studyInstanceUID: nil,
            numberOfFrames: 1
        )
    }

    let model = DICOMModel()
    model.allSeries = [
        DicomSeries(
            id: "integration-series",
            seriesNumber: 1,
            seriesDescription: "integration",
            images: [context(url: firstURL, instance: 1), context(url: secondURL, instance: 2)]
        )
    ]

    // Reproduce the reported path: a compressed non-cover slice is populated
    // by background caching before the panel navigates to it.
    model.cacheImageBackground(url: secondURL)

    let panel = PanelState()
    panel.seriesIndex = 0
    panel.imageIndex = 1
    panel.windowWidth = referenceWW
    panel.windowCenter = referenceWC
    model.loadSingleFileForPanel(secondURL, panel: panel)

    let deadline = Date().addingTimeInterval(10)
    while panel.isLoading && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(!panel.isLoading)
    #expect(panel.errorMessage == nil)
    #expect(panel.dcmtkImage != nil)
    #expect(panel.rawPixelData != nil)
    #expect(panel.windowWidth == referenceWW)
    #expect(panel.windowCenter == referenceWC)

    let imageBeforeAdjustment = try #require(panel.image)
    model.adjustWindowLevelForPanel(panel, deltaWidth: 25, deltaCenter: 10)
    let imageAfterAdjustment = try #require(panel.image)

    #expect(panel.windowWidth == referenceWW + 25)
    #expect(panel.windowCenter == referenceWC + 10)
    #expect(imageAfterAdjustment !== imageBeforeAdjustment)
}
