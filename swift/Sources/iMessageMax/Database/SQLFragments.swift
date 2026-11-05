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
