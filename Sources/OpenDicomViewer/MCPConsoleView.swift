// MCPConsoleView.swift
// OpenDicomViewer
//
// Simple in-app console to execute MCP JSON requests against the local
// MCPToolExecutor and inspect JSON responses/audit events.

import SwiftUI

struct MCPConsoleView: View {
    enum RequestTemplate: String, CaseIterable, Identifiable {
        case listSeries = "dicom.list_series"
        case getSlice = "dicom.get_slice"
        case getTags = "dicom.get_tags"
        case measureDistance = "measure.distance"
        case measureAngle = "measure.angle"
        case roiStats = "measure.roi_stats"
        case tracking = "tracking.find_matching_slice"
        case mpr = "volume.get_mpr"

        var id: String { rawValue }
    }

    @ObservedObject var model: DICOMModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTemplate: RequestTemplate = .listSeries
    @State private var requestJSON: String = """
{
  "request_id": "req-1",
  "tool": "dicom.list_series",
  "version": "1.0.0",
  "input": {
    "include_stats": true
  }
}
"""

    @State private var contextJSON: String = """
{
  "user_id": "local-user",
  "role": "radiologist",
  "scopes": ["scope:dicom.read", "scope:measure.read", "scope:tracking.read", "scope:volume.read", "scope:tags.read_phi"],
  "masking_level": "partial",
  "patient_context_id": "local-session",
  "break_glass_reason": null
}
"""

    @State private var responseJSON: String = ""
    @State private var statusMessage: String = "Ready"
    @State private var auditCount: Int = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("MCP Console")
                    .font(.headline)
                Spacer()
                Text("Audit: \(auditCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Template")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Template", selection: $selectedTemplate) {
                    ForEach(RequestTemplate.allCases) { template in
                        Text(template.rawValue).tag(template)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTemplate) { _, newValue in
                    requestJSON = templateJSON(for: newValue)
                    statusMessage = "Loaded template: \(newValue.rawValue)"
                }
                Spacer()
                Button("Load Template") {
                    requestJSON = templateJSON(for: selectedTemplate)
                    statusMessage = "Loaded template: \(selectedTemplate.rawValue)"
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Request JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $requestJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Context JSON")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $contextJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Response JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $responseJSON)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            }

            HStack {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Run MCP Request") {
                    runRequest()
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear {
            auditCount = model.mcpAuditLogger.snapshot().count
            requestJSON = templateJSON(for: selectedTemplate)
        }
    }

    private func runRequest() {
        do {
            let decoder = JSONDecoder()
            let reqData = Data(requestJSON.utf8)
            let ctxData = Data(contextJSON.utf8)
            let request = try decoder.decode(MCPToolRequest.self, from: reqData)
            let context = try decoder.decode(MCPRequestContext.self, from: ctxData)

            let executor = MCPToolExecutor(model: model, auditLogger: model.mcpAuditLogger)
            let response = executor.handle(request: request, context: context)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(response)
            responseJSON = String(decoding: encoded, as: UTF8.self)
            auditCount = model.mcpAuditLogger.snapshot().count
            statusMessage = response.ok ? "OK" : "Error: \(response.error?.code ?? "unknown")"
        } catch {
            statusMessage = "Decode error: \(error.localizedDescription)"
            responseJSON = ""
        }
    }

    private func templateJSON(for template: RequestTemplate) -> String {
        switch template {
        case .listSeries:
            return """
{
  "request_id": "req-list-1",
  "tool": "dicom.list_series",
  "version": "1.0.0",
  "input": {
    "include_stats": true
  }
}
"""
        case .getSlice:
            return """
{
  "request_id": "req-slice-1",
  "tool": "dicom.get_slice",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "index": 0,
    "panel_mode": "slice2D"
  }
}
"""
        case .getTags:
            return """
{
  "request_id": "req-tags-1",
  "tool": "dicom.get_tags",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "index": 0
  }
}
"""
        case .measureDistance:
            return """
{
  "request_id": "req-distance-1",
  "tool": "measure.distance",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "index": 0,
    "p1": { "x": 120, "y": 150 },
    "p2": { "x": 210, "y": 260 }
  }
}
"""
        case .measureAngle:
            return """
{
  "request_id": "req-angle-1",
  "tool": "measure.angle",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "index": 0,
    "vertex": { "x": 180, "y": 180 },
    "arm1": { "x": 130, "y": 210 },
    "arm2": { "x": 240, "y": 140 }
  }
}
"""
        case .roiStats:
            return """
{
  "request_id": "req-roi-1",
  "tool": "measure.roi_stats",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "index": 0,
    "rect": { "x": 100, "y": 120, "width": 80, "height": 70 }
  }
}
"""
        case .tracking:
            return """
{
  "request_id": "req-track-1",
  "tool": "tracking.find_matching_slice",
  "version": "1.0.0",
  "input": {
    "source_series_id": "REPLACE_SOURCE_SERIES_ID",
    "source_index": 0,
    "target_series_id": "REPLACE_TARGET_SERIES_ID"
  }
}
"""
        case .mpr:
            return """
{
  "request_id": "req-mpr-1",
  "tool": "volume.get_mpr",
  "version": "1.0.0",
  "input": {
    "series_id": "REPLACE_SERIES_ID",
    "mode": "mip",
    "slice_index": 10,
    "slab_thickness": 12
  }
}
"""
        }
    }
}
