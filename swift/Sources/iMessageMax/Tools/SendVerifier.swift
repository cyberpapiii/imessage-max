// Sources/iMessageMax/Tools/SendVerifier.swift
import Foundation

// MARK: - Result

/// The outcome of a post-send chat.db verification attempt.
enum VerificationResult: Equatable {
    /// Row found in the intended chat within the polling window, with error = 0.
    case confirmed(guid: String, dateNs: Int64)
    /// Row found in a different chat (routing mismatch). Includes the message guid.
    case mismatch(actualChatId: Int64, guid: String)
    /// Polling window exhausted; no matching row found.
    case notFound
}

// MARK: - Verifier

/// Verifies that a sent text message appeared in chat.db within a polling window.
///
/// Design: §2.2 primary query (chatId-scoped) + §2.2 fallback handle-scan when primary
/// finds nothing and a handle is available. §3 finding 3: rows with error ≠ 0 must not
/// confirm (failed iMessage sends write error=22 rows immediately). Text comparison uses
/// MessageTextExtractor to handle attributedBody-only rows (§3 finding 2). Multiple
/// matches take the earliest (§2.3).
///
/// Inject `maxAttempts: 1` and `pollInterval: .milliseconds(0)` in tests for speed.
struct SendVerifier: Sendable {
    let db: Database
    let maxAttempts: Int
    let pollInterval: Duration

    init(db: Database, maxAttempts: Int = 5, pollInterval: Duration = .milliseconds(200)) {
        self.db = db
        self.maxAttempts = maxAttempts
        self.pollInterval = pollInterval
    }

    // MARK: - Public API

    /// Poll chat.db to verify a text send landed in the intended chat.
    ///
    /// - Parameters:
    ///   - intendedChatId: DB ROWID of the chat the send targeted (nil for participant sends
    ///     with no prior DM; fallback handle-scan is used instead).
    ///   - handle: Participant handle for fallback scan and mismatch detection.
    ///   - sendTime: Wall-clock time captured immediately before the AppleScript call.
    ///   - expectedText: The text string passed to the AppleScript send command.
    /// - Returns: `.confirmed`, `.mismatch`, or `.notFound`.
    /// - Throws: Rethrows `Database` errors and `CancellationError` from `Task.sleep`.
    func verify(
        intendedChatId: Int64?,
        handle: String?,
        sendTime: Date,
        expectedText: String
    ) async throws -> VerificationResult {
        let sendTimeNs = AppleTime.fromDate(sendTime)
        let skewNs: Int64   = 2_000_000_000   // 2 s look-behind for clock skew
        let windowNs: Int64 = 60_000_000_000  // 60 s forward window
        let lowerBound = sendTimeNs - skewNs
        let upperBound = sendTimeNs + windowNs

        let normalizedExpected = expectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: pollInterval)
            }

            // 1. Primary: look in the intended chat (if we have a chatId).
            if let chatId = intendedChatId {
                if let result = try primaryScan(
                    chatId: chatId,
                    lowerBound: lowerBound,
                    upperBound: upperBound,
                    expectedText: normalizedExpected
                ) {
                    return result
                }
            }

            // 2. Fallback: scan by handle (when primary found nothing and handle available).
            if let handle {
                if let result = try fallbackScan(
                    handle: handle,
                    intendedChatId: intendedChatId,
                    lowerBound: lowerBound,
                    upperBound: upperBound,
                    expectedText: normalizedExpected
                ) {
                    return result
                }
            }
        }

        return .notFound
    }

    // MARK: - Private

    private struct MessageRow {
        let guid: String
        let dateNs: Int64
        let text: String?
        let attributedBody: Data?
    }

    private func primaryScan(
        chatId: Int64,
        lowerBound: Int64,
        upperBound: Int64,
        expectedText: String
    ) throws -> VerificationResult? {
        let rows: [MessageRow] = try db.query(
            """
            SELECT m.guid, m.date, m.text, m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            WHERE cmj.chat_id = ?
              AND m.is_from_me = 1
              AND m.error = 0
              AND m.associated_message_type = 0
              AND m.date >= ?
              AND m.date <= ?
            ORDER BY m.date ASC
            """,
            params: [chatId, lowerBound, upperBound]
        ) { row in
            MessageRow(
                guid: row.string(0) ?? "",
                dateNs: row.int(1),
                text: row.string(2),
                attributedBody: row.blob(3)
            )
        }

        for row in rows {
            if textMatches(row: row, expected: expectedText) {
                return .confirmed(guid: row.guid, dateNs: row.dateNs)
            }
        }
        return nil
    }

    private struct FallbackRow {
        let guid: String
        let dateNs: Int64
        let text: String?
        let attributedBody: Data?
        let chatId: Int64
    }

    private func fallbackScan(
        handle: String,
        intendedChatId: Int64?,
        lowerBound: Int64,
        upperBound: Int64,
        expectedText: String
    ) throws -> VerificationResult? {
        let rows: [FallbackRow] = try db.query(
            """
            SELECT m.guid, m.date, m.text, m.attributedBody, c.ROWID
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            JOIN chat c ON cmj.chat_id = c.ROWID
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = ?
              AND m.is_from_me = 1
              AND m.error = 0
              AND m.associated_message_type = 0
              AND m.date >= ?
              AND m.date <= ?
            ORDER BY m.date ASC
            """,
            params: [handle, lowerBound, upperBound]
        ) { row in
            FallbackRow(
                guid: row.string(0) ?? "",
                dateNs: row.int(1),
                text: row.string(2),
                attributedBody: row.blob(3),
                chatId: row.int(4)
            )
        }

        for row in rows {
            guard textMatches(row: MessageRow(
                guid: row.guid,
                dateNs: row.dateNs,
                text: row.text,
                attributedBody: row.attributedBody
            ), expected: expectedText) else { continue }

            if let intended = intendedChatId, row.chatId != intended {
                return .mismatch(actualChatId: row.chatId, guid: row.guid)
            }
            return .confirmed(guid: row.guid, dateNs: row.dateNs)
        }
        return nil
    }

    // MARK: - Text Matching (§2.3)

    private func textMatches(row: MessageRow, expected: String) -> Bool {
        guard let extracted = MessageTextExtractor.extract(
            text: row.text,
            attributedBody: row.attributedBody
        ) else { return false }

        let normalized = extracted.trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact match first.
        if normalized == expected { return true }

        // Case-insensitive + diacritic-insensitive fallback (§2.3).
        return normalized.compare(
            expected,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}
