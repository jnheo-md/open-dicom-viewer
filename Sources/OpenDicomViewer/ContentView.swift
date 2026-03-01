// ContentView.swift
// OpenDicomViewer
//
// Root view of the application. Implements a NavigationSplitView with:
//   - Sidebar: file open button, series list with thumbnails and panel indicators
//   - Detail: multi-panel DICOM viewer with floating layout toolbar
//
// Also handles all keyboard shortcuts and file drag-and-drop.
//
// Key types:
//   ContentView       — Top-level split view + keyboard routing
//   SidebarView       — Open button + series list
//   SeriesListView    — Scrollable list of series with panel assignment indicators
//   SeriesRow         — Single series row: thumbnail, description, panel grid icon
//   PanelPositionIndicator — Miniature grid showing which panels display a series
//   DetailView        — Legacy single-panel detail (used as fallback)
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI
import UniformTypeIdentifiers
import QuartzCore



struct ContentView: View {
    @ObservedObject var model: DICOMModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model, columnVisibility: $columnVisibility)
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: 0) {
                // Fixed tool palette column
                ToolPalette(model: model)
                    .padding(.vertical, 8)

                // Main viewer area
                ZStack(alignment: .topLeading) {
                    // Multi-panel container replaces old single DetailView
                    MultiPanelContainer(model: model, isFocused: $isFocused)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            _ = handleDrop(providers: providers)
                            return true
                        }
                        .onTapGesture {
                            isFocused = true
                        }

                    // Floating controls overlay
                    VStack {
                        HStack(alignment: .top) {
                            // Sidebar toggle (when hidden)
                            if columnVisibility == .detailOnly {
                                Button(action: { columnVisibility = .all }) {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("Show Sidebar")
                            }

                            Spacer()

                            // Layout toolbar + Tag toggle
                            HStack(spacing: 8) {
                                LayoutToolbar(model: model)

                                Button(action: { model.showTags.toggle() }) {
                                    ZStack(alignment: .bottomTrailing) {
                                        Image(systemName: "tag")
                                            .font(.system(size: 16))
                                            .foregroundStyle(model.showTags ? .white : .secondary)
                                            .padding(8)

                                        Text("T")
                                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                            .offset(x: -2, y: -2)
                                    }
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .help("Toggle Tags (T)")
                            }
                        }
                        .padding()

                        Spacer()
                    }
                }
            }
        }
        // Keyboard Handlers — route through active panel
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .prevSeries)
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .nextSeries)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .prevImage)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if let panel = model.activePanel {
                model.navigatePanel(panel, direction: .nextImage)
            }
            return .handled
        }
        .onKeyPress(.tab) {
            cyclePanelForward()
            return .handled
        }
        .onKeyPress(.pageUp) {
            if let panel = model.activePanel {
                model.navigatePanelByOffset(panel, offset: -10)
            }
            return .handled
        }
        .onKeyPress(.pageDown) {
            if let panel = model.activePanel {
                model.navigatePanelByOffset(panel, offset: 10)
            }
            return .handled
        }
        .onKeyPress(.home) {
            if let panel = model.activePanel {
                model.navigatePanelToEdge(panel, toFirst: true)
            }
            return .handled
        }
        .onKeyPress(.end) {
            if let panel = model.activePanel {
                model.navigatePanelToEdge(panel, toFirst: false)
            }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            if press.modifiers.isEmpty {
                switch press.characters {
                // 1-4: Layout switching
                case "1":
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
                    return .handled
                case "2":
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
                    return .handled
                case "3":
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
                    return .handled
                case "4":
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
                    return .handled
                default: break
                }

                switch press.characters.lowercased() {
                // R = Reset view (zoom/pan + auto W/L)
                case "r":
                    model.resetViewForPanel(model.activePanel)
                    return .handled
                // L = Toggle synchronized scrolling (link)
                case "l":
                    model.synchronizedScrolling.toggle()
                    return .handled
                // X = Toggle cross-reference lines
                case "x":
                    model.showCrossReference.toggle()
                    return .handled
                // T = Toggle DICOM tags
                case "t":
                    model.showTags.toggle()
                    return .handled
                // I = Invert
                case "i":
                    model.invertForPanel(model.activePanel)
                    return .handled
                // F = Fit to window
                case "f":
                    model.fitToWindowForPanel(model.activePanel)
                    return .handled
                // A = Auto W/L
                case "a":
                    if let panel = model.activePanel {
                        model.autoWindowLevelForPanel(panel)
                    }
                    return .handled
                // Tool selection shortcuts
                case "o":
                    model.activeTool = .roiWL
                    return .handled
                case "s":
                    model.activeTool = .roiStats
                    return .handled
                case "d":
                    model.activeTool = .ruler
                    return .handled
                case "n":
                    model.activeTool = .angle
                    return .handled
                case "e":
                    model.activeTool = .eraser
                    return .handled
                // ] or . = Rotate clockwise 90°
                case "]", ".":
                    model.rotateClockwiseForPanel(model.activePanel)
                    return .handled
                // [ or , = Rotate counter-clockwise 90°
                case "[", ",":
                    model.rotateCounterClockwiseForPanel(model.activePanel)
                    return .handled
                // W = Window/Level tool
                case "w":
                    model.activeTool = .windowLevel
                    return .handled
                // V = Select tool (default)
                case "v":
                    model.activeTool = .select
                    return .handled
                // P = Pan tool
                case "p":
                    model.activeTool = .pan
                    return .handled
                // Z = Zoom tool
                case "z":
                    model.activeTool = .zoom
                    return .handled
                // H = Flip horizontal
                case "h":
                    model.flipHorizontalForPanel(model.activePanel)
                    return .handled
                default: break
                }
            }

            // Escape = Clear group selection
            if press.key == .escape {
                if model.groupSelectedPanels.count > 0 {
                    model.clearGroupSelection()
                    return .handled
                }
            }

            return .ignored
        }
        .inspector(isPresented: $model.showTags) {
            Group {
                let activeTags = model.activePanel?.tags ?? []
                if activeTags.isEmpty {
                    ContentUnavailableView("No Tags", systemImage: "tag.slash")
                } else {
                    TagView(tags: activeTags)
                }
            }
            .id(model.activePanelID)
        }
        .sheet(isPresented: $model.showHelp) {
            HelpView()
        }
        .preferredColorScheme(.dark)
        .background(WindowAccessor())
    }

    // MARK: - Handlers

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async { model.load(url: url) }
                    }
                }
                return true
            }
        }
        return false
    }

    private func cyclePanelForward() {
        guard model.panels.count > 1 else { return }
        if let currentIndex = model.panels.firstIndex(where: { $0.id == model.activePanelID }) {
            let nextIndex = (currentIndex + 1) % model.panels.count
            model.activePanelID = model.panels[nextIndex].id
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: DICOMModel
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    var body: some View {
        VStack(spacing: 0) {
            // Custom Toolbar / Header
            HStack {
                Button(action: { columnVisibility = .detailOnly }) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide Sidebar")
                
                Spacer()
                
                Button(action: openFile) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Open")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open DICOM Folder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Remove background or make it very subtle
            // .background(Color.black.opacity(0.4))
            
            SeriesListView(model: model)
        }
    }
    
    private func openFile() {
        model.openFolder()
    }
}

struct SeriesListView: View {
    @ObservedObject var model: DICOMModel

    /// The series index shown by the active panel (for highlight)
    private var activeSeriesIndex: Int {
        model.activePanel?.seriesIndex ?? model.currentSeriesIndex
    }

    /// Row background color for a given series index
    private func rowBackground(for index: Int) -> Color? {
        if index == activeSeriesIndex {
            return Color.blue.opacity(0.15)
        }
        if model.panels.contains(where: { $0.seriesIndex == index }) {
            return Color.blue.opacity(0.05)
        }
        return nil
    }

    var body: some View {
        List(selection: $model.currentSeriesIndex) {
            ForEach(model.allSeries.indices, id: \.self) { index in
                SeriesRow(model: model, series: model.allSeries[index], isSelected: index == activeSeriesIndex, seriesIndex: index)
                .contentShape(Rectangle())
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: "public.utf8-plain-text",
                        visibility: .all
                    ) { completion in
                        completion("\(index)".data(using: .utf8), nil)
                        return nil
                    }
                    return provider
                }
                .onTapGesture {
                    // Update legacy indices first (avoids double-load from didSet)
                    model.currentImageIndex = 0
                    model.currentSeriesIndex = index
                    // Load via panel path (legacy state synced via syncLegacyStateToActivePanel)
                    if let panel = model.activePanel {
                        model.assignSeriesToPanel(panel, seriesIndex: index)
                    } else {
                        // Fallback: no panels yet, use legacy path
                        if let first = model.allSeries[index].images.first {
                            model.loadSingleFile(first.url)
                        }
                    }
                }
                .listRowBackground(rowBackground(for: index))
            }
            
            if model.isScanning && !model.allSeries.isEmpty {
                 HStack {
                     Spacer()
                     ProgressView()
                         .controlSize(.small)
                     Text("Scanning...")
                         .font(.caption)
                         .foregroundStyle(.secondary)
                     Spacer()
                 }
                 .listRowSeparator(.hidden)
                 .padding(.vertical, 8)
            }
        }
        .listStyle(.sidebar)
        .overlay {
             if model.allSeries.isEmpty {
                 if model.isScanning {
                     VStack {
                         ProgressView("Scanning Directory...")
                             .controlSize(.regular)
                     }
                 } else {
                     ContentUnavailableView {
                         Label("No Series Found", systemImage: "folder.badge.questionmark")
                     } description: {
                         Text("Drag a FOLDER to this window to scan for all series.")
                     }
                 }
             }
        }
    }
}

