import Foundation
import Synchronization

/// The outcome of a post-send chat.db verification attempt.
enum VerificationResult: Equatable {
    /// Row found in the intended chat within the polling window, with error = 0.
    case confirmed(guid: String, dateNs: Int64)
    /// Row found in a different chat (routing mismatch). Includes the message guid.
    case mismatch(actualChatId: Int64, guid: String)
    /// Row found in the intended chat, but with error ≠ 0. The delivery failed.
    case failedDelivery(guid: String, errorCode: Int)
    /// Polling window exhausted; no matching row found.
    case notFound
}

/// Verifies that a sent text message appeared in chat.db within a polling window.
///
/// Only rows written after the send are candidates: the caller reads
/// `baseline()` (the newest message ROWID) immediately before dispatching the
/// verified payload, and `verify` considers only `ROWID > baseline`. A ROWID
/// bound, unlike a time window, cannot match an earlier identical text (a quick
/// retry) and does not close while earlier file payloads are still transferring.
///
/// Primary query is chatId-scoped, with a fallback handle-scan when the primary
/// finds no clean row and a handle is available. Rows with error ≠ 0 must not
/// confirm. They classify as `.failedDelivery` when they match in the intended chat
/// (failed iMessage sends write error=22 rows immediately). Text comparison uses
/// MessageTextExtractor to handle attributedBody-only rows. Multiple
/// matches take the earliest. A confirmed row is claimed, so two concurrent
/// identical sends sharing this verifier cannot both confirm the same row.
///
/// Inject `maxAttempts: 1` and `pollInterval: .milliseconds(0)` in tests for speed.
struct SendVerifier: Sendable {
    let db: Database
    let maxAttempts: Int
    let pollInterval: Duration
    private let claims = ClaimedRows()

    init(db: Database, maxAttempts: Int = 5, pollInterval: Duration = .milliseconds(200)) {
        self.db = db
        self.maxAttempts = maxAttempts
        self.pollInterval = pollInterval
    }

