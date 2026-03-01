// TagView.swift
// OpenDicomViewer
//
// DICOM tag inspector view. Displays all parsed DICOM metadata elements
// for the currently selected image in a scrollable list. Each row shows
// the tag ID (group,element), VR, and value. Large binary values are
// summarized as byte counts.
// Licensed under the MIT License. See LICENSE for details.

import SwiftUI

struct TagView: View {
    let tags: [DicomElement]

    var body: some View {
        List(tags) { element in
            HStack {
                Text(element.tag.description)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(element.vr.rawValue)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                VStack(alignment: .leading) {
                    Text(displayValue(for: element))
                        .font(.body)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
            }
        }
        .navigationTitle("DICOM Tags")
    }
    
    private func displayValue(for element: DicomElement) -> String {
        if element.length > 100 {
            return "Data (\(element.length) bytes)"
        }
        if let str = element.stringValue {
            return str
        }
        if let intVal = element.intValue {
            return "\(intVal)"
        }
        return "\(element.data.count) bytes"
    }
}
