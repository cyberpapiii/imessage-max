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

    static func formatCompactRelative(_ date: Date?) -> String? {
        guard let date = date else { return nil }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < Seconds.minute {
            return "just now"
        } else if interval < Seconds.hour {
            let mins = Int(interval / Seconds.minute)
            return "\(mins)m ago"
        } else if interval < Seconds.day {
            let hours = Int(interval / Seconds.hour)
            return "\(hours)h ago"
        } else if interval < Seconds.week {
            let days = Int(interval / Seconds.day)
            return "\(days)d ago"
        } else {
            return monthDayFormatter.string(from: date)
        }
    }

    static func formatISO(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        return isoFormatter.string(from: date)
    }
}
