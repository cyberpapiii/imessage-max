import Foundation

/// chat.db predicates that encode Messages.app rules, so each rule is written once.
enum SQLFragments {
    /// `?, ?, ?` for an IN list of `count` bindings.
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// `chat.is_filtered` is a bitmask; shown chats are exactly 0, so never test `!= 1`.
    static func shownChat(_ alias: String = "c") -> String { "\(alias).is_filtered = 0" }
    static func hiddenChat(_ alias: String = "c") -> String { "\(alias).is_filtered != 0" }

    /// Number of other participants in chat `alias`, counted by handle
    /// string. chat_handle_join can hold the same pair twice, and SMS and
    /// iMessage keep separate handle rows for one address; the participant
    /// list collapses both, so the count must too.
    static func participantCount(_ alias: String = "c") -> String {
        """
        (SELECT COUNT(DISTINCT ph.id) FROM chat_handle_join pc \
        JOIN handle ph ON ph.ROWID = pc.handle_id WHERE pc.chat_id = \(alias).ROWID)
        """
    }

    /// A group chat has more than one other participant; every other chat,
    /// including one with no handles left, is a DM.
    static func isGroup(_ alias: String = "c") -> String { isGroup(count: participantCount(alias)) }
    static func isDirect(_ alias: String = "c") -> String { isDirect(count: participantCount(alias)) }

    /// The same rule over a `participantCount` the query already selected,
    /// so a HAVING clause does not run the subquery a second time.
    static func isGroup(count: String) -> String { "\(count) > 1" }
    static func isDirect(count: String) -> String { "\(count) <= 1" }

    /// ORDER BY terms putting chat `alias` with the newest message first; a
    /// chat with no messages sorts last, and ties go to the newest chat.
    static func newestChatFirst(_ alias: String = "c") -> String {
        """
        COALESCE((SELECT MAX(lm.date) FROM chat_message_join lcmj \
        JOIN message lm ON lm.ROWID = lcmj.message_id WHERE lcmj.chat_id = \(alias).ROWID), 0) DESC, \
        \(alias).ROWID DESC
        """
    }

    /// The one chat a message is listed under where a tool shows one chat
    /// per message: the lowest chat id it is joined to. With `preferShown`
    /// (the tool leaves hidden chats out) it is the lowest shown chat, so a
    /// message also in a shown chat does not vanish with a hidden one; a
    /// message only in hidden chats keeps the lowest, which the shown-chat
    /// filter then drops. `messageId` is the SQL expression for the message's ROWID.
    static func homeChat(of messageId: String = "m.ROWID", preferShown: Bool = false) -> String {
        let lowest = "(SELECT MIN(hcmj.chat_id) FROM chat_message_join hcmj WHERE hcmj.message_id = \(messageId))"
        guard preferShown else { return lowest }
        return """
            COALESCE((SELECT MIN(scmj.chat_id) FROM chat_message_join scmj \
            JOIN chat sc ON sc.ROWID = scmj.chat_id \
            WHERE scmj.message_id = \(messageId) AND \(shownChat("sc"))), \(lowest))
            """
    }

    /// Received messages not yet read. A tapback is never unread.
    static func unreadInbound(_ alias: String = "m") -> String {
        "(\(alias).is_read = 0 AND \(alias).is_from_me = 0 AND \(notReaction(alias)))"
    }

    /// Attachments Messages.app shows.
    static func shownAttachment(_ alias: String = "a") -> String {
        "COALESCE(\(alias).hide_attachment, 0) = 0"
    }

    /// Tapbacks and other associated messages carry a nonzero type.
    static func notReaction(_ alias: String = "m") -> String { "\(alias).associated_message_type = 0" }

    /// A message that carries the conversation: not a tapback and not a
    /// group event (rename, membership change, leave).
    static func conversational(_ alias: String = "m") -> String {
        "(\(notReaction(alias)) AND \(alias).item_type = 0)"
    }

    /// Whether chat `chat` (an SQL expression) awaits my reply: its newest
    /// conversational message, at or after one bound `?` date when
    /// `sinceBound`, was received. 0 when it has none.
    static func awaitingReply(chat: String, sinceBound: Bool) -> String {
        """
        COALESCE((SELECT ar.is_from_me = 0 FROM chat_message_join arj \
        JOIN message ar ON ar.ROWID = arj.message_id \
        WHERE arj.chat_id = \(chat) AND \(conversational("ar"))\(sinceBound ? " AND ar.date >= ?" : "") \
        ORDER BY ar.date DESC, ar.ROWID DESC LIMIT 1), 0)
        """
    }

    /// Tapback rows and their removals (see `ReactionType`), nothing else.
    static func tapbackOrRemoval(_ alias: String = "m") -> String {
        let types = ReactionType.types, removals = ReactionType.removalTypes
        return "(\(alias).associated_message_type BETWEEN \(types.lowerBound) AND \(types.upperBound)"
            + " OR \(alias).associated_message_type BETWEEN \(removals.lowerBound) AND \(removals.upperBound))"
    }

    /// The guid of the message an associated row points at. Messages.app
    /// writes `p:<part>/<guid>` for a tapback on one part of a message and
    /// `bp:<guid>` for one on a link-preview balloon; older rows hold the bare guid.
    static func associatedTargetGuid(_ alias: String = "m") -> String {
        let column = "\(alias).associated_message_guid"
        return "(CASE WHEN \(column) LIKE 'bp:%' THEN substr(\(column), 4)"
            + " ELSE substr(\(column), instr(\(column), '/') + 1) END)"
    }

    /// Text carrying an http(s) URL, or a message Messages.app shows as a link preview.
    static func hasLink(_ alias: String = "m") -> String {
        "(\(alias).text LIKE '%http://%' OR \(alias).text LIKE '%https://%'"
            + " OR \(alias).balloon_bundle_id = '\(BalloonBundle.urlPreview)')"
    }

    /// At least one attachment Messages.app shows, optionally only of one
    /// `AttachmentType.sqlPredicate` kind.
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

    /// The predicate for a `has` argument, nil for an unknown value (no
    /// filter). Takes search's singular and get_messages' plural spellings.
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
    /// only in the attributedBody typedstream, so the blob is searched too:
    /// instr is case-sensitive, hence lower, titled and upper forms. The blob
    /// also holds class names, so callers must confirm on the decoded text.
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
