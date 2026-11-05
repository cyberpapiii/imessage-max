import Foundation

/// The chats a `participants` argument names: every chat that holds at
/// least one handle of every entry. find_chat and get_messages both match
/// participants this way.
struct ParticipantChats {
    struct Chat {
        let id: Int64
        let guid: String?
        let displayName: String?
        /// Other participants, by `SQLFragments.participantCount`.
        let participantCount: Int
    }

    enum Order {
        /// Newest activity first.
        case recent
        /// Chats with exactly the named people (plus me) first, then newest.
        case exactSizeFirst
    }

    /// One entry per resolved participant: the handles that entry may be.
    let handleGroups: [[String]]
    /// Entries that name nobody. A chat can't hold someone nobody resolves
    /// to, so any unresolved entry means no chat matches.
    let unresolved: [String]

    /// Resolves each entry by `SenderFilter`'s handle rules.
    static func resolve(_ participants: [String], resolver: ContactResolver) async -> ParticipantChats {
        var groups: [[String]] = []
        var unresolved: [String] = []
        for participant in participants {
            let handles = await SenderFilter.exactHandles(for: participant, resolver: resolver)
            if handles.isEmpty {
                unresolved.append(participant)
            } else {
                groups.append(handles)
            }
        }
        return ParticipantChats(handleGroups: groups, unresolved: unresolved)
    }

    private var matchesNothing: Bool { handleGroups.isEmpty || !unresolved.isEmpty }

    /// Matching chats in `order`, ties broken by newest ROWID.
    /// `chatPredicate` and `isGroup` narrow the chats over alias `c`.
    func chats(
        db: Database,
        chatPredicate: String? = nil,
        isGroup: Bool? = nil,
        order: Order,
        limit: Int
    ) throws -> [Chat] {
        guard !matchesNothing else { return [] }
        let (filter, params) = whereClause(chatPredicate: chatPredicate, isGroup: isGroup)
        let ordering: String
        var orderParams: [Any] = []
        switch order {
        case .recent:
            ordering = SQLFragments.newestChatFirst()
        case .exactSizeFirst:
            ordering = "(participant_count = ?) DESC, \(SQLFragments.newestChatFirst())"
            orderParams.append(handleGroups.count)
        }
        let sql = """
            SELECT c.ROWID, c.guid, c.display_name, \(SQLFragments.participantCount()) AS participant_count
            FROM chat c
            WHERE \(filter)
            ORDER BY \(ordering)
            LIMIT ?
            """
        return try db.query(sql, params: params + orderParams + [limit]) { row in
            Chat(id: row.int(0), guid: row.string(1), displayName: row.string(2), participantCount: Int(row.int(3)))
        }
    }

    /// How many chats match.
    func count(db: Database, chatPredicate: String? = nil, isGroup: Bool? = nil) throws -> Int {
        guard !matchesNothing else { return 0 }
        let (filter, params) = whereClause(chatPredicate: chatPredicate, isGroup: isGroup)
        let rows: [Int] = try db.query("SELECT COUNT(*) FROM chat c WHERE \(filter)", params: params) {
            Int($0.int(0))
        }
        return rows.first ?? 0
    }

    private func whereClause(chatPredicate: String?, isGroup: Bool?) -> (String, [Any]) {
        var clauses: [String] = []
        var params: [Any] = []
        for group in handleGroups {
            clauses.append("""
                c.ROWID IN (SELECT chj.chat_id FROM chat_handle_join chj
                            JOIN handle h ON h.ROWID = chj.handle_id
                            WHERE h.id IN (\(SQLFragments.placeholders(group.count))))
                """)
            params += group.map { $0 as Any }
        }
        if let isGroup {
            clauses.append(isGroup ? SQLFragments.isGroup() : SQLFragments.isDirect())
        }
        if let chatPredicate {
            clauses.append(chatPredicate)
        }
        return (clauses.joined(separator: "\n  AND "), params)
    }
}