struct SeriesRow: View {
    @ObservedObject var model: DICOMModel
    let series: DicomSeries
    let isSelected: Bool
    let seriesIndex: Int

    /// Whether any panel is displaying this series
    private var isInAnyPanel: Bool {
        model.panels.contains { $0.seriesIndex == seriesIndex }
    }

    var body: some View {
        HStack {
            Group {
                if let thumb = model.seriesThumbnails[series.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "folder")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .onAppear {
                            model.requestSeriesThumbnail(for: series)
                        }
                }
            }
            VStack(alignment: .leading) {
                Text("Series \(series.seriesNumber)")
                    .font(.headline)
                if !series.seriesDescription.isEmpty {
                    Text(series.seriesDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(series.images.count) Images")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isInAnyPanel {
                PanelPositionIndicator(model: model, seriesIndex: seriesIndex)
            }
        }
    }
}

/// Miniature grid icon showing which panel(s) display a given series.
/// Each cell is a tiny rounded rectangle: filled blue if the panel shows this series, border-only otherwise.
struct PanelPositionIndicator: View {
    @ObservedObject var model: DICOMModel
    let seriesIndex: Int

    private let cellSize: CGFloat = 7
    private let spacing: CGFloat = 2

    var body: some View {
        let rows = model.layout.rows
        let cols = model.layout.columns

        VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<cols, id: \.self) { col in
                        let panelIdx = row * cols + col
                        let isFilled = panelIdx < model.panels.count && model.panels[panelIdx].seriesIndex == seriesIndex
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isFilled ? Color.blue : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5)
                                    .strokeBorder(Color.blue.opacity(isFilled ? 1 : 0.4), lineWidth: 1)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
    }
}

