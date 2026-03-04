import Foundation
import Testing
import simd
@testable import OpenDicomViewer

private func imageContext(orientation: [Double]) -> DicomImageContext {
    DicomImageContext(
        url: URL(fileURLWithPath: "/tmp/test.dcm"),
        seriesUID: "series-1",
        seriesDescription: "test",
        instanceNumber: 1,
        seriesNumber: 1,
        zLocation: nil,
        imagePosition: SIMD3<Double>(0, 0, 0),
        imageOrientation: orientation,
        pixelSpacing: SIMD2<Double>(1, 1),
        sliceThickness: 1.0,
        spacingBetweenSlices: 1.0,
        frameOfReferenceUID: nil,
        studyInstanceUID: nil
    )
}

@Test
func crossProduct() {
    let a = SIMD3<Double>(1, 0, 0)
    let b = SIMD3<Double>(0, 1, 0)
    #expect(OpenDicomViewer.cross(a, b) == SIMD3<Double>(0, 0, 1))
}

@Test
func dominantAxisAxial() {
    let series = DicomSeries(
        id: "axial",
        seriesNumber: 1,
        seriesDescription: "axial",
        images: [imageContext(orientation: [1, 0, 0, 0, 1, 0])]
    )
    #expect(series.dominantAxis == .axial)
}

@Test
func dominantAxisCoronal() {
    let series = DicomSeries(
        id: "coronal",
        seriesNumber: 2,
        seriesDescription: "coronal",
        images: [imageContext(orientation: [1, 0, 0, 0, 0, 1])]
    )
    #expect(series.dominantAxis == .coronal)
}

@Test
func dominantAxisSagittal() {
    let series = DicomSeries(
        id: "sagittal",
        seriesNumber: 3,
        seriesDescription: "sagittal",
        images: [imageContext(orientation: [0, 1, 0, 0, 0, 1])]
    )
    #expect(series.dominantAxis == .sagittal)
}
