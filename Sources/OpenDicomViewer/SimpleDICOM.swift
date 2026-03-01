// SimpleDICOM.swift
// OpenDicomViewer
//
// Pure-Swift DICOM file parser. Reads DICOM Part 10 files without any
// external library dependencies. Used for fast metadata extraction during
// directory scanning (series UID, instance number, spatial metadata, etc.)
// while the heavier DCMTK wrapper handles pixel data decoding.
//
// Key types:
//   DicomTag           — (group, element) tag identifier with standard name lookup
//   DicomVR            — Value Representation enum (all standard DICOM VRs)
//   DicomElement       — Parsed tag: tag, VR, data, and convenience accessors
//   SimpleDicomParser  — Streaming parser that reads tags sequentially from Data,
//                        supports both explicit and implicit VR, little/big endian,
//                        and can stop at PixelData for fast header-only parsing
// Licensed under the MIT License. See LICENSE for details.

import Foundation

enum DicomError: Error {
    case invalidFile
    case notDicom
    case unsupportedTransferSyntax
    case endOfFile
}

enum VR: String {
    case AE, AS, AT, CS, DA, DS, DT, FL, FD, IS, LO, LT, OB, OD, OF, OL, OV, OW, PN, SH, SL, SQ, SS, ST, SV, TM, UC, UI, UL, UN, UR, US, UT, UV
    case unknown
}

struct DicomTag: Equatable, Hashable, CustomStringConvertible {
    let group: UInt16
    let element: UInt16
    
    var description: String {
        return String(format: "(%04X,%04X)", group, element)
    }
}

struct DicomElement: Identifiable {
    let tag: DicomTag
    let vr: VR
    let length: Int
    let data: Data
    
    var id: String { tag.description }
    
    var stringValue: String? {
        return data.robustString()
    }
    
    var intValue: Int? {
        if data.count == 2 {
            var val: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
            return Int(val)
        } else if data.count == 4 {
             var val: UInt32 = 0
             _ = withUnsafeMutableBytes(of: &val) { data.copyBytes(to: $0) }
             return Int(val)
        }
        return nil
    }
}