struct DetailView: View {
    @ObservedObject var model: DICOMModel
    @FocusState.Binding var isFocused: Bool
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Image View (Always Present if configured, barely visible if no image?)
            // We want to keep it in the hierarchy to preserve state/focus if possible.
            // If image is nil, maybe show nothing or keep previous?
            if let image = model.image {
                 InteractiveDICOMView(model: model, image: image)
                     .frame(maxWidth: .infinity, maxHeight: .infinity)
                     .zIndex(0)
            } else if model.errorMessage == nil && !model.isLoading {
                ContentUnavailableView("No Image Selected", systemImage: "photo")
            }

            // Error Overlay
            if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                     Text(error).font(.caption)
                }
                .background(Color.black.opacity(0.8))
                .zIndex(200)
            }
            
            // Exclusive Loading Overlay - REMOVED for non-obstructive UX
            // if model.isLoading { ... }
            
            // Info Overlay (Only show if image exists)
            if model.image != nil {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading) {
                            if !model.currentSeriesInfo.isEmpty {
                                Text(model.currentSeriesInfo).padding(4)
                            }
                            if model.windowWidth != 0 {
                                Text(String(format: "WL: %.0f WW: %.0f", model.windowCenter, model.windowWidth))
                                    .padding(4)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .background(.thinMaterial)
                        .cornerRadius(8)
                        
                        Spacer()
                        
                        if !model.currentImageInfo.isEmpty {
                            HStack {
                                if model.cacheProgress < 1.0 && model.cacheProgress > 0 {
                                    Text(String(format: "Loading: %.0f%%", model.cacheProgress * 100))
                                        .font(.caption)
                                        .padding(6)
                                        .background(.thinMaterial)
                                        .cornerRadius(8)
                                        .transition(.opacity)
                                }
                                Text(model.currentImageInfo)
                                    .padding(8)
                                    .background(.thinMaterial)
                                    .cornerRadius(8)
                            }
                            .animation(.easeInOut, value: model.cacheProgress < 1.0)
                        }
                    }
                    .padding()
                }
                .zIndex(50)
            }
            
            // Advanced Controls Overlay (Bottom)
             if model.image != nil && !model.isLoading {
                 VStack {
                     Spacer()
                     AdjustmentToolbar(model: model)
                         .padding(.bottom, 20)
                 }
                 .zIndex(60)
                 
                 // Right Side Scroller
                 HStack {
                     Spacer()
                     DICOMScroller(model: model)
                         .frame(width: 40)
                         .padding(.trailing, 4)
                         .padding(.vertical, 20)
                 }
                 .frame(maxHeight: .infinity) // Ensure full height
                 .zIndex(70)
             }
            
            // Keyboard Handling (Backup for SwiftUI Focus)
            ZStack { Color.clear }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(.leftArrow) {
                model.prevSeries()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.nextSeries()
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.prevImage()
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.nextImage()
                return .handled
            }
        }
    }
}

