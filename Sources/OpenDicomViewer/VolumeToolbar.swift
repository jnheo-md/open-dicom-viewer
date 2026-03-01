// VolumeToolbar.swift
// OpenDicomViewer
//
// Per-panel toolbar that appears at the top of each panel when a 3D volume
// is available. Provides controls for switching between display modes
// (2D Slice, Sagittal MPR, Coronal MPR, MIP) and adjusting MIP-specific
// parameters like slab thickness, projection type, and rotation.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Per-panel toolbar for switching between Slice/MPR/MIP modes.
/// Appears at the top of each panel when a series is assigned and a volume is available.
struct VolumeToolbar: View {
    @ObservedObject var model: DICOMModel
    @ObservedObject var panel: PanelState

    private var isVolumetric: Bool {
        model.isSeriesVolumetric(seriesIndex: panel.seriesIndex)
    }

    /// Maximum slab slices (volume depth)
    private var maxSlabSlices: Int {
        model.volumeSliceCount(seriesIndex: panel.seriesIndex)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelMode.allCases) { mode in
                modeButton(mode)
            }

            // MIP mode controls
            if panel.panelMode == .mip {
                Divider().frame(height: 16)

                // Projection mode picker
                Menu {
                    ForEach(ProjectionMode.allCases) { projMode in
                        Button(projMode.rawValue) {
                            model.loadMIPForPanel(panel, mode: projMode)
                        }
                    }
                } label: {
                    Text("MIP")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Divider().frame(height: 16)

                // Slab thickness slider (number of slices)
                // Only show when volume is ready (maxSlabSlices > 1), otherwise Slider crashes
                if maxSlabSlices > 1 {
                    Text("Slab")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(panel.mipSlabThickness) },
                            set: { panel.mipSlabThickness = max(1, Int($0)) }
                        ),
                        in: 1...Double(maxSlabSlices),
                        step: 1
                    ) {
                        Text("Slab")
                    } onEditingChanged: { editing in
                        if !editing {
                            model.loadMIPForPanel(panel)
                        }
                    }
                    .frame(width: 80)
                    Text("\(panel.mipSlabThickness)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                }
            }

            // Volume build progress
            if model.isVolumeBuildingInProgress {
                Divider().frame(height: 16)
                ProgressView(value: model.volumeBuildProgress)
                    .frame(width: 60)
                Text(String(format: "%.0f%%", model.volumeBuildProgress * 100))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            // Rotate / Flip controls
            Button(action: {
                panel.rotationSteps = (panel.rotationSteps + 1) % 4
            }) {
                Image(systemName: "rotate.right")
                    .font(.system(.caption))
            }
            .buttonStyle(.plain)
            .help("Rotate 90° clockwise")

            Button(action: {
                panel.isFlippedH.toggle()
            }) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(.caption))
                    .foregroundStyle(panel.isFlippedH ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Flip horizontal")

            Button(action: {
                panel.isFlippedV.toggle()
            }) {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    .font(.system(.caption))
                    .foregroundStyle(panel.isFlippedV ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Flip vertical")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .cornerRadius(6)
    }

    @ViewBuilder
    private func modeButton(_ mode: PanelMode) -> some View {
        let needsVolume = mode != .slice2D
        let modeDisabled = needsVolume && !isVolumetric
        let foreground: Color = modeDisabled ? .gray.opacity(0.35) :
            panel.panelMode == mode ? .white : .secondary
        Button(action: {
            model.setPanelMode(panel, mode: mode)
        }) {
            Text(mode.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundColor(foreground)
                .background(
                    panel.panelMode == mode
                        ? Color.accentColor.opacity(0.4)
                        : Color.clear
                )
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(modeDisabled)
    }
}