extension Data {
    func robustString() -> String? {
        // 1. Try UTF-8
        if let s = String(data: self, encoding: .utf8) {
            return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 2. Try Korean EUC-KR (Common in KR Medical)
        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0949)))
        if let s = String(data: self, encoding: eucKR) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 3. Try ISO-Latin-1 (Default DICOM)
        if let s = String(data: self, encoding: .isoLatin1) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 4. Fallback ASCII (Lossy)
        if let s = String(data: self, encoding: .ascii) {
             return s.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

class SimpleDicomParser {
    let data: Data
    var offset: Int = 0
    var isLittleEndian: Bool = true
    var isExplicitVR: Bool = true 
    var debugMode: Bool = false
    
    init(data: Data) {
        self.data = data
    }
    
    func parse(stopAtPixelData: Bool = false) throws -> ([DicomElement], Data?, String?) {
        guard data.count >= 132 else { throw DicomError.invalidFile }
        
        offset = 128
        let magic = data.subdata(in: offset..<offset+4)
        guard let magicStr = String(data: magic, encoding: .ascii), magicStr == "DICM" else {
            throw DicomError.notDicom
        }
        offset += 4
        
        if debugMode { print("DICM Header found. File size: \(data.count)") }
        
        var elements: [DicomElement] = []
        var pixelData: Data? = nil
        var transferSyntaxUID: String? = nil
        
        isLittleEndian = true
        isExplicitVR = true
        
        while offset < data.count {
             // Safety check for EOF peeking
             guard offset + 4 <= data.count else { 
                 if debugMode { print("Ending parse loop: Near EOF at \(offset)") }
                 break 
             }
             let groupNext = withUnsafeBytes(of: UInt16(0)) { ptr -> UInt16 in
                 var temp: UInt16 = 0
                 _ = withUnsafeMutableBytes(of: &temp) { 
                     data.copyBytes(to: $0, from: offset..<offset+2) 
                 }
                 return temp
             }.littleEndian 
             
             if groupNext != 0x0002 {
                 if let syntax = transferSyntaxUID {
                     applyTransferSyntax(syntax)
                 } else {
                     isExplicitVR = false
                     isLittleEndian = true
                 }
             }
             
            do {
                let element = try parseElement()
                elements.append(element)
                
                if element.tag == DicomTag(group: 0x0002, element: 0x0010) {
                 transferSyntaxUID = element.stringValue
                 if debugMode { print("Transfer Syntax: \(transferSyntaxUID ?? "nil")") }
             }
             
             if element.tag == DicomTag(group: 0x7FE0, element: 0x0010) {
                 if debugMode { print("Pixel Data Found! Length: \(element.length)") }
                 pixelData = element.data
                    if stopAtPixelData {
                        return (elements, nil, transferSyntaxUID)
                    }
                 }
            } catch DicomError.endOfFile {
                // If we hit EOF during an element parse, just stop and return what we have (truncated file support)
                // EOF reached — return captured elements
                break
            } catch {
                throw error
            }
        }
        
        return (elements, pixelData, transferSyntaxUID)
    }
    
    private func parseElement() throws -> DicomElement {
        let group = try readUInt16()
        let element = try readUInt16()
        let tag = DicomTag(group: group, element: element)
        
        var vr: VR = .unknown
        var length: Int = 0
        
        let isActuallyExplicit = isExplicitVR || (group == 0x0002)
        
        if isActuallyExplicit {
            let vrStr = try readString(length: 2)
            vr = VR(rawValue: vrStr) ?? .unknown
            
            if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"].contains(vrStr) {
                offset += 2
                let l = try readUInt32()
                length = Int(l)
            } else {
                let l = try readUInt16()
                length = Int(l)
            }
        } else {
            let l = try readUInt32()
            length = Int(l)
            vr = lookupVR(tag: tag)
        }
        
        if length == -1 || length == 0xFFFFFFFF {
             let d = try readUntitledSequence()
             return DicomElement(tag: tag, vr: vr, length: d.count, data: d)
        }
        
        // Tolerant read: if EOF, read what we have
        let runEnd = offset + length
        let safeEnd = min(runEnd, data.count)
        let actualLength = safeEnd - offset
        
        let valueData = data.subdata(in: offset..<safeEnd)
        offset = safeEnd // Advance by actual read amount
        
        // If we extracted less than expected, we might want to warn or just proceed.
        // For visualizer, proceeding is better.
        // However, if we are NOT at the end, this might desync the parser.
        // But usually mismatch happens at the very end (Pixel Data).
        
        // If we strictly enforced checks before, we would throw.
        // Now we return the partial element.
        
        return DicomElement(tag: tag, vr: vr, length: actualLength, data: valueData)
    }
    
    private func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw DicomError.endOfFile }
        var val: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &val) { valPtr in
            data.copyBytes(to: valPtr, from: offset..<offset+2)
        }
        offset += 2
        return isLittleEndian ? val.littleEndian : val.bigEndian
    }
    
    private func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw DicomError.endOfFile }
        var val: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &val) { valPtr in
            data.copyBytes(to: valPtr, from: offset..<offset+4)
        }
        offset += 4
        return isLittleEndian ? val.littleEndian : val.bigEndian
    }
    
    private func readString(length: Int) throws -> String {
        guard offset + length <= data.count else { throw DicomError.endOfFile }
        let d = data.subdata(in: offset..<offset+length)
        offset += length
        return d.robustString() ?? ""
    }
    
    private func readUntitledSequence() throws -> Data {
        let startIndex = offset
        while offset + 4 <= data.count {
             let b1 = data[offset]
             let b2 = data[offset+1]
             let b3 = data[offset+2]
             let b4 = data[offset+3]
             
             let isLE = (b1 == 0xFE && b2 == 0xFF && b3 == 0xDD && b4 == 0xE0)
             let isBE = (b1 == 0xFF && b2 == 0xFE && b3 == 0xE0 && b4 == 0xDD)
             
             if isLE || isBE {
                 offset += 4 
                 offset += 4 
                 return data.subdata(in: startIndex..<offset-8)
             }
             offset += 1
        }
        return data.subdata(in: startIndex..<data.count)
    }
    
    private func lookupVR(tag: DicomTag) -> VR {
        if tag.group == 0x7FE0 && tag.element == 0x0010 { return .OW } 
        return .UN
    }
    
    private func applyTransferSyntax(_ uid: String) {
        // Implicit VR Little Endian
        if uid == "1.2.840.10008.1.2" {
             isExplicitVR = false
             isLittleEndian = true
             return
        }
        
        // Explicit VR Big Endian
        if uid == "1.2.840.10008.1.2.2" {
             isExplicitVR = true
             isLittleEndian = false
             return
        }
        
        // Default: Explicit VR Little Endian
        // This covers:
        // - 1.2.840.10008.1.2.1 (Explicit VR Little Endian)
        // - 1.2.840.10008.1.2.4.xx (JPEG Encapsulated, always Explicit VR LE)
        // - 1.2.840.10008.1.2.5 (RLE, Explicit VR LE)
        isExplicitVR = true
        isLittleEndian = true
        }
    
    // Fallback: Scan entire data for a specific tag pattern (Explicit VR)
    func findTagRaw(_ target: DicomTag) -> String? {
        let g = target.group
        let e = target.element
        
        let targetBytes: [UInt8]
        if isLittleEndian {
            targetBytes = [
                UInt8(g & 0xFF), UInt8(g >> 8),
                UInt8(e & 0xFF), UInt8(e >> 8)
            ]
        } else {
             targetBytes = [
                 UInt8(g >> 8), UInt8(g & 0xFF),
                 UInt8(e >> 8), UInt8(e & 0xFF)
             ]
        }
        
        // Naive search
        // Optimization: Start searching after meta header (132 + 128?)
        var searchIdx = 132
        
        while searchIdx < data.count - 8 {
            if data[searchIdx] == targetBytes[0] &&
               data[searchIdx+1] == targetBytes[1] &&
               data[searchIdx+2] == targetBytes[2] &&
               data[searchIdx+3] == targetBytes[3] {
                
                // Found Tag. Check VR.
                let vrOffset = searchIdx + 4
                guard vrOffset + 2 <= data.count else { return nil }
                
                let vrBytes = data.subdata(in: vrOffset..<vrOffset+2)
                let vrStr = String(data: vrBytes, encoding: .ascii) ?? ""
                
                if VR(rawValue: vrStr) != nil {
                    // Valid explicit VR found
                     var valOffset = vrOffset + 2
                     var length = 0
                     
                     if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"].contains(vrStr) {
                         valOffset += 2 // Reserved
                         guard valOffset + 4 <= data.count else { break }
                         // Length is 32-bit
                         let lData = data.subdata(in: valOffset..<valOffset+4)
                         length = Int(lData.withUnsafeBytes { $0.load(as: UInt32.self) }) // Endianness?
                         // Assuming LE for simplified scan, or check isLittleEndian
                         if !isLittleEndian {
                             // Fix endian if BE
                             let val = lData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                             length = Int(val)
                         }
                         valOffset += 4
                     } else {
                         // Length is 16-bit
                         guard valOffset + 2 <= data.count else { break }
                         let lData = data.subdata(in: valOffset..<valOffset+2)
                         let val = lData.withUnsafeBytes { $0.load(as: UInt16.self) }
                         length = Int(isLittleEndian ? val : val.bigEndian)
                         valOffset += 2
                     }
                     
                     if length > 0 && length < 1000 && valOffset + length <= data.count {
                         let valData = data.subdata(in: valOffset..<valOffset+length)
                         return String(data: valData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
                             ?? String(data: valData, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters).trimmingCharacters(in: .whitespacesAndNewlines)
                     }
                }
            }
            searchIdx += 1
        }
        return nil
    }
}
