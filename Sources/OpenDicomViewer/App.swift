// App.swift
// OpenDicomViewer
//
// Application entry point. Configures the main window with a hidden titlebar
// and registers menu bar commands for layout switching, view operations
// (window/level, transforms, overlays), MPR mode, and synchronized scrolling.

import SwiftUI

@main
struct OpenDicomViewerApp: App {
    @StateObject private var model = DICOMModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("View") {
                // ─ Window/Level ─
                Button("Auto Window/Level") {
                    if let panel = model.activePanel {
                        model.autoWindowLevelForPanel(panel)
                    }
                }

                Button("Invert") {
                    model.invertForPanel(model.activePanel)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                // ─ Transform ─
                Button("Fit to Window") {
                    model.fitToWindowForPanel(model.activePanel)
                }

                Button("Reset View") {
                    model.resetViewForPanel(model.activePanel)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Rotate Clockwise 90°") {
                    model.rotateClockwiseForPanel(model.activePanel)
                }
                .keyboardShortcut("]", modifiers: .command)

                Button("Rotate Counter-Clockwise 90°") {
                    model.rotateCounterClockwiseForPanel(model.activePanel)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Flip Horizontal") {
                    model.flipHorizontalForPanel(model.activePanel)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("Flip Vertical") {
                    model.flipVerticalForPanel(model.activePanel)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                // ─ Overlays ─
                Toggle("Cross-Reference Lines", isOn: $model.showCrossReference)
                    .keyboardShortcut("x", modifiers: [.command, .shift])

                Toggle("DICOM Tags Inspector", isOn: $model.showTags)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            CommandMenu("Layout") {
                Button("Single Panel") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.single) }
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Side by Side") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoHorizontal) }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Stacked") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.twoVertical) }
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Four Panels") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setLayout(.quad) }
                }
                .keyboardShortcut("4", modifiers: .command)

                Divider()

                Button("MPR Layout") {
                    withAnimation(.easeInOut(duration: 0.25)) { model.setupMPRLayout() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Divider()

                Toggle("Synchronized Scrolling", isOn: $model.synchronizedScrolling)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
