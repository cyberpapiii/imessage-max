// Sources/iMessageMax/Utilities/MessageTextExtractor.swift
import Foundation

enum MessageTextExtractor {
    /// Extract displayable text from a message, trying plain text first,
    /// then falling back to attributedBody binary parsing.
    /// Replaces \u{FFFC} (object replacement character) with [Photo].
    static func extract(text: String?, attributedBody: Data?) -> String? {
        if let text = text, !text.isEmpty {
            return text.replacingOccurrences(of: "\u{FFFC}", with: "[Photo]")
        }
        guard let blob = attributedBody else { return nil }
        guard let parsed = extractFromTypedstream(blob) else { return nil }
        return parsed.replacingOccurrences(of: "\u{FFFC}", with: "[Photo]")
    }

    /// Parse Apple typedstream format to extract plain text.
    /// Searches for "NSString" / "NSMutableString" marker, skips 5 bytes,
    /// reads length byte (0x81 = 2-byte, 0x82 = 3-byte, else single byte),
    /// then reads UTF-8 text of that length.
    static func extractFromTypedstream(_ data: Data) -> String? {
        // Look for NSString or NSMutableString marker in the typedstream
        guard let nsStringRange = data.range(of: Data("NSString".utf8)) ??
              data.range(of: Data("NSMutableString".utf8)) else {
            return nil
        }

        // Skip past the class name marker to the length field
        // The format is: marker + some bytes + length + data
        let idx = nsStringRange.upperBound + 5

        guard idx < data.count else { return nil }

        let lengthByte = data[idx]
        let length: Int
        let dataStart: Int

        // Parse length based on prefix byte
        if lengthByte == 0x81 {
            // 2-byte length (little endian)
            guard idx + 3 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            // 3-byte length (little endian)
            guard idx + 4 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8) | (Int(data[idx + 3]) << 16)
            dataStart = idx + 4
        } else {
            // Single byte length
            length = Int(lengthByte)
            dataStart = idx + 1
        }

        guard length > 0 && dataStart + length <= data.count else { return nil }

        let textData = data[dataStart..<(dataStart + length)]
        return String(data: textData, encoding: .utf8)
    }
}