// NSView for High-Performance Interaction
struct InteractiveDICOMView: NSViewRepresentable {
    @ObservedObject var model: DICOMModel
    var image: NSImage
    
    func makeNSView(context: Context) -> DICOMInteractView {
        let view = DICOMInteractView()
        view.model = model
        return view
    }
    
    func updateNSView(_ nsView: DICOMInteractView, context: Context) {
        nsView.model = model
        nsView.setImage(image)
        // Apply W/L filters for compressed images
        nsView.applyFilters()
    }
    
    class DICOMInteractView: NSView {
        weak var model: DICOMModel?
        private var imageView = NSImageView()
        
        // Interaction State
        private var lastDragLocation: NSPoint?
        
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
            
            // CRITICAL: Ensure Anchor Point is strictly Center (0.5, 0.5)
            // macOS AutoLayout with Layers can sometimes reset this or imply (0,0).
            // We force it here to ensure Zoom (Scale) happens around the center.
            if let layer = imageView.layer {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                
                // When modifying anchor point, position must be updated to maintain frame.
                // Since this is AutoLayout, we ensure position matches the view center.
                // Constraints usually handle this, but explicit setting ensures the layer model matches.
                let midX = self.bounds.width / 2.0
                let midY = self.bounds.height / 2.0
                layer.position = CGPoint(x: midX, y: midY)
            }
        }

