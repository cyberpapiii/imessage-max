import Foundation
import MCP

enum FindContactTool {
    static let name = "find_contact"
    static let limit = IntArgument(name: "limit", defaultValue: 5, range: 1...25)
    /// The contacts ranked by recency. A two-letter query on a large address
    /// book matches thousands, and ranking reads chat.db for each handle.
    static let rankedContacts = 200

    static let description = """
        Look up a person in Contacts by name, phone number, or email, including people you have never messaged. \
        Returns each matching contact with every number and email it has. A handle with a 1:1 chat carries that chat_id, \
        the chat send(to: handle) would use, and last_contact. A handle without chat_id has no 1:1 chat yet: send(to: handle) \
        starts one. Contacts messaged most recently come first.
        """

    static let inputSchema: Value = .object([
        "type": "object",
        "properties": .object([
            "query": .object([
                "type": "string",
                "description": "A name or part of one (\"Sam\", \"Sam L\"), a phone number, or an email",
            ]),
            "limit": .object([
                "type": "integer",
                "description": "Maximum contacts to return (\(limit.defaultAndMax))",
                "default": .int(limit.defaultValue),
            ]),
        ]),
        "required": .array([.string("query")]),
        "additionalProperties": false,
    ])

    struct Response: Encodable {
        let contacts: [Match]
        let more: Bool
    }

    struct Match: Encodable {
        let name: String
        let handles: [Handle]
    }

    struct Handle: Encodable {
        let handle: String
        let chatId: String?
        let lastContact: String?

        enum CodingKeys: String, CodingKey {
            case handle
            case chatId = "chat_id"
            case lastContact = "last_contact"
        }
    }

    static func definition(db: Database, resolver: ContactResolver) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: OutputSchema.object,
            annotations: Tool.Annotations(
                title: "Find Contact",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await execute(arguments: arguments, database: db, resolver: resolver)
        }
    }

    static func execute(
        arguments: [String: Value]?,
        database: Database,
        resolver: ContactResolver
    ) async throws -> [Tool.Content] {
        guard let query = arguments?["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolFailure("validation_error", "query is required")
        }
        guard await resolver.authorization().authorized else {
            throw ToolFailure("contacts_unavailable", "Contacts access is off, so the server cannot look anyone up. Run diagnose for the fix.")
        }
        let limit = limit.read(arguments)

        let contacts = Array(await resolver.contacts(matching: query).prefix(rankedContacts))
        let known = try messagesHandles(for: contacts.flatMap(\.handles), db: database)
        let ranked = contacts.sorted { lhs, rhs in
            let left = lhs.handles.compactMap { known[$0]?.lastDate }.max()
            let right = rhs.handles.compactMap { known[$0]?.lastDate }.max()
            if left != right { return (left ?? .min) > (right ?? .min) }
            return lhs.name < rhs.name
        }

        var matches: [Match] = []
        for contact in ranked.prefix(limit) {
            var handles: [Handle] = []
            for handle in contact.handles {
                let row = known[handle]
                let chat = try row.flatMap { try SendResolver.latestDirectChat(for: $0.id, db: database) }
                handles.append(Handle(
                    handle: handle,
                    chatId: chat.map { ChatIdentifier.format($0.chatId) },
                    lastContact: row?.lastDate.flatMap { TimeUtils.formatCompactRelative(AppleTime.toDate($0)) }
                ))
            }
            matches.append(Match(name: contact.name, handles: handles))
        }

        return [.plainText(try FormatUtils.encodeJSON(Response(contacts: matches, more: ranked.count > limit)))]
    }

    /// chat.db's handle row for each Contacts number or email that Messages
    /// has seen, keyed by the Contacts form (E.164, or a lowercased email),
    /// with the date of the newest message from or to it.
    private static func messagesHandles(
        for handles: [String],
        db: Database
    ) throws -> [String: (id: String, lastDate: Int64?)] {
        let emails = handles.filter { $0.contains("@") }
        let numbers = handles.filter { !$0.contains("@") }
        var clauses: [String] = []
        if !numbers.isEmpty { clauses.append("h.id IN (\(SQLFragments.placeholders(numbers.count)))") }
        if !emails.isEmpty { clauses.append("LOWER(h.id) IN (\(SQLFragments.placeholders(emails.count)))") }
        guard !clauses.isEmpty else { return [:] }

        let rows: [(id: String, lastDate: Int64?)] = try db.query(
            """
            SELECT h.id, MAX(m.date)
            FROM handle h
            LEFT JOIN message m ON m.handle_id = h.ROWID
            WHERE \(clauses.joined(separator: " OR "))
            GROUP BY h.id
            """,
            params: numbers + emails
        ) { row in
            (id: row.string(0) ?? "", lastDate: row.optionalInt(1))
        }

        var known: [String: (id: String, lastDate: Int64?)] = [:]
        for row in rows {
            let key = row.id.contains("@") ? row.id.lowercased() : row.id
            if let existing = known[key], (existing.lastDate ?? .min) >= (row.lastDate ?? .min) { continue }
            known[key] = row
        }
        return known
    }
}
