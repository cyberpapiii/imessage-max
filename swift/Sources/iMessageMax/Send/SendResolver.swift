import Foundation

enum SendDestination {
    case chatId(String)
    case recipient(String)
}

struct ResolvedSendTarget {
    let target: SendTarget
    let deliveredTo: [String]
    let chat: ChatReference?
}

enum SendResolution {
    case success(ResolvedSendTarget)
    case failure(String)
    case ambiguous([RecipientCandidate], AmbiguityReason)
}

enum AmbiguityReason: Equatable {
    /// More than one contact number or email matches the name.
    case multipleMatches
    /// The one match is a Contacts number or email that chat.db has never
    /// seen, so nothing proves it reaches the person the agent meant.
    case notInMessages
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

            guard let handle = handles.first else {
                if normalized == nil {
                    return await resolveContactName(phone)
                }
                return .failure("No conversation found with \(phone)")
            }
            let name = IdentityDisplayFormatter.displayName(handle: handle, contactName: await resolver.resolve(handle))
            return .success(try await participantTarget(handle: handle, displayName: name))
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

            guard let handle = handles.first else {
                return .failure("No conversation found with \(email)")
            }
            let name = IdentityDisplayFormatter.displayName(handle: handle, contactName: await resolver.resolve(handle))
            return .success(try await participantTarget(handle: handle, displayName: name))
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
                // A name sends only to a handle Messages already knows. A
                // Contacts number alone may be misread (a number saved
                // without its country code) and reach a stranger.
                guard let handle = try messagesHandle(for: match.handle) else {
                    return .ambiguous(
                        [RecipientCandidate(name: match.name, handle: match.handle, lastContact: "never")],
                        .notInMessages
                    )
                }
                return .success(try await participantTarget(handle: handle, displayName: match.name))
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
            },
            .multipleMatches
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

    private func participantTarget(handle: String, displayName: String) async throws -> ResolvedSendTarget {
        let chatId = try findDirectChatForHandle(handle)
        var chat: ChatReference? = nil
        if let chatId, let identity = try await chatIdentity(chatId) {
            chat = ChatReference(id: identity.mcpId, name: identity.displayName)
        }
        return ResolvedSendTarget(
            target: .participant(handle: handle, chatId: chatId),
            deliveredTo: [displayName],
            chat: chat
        )
    }

    private func findDirectChatForHandle(_ handle: String) throws -> Int64? {
        let oneOnOneChats: [Int64] = try db.query(
            """
            SELECT c.ROWID
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = ?
              AND \(SQLFragments.participantCount()) = 1
            ORDER BY c.ROWID DESC
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.int(0)
        }

        return oneOnOneChats.first
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
