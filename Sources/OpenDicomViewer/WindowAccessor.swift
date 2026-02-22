// WindowAccessor.swift
// OpenDicomViewer
//
// NSViewRepresentable that customizes the hosting NSWindow on appear:
// hides the titlebar, removes traffic light buttons, and enables
// window dragging by background. Used to achieve a clean, immersive
// viewer interface.

import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                
                // Hide Traffic Lights
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                
                // Allow moving by dragging background
                window.isMovableByWindowBackground = true
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
    }
}
