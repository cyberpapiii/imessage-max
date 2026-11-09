import Foundation

enum MessageTextExtractor {
    static let photoPlaceholder = "[Photo]"

    /// Replaces \u{FFFC} (object replacement character, one per inline
    /// attachment) with `photoPlaceholder`. Falls back to the attributedBody
    /// typedstream when plain text is empty.
    static func extract(text: String?, attributedBody: Data?) -> String? {
        let raw = text.flatMap { $0.isEmpty ? nil : $0 } ?? attributedBody.flatMap(extractFromTypedstream)
        return raw?.replacingOccurrences(of: "\u{FFFC}", with: photoPlaceholder)
    }

    /// Parses an Apple typedstream. It finds "NSString" or "NSMutableString",
    /// skips 5 bytes, and reads the length as a typedstream integer: a byte
    /// below 0x80 is the length itself, 0x81 means a little-endian 2-byte
    /// length follows, and 0x82 a little-endian 4-byte one (text of 32 KB or
    /// more). It then reads that many bytes as UTF-8 text.
    static func extractFromTypedstream(_ data: Data) -> String? {
        // Re-base the data. Callers may pass a Data slice whose indices don't
        // start at 0, and all the math below assumes zero-based absolute indexing.
        let data = data.startIndex == 0 ? data : Data(data)

        guard let nsStringRange = data.range(of: Data("NSString".utf8)) ??
              data.range(of: Data("NSMutableString".utf8)) else {
            return nil
        }

        let idx = nsStringRange.upperBound + 5

        guard idx < data.count else { return nil }

        let lengthByte = data[idx]
        let length: Int
        let dataStart: Int

        if lengthByte == 0x81 {
            guard idx + 3 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
            dataStart = idx + 3
        } else if lengthByte == 0x82 {
            guard idx + 5 <= data.count else { return nil }
            length = Int(data[idx + 1]) | (Int(data[idx + 2]) << 8)
                | (Int(data[idx + 3]) << 16) | (Int(data[idx + 4]) << 24)
            dataStart = idx + 5
        } else if lengthByte >= 0x80 {
            return nil
        } else {
            length = Int(lengthByte)
            dataStart = idx + 1
        }

        guard length > 0 && dataStart + length <= data.count else { return nil }

        let textData = data[dataStart..<(dataStart + length)]
        return String(data: textData, encoding: .utf8)
    }
}
