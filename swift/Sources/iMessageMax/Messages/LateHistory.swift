import Foundation

/// Messages in iCloud can sync old history into chat.db long after it was
/// sent, for example on a Mac that was just set up. Those rows get new,
/// high ROWIDs, so a ROWID cursor sees them as new mail.
///
/// chat.db records no arrival time, so a row's arrival is bounded from
/// below by the newest date among the rows before it in ROWID order (the
/// high-water date): it arrived after them, and they arrived no earlier
/// than their own dates. A row dated more than `threshold` before that
/// high-water date therefore arrived at least `threshold` after it was
/// sent. Messages that queued while the Mac slept are dated after the last
/// row seen before the sleep, so they are not late.
enum LateHistory {
    static let threshold: TimeInterval = Seconds.hour
    /// How many rows at or below the cursor set the starting high-water date.
    static let baselineRows = 64

    static var thresholdNanoseconds: Int64 { Int64(threshold * 1_000_000_000) }

    /// The high-water date of the rows at or below `rowid`, never later than
    /// now, so one row with a future date cannot mark everything after it late.
    static func baseline(db: Database, atOrBelow rowid: Int64, now: Date = Date()) throws -> Int64? {
        let newest = try db.query(
            """
            SELECT MAX(date) FROM (
                SELECT date FROM message WHERE ROWID <= ? ORDER BY ROWID DESC LIMIT \(baselineRows)
            )
            """,
            params: [rowid]
        ) { $0.optionalInt(0) }.first ?? nil
        return newest.map { min($0, AppleTime.fromDate(now)) }
    }

    /// Whether a row dated `date` is late against the high-water date of the
    /// rows before it.
    static func isLate(_ date: Int64?, highWater: Int64?) -> Bool {
        guard let date, let highWater, date > 0 else { return false }
        return highWater - date > thresholdNanoseconds
    }

    /// Tracks the high-water date while rows are read in ROWID order.
    struct Tracker {
        private(set) var highWater: Int64?
        private let ceiling: Int64

        init(baseline: Int64?, now: Date = Date()) {
            highWater = baseline
            ceiling = AppleTime.fromDate(now)
        }

        /// Returns whether the row is late, then counts its date.
        mutating func observe(_ date: Int64?) -> Bool {
            let late = LateHistory.isLate(date, highWater: highWater)
            if let date, date > 0 {
                highWater = min(max(highWater ?? date, date), ceiling)
            }
            return late
        }
    }
}
