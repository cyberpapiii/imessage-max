// Sources/iMessageMax/Database/AppleTime.swift
import Foundation

enum AppleTime {
    /// Apple epoch: January 1, 2001 00:00:00 UTC
    static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    /// Convert Apple nanoseconds timestamp to Date
    static func toDate(_ nanoseconds: Int64?) -> Date? {
        guard let ns = nanoseconds else { return nil }
        let seconds = Double(ns) / 1_000_000_000.0
        return epoch.addingTimeInterval(seconds)
    }

    /// Convert Date to Apple nanoseconds timestamp
    static func fromDate(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate * 1_000_000_000)
    }

    /// Parse various time formats to Apple timestamp
    static func parse(_ input: String) -> Int64? {
        // Try relative formats first: "24h", "7d", "2w"
        if let relative = parseRelative(input) {
            return fromDate(relative)
        }

        // Try ISO 8601
        if let iso = parseISO(input) {
            return fromDate(iso)
        }

        // Try natural language: "yesterday", "last week"
        if let natural = parseNatural(input) {
            return fromDate(natural)
        }

        return nil
    }

    private static func parseRelative(_ input: String) -> Date? {
        let pattern = #"^(\d+)(h|d|w|m)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let numRange = Range(match.range(at: 1), in: input),
              let unitRange = Range(match.range(at: 2), in: input),
              let num = Double(input[numRange]) else {
            return nil
        }

        let unit = String(input[unitRange])
        let seconds: Double
        switch unit {
        case "h": seconds = num * 3600
        case "d": seconds = num * 86400
        case "w": seconds = num * 604800
        case "m": seconds = num * 2592000  // ~30 days
        default: return nil
        }

        return Date().addingTimeInterval(-seconds)
    }

    private static func parseISO(_ input: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: input) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: input)
    }

    private static func parseNatural(_ input: String) -> Date? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let now = Date()

        switch lower {
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: now)
        case "last week":
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now)
        case "last month":
            return calendar.date(byAdding: .month, value: -1, to: now)
        case "today":
            return calendar.startOfDay(for: now)
        default:
            return nil
        }
    }
}
