// MultiPanelContainer.swift
// OpenDicomViewer
//
// The main viewer area that arranges panels in a grid (1x1 to 2x2).
// Each panel is a self-contained DICOM image viewer with:
//   - Image display with aspect-ratio-preserving fit
//   - Mouse gesture handling: right-drag for W/L, scroll for navigation,
//     pinch-to-zoom, two-finger pan, click to activate
//   - Drag-and-drop series assignment from the sidebar
//   - Overlay layers: info strings, orientation labels, cross-reference
//     lines, ROI rectangle, cursor readout, cache progress bar
//   - Bottom toolbar: histogram, Auto W/L, ROI mode buttons
//
// Key types:
//   MultiPanelContainer      — Grid layout that creates PanelView per slot
//   PanelView                — Single panel: image + all overlays + gestures
//   InteractiveDICOMView     — NSViewRepresentable wrapping NSImageView with
//                              gesture recognizers for W/L, zoom, pan, scroll
//   PanelAdjustmentToolbar   — Bottom bar with histogram + Auto/ROI buttons
//   PanelHistogramView       — Miniature histogram with W/L window indicator

import SwiftUI
import QuartzCore

// MARK: - Multi-Panel Container

/// Arranges panels in a grid based on the current ViewerLayout.
struct MultiPanelContainer: View {
    @ObservedObject var model: DICOMModel
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        let layout = model.layout

        GeometryReader { geo in
            // Fullscreen mode: show only the fullscreen panel
            if let fsID = model.fullscreenPanelID,
               let fsPanel = model.panels.first(where: { $0.id == fsID }) {
                PanelView(
                    model: model,
                    panel: fsPanel,
                    isActive: true,
                    isFocused: $isFocused
                )
                .id(fsPanel.id)
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.toggleFullscreen(for: fsPanel)
                    }
                }
                .onTapGesture(count: 1) {
                    isFocused = true
                }
            } else {
                // Grid mode — compute exact cell size to guarantee equal panels
                let rows = layout.rows
                let cols = layout.columns
                let cellW = (geo.size.width - CGFloat(cols - 1)) / CGFloat(cols)
                let cellH = (geo.size.height - CGFloat(rows - 1)) / CGFloat(rows)

                VStack(spacing: 1) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(0..<cols, id: \.self) { col in
                                let index = row * cols + col
                                if index < model.panels.count {
                                    let panel = model.panels[index]
                                    PanelView(
                                        model: model,
                                        panel: panel,
                                        isActive: panel.id == model.activePanelID,
                                        isFocused: $isFocused
                                    )
                                    .frame(width: cellW, height: cellH)
                                    .id(panel.id)
                                    .onTapGesture(count: 2) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            model.toggleFullscreen(for: panel)
                                        }
                                    }
                                    .onTapGesture(count: 1) {
                                        model.activePanelID = panel.id
                                        isFocused = true
                                    }
                                } else {
                                    EmptyPanelView()
                                        .frame(width: cellW, height: cellH)
                                }
                            }
                        }
                    }
                }
                .background(Color(white: 0.15))
            }
        }
    }
}

// MARK: - Empty Panel View

struct EmptyPanelView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Drag a series here, or drop a DICOM folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Panel View