        private func setup() {
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
            
            // imageView Setup
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
            // Initial setting (reinforced in layout)
            imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        
        func setImage(_ img: NSImage) {
            if imageView.image != img {
                imageView.image = img
                // Defer restoration to ensure NSImageView doesn't reset the layer transform immediately after setting image
                DispatchQueue.main.async {
                    self.restoreState()
                }
            }
        }
        
        private func restoreState() {
            guard let model = model, let layer = imageView.layer else { return }
            let (scale, translation) = model.getViewState()
            
            // Debug
            // print("[RestoreState] s:\(scale) t:\(translation)")
            
            var t = CATransform3DIdentity
            t.m11 = scale
            t.m22 = scale
            t.m41 = translation.x
            t.m42 = translation.y
            
            layer.transform = t
        }
        
        
        
        func applyFilters() {
            guard let model = model else { return } // Removed layer guard for safety, though mostly needed for CALayer
            
            // CRITICAL FIX: If Model has Raw Data, it manually re-renders the NSImage with the new W/L baked in.
            // We MUST NOT apply CIColorControls filters on top of that, or it effectively applies W/L twice.
            if model.isRawDataAvailable {
                imageView.contentFilters = []
                return
            }
            
            let currentWW = model.windowWidth
            let currentWC = model.windowCenter
            let initialWW = model.initialWindowWidth
            let initialWC = model.initialWindowCenter
            
            if initialWW == 0 { return }
            
            // Prevent divide by zero
            let safeWW = currentWW == 0 ? 1 : currentWW
            let contrast = CGFloat(initialWW / safeWW)
            let brightness = CGFloat((initialWC - currentWC) / 255.0)
            
            guard let filter = CIFilter(name: "CIColorControls") else { return }
            
            filter.setDefaults()
            filter.setValue(contrast, forKey: "inputContrast")
            filter.setValue(brightness, forKey: "inputBrightness")
            
            imageView.contentFilters = [filter]
        }
        
        private func saveState() {
            guard let model = model, let layer = imageView.layer else { return }
            let scale = layer.transform.m11
            let tx = layer.transform.m41
            let ty = layer.transform.m42
            
            model.saveViewState(scale: scale, translation: CGPoint(x: tx, y: ty))
        }
        
        override var acceptsFirstResponder: Bool { true }
        
        override func keyDown(with event: NSEvent) {
            guard let model = model else {
                super.keyDown(with: event)
                return
            }
            
            // Interpret Arrow Keys
            let code = event.keyCode
            // 123: Left, 124: Right, 125: Down, 126: Up
            
            switch code {
            case 123: // Left
                 model.prevSeries()
            case 124: // Right
                 model.nextSeries()
            case 126: // Up
                 model.prevImage()
            case 125: // Down
                 model.nextImage()
            default:
                super.keyDown(with: event)
            }
        }
        
        override func scrollWheel(with event: NSEvent) {
            // Check for Option key -> Zoom
            if event.modifierFlags.contains(.option) {
                 guard let layer = imageView.layer else { return }
                 let dy = event.deltaY
                 if dy == 0 { return }
                 
                 // Zoom Factor
                 let zoomSpeed: CGFloat = 0.05
                 let delta = dy * zoomSpeed
                 
                 let oldScale = layer.transform.m11
                 var newScale = oldScale + convertToCGFloat(delta)
                 
                 // Clamp Scale
                 newScale = max(0.1, min(10.0, newScale))
                 
                 // User Request: Zoom around Image Center (Fixed Center)
                 // Do NOT adjust translation (m41/m42).
                 // layer.anchorPoint is (0.5, 0.5), so scaling m11/m22 zooms around the image center.
                 
                 layer.transform.m11 = newScale
                 layer.transform.m22 = newScale
                 
                 saveState()
                 return
            }
            
            // Normal Scroll -> Navigation
            // Threshold for scrolling
            if abs(event.deltaY) > 0.5 {
                if event.deltaY > 0 {
                    model?.prevImage()
                } else {
                    model?.nextImage()
                }
            }
        }
        
        private func convertToCGFloat(_ val: Double) -> CGFloat {
            return CGFloat(val)
        }

        override func rightMouseDown(with event: NSEvent) {
            lastDragLocation = event.locationInWindow
        }
        
        override func rightMouseDragged(with event: NSEvent) {
            guard let start = lastDragLocation else { return }
            let current = event.locationInWindow
            
            let dx = Double(current.x - start.x)
            let dy = Double(current.y - start.y)
            
            // Dynamic Sensitivity
            // If Window Width is huge (e.g. 2000), we need larger steps.
            // If Window Width is tiny (e.g. 50), we need fine control.
            // Base sensitivity 1.0 corresponds to roughly 1 unit per pixel?
            // Usually we want full screen drag to cover a significant portion.
            
            let currentWW = model?.windowWidth ?? 256
            let dynamicFactor = max(0.1, currentWW / 500.0) // 500 pixels drag = full width change if factor 1
            let sensitivity: Double = 1.0 * dynamicFactor
            
            model?.adjustWindowLevel(deltaWidth: dx * sensitivity, deltaCenter: dy * sensitivity)
            applyFilters()
            lastDragLocation = current
        }
        
        override func mouseDragged(with event: NSEvent) {
             // Left-click drag = pan (standard clinical convention)
             guard let layer = imageView.layer else { return }
             let dx = event.deltaX
             let dy = -event.deltaY

             layer.transform.m41 += CGFloat(dx)
             layer.transform.m42 += CGFloat(dy)

             saveState()
        }
    }
}

// MARK: - Advanced Controls
struct AdjustmentToolbar: View {
    @ObservedObject var model: DICOMModel
    
    var body: some View {
        HStack(spacing: 12) {
            // Histogram
            if !model.histogramData.isEmpty {
                 HistogramView(
                    data: model.histogramData,
                    minVal: model.minPixelValue,
                    maxVal: model.maxPixelValue,
                    windowWidth: model.windowWidth,
                    windowCenter: model.windowCenter
                 )
                 .frame(width: 100, height: 40)
                 .background(Color.black.opacity(0.5))
                 .border(Color.white.opacity(0.2), width: 1)
            }
            
            // Presets
            Group {
                Button("Auto") { model.autoWindowLevel() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.white)
        }
        .padding(8)
        .background(.thinMaterial)
        .cornerRadius(12)
    }
}

struct HistogramView: View {
    let data: [Double]
    let minVal: Double
    let maxVal: Double
    let windowWidth: Double
    let windowCenter: Double
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 1. Histogram Path
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
                
