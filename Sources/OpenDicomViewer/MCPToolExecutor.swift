// MCPToolExecutor.swift
// OpenDicomViewer
//
// Read-only MCP tool executor over the existing DICOMModel.

import Foundation
import DCMTKWrapper

final class MCPAuthorizer {
    private let roleTools: [MCPRole: Set<String>] = [
        .radiologist: [
            "dicom.list_series", "dicom.get_slice", "dicom.get_tags",
            "measure.distance", "measure.angle", "measure.roi_stats",
            "tracking.find_matching_slice", "volume.get_mpr"
        ],
        .resident: [
            "dicom.list_series", "dicom.get_slice", "dicom.get_tags",
            "measure.distance", "measure.angle", "measure.roi_stats",
            "tracking.find_matching_slice"
        ],
        .researcher: [
            "dicom.list_series", "dicom.get_slice",
            "measure.roi_stats", "tracking.find_matching_slice"
        ],
        .admin: [
            "dicom.list_series", "dicom.get_slice", "dicom.get_tags",
            "measure.distance", "measure.angle", "measure.roi_stats",
            "tracking.find_matching_slice", "volume.get_mpr"
        ]
    ]

    func authorize(tool: String, context: MCPRequestContext) -> MCPToolError? {
        guard let allowed = roleTools[context.role], allowed.contains(tool) else {
            return MCPToolError(code: "ODV_FORBIDDEN", message: "Tool is not permitted for role", details: ["tool": .string(tool)])
        }
        if tool == "dicom.get_tags" && !context.scopes.contains("scope:tags.read_phi") && context.role != .resident {
            return MCPToolError(code: "ODV_FORBIDDEN", message: "Missing scope:tags.read_phi", details: [:])
        }
        if context.role == .admin, context.breakGlassReason == nil, tool == "dicom.get_tags" {
            return MCPToolError(code: "ODV_BREAK_GLASS_REQUIRED", message: "Admin PHI access requires break-glass reason", details: [:])
        }
        return nil
    }
}

@MainActor
final class MCPToolExecutor {
    private let model: DICOMModel
    private let authorizer: MCPAuthorizer
    private weak var auditLogger: MCPAuditLogging?

    private let phiTags: Set<String> = [
        "(0010,0010)", "(0010,0020)", "(0010,0030)", "(0010,0040)", "(0010,1000)", "(0010,1001)"
    ]
    private let safeTags: Set<String> = [
        "(0008,0060)", "(0020,000D)", "(0020,000E)", "(0020,0032)", "(0020,0037)", "(0028,0030)"
    ]

    init(model: DICOMModel, authorizer: MCPAuthorizer = MCPAuthorizer(), auditLogger: MCPAuditLogging? = nil) {
        self.model = model
        self.authorizer = authorizer
        self.auditLogger = auditLogger
    }

