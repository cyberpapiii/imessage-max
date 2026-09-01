// Sources/iMessageMax/Utilities/TimeUtils.swift
import Foundation

enum TimeUtils {
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "MMM d"
        return f
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// Format date as compact relative string for AI consumption
    static func formatCompactRelative(_ date: Date?) -> String? {
        guard let date = date else { return nil }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else {
            return monthDayFormatter.string(from: date)
        }
    }

    /// Format date as ISO 8601 for precise timestamps
    static func formatISO(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        return isoFormatter.string(from: date)
    }
}