/// Individual panel — refactored from the original DetailView.
/// Each panel has its own image, histogram, scrollbar, W/L, zoom/pan state.
struct PanelView: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    let isActive: Bool
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image View
            if let image = panel.image {
                PanelInteractiveDICOMView(model: model, panel: panel, image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(0)
            } else if panel.errorMessage == nil && !panel.isLoading {
                if panel.seriesIndex >= 0 {
                    // Series assigned but no image yet
                    ProgressView()
                        .controlSize(.large)
                } else {
                    EmptyPanelView()
                }
            }

            // Volume mode toolbar (top-left)
            if panel.seriesIndex >= 0 && panel.image != nil {
                VStack {
                    HStack {
                        VolumeToolbar(model: model, panel: panel)
                            .padding(6)
                        Spacer()
                    }
                    Spacer()
                }
                .zIndex(5)
            }

            // Cross-reference lines overlay
            if panel.image != nil && model.panels.count > 1 && model.showCrossReference {
                CrossReferenceOverlay(model: model, panel: panel)
                    .zIndex(10)
            }

            // ROI rectangle overlay
            if panel.image != nil, let roiRect = panel.roiRect {
                ROIOverlay(panel: panel, roiRect: roiRect)
                    .zIndex(12)
            }

            // Orientation labels (A/P/R/L/S/I)
            if panel.image != nil {
                OrientationLabelsOverlay(orientation: panel.imageOrientationPatient)
                    .zIndex(15)
            }

            // Cursor info (HU readout)
            if panel.showCursorInfo {
                CursorInfoOverlay(panel: panel)
                    .zIndex(55)
            }

            // Error Overlay
            if let error = panel.errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).font(.caption)
                }
                .background(Color.black.opacity(0.8))
                .zIndex(200)
            }

            // Info Overlay (bottom)
            if panel.image != nil {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading) {
                            if !panel.currentSeriesInfo.isEmpty {
                                Text(panel.currentSeriesInfo).padding(4)
                            }
                            if panel.windowWidth != 0 {
                                Text(String(format: "WL: %.0f WW: %.0f", panel.windowCenter, panel.windowWidth))
                                    .padding(4)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .background(.thinMaterial)
                        .cornerRadius(8)

                        Spacer()

                        if !panel.currentImageInfo.isEmpty {
                            HStack {
                                if panel.cacheProgress < 1.0 && panel.cacheProgress > 0 {
                                    Text(String(format: "Loading: %.0f%%", panel.cacheProgress * 100))
                                        .font(.caption)
                                        .padding(6)
                                        .background(.thinMaterial)
                                        .cornerRadius(8)
                                        .transition(.opacity)
                                }
                                Text(panel.currentImageInfo)
                                    .padding(8)
                                    .background(.thinMaterial)
                                    .cornerRadius(8)
                            }
                            .animation(.easeInOut, value: panel.cacheProgress < 1.0)
                        }
                    }
                    .padding()
                }
                .zIndex(50)
            }

            // Adjustment Toolbar (bottom center)
            if panel.image != nil && !panel.isLoading {
                VStack {
                    Spacer()
                    PanelAdjustmentToolbar(model: model, panel: panel)
                        .padding(.bottom, 20)
                }
                .zIndex(60)

                // Right Side Scroller
                HStack {
                    Spacer()
                    PanelDICOMScroller(model: model, panel: panel)
                        .frame(width: 40)
                        .padding(.trailing, 4)
                        .padding(.vertical, 20)
                }
                .frame(maxHeight: .infinity)
                .zIndex(70)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Active panel border
        .overlay(
            Rectangle()
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .clipped()
    }
}

// MARK: - Panel Interactive DICOM View (NSViewRepresentable)

struct PanelInteractiveDICOMView: NSViewRepresentable {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    var image: NSImage

    func makeNSView(context: Context) -> PanelDICOMInteractView {
        let view = PanelDICOMInteractView()
        view.model = model
        view.panel = panel
        return view
    }

    func updateNSView(_ nsView: PanelDICOMInteractView, context: Context) {
        nsView.model = model
        nsView.panel = panel
        nsView.setImage(image)
        nsView.applyFilters()
        nsView.updateTransform()
    }

    class PanelDICOMInteractView: NSView {
        weak var model: DICOMModel?
        var panel: PanelState?
        private var imageView = NSImageView()
        private var lastDragLocation: NSPoint?
        private var scrollAccumulator: CGFloat = 0.0
        private var roiStartPixel: CGPoint?  // ROI drag start in pixel coords

        override init(frame: CGRect) {
            super.init(frame: frame)
            setup()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setup()
        }

        override func layout() {
            super.layout()
            if let layer = imageView.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                let midX = self.bounds.width / 2.0
                let midY = self.bounds.height / 2.0
                layer.position = CGPoint(x: midX, y: midY)
            }
        }

