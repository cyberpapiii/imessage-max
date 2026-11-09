import Foundation

enum SendDestination {
    case chatId(String)
    case recipient(String)
}

struct ResolvedSendTarget {
    let target: SendTarget
    let deliveredTo: [String]
    let chat: ChatReference?
    /// The recipient's handle for a `to:` send. Verification also looks for
    /// the message in the handle's other chats, to catch a misrouted send.
    var recipientHandle: String? = nil
    /// chat.db has no handle row for `recipientHandle`: this send starts the
    /// first conversation with it.
    var handleIsNew = false
}

enum SendResolution {
    case success(ResolvedSendTarget)
    case failure(String)
    /// More than one contact number or email matches the name.
    case ambiguous([RecipientCandidate])
}

struct SendResolver: Sendable {
    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    func resolve(_ destination: SendDestination) async -> SendResolution {
        switch destination {
        case .chatId(let chatId): return await resolveChatId(chatId)
        case .recipient(let to): return await resolveRecipient(to)
        }
    }

    private func resolveChatId(_ chatId: String) async -> SendResolution {
        guard let numericId = ChatIdentifier.parseRowId(chatId) else {
            return .failure("Invalid chat_id format: \(chatId)")
        }

        do {
            guard let identity = try await chatIdentity(numericId) else {
                return .failure(ClientErrorMessages.chatNotFound(chatId))
            }

            guard let guid = identity.guid, !guid.isEmpty else {
                return .failure("The chat has no guid, so the tool cannot target it exactly: \(chatId)")
            }

            guard !identity.participants.isEmpty else {
                return .failure("No participants found for chat: \(chatId)")
            }

            return .success(
                ResolvedSendTarget(
                    target: .chat(guid: guid, chatId: numericId),
                    deliveredTo: identity.participants.map(\.displayName),
                    chat: ChatReference(id: identity.mcpId, name: identity.displayName)
                )
            )
        } catch {
            return .failure(ClientErrorMessages.sanitized(error))
        }
    }

    private func resolveRecipient(_ to: String) async -> SendResolution {
        if to.hasPrefix("+") || PhoneUtils.isPhoneNumber(to) {
            return await resolvePhoneNumber(to)
        }

        if PhoneUtils.isEmail(to) {
            return await resolveEmail(to)
        }

        return await resolveContactName(to)
    }

    /// "+" and 7 digits, the shortest E.164 numbers in use. A shorter one
    /// is a short code, which only an existing conversation can reach.
    static let shortestNewNumber = 8

    private func resolvePhoneNumber(_ phone: String) async -> SendResolution {
        let raw = phone.trimmingCharacters(in: .whitespaces)
        let normalized = PhoneUtils.normalizeToE164(raw, region: resolver.region)
        if normalized == nil && raw.hasPrefix("+") {
            return .failure("Invalid phone number format: \(phone)")
        }

        do {
            var handles: [String] = try db.query(
                "SELECT id FROM handle WHERE id = ?",
                params: [normalized ?? raw]
            ) { row in
                row.string(0) ?? ""
            }

            if handles.isEmpty, normalized != nil {
                handles = try db.query(
                    "SELECT id FROM handle WHERE id = ?",
                    params: [raw]
                ) { row in
                    row.string(0) ?? ""
                }
            }

            if handles.isEmpty, let normalized, normalized.count < Self.shortestNewNumber {
                return .failure("No conversation found with \(phone)")
            }
            guard let handle = handles.first ?? normalized else {
                return await resolveContactName(phone)
            }
            let name = IdentityDisplayFormatter.displayName(handle: handle, contactName: await resolver.resolve(handle))
            return .success(try await participantTarget(handle: handle, displayName: name, isNew: handles.isEmpty))
        } catch {
            return .failure(ClientErrorMessages.sanitized(error))
        }
    }

    private func resolveEmail(_ email: String) async -> SendResolution {
        do {
            let handles: [String] = try db.query(
                "SELECT id FROM handle WHERE LOWER(id) = LOWER(?)",
                params: [email]
            ) { row in
                row.string(0) ?? ""
            }

            let handle = handles.first ?? email.trimmingCharacters(in: .whitespaces).lowercased()
            let name = IdentityDisplayFormatter.displayName(handle: handle, contactName: await resolver.resolve(handle))
            return .success(try await participantTarget(handle: handle, displayName: name, isNew: handles.isEmpty))
        } catch {
            return .failure(ClientErrorMessages.sanitized(error))
        }
    }

