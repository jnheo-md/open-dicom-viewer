// DICOMThumbnailRenderer.swift
// OpenDicomViewer
// Licensed under the MIT License. See LICENSE for details.

import AppKit
import DCMTKWrapper

/// Thumbnail rendering follows the same DICOM decoder as the viewer. Applying
/// VOI before conversion to eight bits preserves CT soft-tissue contrast; an
/// eight-bit contrast stretch cannot recover values already rounded to black.
enum DICOMThumbnailRenderer {
    struct Metadata {
        let windowWidth: Double?
        let windowCenter: Double?
        let slope: Double
        let intercept: Double
        let monochrome1: Bool
        let paddingValue: Double?
        let bitsStored: Int?

        init(elements: [DicomElement]) {
            func value(_ group: UInt16, _ element: UInt16) -> DicomElement? {
                elements.first { $0.tag == DicomTag(group: group, element: element) }
            }
            func number(_ group: UInt16, _ element: UInt16) -> Double? {
                guard let item = value(group, element) else { return nil }
                if item.vr == .SS, item.data.count == 2 {
                    let value = item.data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
                    return Double(Int16(bitPattern: value))
                }
                if item.vr == .US, item.data.count == 2 {
                    return Double(item.data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian })
                }
                if let text = item.stringValue?.components(separatedBy: "\\").first,
                   let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
                    return number
                }
                return item.intValue.map(Double.init)
            }
            windowWidth = number(0x0028, 0x1051)
            windowCenter = number(0x0028, 0x1050)
            slope = number(0x0028, 0x1053) ?? 1
            intercept = number(0x0028, 0x1052) ?? 0
            monochrome1 = value(0x0028, 0x0004)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "MONOCHROME1"
            paddingValue = number(0x0028, 0x0120)
            bitsStored = number(0x0028, 0x0101).map(Int.init)
        }

        var window: (width: Double, center: Double)? {
            guard let width = windowWidth, let center = windowCenter,
                  width > 0, width.isFinite, center.isFinite else { return nil }
            return (width, center)
        }
    }

    static func render(_ context: DicomImageContext, maximumPixelSize: Int = 96) -> NSImage? {
        if context.numberOfFrames > 1,
           let decoder = MultiFrameDecoder(url: context.url),
           let image = decoder.frameImage(at: decoder.effectiveFrameCount / 2) {
            return resized(image, maximumPixelSize: maximumPixelSize)
        }

        let metadata = readMetadata(context.url)
        if let image = DCMTKImageObject(path: context.url.path) {
            var width = 0, height = 0, depth = 0, samples = 0
            var signed: ObjCBool = false
            guard let data = image.getRawDataWidth(&width, height: &height, bitDepth: &depth,
                                                  samples: &samples, isSigned: &signed) else { return nil }
            // DCMTK has already applied the modality transform to raw values.
            let padding = metadata.paddingValue.map { $0 * metadata.slope + metadata.intercept }
            let window = samples == 1 ? (metadata.window ?? robustWindow(data: data, bitDepth: depth,
                signed: signed.boolValue, padding: padding)) : (width: 0.0, center: 0.0)
            guard let rendered = image.renderImage(withWidth: 0, height: 0,
                                                    ww: samples == 1 ? window.width : 0,
                                                    wc: samples == 1 ? window.center : 0) else { return nil }
            return resized(rendered, maximumPixelSize: maximumPixelSize)
        }

        // OpenJPEG returns stored samples, so apply rescale before VOI here.
        var width = 0, height = 0, depth = 0, samples = 0
        var signed: ObjCBool = false
        guard let data = DCMTKHelper.decodeJPEG2000DICOM(context.url.path, width: &width, height: &height,
                bitDepth: &depth, samples: &samples, isSigned: &signed),
              let rendered = renderStoredPixels(data: data, width: width, height: height, bitDepth: depth,
                    samples: samples, signed: signed.boolValue, metadata: metadata) else { return nil }
        return resized(rendered, maximumPixelSize: maximumPixelSize)
    }

    private static func readMetadata(_ url: URL) -> Metadata {
        guard let file = try? FileHandle(forReadingFrom: url) else { return Metadata(elements: []) }
        defer { try? file.close() }
        let data = file.readData(ofLength: 65_536)
        let elements = (try? SimpleDicomParser(data: data).parse(stopAtPixelData: true))?.0 ?? []
        return Metadata(elements: elements)
    }

    /// Percentiles exclude padding and isolated hot pixels when no VOI is
    /// supplied. Reading the returned storage depth also handles 32-bit rescale.
    static func robustWindow(data: Data, bitDepth: Int, signed: Bool, slope: Double = 1,
                             intercept: Double = 0, padding: Double? = nil) -> (width: Double, center: Double) {
        let values = scalarValues(data: data, bitDepth: bitDepth, signed: signed, sampleLimit: 50_000)
            .map { $0 * slope + intercept }.filter { $0.isFinite && $0 != padding }.sorted()
        guard let first = values.first, let last = values.last else { return (1, 0) }
        let low = values[Int(Double(values.count - 1) * 0.01)]
        let high = values[Int(Double(values.count - 1) * 0.99)]
        let lower = high > low ? low : first
        let upper = high > low ? high : last
        return (max(1, upper - lower), (lower + upper) / 2)
    }

    private static func scalarValues(data: Data, bitDepth: Int, signed: Bool, sampleLimit: Int = .max) -> [Double] {
        let byteCount = bitDepth > 16 ? 4 : bitDepth > 8 ? 2 : 1
        guard [8, 16, 32].contains(bitDepth) else { return [] }
        let count = data.count / byteCount
        let step = max(1, count / sampleLimit)
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: count, by: step).map { index in
                switch byteCount {
                case 4:
                    let value = bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self).littleEndian
                    return signed ? Double(Int32(bitPattern: value)) : Double(value)
                case 2:
                    let value = bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self).littleEndian
                    return signed ? Double(Int16(bitPattern: value)) : Double(value)
                default:
                    let value = bytes[index]
                    return signed ? Double(Int8(bitPattern: value)) : Double(value)
                }
            }
        }
    }

    static func renderStoredPixels(data: Data, width: Int, height: Int, bitDepth: Int, samples: Int,
                                   signed: Bool, metadata: Metadata) -> NSImage? {
        guard width > 0, height > 0, [1, 3].contains(samples) else { return nil }
        let values = scalarValues(data: data, bitDepth: bitDepth, signed: signed)
        guard values.count >= width * height * samples else { return nil }
        let output: [UInt8]
        if samples == 3 {
            // OpenJPEG color components are interleaved. Keep their color, using
            // their full bit range when the stream carries more than eight bits.
            let precision = min(bitDepth, max(1, metadata.bitsStored ?? bitDepth))
            let maximum = pow(2.0, Double(precision)) - 1
            output = values.prefix(width * height * samples).map { UInt8(clamping: Int(($0 / maximum * 255).rounded())) }
        } else {
            let padding = metadata.paddingValue.map { $0 * metadata.slope + metadata.intercept }
            let window = metadata.window ?? robustWindow(data: data, bitDepth: bitDepth, signed: signed,
                                                          slope: metadata.slope, intercept: metadata.intercept, padding: padding)
            output = values.prefix(width * height).map { stored in
                let value = stored * metadata.slope + metadata.intercept
                // DICOM linear VOI, including the width-one threshold case.
                let normalized = window.width <= 1 ? (value > window.center - 0.5 ? 1.0 : 0.0)
                    : min(1, max(0, (value - (window.center - 0.5)) / (window.width - 1) + 0.5))
                return UInt8(((metadata.monochrome1 ? 1 - normalized : normalized) * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: samples * 8,
                    bytesPerRow: width * samples, space: samples == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }

    static func resized(_ image: NSImage, maximumPixelSize: Int) -> NSImage? {
        guard maximumPixelSize > 0,
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, Double(maximumPixelSize) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        // An RGB destination preserves both color images and grayscale tones.
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = bitmap.makeImage() else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
    }
}