                // 2. Window/Level Indicator
                // Map W/L range to 0-1 coordinate space relative to minVal...maxVal
                let totalRange = maxVal - minVal
                if totalRange > 0 {
                    let windowStart = (windowCenter - (windowWidth / 2.0))
                    let windowEnd = (windowCenter + (windowWidth / 2.0))
                    
                    let startRatio = max(0.0, min(1.0, (windowStart - minVal) / totalRange))
                    let endRatio = max(0.0, min(1.0, (windowEnd - minVal) / totalRange))
                    
                    let startX = CGFloat(startRatio) * geo.size.width
                    let widthPx = CGFloat(endRatio - startRatio) * geo.size.width
                    
                    // Draw Window Range (Yellow box overlay)
                    Rectangle()
                        .fill(Color.yellow.opacity(0.2))
                        .frame(width: max(2, widthPx), height: geo.size.height) // Min 2px
                        .position(x: startX + (widthPx / 2.0), y: geo.size.height / 2.0)
                        
                    // Draw Center Line (White)
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

struct DICOMScroller: View {
    @ObservedObject var model: DICOMModel
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var dragLocation: CGPoint? = nil
    
    var body: some View {
        GeometryReader { geo in
            let total = model.allSeries.indices.contains(model.currentSeriesIndex) ? model.allSeries[model.currentSeriesIndex].images.count : 0
            
            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.2)) // Increased visibility
                    .frame(width: 6, height: geo.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                // Handle
                if total > 0 {
                    let thumbHeight = max(20.0, geo.size.height / CGFloat(total) * 4.0) // Minimal height
                    let progress = Double(model.currentImageIndex) / Double(max(1, total - 1))
                    let availHeight = geo.size.height - thumbHeight
                    let offset = CGFloat(progress) * availHeight
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.8)) // High visibility
                        .frame(width: 6, height: thumbHeight)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .offset(y: offset)
                }
            }
            .contentShape(Rectangle())
            // Mouse Tracking for Hover
            .contentShape(Rectangle())
            // Interaction Overlay (Captures Clicks & Drags)
            .overlay {
                ScrollerInteractionView(
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
                        dragLocation = nil // Reset drag on exit if needed, or keep it
                    }
                )
            }
            .overlay(alignment: .topTrailing) {
                 if total > 0, let pY = activeY() {
                     let idx = getIndex(y: pY, height: geo.size.height, total: total)
                     ThumbnailPopup(model: model, index: idx, total: total)
                         .offset(x: -20, y: min(max(0, pY - 45), geo.size.height - 90))
                         .allowsHitTesting(false)
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
        if commit && idx != model.currentImageIndex {
            // Update index immediately for UI feedback
            model.currentImageIndex = idx
            
            // Trigger proper load logic
            if model.currentSeriesIndex >= 0 && model.currentSeriesIndex < model.allSeries.count {
               let series = model.allSeries[model.currentSeriesIndex]
               if idx >= 0 && idx < series.images.count {
                   model.loadSingleFile(series.images[idx].url)
               }
            }
        }
    }
    
    func getIndex(y: CGFloat, height: CGFloat, total: Int) -> Int {
        let pct = max(0, min(1, y / height))
        return Int(pct * Double(total - 1))
    }
}

struct ThumbnailPopup: View {
    @ObservedObject var model: DICOMModel
    let index: Int
    let total: Int
    
    var body: some View {
        HStack {
            Text("\(index + 1)")
                .font(.caption)
                .padding(4)
                .background(.black.opacity(0.7))
                .cornerRadius(4)
            
            if let img = model.getCachedImage(at: index) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .background(Color.black)
                    .cornerRadius(4)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
    }
}

struct ScrollerInteractionView: NSViewRepresentable {
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
        
        // MARK: - Mouse Events
        override func mouseDown(with event: NSEvent) {
            handleDrag(event)
        }
        
        override func mouseDragged(with event: NSEvent) {
            handleDrag(event)
        }
        
        private func handleDrag(_ event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            // Flip Y for SwiftUI
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