    func handle(request: MCPToolRequest, context: MCPRequestContext) -> MCPToolResponse {
        let startedAt = Date()
        let response: MCPToolResponse

        if let authError = authorizer.authorize(tool: request.tool, context: context) {
            response = .failure(requestID: request.requestID, code: authError.code, message: authError.message, details: authError.details)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        }

        switch request.tool {
        case "dicom.list_series":
            response = listSeries(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        case "dicom.get_slice":
            let result = getSlice(requestID: request.requestID, input: request.input)
            logAudit(
                request: request,
                context: context,
                response: result.response,
                startedAt: startedAt,
                seriesID: result.seriesID,
                studyUID: result.studyUID,
                phiAccessed: false
            )
            return result.response
        case "dicom.get_tags":
            let result = getTags(requestID: request.requestID, input: request.input, context: context)
            logAudit(
                request: request,
                context: context,
                response: result.response,
                startedAt: startedAt,
                seriesID: result.seriesID,
                studyUID: result.studyUID,
                phiAccessed: true
            )
            return result.response
        case "measure.distance":
            response = measureDistance(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        case "measure.angle":
            response = measureAngle(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        case "measure.roi_stats":
            response = measureROIStats(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        case "tracking.find_matching_slice":
            response = trackingFindMatchingSlice(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        case "volume.get_mpr":
            response = volumeGetMPR(requestID: request.requestID, input: request.input)
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        default:
            response = .failure(requestID: request.requestID, code: "ODV_INVALID_TOOL", message: "Unsupported tool", details: ["tool": .string(request.tool)])
            logAudit(request: request, context: context, response: response, startedAt: startedAt, seriesID: nil, studyUID: nil, phiAccessed: false)
            return response
        }
    }

    private func listSeries(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        let studyUID = input["study_uid"]?.string
        let includeStats = input["include_stats"]?.bool ?? false

        var seriesPayload: [JSONValue] = []
        for (index, series) in model.allSeries.enumerated() {
            guard studyUID == nil || series.images.first?.studyInstanceUID == studyUID else { continue }
            var obj: [String: JSONValue] = [
                "series_id": .string(series.id),
                "series_number": .number(Double(series.seriesNumber)),
                "description": .string(series.seriesDescription),
                "image_count": .number(Double(series.images.count))
            ]
            if let sUID = series.images.first?.studyInstanceUID {
                obj["study_uid"] = .string(sUID)
            }
            if includeStats {
                obj["is_volumetric"] = .bool(model.isSeriesVolumetric(seriesIndex: index))
            }
            seriesPayload.append(.object(obj))
        }
        return .success(requestID: requestID, data: ["series": .array(seriesPayload)])
    }

    private func getSlice(requestID: String, input: [String: JSONValue]) -> (response: MCPToolResponse, seriesID: String?, studyUID: String?) {
        guard let seriesID = input["series_id"]?.string else {
            return (.failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "series_id is required"), nil, nil)
        }
        guard let idxRaw = input["index"]?.int, idxRaw >= 0 else {
            return (.failure(requestID: requestID, code: "ODV_INVALID_INDEX", message: "index must be >= 0"), seriesID, nil)
        }
        guard let series = model.allSeries.first(where: { $0.id == seriesID }) else {
            return (.failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Series not found"), seriesID, nil)
        }
        guard idxRaw < series.images.count else {
            return (.failure(requestID: requestID, code: "ODV_SLICE_NOT_FOUND", message: "Slice index out of range"), seriesID, series.images.first?.studyInstanceUID)
        }
        let ctx = series.images[idxRaw]
        var payload: [String: JSONValue] = [
            "series_id": .string(seriesID),
            "index": .number(Double(idxRaw)),
            "image_ref": .string("file://\(ctx.url.path)")
        ]
        if let z = ctx.zLocation { payload["z_location"] = .number(z) }
        if let pos = ctx.imagePosition {
            payload["image_position"] = .array([.number(pos.x), .number(pos.y), .number(pos.z)])
        }
        if let orient = ctx.imageOrientation {
            payload["image_orientation"] = .array(orient.map { .number($0) })
        }
        if let spacing = ctx.pixelSpacing {
            payload["pixel_spacing"] = .array([.number(spacing.x), .number(spacing.y)])
        }
        return (.success(requestID: requestID, data: payload), seriesID, ctx.studyInstanceUID)
    }

    private func getTags(requestID: String, input: [String: JSONValue], context: MCPRequestContext) -> (response: MCPToolResponse, seriesID: String?, studyUID: String?) {
        guard let seriesID = input["series_id"]?.string else {
            return (.failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "series_id is required"), nil, nil)
        }
        guard let idxRaw = input["index"]?.int, idxRaw >= 0 else {
            return (.failure(requestID: requestID, code: "ODV_INVALID_INDEX", message: "index must be >= 0"), seriesID, nil)
        }
        guard let series = model.allSeries.first(where: { $0.id == seriesID }) else {
            return (.failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Series not found"), seriesID, nil)
        }
        guard idxRaw < series.images.count else {
            return (.failure(requestID: requestID, code: "ODV_SLICE_NOT_FOUND", message: "Slice index out of range"), seriesID, series.images.first?.studyInstanceUID)
        }

        let requestedTags = Set(input["tags"]?.stringArray ?? [])
        let fileURL = series.images[idxRaw].url

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let parser = SimpleDicomParser(data: data)
            let (elements, _, _) = try parser.parse(stopAtPixelData: true)

            let filtered = elements.filter { el in
                let tagStr = el.tag.description
                if !requestedTags.isEmpty && !requestedTags.contains(tagStr) { return false }
                if context.scopes.contains("scope:tags.read_phi") { return true }
                return safeTags.contains(tagStr)
            }

            let tagsPayload: [JSONValue] = filtered.map { el in
                let tagStr = el.tag.description
                let maskedValue = maskTagValue(tag: tagStr, value: stringifyTagValue(el), level: context.maskingLevel, allowPHI: context.scopes.contains("scope:tags.read_phi"))
                return .object([
                    "tag": .string(tagStr),
                    "vr": .string(el.vr.rawValue),
                    "value": .string(maskedValue)
                ])
            }

            return (
                .success(requestID: requestID, data: ["tags": .array(tagsPayload)]),
                seriesID,
                series.images[idxRaw].studyInstanceUID
            )
        } catch {
            return (
                .failure(requestID: requestID, code: "ODV_INTERNAL", message: "Failed to parse DICOM tags", details: ["reason": .string(error.localizedDescription)]),
                seriesID,
                series.images[idxRaw].studyInstanceUID
            )
        }
    }

    private func measureDistance(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        guard
            let seriesID = input["series_id"]?.string,
            let idxRaw = input["index"]?.int,
            let p1 = point2D(from: input["p1"]),
            let p2 = point2D(from: input["p2"]),
            idxRaw >= 0
        else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "series_id/index/p1/p2 are required")
        }
        guard let series = model.allSeries.first(where: { $0.id == seriesID }), idxRaw < series.images.count else {
            return .failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Series or index not found")
        }

        let ctx = series.images[idxRaw]
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let distance: Double
        let spacingUsed: Bool
        if let spacing = ctx.pixelSpacing {
            distance = sqrt(pow(dx * spacing.y, 2) + pow(dy * spacing.x, 2))
            spacingUsed = true
        } else {
            distance = sqrt(dx * dx + dy * dy)
            spacingUsed = false
        }
        return .success(requestID: requestID, data: [
            "distance_mm": .number(distance),
            "pixel_spacing_used": .bool(spacingUsed)
        ])
    }

    private func measureAngle(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        guard
            point2D(from: input["vertex"]) != nil,
            let vertex = point2D(from: input["vertex"]),
            let arm1 = point2D(from: input["arm1"]),
            let arm2 = point2D(from: input["arm2"])
        else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "vertex/arm1/arm2 are required")
        }

        let v1x = arm1.x - vertex.x
        let v1y = arm1.y - vertex.y
        let v2x = arm2.x - vertex.x
        let v2y = arm2.y - vertex.y
        let dot = v1x * v2x + v1y * v2y
        let mag1 = sqrt(v1x * v1x + v1y * v1y)
        let mag2 = sqrt(v2x * v2x + v2y * v2y)

        var degrees = 0.0
        if mag1 > 0, mag2 > 0 {
            let cosAngle = max(-1.0, min(1.0, dot / (mag1 * mag2)))
            degrees = acos(cosAngle) * 180.0 / .pi
        }
        return .success(requestID: requestID, data: ["angle_deg": .number(degrees)])
    }

