// CrossReferenceOverlay.swift
// OpenDicomViewer
//
// Draws cross-reference lines on a panel showing where other panels' slice
// planes intersect the current image plane. Uses DICOM spatial metadata
// (ImagePositionPatient, ImageOrientationPatient, PixelSpacing) to compute
// the geometric intersection of two image planes in 3D patient space, then
// projects the result into 2D pixel coordinates.
//
// The overlay respects the panel's current zoom, pan, rotation, and flip
// transforms so lines stay aligned with the displayed image.
//
// Each panel gets a distinct color (blue, green, yellow, red) for its
// cross-reference line, drawn as a dashed stroke.

import SwiftUI

/// Draws cross-reference lines showing where other panels' slices intersect this panel's image plane.
struct CrossReferenceOverlay: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    /// Color per panel slot index
    static let panelColors: [Color] = [.blue, .green, .yellow, .red]

    var body: some View {
        GeometryReader { geo in
            ForEach(model.panels.filter { $0.id != panel.id }) { otherPanel in
                // Use a sub-view so SwiftUI observes otherPanel's @Published changes
                CrossRefLineView(
                    displayPanel: panel,
                    sourcePanel: otherPanel,
                    color: panelColor(for: otherPanel),
                    viewSize: geo.size
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func panelColor(for targetPanel: PanelState) -> Color {
        guard let index = model.panels.firstIndex(where: { $0.id == targetPanel.id }) else {
            return .white
        }
        return Self.panelColors[index % Self.panelColors.count]
    }

}

/// Sub-view that observes BOTH display and source panels so the line updates
/// when either panel scrolls (changes imagePositionPatient).
private struct CrossRefLineView: View {
    @ObservedObject var displayPanel: PanelState
    @ObservedObject var sourcePanel: PanelState
    let color: Color
    let viewSize: CGSize

    var body: some View {
        if let line = CrossReferenceOverlay.computeCrossReference(
            displayPanel: displayPanel, sourcePanel: sourcePanel
        ) {
            let p0 = pixelToScreen(line.startPixel)
            let p1 = pixelToScreen(line.endPixel)

            Path { path in
                path.move(to: p0)
                path.addLine(to: p1)
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            )
            .opacity(0.7)
        }
    }

    private func pixelToScreen(_ pixel: CGPoint) -> CGPoint {
        let imgW = CGFloat(max(1, displayPanel.imageWidth))
        let imgH = CGFloat(max(1, displayPanel.imageHeight))
        let vw = viewSize.width
        let vh = viewSize.height

        // Aspect-ratio-preserving fit (matches .scaleProportionallyUpOrDown)
        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        // Center-relative (transforms applied around view center)
        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        // Flip
        if displayPanel.isFlippedH { x = -x }
        if displayPanel.isFlippedV { y = -y }

        // Rotation (90° steps)
        let steps = displayPanel.rotationSteps % 4
        if steps > 0 {
            let angle = CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        // Zoom
        x *= displayPanel.scale
        y *= displayPanel.scale

        // Pan (translation is screen-space; Y is inverted between NSView Y-up and SwiftUI Y-down)
        x += displayPanel.translation.x
        y -= displayPanel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

extension CrossReferenceOverlay {

    // MARK: - Cross-Reference Geometry

    struct CrossReferenceLine {
        var startPixel: CGPoint
        var endPixel: CGPoint
    }

    /// Compute where `sourcePanel`'s slice plane intersects `displayPanel`'s image plane.
    /// Returns pixel coordinates in the display panel's image space, or nil if planes are parallel
    /// or spatial metadata is missing.
    static func computeCrossReference(
        displayPanel: PanelState,
        sourcePanel: PanelState
    ) -> CrossReferenceLine? {
        guard let posA = displayPanel.imagePositionPatient,
              let oriA = displayPanel.imageOrientationPatient, oriA.count == 6,
              let spacingA = displayPanel.pixelSpacing,
              let posB = sourcePanel.imagePositionPatient,
              let oriB = sourcePanel.imageOrientationPatient, oriB.count == 6
        else { return nil }

        // Display panel basis vectors
        let rowA = SIMD3<Double>(oriA[0], oriA[1], oriA[2])
        let colA = SIMD3<Double>(oriA[3], oriA[4], oriA[5])
        let normalA = cross(rowA, colA)

        // Source panel normal
        let rowB = SIMD3<Double>(oriB[0], oriB[1], oriB[2])
        let colB = SIMD3<Double>(oriB[3], oriB[4], oriB[5])
        let normalB = cross(rowB, colB)

        // Intersection line direction (cross product of normals)
        let lineDir = cross(normalA, normalB)
        let lineDirLen = length(lineDir)
        if lineDirLen < 1e-6 { return nil } // Parallel planes

        // Find a point on the intersection line
        // Project source origin onto display plane
        let originA = SIMD3<Double>(posA.0, posA.1, posA.2)
        let originB = SIMD3<Double>(posB.0, posB.1, posB.2)

        let diff = originB - originA

        // Project intersection onto display panel's 2D coordinate system
        // The intersection of plane B with plane A forms a line.
        // We need to find where this line is in A's image coordinates.

        // For the common orthogonal case (axial/sagittal/coronal),
        // the intersection is a straight line at a constant position along one axis.

        // Project source origin onto display panel axes (in mm)
        let u0 = dot(diff, rowA)  // mm along row direction
        let v0 = dot(diff, colA)  // mm along column direction

        // Project line direction onto display panel axes
        let du = dot(lineDir, rowA)
        let dv = dot(lineDir, colA)

        // Convert from mm to pixels
        // DICOM PixelSpacing: (row_spacing, col_spacing)
        //   row_spacing = distance between rows = mm per Y pixel step
        //   col_spacing = distance between columns = mm per X pixel step
        let rowSpacing = spacingA.0  // mm per pixel along column direction (Y)
        let colSpacing = spacingA.1  // mm per pixel along row direction (X)

        guard colSpacing > 0 && rowSpacing > 0 else { return nil }

        let u0px = u0 / colSpacing
        let v0px = v0 / rowSpacing
        let dupx = du / colSpacing
        let dvpx = dv / rowSpacing

        // Parameterize line: P(t) = (u0px + t*dupx, v0px + t*dvpx)
        // Clip to image bounds [0, width] x [0, height]
        let w = Double(displayPanel.imageWidth)
        let h = Double(displayPanel.imageHeight)

        guard w > 0 && h > 0 else { return nil }

        // Find t range where line is within bounds
        var tMin = -1e10
        var tMax = 1e10

        if abs(dupx) > 1e-10 {
            let t1 = (0 - u0px) / dupx
            let t2 = (w - u0px) / dupx
            let tLo = min(t1, t2)
            let tHi = max(t1, t2)
            tMin = max(tMin, tLo)
            tMax = min(tMax, tHi)
        } else if u0px < 0 || u0px > w {
            return nil // Line outside horizontal bounds
        }

        if abs(dvpx) > 1e-10 {
            let t1 = (0 - v0px) / dvpx
            let t2 = (h - v0px) / dvpx
            let tLo = min(t1, t2)
            let tHi = max(t1, t2)
            tMin = max(tMin, tLo)
            tMax = min(tMax, tHi)
        } else if v0px < 0 || v0px > h {
            return nil // Line outside vertical bounds
        }

        if tMin >= tMax { return nil }

        let startX = u0px + tMin * dupx
        let startY = v0px + tMin * dvpx
        let endX = u0px + tMax * dupx
        let endY = v0px + tMax * dvpx

        return CrossReferenceLine(
            startPixel: CGPoint(x: startX, y: startY),
            endPixel: CGPoint(x: endX, y: endY)
        )
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3<Double>(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func length(_ v: SIMD3<Double>) -> Double {
        sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }
}
