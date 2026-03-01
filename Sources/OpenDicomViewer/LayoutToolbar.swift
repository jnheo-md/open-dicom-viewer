// LayoutToolbar.swift
// OpenDicomViewer
//
// Floating toolbar overlay in the top-right corner of the detail area.
// Provides buttons for:
//   - Panel layout switching (1x1, 2x1, 1x2, 2x2) with number key badges
//   - Synchronized scrolling toggle (link icon, "L" key)
//   - Cross-reference line toggle (cross icon, "X" key)
// Each button shows its keyboard shortcut as a small badge.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

/// Floating toolbar for switching panel layouts and toggling synchronized scrolling.
struct LayoutToolbar: View {
    @ObservedObject var model: DICOMModel

    /// Shortcut label for each layout (matched to ViewerLayout.allCases order)
    private static let layoutKeys = ["1", "2", "3", "4"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ViewerLayout.allCases.enumerated()), id: \.element.id) { idx, layout in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        model.setLayout(layout)
                    }
                }) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: layout.iconName)
                            .font(.system(size: 14))
                            .foregroundStyle(
                                model.layout == layout ? .white : .secondary
                            )
                            .frame(width: 28, height: 28)

                        Text(Self.layoutKeys[idx])
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .offset(x: -2, y: -1)
                    }
                    .background(
                        model.layout == layout
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear
                    )
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("\(layout.rawValue) (\(Self.layoutKeys[idx]))")
            }

            Divider()
                .frame(height: 20)

            Button(action: { model.synchronizedScrolling.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: model.synchronizedScrolling ? "link" : "link.badge.plus")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            model.synchronizedScrolling ? .yellow : .secondary
                        )
                        .frame(width: 28, height: 28)

                    Text("L")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .offset(x: -2, y: -1)
                }
            }
            .buttonStyle(.plain)
            .help(model.synchronizedScrolling
                ? "Disable Synchronized Scrolling (L)"
                : "Enable Synchronized Scrolling (L)")

            Button(action: { model.showCrossReference.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "cross")
                        .font(.system(size: 14))
                        .foregroundStyle(
                            model.showCrossReference ? .cyan : .secondary
                        )
                        .frame(width: 28, height: 28)

                    Text("X")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .offset(x: -2, y: -1)
                }
            }
            .buttonStyle(.plain)
            .help(model.showCrossReference
                ? "Hide Cross-Reference Lines (X)"
                : "Show Cross-Reference Lines (X)")
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}
