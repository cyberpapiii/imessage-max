import Foundation

enum Seconds {
    static let minute: Double = 60
    static let hour: Double = 3600
    static let day: Double = 86_400
    static let week: Double = 604_800
    static let month: Double = 30 * day
}

/// chat.db stores times as nanoseconds since 2001-01-01 UTC.
enum AppleTime {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    static func toDate(_ nanoseconds: Int64?) -> Date? {
        guard let ns = nanoseconds else { return nil }
        let seconds = Double(ns) / 1_000_000_000.0
        return epoch.addingTimeInterval(seconds)
    }

    static func fromDate(_ date: Date) -> Int64 {
        let nanoseconds = date.timeIntervalSinceReferenceDate * 1_000_000_000
        if nanoseconds >= Double(Int64.max) { return Int64.max }
        if nanoseconds <= Double(Int64.min) { return Int64.min }
        if nanoseconds.isNaN { return 0 }
        return Int64(nanoseconds)
    }

    /// The time-bound forms parse accepts, for tool descriptions.
    static let boundFormats = "ISO 8601 like \"2026-01-15T10:30:00Z\", relative like \"30min\", \"24h\", \"7d\", \"2w\" or \"3mo\", or natural like \"yesterday\", \"last tuesday\" or \"2 weeks ago\""

    /// Checks a time-bound tool argument at the tool boundary, so the queries
    /// behind it can parse it without a failure path. A value that does not
    /// parse is a validation error, never a silently dropped filter.
    static func checkedBound(_ input: String?, name: String) throws -> String? {
        guard let input else { return nil }
        if parse(input) != nil { return input }
        if let match = input.wholeMatch(of: /(\d+)m/) {
            // Server output writes "5m ago" for minutes, so a bare m is ambiguous.
            throw ToolFailure("validation_error", "\(name) \"\(input)\" is ambiguous. Use \"\(match.1)min\" for minutes or \"\(match.1)mo\" for months.")
        }
        throw ToolFailure("validation_error", "\(name) \"\(input)\" is not a time. Use \(boundFormats).")
    }

    static func parse(_ input: String) -> Int64? {
        if let relative = parseRelative(input) {
            return fromDate(relative)
        }

        if let iso = parseISO(input) {
            return fromDate(iso)
        }

        if let natural = parseNatural(input) {
            return fromDate(natural)
        }

        return nil
    }

    private static func parseRelative(_ input: String) -> Date? {
        let pattern = #"^(\d+)(min|h|d|w|mo)$"#
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
        case "min": seconds = num * Seconds.minute
        case "h": seconds = num * Seconds.hour
        case "d": seconds = num * Seconds.day
        case "w": seconds = num * Seconds.week
        case "mo": seconds = num * Seconds.month
        default: return nil
        }

        let maxRelativeSeconds: Double = 100 * 365 * Seconds.day
        let bounded = min(seconds, maxRelativeSeconds)
        return Date().addingTimeInterval(-bounded)
    }

    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO(_ input: String) -> Date? {
        isoWithFraction.date(from: input) ?? isoWhole.date(from: input)
    }

    private static func parseNatural(_ input: String) -> Date? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let now = Date()

        switch lower {
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "today":
            return calendar.startOfDay(for: now)

        case "this week":
            return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        case "this month":
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        case "this year":
            return calendar.date(from: calendar.dateComponents([.year], from: now))

        case "last week":
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now)
        case "last month":
            return calendar.date(byAdding: .month, value: -1, to: now)
        case "last year":
            return calendar.date(byAdding: .year, value: -1, to: now)

        default:
            break
        }

        let agoPattern = #"^(\d+)\s+(day|days|week|weeks|month|months)\s+ago$"#
        if let regex = try? NSRegularExpression(pattern: agoPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let numRange = Range(match.range(at: 1), in: lower),
           let unitRange = Range(match.range(at: 2), in: lower),
           let num = Int(lower[numRange]) {
            let unit = String(lower[unitRange]).lowercased()
            switch unit {
            case "day", "days":
                guard num <= 36_500 else { return nil }
                return calendar.date(byAdding: .day, value: -num, to: now)
            case "week", "weeks":
                guard num <= 5_200 else { return nil }
                return calendar.date(byAdding: .weekOfYear, value: -num, to: now)
            case "month", "months":
                guard num <= 1_200 else { return nil }
                return calendar.date(byAdding: .month, value: -num, to: now)
            default:
                break
            }
        }

        let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                        "thursday": 5, "friday": 6, "saturday": 7]
        if lower.hasPrefix("last ") {
            let dayName = String(lower.dropFirst(5))
            if let targetWeekday = weekdays[dayName] {
                let currentWeekday = calendar.component(.weekday, from: now)
                var daysBack = currentWeekday - targetWeekday
                if daysBack <= 0 { daysBack += 7 }
                return calendar.date(byAdding: .day, value: -daysBack, to: now)
            }
        }

        return nil
    }
}
