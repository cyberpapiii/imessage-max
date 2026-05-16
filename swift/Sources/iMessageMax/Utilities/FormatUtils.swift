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
        "attachments",
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
        "message",
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

    /// Encode an Encodable value to a JSON string with deliberate user-facing key order.
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        let json = try JSONSerialization.jsonObject(with: data)
        return try orderedJSONString(from: json)
    }

    static func encodeJSONObject(_ value: Any) throws -> String {
        try orderedJSONString(from: value)
    }

    private static func orderedJSONString(from value: Any) throws -> String {
        switch value {
        case is NSNull:
            return "null"
        case let string as String:
            return "\"\(escapeJSONString(string))\""
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            let items = try array.map { try orderedJSONString(from: $0) }.joined(separator: ",")
            return "[\(items)]"
        case let dictionary as [String: Any]:
            let keys = dictionary.keys.sorted { lhs, rhs in
                let lhsRank = orderedKeys.firstIndex(of: lhs) ?? Int.max
                let rhsRank = orderedKeys.firstIndex(of: rhs) ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs < rhs
            }
            let items = try keys.map { key in
                let encodedValue = try orderedJSONString(from: dictionary[key] as Any)
                return "\"\(escapeJSONString(key))\":\(encodedValue)"
            }.joined(separator: ",")
            return "{\(items)}"
        default:
            throw NSError(
                domain: "FormatUtils",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value: \(type(of: value))"]
            )
        }
    }

    private static func escapeJSONString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0C}":
                result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.append(String(scalar))
                }
            }
        }
        return result
    }
}