    /// The newest message ROWID right now (0 for an empty table). Read it
    /// immediately before dispatching the payload `verify` will look for.
    func baseline() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0
    }

    /// Poll chat.db to verify a text send landed in the intended chat.
    ///
    /// - Parameters:
    ///   - intendedChatId: DB ROWID of the chat the send targeted (nil for participant sends
    ///     with no prior DM; fallback handle-scan is used instead).
    ///   - handle: Participant handle for fallback scan and mismatch detection.
    ///   - afterRowId: `baseline()` read immediately before the payload was dispatched.
    ///     Only rows with a greater ROWID are considered.
    ///   - expectedText: The text string passed to the AppleScript send command.
    /// - Returns: `.confirmed`, `.mismatch`, `.failedDelivery`, or `.notFound`.
    /// - Throws: Rethrows `Database` errors.
    func verify(
        intendedChatId: Int64?,
        handle: String?,
        afterRowId: Int64,
        expectedText: String
    ) async throws -> VerificationResult {
        let normalizedExpected = expectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A failed row is written immediately, but a clean row from the same send may
        // still land on a later poll. Remember the failure and only surface it once the
        // polling window closes.
        var pendingFailure: VerificationResult? = nil

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                await AsyncTimeout.sleep(pollInterval)
            }

            // 1. Primary: the intended chat. Its failure overrides any earlier one.
            if let chatId = intendedChatId,
               let result = try scan(.chat(chatId), intendedChatId: intendedChatId,
                                     afterRowId: afterRowId,
                                     expectedText: normalizedExpected) {
                guard case .failedDelivery = result else { return result }
                pendingFailure = result
            }

            // 2. Fallback: every chat with the handle. Its failure only fills an
            //    empty slot, so a primary-scan failure wins.
            if let handle,
               let result = try scan(.handle(handle), intendedChatId: intendedChatId,
                                     afterRowId: afterRowId,
                                     expectedText: normalizedExpected) {
                guard case .failedDelivery = result else { return result }
                pendingFailure = pendingFailure ?? result
            }
        }

        return pendingFailure ?? .notFound
    }

    // MARK: - Private

    private enum Scope {
        case chat(Int64)
        case handle(String)
    }

    private struct MessageRow {
        let rowId: Int64
        let guid: String
        let dateNs: Int64
        let text: String?
        let attributedBody: Data?
        let error: Int64
        let chatId: Int64
    }

    /// Outbound, non-reaction rows written after `afterRowId`, earliest first.
    private func candidateRows(_ scope: Scope, afterRowId: Int64) throws -> [MessageRow] {
        let joins: String
        let filter: String
        let scopeParam: Any
        switch scope {
        case .chat(let chatId):
            joins = ""
            filter = "cmj.chat_id = ?"
            scopeParam = chatId
        case .handle(let handle):
            joins = """
                JOIN chat c ON cmj.chat_id = c.ROWID
                JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
                JOIN handle h ON chj.handle_id = h.ROWID
                """
            filter = "h.id = ?"
            scopeParam = handle
        }
        return try db.query(
            """
            SELECT m.ROWID, m.guid, m.date, m.text, m.attributedBody, m.error, cmj.chat_id
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            \(joins)
            WHERE \(filter)
              AND m.is_from_me = 1
              AND \(SQLFragments.notReaction())
              AND m.ROWID > ?
            ORDER BY m.ROWID ASC
            LIMIT 200
            """,
            params: [scopeParam, afterRowId]
        ) { row in
            MessageRow(
                rowId: row.int(0),
                guid: row.string(1) ?? "",
                dateNs: row.int(2),
                text: row.string(3),
                attributedBody: row.blob(4),
                error: row.int(5),
                chatId: row.int(6)
            )
        }
    }

    /// The earliest clean text match wins. A clean match in another chat is a
    /// mismatch; a failed match there is ignored. Failing that, the earliest
    /// failed match in the intended chat is a delivery failure. A row another
    /// send already confirmed belongs to that send and is skipped.
    private func scan(
        _ scope: Scope,
        intendedChatId: Int64?,
        afterRowId: Int64,
        expectedText: String
    ) throws -> VerificationResult? {
        var failedMatch: MessageRow? = nil
        for row in try candidateRows(scope, afterRowId: afterRowId) {
            guard textMatches(row: row, expected: expectedText), !claims.isClaimed(row.rowId) else { continue }
            if let intended = intendedChatId, row.chatId != intended {
                if row.error == 0 {
                    return .mismatch(actualChatId: row.chatId, guid: row.guid)
                }
                continue
            }
            if row.error == 0 {
                // Lost the race to a concurrent identical send: keep looking.
                guard claims.claim(row.rowId) else { continue }
                return .confirmed(guid: row.guid, dateNs: row.dateNs)
            }
            if failedMatch == nil { failedMatch = row }
        }
        if let failed = failedMatch {
            return .failedDelivery(guid: failed.guid, errorCode: Int(failed.error))
        }
        return nil
    }

    private func textMatches(row: MessageRow, expected: String) -> Bool {
        guard let extracted = MessageTextExtractor.extract(
            text: row.text,
            attributedBody: row.attributedBody
        ) else { return false }

        let normalized = extracted.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == expected { return true }

        // Case-insensitive + diacritic-insensitive fallback.
        return normalized.compare(
            expected,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}

/// ROWIDs a send has already confirmed. Shared by every copy of one
/// `SendVerifier` (one per served `send` tool). Grows by one Int64 per
/// confirmed text send for the life of the process.
private final class ClaimedRows: Sendable {
    private let rows = Mutex<Set<Int64>>([])

    func isClaimed(_ rowId: Int64) -> Bool {
        rows.withLock { $0.contains(rowId) }
    }

    /// True if this call claimed the row; false if it was already claimed.
    func claim(_ rowId: Int64) -> Bool {
        rows.withLock { $0.insert(rowId).inserted }
    }
}
