import Foundation

enum SQLFragments {
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `chat.is_filtered` is a bitmask. Shown chats have exactly 0, so never test `!= 1`.
    static func shownChat(_ alias: String = "c") -> String { "\(alias).is_filtered = 0" }
    static func hiddenChat(_ alias: String = "c") -> String { "\(alias).is_filtered != 0" }

    /// The number of other participants in chat `alias`, counted by handle
    /// string. chat_handle_join can hold the same pair twice, and SMS and
    /// iMessage keep separate handle rows for one address. The participant
    /// list collapses both cases, so the count must too.
    static func participantCount(_ alias: String = "c") -> String {
        """
        (SELECT COUNT(DISTINCT ph.id) FROM chat_handle_join pc \
        JOIN handle ph ON ph.ROWID = pc.handle_id WHERE pc.chat_id = \(alias).ROWID)
        """
    }

    static func isGroup(_ alias: String = "c") -> String { isGroup(count: participantCount(alias)) }
    static func isDirect(_ alias: String = "c") -> String { isDirect(count: participantCount(alias)) }

    static func isGroup(count: String) -> String { "\(count) > 1" }
    static func isDirect(count: String) -> String { "\(count) <= 1" }

    static func newestChatFirst(_ alias: String = "c") -> String {
        """
        COALESCE((SELECT MAX(lm.date) FROM chat_message_join lcmj \
        JOIN message lm ON lm.ROWID = lcmj.message_id WHERE lcmj.chat_id = \(alias).ROWID), 0) DESC, \
        \(alias).ROWID DESC
        """
    }

    static func homeChat(of messageId: String = "m.ROWID", preferShown: Bool = false) -> String {
        let lowest = "(SELECT MIN(hcmj.chat_id) FROM chat_message_join hcmj WHERE hcmj.message_id = \(messageId))"
        guard preferShown else { return lowest }
        return """
            COALESCE((SELECT MIN(scmj.chat_id) FROM chat_message_join scmj \
            JOIN chat sc ON sc.ROWID = scmj.chat_id \
            WHERE scmj.message_id = \(messageId) AND \(shownChat("sc"))), \(lowest))
            """
    }

    static func unreadInbound(_ alias: String = "m") -> String {
        "(\(alias).is_read = 0 AND \(alias).is_from_me = 0 AND \(notReaction(alias)))"
    }

    static func shownAttachment(_ alias: String = "a") -> String {
        "COALESCE(\(alias).hide_attachment, 0) = 0"
    }

    /// Tapbacks and other associated messages carry a nonzero type.
    static func notReaction(_ alias: String = "m") -> String { "\(alias).associated_message_type = 0" }

    /// A message that is part of the conversation itself. It is neither a
    /// tapback nor a group event such as a rename, a membership change or a leave.
    static func conversational(_ alias: String = "m") -> String {
        "(\(notReaction(alias)) AND \(alias).item_type = 0)"
    }

    static func awaitingReply(chat: String, sinceBound: Bool) -> String {
        """
        COALESCE((SELECT ar.is_from_me = 0 FROM chat_message_join arj \
        JOIN message ar ON ar.ROWID = arj.message_id \
        WHERE arj.chat_id = \(chat) AND \(conversational("ar"))\(sinceBound ? " AND ar.date >= ?" : "") \
        ORDER BY ar.date DESC, ar.ROWID DESC LIMIT 1), 0)
        """
    }

    static func tapbackOrRemoval(_ alias: String = "m") -> String {
        let types = ReactionType.types, removals = ReactionType.removalTypes
        return "(\(alias).associated_message_type BETWEEN \(types.lowerBound) AND \(types.upperBound)"
            + " OR \(alias).associated_message_type BETWEEN \(removals.lowerBound) AND \(removals.upperBound))"
    }

    /// The guid of the message an associated row points at. Messages.app
    /// writes `p:<part>/<guid>` for a tapback on one part of a message and
    /// `bp:<guid>` for one on a link-preview balloon. Older rows hold the bare guid.
    static func associatedTargetGuid(_ alias: String = "m") -> String {
        let column = "\(alias).associated_message_guid"
        return "(CASE WHEN \(column) LIKE 'bp:%' THEN substr(\(column), 4)"
            + " ELSE substr(\(column), instr(\(column), '/') + 1) END)"
    }

    static func hasLink(_ alias: String = "m") -> String {
        "(\(alias).text LIKE '%http://%' OR \(alias).text LIKE '%https://%'"
            + " OR \(alias).balloon_bundle_id = '\(BalloonBundle.urlPreview)')"
    }

    static func hasAttachment(ofType type: String? = nil, _ alias: String = "m") -> String {
        let typeClause = AttachmentType.sqlPredicate(for: type, alias: "a").map { "\n  AND (\($0))" } ?? ""
        return """
            EXISTS (
              SELECT 1 FROM attachment a
              JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
              WHERE maj.message_id = \(alias).ROWID
                AND \(shownAttachment("a"))\(typeClause)
            )
            """
    }

    static func has(_ value: String?, _ alias: String = "m") -> String? {
        switch value {
        case "link", "links": hasLink(alias)
        case "attachment", "attachments": hasAttachment(ofType: nil, alias)
        case "image", "images": hasAttachment(ofType: "image", alias)
        case "video", "videos": hasAttachment(ofType: "video", alias)
        default: nil
        }
    }

    /// Rows whose text might contain `term`. Recent macOS stores most text
    /// only in the attributedBody typedstream, so this also searches the blob.
    /// instr is case-sensitive, so the blob search tries the lower-case,
    /// capitalized and upper-case forms of `term`. The blob also holds class
    /// names, so callers must confirm each match on the decoded text.
    static func textMayContain(_ term: String, _ alias: String = "m") -> (sql: String, bindings: [Any]) {
        let lower = term.lowercased()
        let titled = lower.prefix(1).uppercased() + lower.dropFirst()
        let blob = "instr(\(alias).attributedBody, ?) > 0"
        return (
            "(\(alias).text LIKE ? ESCAPE '\\' OR \(blob) OR \(blob) OR \(blob))",
            ["%\(QueryBuilder.escapeLike(term))%", Data(lower.utf8), Data(titled.utf8), Data(lower.uppercased().utf8)]
        )
    }
}
