// Sources/iMessageMax/Utilities/FormatUtils.swift
import Foundation

enum FormatUtils {
    /// Format byte count as a compact human-readable string (e.g., "45.0KB").
    static func fileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        else if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        else { return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0)) }
    }

    /// Encode an Encodable value to a JSON string with sorted keys.
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