    private func resolveContactName(_ name: String) async -> SendResolution {
        let matches = await resolver.searchByName(name)
        if matches.isEmpty {
            let (authorized, _) = await resolver.authorization()
            guard authorized else {
                return .failure("Cannot search by name without contacts access")
            }
            return .failure("No contact found matching '\(name)'")
        }

        if matches.count == 1 {
            let match = matches[0]
            do {
                // One number or email in all of Contacts matches, so there is
                // nothing to choose between. A number saved without a country
                // code is read in the Mac's region, as Messages reads it, and
                // one that cannot be read that way never reaches the cache.
                let known = try messagesHandle(for: match.handle)
                return .success(try await participantTarget(
                    handle: known ?? match.handle, displayName: match.name, isNew: known == nil))
            } catch {
                return .failure(ClientErrorMessages.sanitized(error))
            }
        }

        let capped = Array(matches.prefix(50))
        let lastTimes = (try? getLastContactTimes(handles: capped.map(\.handle))) ?? [:]
        var candidates: [(handle: String, name: String, lastContact: Date?)] = []
        for match in capped {
            candidates.append((match.handle, match.name, lastTimes[match.handle]))
        }

        candidates.sort { lhs, rhs in
            switch (lhs.lastContact, rhs.lastContact) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let l?, let r?): return l > r
            }
        }

        return .ambiguous(
            candidates.map { candidate in
                RecipientCandidate(
                    name: candidate.name,
                    handle: candidate.handle,
                    lastContact: TimeUtils.formatCompactRelative(candidate.lastContact) ?? "never"
                )
            }
        )
    }

    /// The chat.db handle id for a Contacts number or email, or nil when
    /// Messages has never seen it.
    private func messagesHandle(for contactHandle: String) throws -> String? {
        let sql = contactHandle.contains("@")
            ? "SELECT id FROM handle WHERE LOWER(id) = LOWER(?) LIMIT 1"
            : "SELECT id FROM handle WHERE id = ? LIMIT 1"
        let ids: [String?] = try db.query(sql, params: [contactHandle]) { row in row.string(0) }
        return ids.compactMap { $0 }.first
    }

    /// A recipient goes through their existing 1:1 chat when there is one,
    /// whatever its service, so the send lands where Messages would put it
    /// and verification reads the chat that was used. A participant send
    /// always goes over iMessage: with only an SMS or RCS DM it reached a
    /// different chat, and the check of the DM reported a false mismatch.
    /// Only a handle with no DM goes through the iMessage participant.
    private func participantTarget(handle: String, displayName: String, isNew: Bool = false) async throws -> ResolvedSendTarget {
        guard let direct = try Self.latestDirectChat(for: handle, db: db) else {
            return ResolvedSendTarget(
                target: .participant(handle: handle, chatId: nil),
                deliveredTo: [displayName],
                chat: nil,
                recipientHandle: handle,
                handleIsNew: isNew
            )
        }
        var chat: ChatReference? = nil
        if let identity = try await chatIdentity(direct.chatId) {
            chat = ChatReference(id: identity.mcpId, name: identity.displayName)
        }
        return ResolvedSendTarget(
            target: .chat(guid: direct.guid, chatId: direct.chatId),
            deliveredTo: [displayName],
            chat: chat,
            recipientHandle: handle
        )
    }

    /// A 1:1 chat: `chat.style` 45 (a group is 43) with one participant.
    static func isDirectChat(_ alias: String = "c") -> String {
        "(\(alias).style = 45 AND \(SQLFragments.participantCount(alias)) = 1)"
    }

    /// The handle's 1:1 chat with the newest message. A group that everyone
    /// else left has one participant too, but it is not the DM. Duplicate
    /// DMs, one per service or left over from an old thread, are common, and
    /// the newest one is where the conversation is.
    static func latestDirectChat(for handle: String, db: Database) throws -> (chatId: Int64, guid: String)? {
        let rows: [(chatId: Int64, guid: String)] = try db.query(
            """
            SELECT c.ROWID, c.guid
            FROM chat c
            WHERE \(Self.isDirectChat())
              AND COALESCE(c.guid, '') != ''
              AND EXISTS (
                  SELECT 1 FROM chat_handle_join chj
                  JOIN handle h ON chj.handle_id = h.ROWID
                  WHERE chj.chat_id = c.ROWID AND h.id = ?
              )
            ORDER BY \(SQLFragments.newestChatFirst())
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            (chatId: row.int(0), guid: row.string(1) ?? "")
        }
        return rows.first
    }

    private func getLastContactTimes(handles: [String]) throws -> [String: Date] {
        guard !handles.isEmpty else { return [:] }
        let placeholders = SQLFragments.placeholders(handles.count)
        let rows: [(String, Int64?)] = try db.query(
            """
            SELECT h.id, MAX(m.date)
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id IN (\(placeholders))
            GROUP BY h.id
            """,
            params: handles
        ) { row in
            (row.string(0) ?? "", row.optionalInt(1))
        }

        var result: [String: Date] = [:]
        for (handle, timestamp) in rows {
            if let timestamp {
                result[handle] = AppleTime.toDate(timestamp)
            }
        }
        return result
    }

    private func chatIdentity(_ chatId: Int64) async throws -> ChatIdentity? {
        let rows: [(guid: String?, displayName: String?)] = try db.query(
            "SELECT guid, display_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            (guid: row.string(0), displayName: row.string(1))
        }
        guard let row = rows.first else { return nil }
        let chat = ChatPage.Chat(id: chatId, guid: row.guid, explicitName: row.displayName)
        return try await ChatPage.identities([chat], db: db, resolver: resolver)[chatId]
    }
}
