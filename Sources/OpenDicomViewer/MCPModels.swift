// MCPModels.swift
// OpenDicomViewer
//
// Minimal MCP request/response contracts, authorization context, and
// audit event shapes for the in-app DICOM tool executor.

import Foundation

enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct MCPToolRequest: Codable {
    let requestID: String
    let tool: String
    let version: String
    let input: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case tool
        case version
        case input
    }
}

struct MCPToolError: Codable {
    let code: String
    let message: String
    let details: [String: JSONValue]
}

struct MCPToolResponse: Codable {
    let requestID: String
    let ok: Bool
    let data: [String: JSONValue]?
    let error: MCPToolError?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case ok
        case data
        case error
    }

    static func success(requestID: String, data: [String: JSONValue]) -> MCPToolResponse {
        MCPToolResponse(requestID: requestID, ok: true, data: data, error: nil)
    }

    static func failure(requestID: String, code: String, message: String, details: [String: JSONValue] = [:]) -> MCPToolResponse {
        MCPToolResponse(
            requestID: requestID,
            ok: false,
            data: nil,
            error: MCPToolError(code: code, message: message, details: details)
        )
    }
}

enum MCPRole: String, Codable {
    case radiologist
    case resident
    case researcher
    case admin
}

enum MCPMaskingLevel: String, Codable {
    case none
    case partial
    case strict
}

struct MCPRequestContext: Codable {
    let userID: String
    let role: MCPRole
    let scopes: [String]
    let maskingLevel: MCPMaskingLevel
    let patientContextID: String?
    let breakGlassReason: String?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
        case scopes
        case maskingLevel = "masking_level"
        case patientContextID = "patient_context_id"
        case breakGlassReason = "break_glass_reason"
    }
}

struct MCPAuditEvent: Codable {
    let eventID: String
    let timestamp: String
    let userID: String
    let role: String
    let tool: String
    let requestID: String
    let patientContextID: String?
    let studyUID: String?
    let seriesID: String?
    let status: String
    let latencyMS: Int
    let phiAccessed: Bool
    let maskingLevel: String
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp
        case userID = "user_id"
        case role
        case tool
        case requestID = "request_id"
        case patientContextID = "patient_context_id"
        case studyUID = "study_uid"
        case seriesID = "series_id"
        case status
        case latencyMS = "latency_ms"
        case phiAccessed = "phi_accessed"
        case maskingLevel = "masking_level"
        case errorCode = "error_code"
    }
}

protocol MCPAuditLogging: AnyObject {
    func log(event: MCPAuditEvent)
}

final class MCPInMemoryAuditLogger: MCPAuditLogging {
    private(set) var events: [MCPAuditEvent] = []
    private let lock = NSLock()

    func log(event: MCPAuditEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [MCPAuditEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
