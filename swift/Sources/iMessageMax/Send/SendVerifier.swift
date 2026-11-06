import Foundation
import Synchronization

enum VerificationResult: Equatable {
    case confirmed(guid: String, dateNs: Int64)
    case mismatch(actualChatId: Int64, guid: String)
    case failedDelivery(guid: String, errorCode: Int)
    case notFound
}

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

    func baseline() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message") { $0.int(0) }.first ?? 0
    }

    func verify(
        intendedChatId: Int64?,
        handle: String?,
        afterRowId: Int64,
        expectedText: String
    ) async throws -> VerificationResult {
        let normalizedExpected = expectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var pendingFailure: VerificationResult? = nil

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                await AsyncTimeout.sleep(pollInterval)
            }

            if let chatId = intendedChatId,
               let result = try scan(.chat(chatId), intendedChatId: intendedChatId,
                                     afterRowId: afterRowId,
                                     expectedText: normalizedExpected) {
                guard case .failedDelivery = result else { return result }
                pendingFailure = result
            }

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

        return normalized.compare(
            expected,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}

private final class ClaimedRows: Sendable {
    private let rows = Mutex<Set<Int64>>([])

    func isClaimed(_ rowId: Int64) -> Bool {
        rows.withLock { $0.contains(rowId) }
    }

    func claim(_ rowId: Int64) -> Bool {
        rows.withLock { $0.insert(rowId).inserted }
    }
}