        private func setup() {
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            self.layer?.masksToBounds = true

            imageView.imageScaling = .scaleProportionallyUpOrDown
            self.addSubview(imageView)

            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                imageView.widthAnchor.constraint(equalTo: self.widthAnchor),
                imageView.heightAnchor.constraint(equalTo: self.heightAnchor)
            ])

            imageView.wantsLayer = true
            imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)

            // Register for drag & drop: series from sidebar (.string) + files/folders from Finder (.fileURL)
            registerForDraggedTypes([.string, .fileURL])
        }

        // MARK: - Drag & Drop (NSDraggingDestination)

        private func hasDraggableContent(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            // Check for series index string (from sidebar)
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first, Int(first) != nil {
                return true
            }
            // Check for file URLs (from Finder)
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
               !urls.isEmpty {
                return true
            }
            return false
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            hasDraggableContent(sender) ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard

            // 1. Series index from sidebar
            if let strs = pb.readObjects(forClasses: [NSString.self]) as? [String],
               let first = strs.first,
               let seriesIndex = Int(first),
               let model = model, let panel = panel {
                DispatchQueue.main.async {
                    model.assignSeriesToPanel(panel, seriesIndex: seriesIndex)
                }
                return true
            }

            // 2. File/folder URL from Finder
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               let url = urls.first,
               let model = model {
                DispatchQueue.main.async {
                    model.load(url: url)
                }
                return true
            }

            return false
        }

        func setImage(_ img: NSImage) {
            if imageView.image != img {
                imageView.image = img
                DispatchQueue.main.async {
                    self.restoreState()
                }
            }
        }

        func updateTransform() { restoreState() }

        private func restoreState() {
            guard let panel = panel, let layer = imageView.layer else { return }

            // Build transform: flip → rotate → scale → translate
            var t = CATransform3DIdentity

            // Apply flip
            let flipX: CGFloat = panel.isFlippedH ? -1.0 : 1.0
            let flipY: CGFloat = panel.isFlippedV ? -1.0 : 1.0
            t = CATransform3DScale(t, flipX, flipY, 1.0)

            // Apply rotation (90° steps around Z axis)
            let angle = CGFloat(panel.rotationSteps) * .pi / 2.0
            t = CATransform3DRotate(t, angle, 0, 0, 1)

            // Apply zoom
            t = CATransform3DScale(t, panel.scale, panel.scale, 1.0)

            // Apply pan
            t = CATransform3DTranslate(t, panel.translation.x / panel.scale, panel.translation.y / panel.scale, 0)

            layer.transform = t
        }

        func applyFilters() {
            guard let panel = panel else { return }

            var filters: [CIFilter] = []

            if !panel.isRawDataAvailable {
                let currentWW = panel.windowWidth
                let currentWC = panel.windowCenter
                let initialWW = panel.initialWindowWidth
                let initialWC = panel.initialWindowCenter

                if initialWW != 0 {
                    let safeWW = currentWW == 0 ? 1 : currentWW
                    let contrast = CGFloat(initialWW / safeWW)
                    let brightness = CGFloat((initialWC - currentWC) / 255.0)

                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setDefaults()
                        filter.setValue(contrast, forKey: "inputContrast")
                        filter.setValue(brightness, forKey: "inputBrightness")
                        filters.append(filter)
                    }
                }
            }

            // Invert filter
            if panel.isInverted {
                if let invertFilter = CIFilter(name: "CIColorInvert") {
                    invertFilter.setDefaults()
                    filters.append(invertFilter)
                }
            }

            imageView.contentFilters = filters
        }

        private func saveState() {
            guard let panel = panel, let model = model, let layer = imageView.layer else { return }
            let scale = layer.transform.m11
            let tx = layer.transform.m41
            let ty = layer.transform.m42

            panel.scale = scale
            panel.translation = CGPoint(x: tx, y: ty)
            model.saveViewStateForPanel(panel, scale: scale, translation: CGPoint(x: tx, y: ty))
        }

        override var acceptsFirstResponder: Bool { true }

        /// Convert a window-space NSEvent location to image pixel coordinates.
        /// Returns nil if the position is outside the image bounds.
        private func screenToPixel(_ event: NSEvent) -> CGPoint? {
            guard let panel = panel, let layer = imageView.layer, let image = imageView.image else { return nil }

            let loc = convert(event.locationInWindow, from: nil)

            let scale = layer.transform.m11
            let tx = layer.transform.m41
            let ty = layer.transform.m42
            let centerX = bounds.width / 2
            let centerY = bounds.height / 2

            let localX = (loc.x - CGFloat(tx) - centerX) / CGFloat(scale) + centerX
            let localY = (loc.y - CGFloat(ty) - centerY) / CGFloat(scale) + centerY

            let viewW = bounds.width
            let viewH = bounds.height
            let imgW = image.size.width
            let imgH = image.size.height

            let fitScale = min(viewW / imgW, viewH / imgH)
            let displayW = imgW * fitScale
            let displayH = imgH * fitScale
            let offsetX = (viewW - displayW) / 2
            let offsetY = (viewH - displayH) / 2

            let pixelX = (localX - offsetX) / fitScale
            let pixelY = imgH - (localY - offsetY) / fitScale  // Flip Y

            guard pixelX.isFinite, pixelY.isFinite else { return nil }
            return CGPoint(x: pixelX, y: pixelY)
        }

        override func mouseDown(with event: NSEvent) {
            // Activate this panel on click
            if let panel = panel, let model = model {
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }

            // ROI mode: start drag
            if let panel = panel, panel.isROIMode {
                if let px = screenToPixel(event) {
                    roiStartPixel = px
                    panel.roiRect = CGRect(x: px.x, y: px.y, width: 0, height: 0)
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            guard let model = model, let panel = panel else {
                super.keyDown(with: event)
                return
            }

            let code = event.keyCode
            switch code {
            case 123: model.navigatePanel(panel, direction: .prevSeries)
            case 124: model.navigatePanel(panel, direction: .nextSeries)
            case 126: model.navigatePanel(panel, direction: .prevImage)
            case 125: model.navigatePanel(panel, direction: .nextImage)
            default: super.keyDown(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            // Option+Scroll = Zoom (unchanged)
            if event.modifierFlags.contains(.option) {
                guard let layer = imageView.layer else { return }
                let dy = event.deltaY
                if dy == 0 { return }
                let zoomSpeed: CGFloat = 0.05
                let delta = dy * zoomSpeed
                let oldScale = layer.transform.m11
                var newScale = oldScale + CGFloat(delta)
                newScale = max(0.1, min(10.0, newScale))
                layer.transform.m11 = newScale
                layer.transform.m22 = newScale
                saveState()
                return
            }

            // Ignore momentum (inertial) scroll events — they fight direction changes
            if event.momentumPhase.rawValue != 0 {
                return
            }

            // Reset accumulator when gesture ends
            if event.phase == .ended || event.phase == .cancelled {
                scrollAccumulator = 0
                return
            }

            guard let model = model, let panel = panel else { return }

            if event.hasPreciseScrollingDeltas {
                // Trackpad: accumulate pixel-level deltas
                let delta = event.scrollingDeltaY
                if delta == 0 { return }

                // Reset accumulator on direction change for immediate responsiveness
                if scrollAccumulator != 0 && ((scrollAccumulator > 0) != (delta > 0)) {
                    scrollAccumulator = 0
                }
                scrollAccumulator += delta

                let threshold: CGFloat = 10.0
                while abs(scrollAccumulator) >= threshold {
                    if scrollAccumulator > 0 {
                        model.navigatePanel(panel, direction: .prevImage)
                        scrollAccumulator -= threshold
                    } else {
                        model.navigatePanel(panel, direction: .nextImage)
                        scrollAccumulator += threshold
                    }
                }
            } else {
                // Mouse wheel: navigate immediately per click
                let dy = event.deltaY
                if dy == 0 { return }
                if dy > 0 {
                    model.navigatePanel(panel, direction: .prevImage)
                } else {
                    model.navigatePanel(panel, direction: .nextImage)
                }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            // Activate panel on right-click too
            if let panel = panel, let model = model {
                DispatchQueue.main.async {
                    model.activePanelID = panel.id
                }
            }
            lastDragLocation = event.locationInWindow
        }

        override func rightMouseDragged(with event: NSEvent) {
            guard let start = lastDragLocation, let model = model, let panel = panel else { return }
            let current = event.locationInWindow

            let dx = Double(current.x - start.x)
            let dy = Double(current.y - start.y)

            let currentWW = panel.windowWidth
            let dynamicFactor = max(0.1, currentWW / 500.0)
            let sensitivity: Double = 1.0 * dynamicFactor

            model.adjustWindowLevelForPanel(panel, deltaWidth: dx * sensitivity, deltaCenter: dy * sensitivity)
            applyFilters()
            lastDragLocation = current
        }

        override func mouseDragged(with event: NSEvent) {
            guard let panel = panel else { return }

            // ROI mode: update rectangle
            if panel.isROIMode, let start = roiStartPixel {
                if let current = screenToPixel(event) {
                    let x = min(start.x, current.x)
                    let y = min(start.y, current.y)
                    let w = abs(current.x - start.x)
                    let h = abs(current.y - start.y)
                    panel.roiRect = CGRect(x: x, y: y, width: w, height: h)
                }
                return
            }

            // Normal mode: left-click drag = pan
            guard let layer = imageView.layer else { return }
            let dx = event.deltaX
            let dy = -event.deltaY

            layer.transform.m41 += CGFloat(dx)
            layer.transform.m42 += CGFloat(dy)
            saveState()
        }

        override func mouseUp(with event: NSEvent) {
            guard let panel = panel, let model = model else { return }

            // ROI mode: compute W/L from rectangle and apply
            if panel.isROIMode, let rect = panel.roiRect, rect.width > 1 && rect.height > 1 {
                model.autoWindowLevelForPanelROI(panel, rect: rect)
            }

            // Clean up ROI state
            roiStartPixel = nil
            panel.roiRect = nil
            panel.isROIMode = false
        }

        // MARK: - Mouse Tracking for HU Readout

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseExited(with event: NSEvent) {
            panel?.showCursorInfo = false
        }

        override func mouseMoved(with event: NSEvent) {
            guard let panel = panel, let layer = imageView.layer, let image = imageView.image else {
                panel?.showCursorInfo = false
                return
            }

            let loc = convert(event.locationInWindow, from: nil)

            // Undo CALayer transform (zoom/pan with anchor at center)
            let scale = layer.transform.m11
            let tx = layer.transform.m41
            let ty = layer.transform.m42
            let centerX = bounds.width / 2
            let centerY = bounds.height / 2

            let localX = (loc.x - CGFloat(tx) - centerX) / CGFloat(scale) + centerX
            let localY = (loc.y - CGFloat(ty) - centerY) / CGFloat(scale) + centerY

            // Convert from view coordinates to image pixel coordinates
            let viewW = bounds.width
            let viewH = bounds.height
            let imgW = image.size.width
            let imgH = image.size.height

            let fitScale = min(viewW / imgW, viewH / imgH)
            let displayW = imgW * fitScale
            let displayH = imgH * fitScale
            let offsetX = (viewW - displayW) / 2
            let offsetY = (viewH - displayH) / 2

            let pixelX = (localX - offsetX) / fitScale
            let pixelY = imgH - (localY - offsetY) / fitScale  // Flip Y

            // Safe Double→Int conversion (pixelX/Y can be NaN/Inf with degenerate transforms)
            guard pixelX.isFinite, pixelY.isFinite else {
                panel.showCursorInfo = false
                return
            }
            let px = Int(max(-1, min(Double(Int.max / 2), pixelX)))
            let py = Int(max(-1, min(Double(Int.max / 2), pixelY)))

            guard px >= 0, px < panel.imageWidth, py >= 0, py < panel.imageHeight else {
                panel.showCursorInfo = false
                return
            }

            // Only update if position changed (throttle view updates)
            guard px != panel.cursorPixelX || py != panel.cursorPixelY else { return }

            // Look up raw pixel value
            var huValue: Double = 0
            if let data = panel.rawPixelData {
                let index = py * panel.imageWidth + px
                if panel.bitDepth > 8 {
                    let byteIndex = index * 2
                    if byteIndex + 1 < data.count {
                        data.withUnsafeBytes { raw in
                            if let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt16.self) {
                                if panel.isSigned {
                                    huValue = Double(Int16(bitPattern: ptr[index]))
                                } else {
                                    huValue = Double(ptr[index])
                                }
                            }
                        }
                    }
                } else if index < data.count {
                    huValue = Double(data[index])
                }
            }

            panel.cursorPixelX = px
            panel.cursorPixelY = py
            panel.cursorHU = huValue
            panel.showCursorInfo = true

            // Compute patient coordinates if spatial metadata available
            if let ipp = panel.imagePositionPatient,
               let iop = panel.imageOrientationPatient, iop.count == 6,
               let ps = panel.pixelSpacing {
                let row = SIMD3<Double>(iop[0], iop[1], iop[2])
                let col = SIMD3<Double>(iop[3], iop[4], iop[5])
                let origin = SIMD3<Double>(ipp.0, ipp.1, ipp.2)
                let patPos = origin + Double(px) * ps.1 * row + Double(py) * ps.0 * col
                panel.cursorPatientX = patPos.x
                panel.cursorPatientY = patPos.y
                panel.cursorPatientZ = patPos.z
                panel.hasCursorPatientPosition = true
            } else {
                panel.hasCursorPatientPosition = false
            }
        }
    }
}

// MARK: - ROI Overlay

/// Draws the ROI selection rectangle during drag.
struct ROIOverlay: View {
    @ObservedObject var panel: PanelState
    let roiRect: CGRect

    var body: some View {
        GeometryReader { geo in
            let screenRect = pixelRectToScreen(roiRect, viewSize: geo.size)
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .background(Color.yellow.opacity(0.1))
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)
        }
        .allowsHitTesting(false)
    }

    /// Convert a pixel-space rectangle to SwiftUI overlay screen coordinates.
    /// Uses the same transform logic as CrossReferenceOverlay's pixelToScreen.
    private func pixelRectToScreen(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        let topLeft = pixelToScreen(CGPoint(x: rect.minX, y: rect.minY), viewSize: viewSize)
        let bottomRight = pixelToScreen(CGPoint(x: rect.maxX, y: rect.maxY), viewSize: viewSize)
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func pixelToScreen(_ pixel: CGPoint, viewSize: CGSize) -> CGPoint {
        let imgW = CGFloat(max(1, panel.imageWidth))
        let imgH = CGFloat(max(1, panel.imageHeight))
        let vw = viewSize.width
        let vh = viewSize.height

        let fitScale = min(vw / imgW, vh / imgH)
        let offsetX = (vw - imgW * fitScale) / 2
        let offsetY = (vh - imgH * fitScale) / 2

        var x = pixel.x * fitScale + offsetX
        var y = pixel.y * fitScale + offsetY

        let cx = vw / 2
        let cy = vh / 2
        x -= cx
        y -= cy

        if panel.isFlippedH { x = -x }
        if panel.isFlippedV { y = -y }

        let steps = panel.rotationSteps % 4
        if steps > 0 {
            let angle = CGFloat(steps) * .pi / 2
            let cosA = cos(angle)
            let sinA = sin(angle)
            let rx = x * cosA - y * sinA
            let ry = x * sinA + y * cosA
            x = rx
            y = ry
        }

        x *= panel.scale
        y *= panel.scale

        // Pan (same as fixed CrossReferenceOverlay)
        x += panel.translation.x
        y -= panel.translation.y

        x += cx
        y += cy
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Panel Adjustment Toolbar

struct PanelAdjustmentToolbar: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    var body: some View {
        HStack(spacing: 8) {
            if !panel.histogramData.isEmpty {
                PanelHistogramView(
                    data: panel.histogramData,
                    minVal: panel.minPixelValue,
                    maxVal: panel.maxPixelValue,
                    windowWidth: panel.windowWidth,
                    windowCenter: panel.windowCenter
                )
                .frame(width: 100, height: 40)
                .background(Color.black.opacity(0.5))
                .border(Color.white.opacity(0.2), width: 1)
            }

            Button(action: { model.autoWindowLevelForPanel(panel) }) {
                HStack(spacing: 4) {
                    Text("Auto")
                    Text("⇧A")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .frame(height: 40)
            .help("Auto W/L (⇧A)")

            Button(action: { panel.isROIMode.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed")
                    Text("ROI")
                    Text("⇧R")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .frame(height: 40)
            .help("ROI Auto W/L (⇧R)")
            .background(panel.isROIMode ? Color.accentColor.opacity(0.3) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(6)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

// MARK: - Panel Histogram View

struct PanelHistogramView: View {
    let data: [Double]
    let minVal: Double
    let maxVal: Double
    let windowWidth: Double
    let windowCenter: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Path { path in
                    let width = geo.size.width
                    let height = geo.size.height
                    let step = width / CGFloat(data.count)

                    path.move(to: CGPoint(x: 0, y: height))
                    for (i, val) in data.enumerated() {
                        let x = CGFloat(i) * step
                        let y = height - (CGFloat(val) * height)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.6)], startPoint: .top, endPoint: .bottom))

                let totalRange = maxVal - minVal
                if totalRange > 0 {
                    let windowStart = (windowCenter - (windowWidth / 2.0))
                    let windowEnd = (windowCenter + (windowWidth / 2.0))

                    let startRatio = max(0.0, min(1.0, (windowStart - minVal) / totalRange))
                    let endRatio = max(0.0, min(1.0, (windowEnd - minVal) / totalRange))

                    let startX = CGFloat(startRatio) * geo.size.width
                    let widthPx = CGFloat(endRatio - startRatio) * geo.size.width

                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: max(2, widthPx), height: geo.size.height)
                        .position(x: startX + (widthPx / 2.0), y: geo.size.height / 2.0)

                    let centerRatio = max(0.0, min(1.0, (windowCenter - minVal) / totalRange))
                    let centerX = CGFloat(centerRatio) * geo.size.width
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1, height: geo.size.height)
                        .position(x: centerX, y: geo.size.height / 2.0)
                }
            }
        }
    }
}

// MARK: - Panel DICOM Scroller

struct PanelDICOMScroller: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var dragLocation: CGPoint? = nil

    var body: some View {
        GeometryReader { geo in
            let total = model.totalSliceCount(for: panel)
            let currentIdx = model.currentSliceIndex(for: panel)

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 6, height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                // Handle
                if total > 0 {
                    let thumbHeight = max(20.0, geo.size.height / CGFloat(total) * 4.0)
                    let progress = Double(currentIdx) / Double(max(1, total - 1))
                    let availHeight = geo.size.height - thumbHeight
                    let offset = CGFloat(progress) * availHeight

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 6, height: thumbHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: offset)
                }
            }
            .contentShape(Rectangle())
            .overlay {
                PanelScrollerInteractionView(
                    onDrag: { loc in
                        dragLocation = loc
                        calculateIndex(y: loc.y, height: geo.size.height, total: total, commit: true)
                    },
                    onHover: { loc in
                        hoverLocation = loc
                    },
                    onEnter: { isHovering = true },
                    onExit: {
                        isHovering = false
                        dragLocation = nil
                    }
                )
            }
            .overlay(alignment: .topTrailing) {
                if total > 0, let pY = activeY() {
                    let idx = getIndex(y: pY, height: geo.size.height, total: total)
                    if panel.panelMode == .slice2D {
                        PanelThumbnailPopup(model: model, panel: panel, index: idx, total: total)
                            .offset(x: -20, y: min(max(0, pY - 45), geo.size.height - 90))
                            .allowsHitTesting(false)
                    } else {
                        // MPR mode: show slice number instead of thumbnail
                        Text("\(idx + 1)/\(total)")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .offset(x: -20, y: min(max(0, pY - 12), geo.size.height - 24))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func activeY() -> CGFloat? {
        if let d = dragLocation { return d.y }
        if isHovering { return hoverLocation.y }
        return nil
    }

    func calculateIndex(y: CGFloat, height: CGFloat, total: Int, commit: Bool) {
        if total <= 1 { return }
        let idx = getIndex(y: y, height: height, total: total)
        if commit {
            model.navigatePanelToSlice(panel, index: idx)
        }
    }

    func getIndex(y: CGFloat, height: CGFloat, total: Int) -> Int {
        let pct = max(0, min(1, y / height))
        return Int(pct * Double(total - 1))
    }
}

// MARK: - Panel Thumbnail Popup

struct PanelThumbnailPopup: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState
    let index: Int
    let total: Int

    var body: some View {
        HStack {
            Text("\(index + 1)")
                .font(.caption)
                .padding(4)
                .background(.black.opacity(0.7))
                .cornerRadius(4)

            if let img = model.getCachedImageForPanel(panel, at: index) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .background(Color.black)
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 80)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

// MARK: - Panel Scroller Interaction View

struct PanelScrollerInteractionView: NSViewRepresentable {
    var onDrag: (CGPoint) -> Void
    var onHover: (CGPoint) -> Void
    var onEnter: () -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = InteractionView()
        v.onDrag = onDrag
        v.onHover = onHover
        v.onEnter = onEnter
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? InteractionView {
            v.onDrag = onDrag
            v.onHover = onHover
            v.onEnter = onEnter
            v.onExit = onExit
        }
    }

    class InteractionView: NSView {
        var onDrag: ((CGPoint) -> Void)?
        var onHover: ((CGPoint) -> Void)?
        var onEnter: (() -> Void)?
        var onExit: (() -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .activeAlways], owner: self, userInfo: nil))
        }

        override func mouseDown(with event: NSEvent) { handleDrag(event) }
        override func mouseDragged(with event: NSEvent) { handleDrag(event) }

        private func handleDrag(_ event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onDrag?(CGPoint(x: loc.x, y: flippedY))
        }

        override func mouseEntered(with event: NSEvent) { onEnter?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func mouseMoved(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let flippedY = bounds.height - loc.y
            onHover?(CGPoint(x: loc.x, y: flippedY))
        }
    }
}

// MARK: - Orientation Labels Overlay

struct OrientationLabelsOverlay: View {
    let orientation: [Double]?

    var body: some View {
        if let ori = orientation, ori.count == 6 {
            let row = SIMD3<Double>(ori[0], ori[1], ori[2])
            let col = SIMD3<Double>(ori[3], ori[4], ori[5])

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                // Right edge: direction of row vector
                Text(dirLabel(row))
                    .position(x: w - 16, y: h / 2)
                // Left edge: opposite of row vector
                Text(oppositeLabel(dirLabel(row)))
                    .position(x: 16, y: h / 2)
                // Bottom edge: direction of column vector
                Text(dirLabel(col))
                    .position(x: w / 2, y: h - 16)
                // Top edge: opposite of column vector
                Text(oppositeLabel(dirLabel(col)))
                    .position(x: w / 2, y: 16)
            }
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow.opacity(0.8))
            .allowsHitTesting(false)
        }
    }

    /// Map a direction vector to its dominant anatomical label.
    /// DICOM patient coordinate system: +x=L, -x=R, +y=P, -y=A, +z=S, -z=I
    private func dirLabel(_ v: SIMD3<Double>) -> String {
        let ax = abs(v.x), ay = abs(v.y), az = abs(v.z)
        if ax >= ay && ax >= az { return v.x > 0 ? "L" : "R" }
        if ay >= ax && ay >= az { return v.y > 0 ? "P" : "A" }
        return v.z > 0 ? "S" : "I"
    }

    private func oppositeLabel(_ l: String) -> String {
        switch l {
        case "L": return "R"; case "R": return "L"
        case "A": return "P"; case "P": return "A"
        case "S": return "I"; case "I": return "S"
        default: return ""
        }
    }
}

// MARK: - Cursor Info Overlay (HU Readout)

struct CursorInfoOverlay: View {
    @ObservedObject var panel: PanelState

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if panel.hasCursorPatientPosition {
                        Text(String(format: "x: %.1f  y: %.1f  z: %.1f",
                             panel.cursorPatientX, panel.cursorPatientY, panel.cursorPatientZ))
                    }
                    Text(String(format: "HU: %.0f  [%d, %d]",
                        panel.cursorHU, panel.cursorPixelX, panel.cursorPixelY))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.6))
                .cornerRadius(4)
                .padding(8)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
