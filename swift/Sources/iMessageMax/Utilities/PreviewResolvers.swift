import Foundation

enum MessagePreviewResolver {
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

    static func attachmentTypesByMessage(
        db: Database,
        messageIds: [Int64]
    ) throws -> [Int64: [AttachmentType]] {
        guard !messageIds.isEmpty else { return [:] }

        let placeholders = SQLFragments.placeholders(messageIds.count)
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
    /// Named groups of more than four show who spoke last, so they need the
    /// chat's recent senders; every other chat previews from participants alone.
    static func needsRecentSenders(_ identity: ChatIdentity) -> Bool {
        identity.isNamed && identity.participantCount > 4
    }

    static func summary(identity: ChatIdentity, recentSenders: [String]) -> ChatSummary {
        ChatSummary(
            id: identity.mcpId,
            name: identity.displayName,
            group: identity.participantCount > 1 ? true : nil,
            participantCount: identity.participantCount,
            participantsPreview: participantsPreview(identity: identity, recentSenders: recentSenders)
        )
    }

    static func participantsPreview(identity: ChatIdentity, recentSenders: [String]) -> [String] {
        let participants = identity.participants
        if participants.count <= 4 {
            return IdentityDisplayFormatter.previewNames(selected: participants, allParticipants: participants)
        }

        let selected: [ChatIdentity.Participant]
        if identity.isNamed {
            let recent = selectRecent(handles: recentSenders, participants: participants)
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
