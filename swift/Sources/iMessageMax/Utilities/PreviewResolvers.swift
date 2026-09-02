import Foundation

enum MessagePreviewResolver {
    static func messageSummary(
        db: Database,
        messageId: Int64,
        text: String?,
        attributedBody: Data?,
        maxLength: Int
    ) throws -> String {
        if let formatted = SummaryPreviewFormatter.formattedTextPreview(
            text: text,
            attributedBody: attributedBody,
            maxLength: maxLength
        ) {
            return formatted
        }

        return messageSummary(
            text: text,
            attributedBody: attributedBody,
            maxLength: maxLength,
            attachmentTypes: try attachmentTypes(db: db, messageId: messageId)
        )
    }

    static func messageSummary(
        text: String?,
        attributedBody: Data?,
        maxLength: Int,
        attachmentTypes: [AttachmentType]
    ) -> String {
        if let formatted = SummaryPreviewFormatter.formattedTextPreview(
            text: text,
            attributedBody: attributedBody,
            maxLength: maxLength
        ) {
            return formatted
        }

        return SummaryPreviewFormatter.attachmentPlaceholder(for: attachmentTypes)
    }

    static func attachmentTypes(db: Database, messageId: Int64) throws -> [AttachmentType] {
        try attachmentTypesByMessage(db: db, messageIds: [messageId])[messageId] ?? []
    }

    static func attachmentTypesByMessage(
        db: Database,
        messageIds: [Int64]
    ) throws -> [Int64: [AttachmentType]] {
        guard !messageIds.isEmpty else { return [:] }

        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT maj.message_id, a.mime_type, a.uti
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            ORDER BY a.ROWID ASC
            """

        var map: [Int64: [AttachmentType]] = [:]
        let rows = try db.query(sql, params: messageIds.map { $0 as Any }) { row in
            (
                messageId: row.int(0),
                type: AttachmentType.from(mimeType: row.string(1), uti: row.string(2))
            )
        }
        for row in rows {
            map[row.messageId, default: []].append(row.type)
        }
        return map
    }
}

enum ChatSummaryBuilder {
    static func buildSummary(
        db: Database,
        chatId: Int64,
        identity: ChatIdentity,
        recentSenders: [String]? = nil
    ) throws -> ChatSummary {
        ChatSummary(
            id: identity.mcpId,
            name: identity.displayName,
            group: identity.participantCount > 1 ? true : nil,
            participantCount: identity.participantCount,
            participantsPreview: try participantsPreview(
                db: db,
                chatId: chatId,
                identity: identity,
                recentSenders: recentSenders
            )
        )
    }

    static func participantsPreview(
        db: Database,
        chatId: Int64,
        identity: ChatIdentity,
        recentSenders: [String]? = nil
    ) throws -> [String] {
        let participants = identity.participants
        if participants.count <= 4 {
            return IdentityDisplayFormatter.previewNames(selected: participants, allParticipants: participants)
        }

        let selected: [ChatIdentity.Participant]
        if identity.isNamed {
            let recent: [ChatIdentity.Participant]
            if let recentSenders {
                recent = selectRecent(handles: recentSenders, participants: participants)
            } else {
                recent = try recentParticipantPreviewNames(db: db, chatId: chatId, participants: participants)
            }
            let backfill = prioritizedParticipants(participants).filter { candidate in
                !recent.contains { $0.handle == candidate.handle }
            }
            selected = Array((recent + backfill).prefix(3))
        } else {
            selected = Array(prioritizedParticipants(participants).prefix(3))
        }

        let remaining = max(0, participants.count - selected.count)
        let preview = IdentityDisplayFormatter.previewNames(selected: selected, allParticipants: participants)
        if remaining == 0 {
            return preview
        }
        return preview + ["+\(remaining) more"]
    }

    static func selectRecent(
        handles: [String],
        participants: [ChatIdentity.Participant]
    ) -> [ChatIdentity.Participant] {
        // Duplicate handles reach here from chat_handle_join; keep the first.
        let handleToParticipant = Dictionary(
            participants.map { ($0.handle, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var selected: [ChatIdentity.Participant] = []
        var seen: Set<String> = []
        for handle in handles {
            guard let participant = handleToParticipant[handle], seen.insert(handle).inserted else {
                continue
            }
            selected.append(participant)
            if selected.count == 3 { break }
        }
        return selected
    }

    private static func recentParticipantPreviewNames(
        db: Database,
        chatId: Int64,
        participants: [ChatIdentity.Participant]
    ) throws -> [ChatIdentity.Participant] {
        let sql = """
            SELECT h.id as sender_handle
            FROM message m
            JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            AND m.associated_message_type = 0
            AND m.is_from_me = 0
            AND h.id IS NOT NULL
            ORDER BY m.date DESC
            LIMIT 50
            """

        let handles = try db.query(sql, params: [chatId]) { row in
            row.string(0)
        }.compactMap { $0 }
        return selectRecent(handles: handles, participants: participants)
    }

    private static func prioritizedParticipants(_ participants: [ChatIdentity.Participant]) -> [ChatIdentity.Participant] {
        participants.sorted {
            let lhsHasContact = $0.contactName != nil
            let rhsHasContact = $1.contactName != nil
            if lhsHasContact != rhsHasContact {
                return lhsHasContact && !rhsHasContact
            }

            let lhsName = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if lhsName != .orderedSame {
                return lhsName == .orderedAscending
            }
            return $0.handle.localizedCaseInsensitiveCompare($1.handle) == .orderedAscending
        }
    }
}
