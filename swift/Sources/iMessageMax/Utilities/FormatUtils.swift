// Sources/iMessageMax/Utilities/FormatUtils.swift
import Foundation

enum FormatUtils {
    private static let orderedKeys: [String] = [
        "status",
        "version",
        "process_id",
        "database",
        "contacts",
        "capabilities",
        "chats",
        "conversations",
        "attachments",
        "results",
        "chat",
        "state",
        "shared",
        "people",
        "message",
        "messages",
        "before",
        "after",
        "sessions",
        "total",
        "total_unread",
        "chats_with_unread",
        "total_chats",
        "total_groups",
        "total_dms",
        "window_hours",
        "chat_count",
        "query",
        "more",
        "cursor",
        "id",
        "type",
        "name",
        "match",
        "last_message",
        "message_preview",
        "awaiting_reply",
        "group",
        "participant_count",
        "participants_preview",
        "unread_count",
        "oldest_unread",
        "participants",
        "identity",
        "activity",
        "from",
        "excerpt",
        "text",
        "ago",
        "ts",
        "context_before",
        "context_after",
        "started",
        "message_count",
        "message_id",
        "reactions",
        "media",
        "links",
        "shared_summary",
        "session_id",
        "session_start",
        "session_gap_hours",
        "available",
        "size_human",
        "mime",
        "size",
        "delivered_to",
        "error",
        "candidates",
        "guid",
        "explicit_name",
        "is_named",
        "aliases",
    ]

    /// Format byte count as a compact human-readable string (e.g., "45.0KB").
    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        else if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        else { return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0)) }
    }

    /// Key → position in `orderedKeys`, built once. Keys absent from the list
    /// rank after every listed key and sort alphabetically among themselves.
    private static let orderedKeyRank: [String: Int] = {
        var rank: [String: Int] = [:]
        rank.reserveCapacity(orderedKeys.count)
        for (index, key) in orderedKeys.enumerated() where rank[key] == nil {
            rank[key] = index
        }
        return rank
    }()

    /// Encode an Encodable value to a JSON string with deliberate user-facing key order.
    ///
    /// Two Foundation passes (`JSONEncoder` for Codable semantics and number
    /// formatting, `JSONSerialization` to get a walkable object graph) followed
    /// by one linear write into a byte buffer. Key ordering is a dictionary
    /// lookup per key and escaping copies unmodified byte runs in bulk.
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let json = try JSONSerialization.jsonObject(with: data)
        var buffer: [UInt8] = []
        buffer.reserveCapacity(data.count + data.count / 8)
        try appendOrderedJSON(json, to: &buffer)
        return String(decoding: buffer, as: UTF8.self)
    }

    static func encodeJSONObject(_ value: Any) throws -> String {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(256)
        try appendOrderedJSON(value, to: &buffer)
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func appendOrderedJSON(_ value: Any, to out: inout [UInt8]) throws {
        switch value {
        case is NSNull:
            out.append(contentsOf: "null".utf8)
        case let string as String:
            appendEscapedJSONString(string, to: &out)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out.append(contentsOf: (number.boolValue ? "true" : "false").utf8)
            } else {
                out.append(contentsOf: number.stringValue.utf8)
            }
        case let bool as Bool:
            out.append(contentsOf: (bool ? "true" : "false").utf8)
        case let array as [Any]:
            out.append(UInt8(ascii: "["))
            for (index, item) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                try appendOrderedJSON(item, to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted { lhs, rhs in
                (orderedKeyRank[lhs] ?? Int.max, lhs) < (orderedKeyRank[rhs] ?? Int.max, rhs)
            }
            out.append(UInt8(ascii: "{"))
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                appendEscapedJSONString(key, to: &out)
                out.append(UInt8(ascii: ":"))
                try appendOrderedJSON(dictionary[key] as Any, to: &out)
            }
            out.append(UInt8(ascii: "}"))
        default:
            throw NSError(
                domain: "FormatUtils",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value: \(type(of: value))"]
            )
        }
    }

    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

    /// Append `string` as a quoted JSON string. Only `"`, `\`, and control
    /// characters below 0x20 are escaped; `/`, U+2028/U+2029 and all non-ASCII
    /// pass through as raw UTF-8 (this matches the pinned golden output).
    private static func appendEscapedJSONString(_ string: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        // Strings out of JSONSerialization are NSString-bridged; withUTF8 makes
        // a contiguous copy only when the storage is not already native.
        var contiguous = string
        contiguous.withUTF8 { bytes in
            var runStart = bytes.startIndex
            var index = runStart
            while index < bytes.endIndex {
                let byte = bytes[index]
                if byte >= 0x20 && byte != 0x22 && byte != 0x5C {
                    index += 1
                    continue
                }
                if runStart < index {
                    out.append(contentsOf: bytes[runStart..<index])
                }
                out.append(UInt8(ascii: "\\"))
                switch byte {
                case 0x22: out.append(UInt8(ascii: "\""))
                case 0x5C: out.append(UInt8(ascii: "\\"))
                case 0x0A: out.append(UInt8(ascii: "n"))
                case 0x0D: out.append(UInt8(ascii: "r"))
                case 0x09: out.append(UInt8(ascii: "t"))
                case 0x08: out.append(UInt8(ascii: "b"))
                case 0x0C: out.append(UInt8(ascii: "f"))
                default:
                    out.append(UInt8(ascii: "u"))
                    out.append(UInt8(ascii: "0"))
                    out.append(UInt8(ascii: "0"))
                    out.append(hexDigits[Int(byte >> 4)])
                    out.append(hexDigits[Int(byte & 0x0F)])
                }
                index += 1
                runStart = index
            }
            if runStart < bytes.endIndex {
                out.append(contentsOf: bytes[runStart...])
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