    private func measureROIStats(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        guard
            let seriesID = input["series_id"]?.string,
            let idxRaw = input["index"]?.int,
            let rectObj = input["rect"]?.object,
            let rx = rectObj["x"]?.double,
            let ry = rectObj["y"]?.double,
            let rw = rectObj["width"]?.double,
            let rh = rectObj["height"]?.double
        else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "series_id/index/rect are required")
        }
        guard let series = model.allSeries.first(where: { $0.id == seriesID }), idxRaw >= 0, idxRaw < series.images.count else {
            return .failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Series or index not found")
        }
        if rw <= 0 || rh <= 0 {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "rect.width and rect.height must be > 0")
        }

        let filePath = series.images[idxRaw].url.path
        var width = 0
        var height = 0
        var bitDepth = 0
        var samples = 0
        var signed = ObjCBool(false)
        guard let data = DCMTKHelper.getRawPixelData(filePath, width: &width, height: &height, bitDepth: &bitDepth, samples: &samples, isSigned: &signed) else {
            return .failure(requestID: requestID, code: "ODV_PIXEL_DATA_UNAVAILABLE", message: "Unable to decode pixel data")
        }

        let minX = max(0, Int(rx))
        let minY = max(0, Int(ry))
        let maxX = min(width - 1, Int(rx + rw))
        let maxY = min(height - 1, Int(ry + rh))
        guard maxX > minX, maxY > minY else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "ROI out of bounds")
        }

        var values: [Double] = []
        values.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        let countPixels = width * height
        data.withUnsafeBytes { raw in
            for y in minY...maxY {
                for x in minX...maxX {
                    let i = y * width + x
                    guard i >= 0, i < countPixels else { continue }
                    let v: Double
                    switch bitDepth {
                    case ..<16:
                        v = Double(raw[i])
                    case 16..<32:
                        let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt16.self)
                        if signed.boolValue {
                            v = Double(Int16(bitPattern: ptr[i]))
                        } else {
                            v = Double(ptr[i])
                        }
                    default:
                        let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
                        if signed.boolValue {
                            v = Double(Int32(bitPattern: ptr[i]))
                        } else {
                            v = Double(ptr[i])
                        }
                    }
                    values.append(v)
                }
            }
        }

        guard !values.isEmpty else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "ROI contains no pixels")
        }
        let count = values.count
        let sum = values.reduce(0, +)
        let mean = sum / Double(count)
        let maxVal = values.max() ?? 0
        let minVal = values.min() ?? 0
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        let stdDev = sqrt(variance)

        return .success(requestID: requestID, data: [
            "mean": .number(mean),
            "min": .number(minVal),
            "max": .number(maxVal),
            "std_dev": .number(stdDev),
            "count": .number(Double(count))
        ])
    }

    private func trackingFindMatchingSlice(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        guard
            let sourceSeriesID = input["source_series_id"]?.string,
            let sourceIndex = input["source_index"]?.int,
            let targetSeriesID = input["target_series_id"]?.string
        else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "source_series_id/source_index/target_series_id are required")
        }
        guard
            let source = model.allSeries.first(where: { $0.id == sourceSeriesID }),
            let target = model.allSeries.first(where: { $0.id == targetSeriesID })
        else {
            return .failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Source or target series not found")
        }
        guard sourceIndex >= 0, sourceIndex < source.images.count else {
            return .failure(requestID: requestID, code: "ODV_INVALID_INDEX", message: "source_index out of range")
        }

        let sourceZ = source.images[sourceIndex].zLocation
        let method: String
        let targetIndex: Int
        let deltaZ: Double?

        if let z = sourceZ {
            let targetZ = target.images.map { $0.zLocation }
            if targetZ.compactMap({ $0 }).count == target.images.count, !target.images.isEmpty {
                var bestIdx = 0
                var bestDist = Double.greatestFiniteMagnitude
                for (idx, value) in targetZ.enumerated() {
                    let dist = abs((value ?? 0) - z)
                    if dist < bestDist {
                        bestDist = dist
                        bestIdx = idx
                    }
                }
                method = "z-match"
                targetIndex = bestIdx
                deltaZ = bestDist
            } else {
                let pct = source.images.count > 1 ? Double(sourceIndex) / Double(source.images.count - 1) : 0
                targetIndex = max(0, min(target.images.count - 1, Int(pct * Double(max(target.images.count - 1, 0)))))
                method = "proportional"
                deltaZ = nil
            }
        } else {
            let pct = source.images.count > 1 ? Double(sourceIndex) / Double(source.images.count - 1) : 0
            targetIndex = max(0, min(target.images.count - 1, Int(pct * Double(max(target.images.count - 1, 0)))))
            method = "proportional"
            deltaZ = nil
        }

        var payload: [String: JSONValue] = [
            "target_index": .number(Double(targetIndex)),
            "method": .string(method)
        ]
        if let deltaZ {
            payload["delta_z_mm"] = .number(deltaZ)
        }
        return .success(requestID: requestID, data: payload)
    }

    private func volumeGetMPR(requestID: String, input: [String: JSONValue]) -> MCPToolResponse {
        guard let seriesID = input["series_id"]?.string, let mode = input["mode"]?.string else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "series_id/mode are required")
        }
        guard let idx = model.allSeries.firstIndex(where: { $0.id == seriesID }) else {
            return .failure(requestID: requestID, code: "ODV_SERIES_NOT_FOUND", message: "Series not found")
        }
        guard ["mprSagittal", "mprCoronal", "mip"].contains(mode) else {
            return .failure(requestID: requestID, code: "ODV_INVALID_ARGUMENT", message: "mode must be one of mprSagittal/mprCoronal/mip")
        }
        guard model.isSeriesVolumetric(seriesIndex: idx) else {
            return .failure(requestID: requestID, code: "ODV_VOLUME_NOT_VOLUMETRIC", message: "Series is not volumetric")
        }

        let series = model.allSeries[idx]
        let defaultIndex = max(0, series.images.count / 2)
        let sliceIndex = max(0, input["slice_index"]?.int ?? defaultIndex)
        let slabThickness = max(1, input["slab_thickness"]?.int ?? 10)

        var payload: [String: JSONValue] = [
            "mode": .string(mode),
            "slice_index": .number(Double(sliceIndex)),
            "slab_thickness": .number(Double(slabThickness)),
            "image_ref": .string("internal://mpr/\(seriesID)/\(mode)/\(sliceIndex)")
        ]

        if let first = series.images.first, let pos = first.imagePosition, let orient = first.imageOrientation, orient.count == 6 {
            payload["world_plane"] = .object([
                "origin": .array([.number(pos.x), .number(pos.y), .number(pos.z)]),
                "row_dir": .array([.number(orient[0]), .number(orient[1]), .number(orient[2])]),
                "col_dir": .array([.number(orient[3]), .number(orient[4]), .number(orient[5])])
            ])
        }
        return .success(requestID: requestID, data: payload)
    }

    private func maskTagValue(tag: String, value: String, level: MCPMaskingLevel, allowPHI: Bool) -> String {
        if allowPHI { return value }
        if !phiTags.contains(tag) { return value }
        switch level {
        case .none: return value
        case .partial:
            if value.count <= 3 { return "***" }
            let prefix = String(value.prefix(3))
            return "\(prefix)***"
        case .strict:
            return "[REDACTED]"
        }
    }

    private func stringifyTagValue(_ el: DicomElement) -> String {
        if el.length > 100 { return "Data (\(el.length) bytes)" }
        if let str = el.stringValue, !str.isEmpty { return str }
        if let intVal = el.intValue { return "\(intVal)" }
        return "\(el.data.count) bytes"
    }

    private func point2D(from value: JSONValue?) -> (x: Double, y: Double)? {
        guard let obj = value?.object, let x = obj["x"]?.double, let y = obj["y"]?.double else { return nil }
        return (x, y)
    }

    private func logAudit(
        request: MCPToolRequest,
        context: MCPRequestContext,
        response: MCPToolResponse,
        startedAt: Date,
        seriesID: String?,
        studyUID: String?,
        phiAccessed: Bool
    ) {
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event = MCPAuditEvent(
            eventID: UUID().uuidString,
            timestamp: formatter.string(from: Date()),
            userID: context.userID,
            role: context.role.rawValue,
            tool: request.tool,
            requestID: request.requestID,
            patientContextID: context.patientContextID,
            studyUID: studyUID,
            seriesID: seriesID,
            status: response.ok ? "success" : "error",
            latencyMS: elapsed,
            phiAccessed: phiAccessed,
            maskingLevel: context.maskingLevel.rawValue,
            errorCode: response.error?.code
        )
        auditLogger?.log(event: event)
    }
}

private extension JSONValue {
    var string: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    var bool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
    var int: Int? {
        if case .number(let v) = self { return Int(v) }
        return nil
    }
    var double: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    var object: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    var stringArray: [String] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap { $0.string }
    }
}

