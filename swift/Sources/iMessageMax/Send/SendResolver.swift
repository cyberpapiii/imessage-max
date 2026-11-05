import Foundation

/// Where the caller asked to send: an exact chat, or a person to find.
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
    case ambiguous([RecipientCandidate])
}

actor SendResolver {
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
            let chats: [(guid: String?, displayName: String?)] = try db.query(
                "SELECT guid, display_name FROM chat WHERE ROWID = ?",
                params: [numericId]
            ) { row in
                (guid: row.string(0), displayName: row.string(1))
            }

            guard let chat = chats.first else {
                return .failure(ClientErrorMessages.chatNotFound(chatId))
            }

            guard let guid = chat.guid, !guid.isEmpty else {
                return .failure("Chat has no guid and cannot be targeted exactly: \(chatId)")
            }

            let rows = try await ChatSummaryQueries.participants(
                db: db,
                chatId: numericId,
                resolver: resolver
            )
            guard !rows.isEmpty else {
                return .failure("No participants found for chat: \(chatId)")
            }

            let identity = ChatIdentity.from(
                chatId: numericId,
                guid: guid,
                explicitName: chat.displayName,
                rows: rows
            )

            return .success(
                ResolvedSendTarget(
                    target: .chat(guid: guid, chatId: numericId),
                    deliveredTo: identity.participants.map(\.displayName),
                    chat: ChatReference(
                        id: identity.mcpId,
                        name: identity.displayName
                    )
                )
            )
        } catch {
            return .failure(ClientErrorMessages.sanitized(error))
        }
    }

    private func resolveRecipient(_ to: String) async -> SendResolution {
        // A leading "+" stays on the phone path even when isPhoneNumber says
        // no ("+55555"), so it fails as a number instead of a contact name.
        if to.hasPrefix("+") || (PhoneUtils.isPhoneNumber(to) && PhoneUtils.normalizeToE164(to) != nil) {
            return await resolvePhoneNumber(to)
        }

        if PhoneUtils.isEmail(to) {
            return await resolveEmail(to)
        }

        return await resolveContactName(to)
    }

    private func resolvePhoneNumber(_ phone: String) async -> SendResolution {
        guard let normalized = PhoneUtils.normalizeToE164(phone) else {
            return .failure("Invalid phone number format: \(phone)")
        }

        do {
            var handles: [String] = try db.query(
                "SELECT id FROM handle WHERE id = ?",
                params: [normalized]
            ) { row in
                row.string(0) ?? ""
            }

            if handles.isEmpty {
                handles = try db.query(
                    "SELECT id FROM handle WHERE id = ?",
                    params: [phone]
                ) { row in
                    row.string(0) ?? ""
                }
            }

            guard let handle = handles.first else {
                return .failure("No conversation found with \(phone)")
            }
            let name = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
            return .success(try participantTarget(handle: handle, displayName: name))
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
            let name = await IdentityDisplayFormatter.displayName(handle: handle, resolver: resolver)
            return .success(try participantTarget(handle: handle, displayName: name))
        } catch {
            return .failure(ClientErrorMessages.sanitized(error))
        }
    }

    private func resolveContactName(_ name: String) async -> SendResolution {
        // Search the resolver first: a seeded/test cache needs no Contacts
        // access, and on live machines the cache is what refresh()
        // populated anyway. Authorization only matters when nothing matched.
        // It distinguishes "you can't search" from "no such contact".
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
                return .success(try participantTarget(handle: match.handle, displayName: match.name))
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

    private func participantTarget(handle: String, displayName: String) throws -> ResolvedSendTarget {
        let chatId = try findDirectChatForHandle(handle)
        return ResolvedSendTarget(
            target: .participant(handle: handle, chatId: chatId),
            deliveredTo: [displayName],
            chat: try chatId.flatMap { id in try chatReference(chatId: id) }
        )
    }

    private func findDirectChatForHandle(_ handle: String) throws -> Int64? {
        // The participant count must be computed over the WHOLE chat, not just the
        // rows surviving `WHERE h.id = ?`. A `GROUP BY ... HAVING COUNT(...) = 1`
        // after the handle filter counts only the filtered handle's rows, so every
        // chat containing the handle (including groups) passes. The correlated
        // subquery below counts all participants of each candidate chat instead.
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

    private func chatReference(chatId: Int64) throws -> ChatReference? {
        let rows: [(String?, String?)] = try db.query(
            "SELECT guid, display_name FROM chat WHERE ROWID = ?",
            params: [chatId]
        ) { row in
            (row.string(0), row.string(1))
        }
        guard let row = rows.first else { return nil }
        let displayName = row.1?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let displayName, !displayName.isEmpty {
            name = displayName
        } else {
            name = ChatIdentifier.format(chatId)
        }
        return ChatReference(id: ChatIdentifier.format(chatId), name: name)
    }
}
