import Foundation

enum SendResolution {
    struct ParticipantInfo {
        let handle: String
        let displayName: String
    }

    enum Target {
        case participant(handle: String, chatId: Int?)
        case chat(guid: String, chatId: Int)
    }

    struct ResolvedTarget {
        let target: Target
        let deliveredTo: [String]
    }

    enum Result {
        case success(ResolvedTarget)
        case failure(String)
        case ambiguous([RecipientCandidate])
    }
}

actor SendResolver {
    private let db: Database
    private let resolver: ContactResolver

    init(db: Database, resolver: ContactResolver) {
        self.db = db
        self.resolver = resolver
    }

    func resolve(chatId: String?, to: String?) async -> SendResolution.Result {
        if let chatId {
            return await resolveChatId(chatId)
        }

        if let to {
            return await resolveRecipient(to)
        }

        return .failure("Either 'to' or 'chat_id' must be provided")
    }

    private func resolveChatId(_ chatId: String) async -> SendResolution.Result {
        let numericString = chatId.replacingOccurrences(of: "chat", with: "")
        guard let numericId = Int(numericString) else {
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
                return .failure("Chat not found: \(chatId)")
            }

            guard let guid = chat.guid, !guid.isEmpty else {
                return .failure("Chat has no guid and cannot be targeted exactly: \(chatId)")
            }

            let participants = try await getParticipants(chatId: numericId)
            guard !participants.isEmpty else {
                return .failure("No participants found for chat: \(chatId)")
            }

            return .success(
                SendResolution.ResolvedTarget(
                    target: .chat(guid: guid, chatId: numericId),
                    deliveredTo: participants.map(\.displayName)
                )
            )
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    private func resolveRecipient(_ to: String) async -> SendResolution.Result {
        if PhoneUtils.isPhoneNumber(to) || to.hasPrefix("+") {
            return await resolvePhoneNumber(to)
        }

        if PhoneUtils.isEmail(to) {
            return await resolveEmail(to)
        }

        return await resolveContactName(to)
    }

    private func resolvePhoneNumber(_ phone: String) async -> SendResolution.Result {
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

            let chatId = try findDirectChatForHandle(handle)
            let name = await resolver.resolve(handle) ?? PhoneUtils.formatDisplay(handle)

            return .success(
                SendResolution.ResolvedTarget(
                    target: .participant(handle: handle, chatId: chatId),
                    deliveredTo: [name]
                )
            )
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    private func resolveEmail(_ email: String) async -> SendResolution.Result {
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

            let chatId = try findDirectChatForHandle(handle)
            let name = await resolver.resolve(handle) ?? email

            return .success(
                SendResolution.ResolvedTarget(
                    target: .participant(handle: handle, chatId: chatId),
                    deliveredTo: [name]
                )
            )
        } catch {
            return .failure("Database error: \(error.localizedDescription)")
        }
    }

    private func resolveContactName(_ name: String) async -> SendResolution.Result {
        let (authorized, _) = ContactResolver.authorizationStatus()
        guard authorized else {
            return .failure("Cannot search by name without contacts access")
        }

        let matches = await resolver.searchByName(name)
        if matches.isEmpty {
            return .failure("No contact found matching '\(name)'")
        }

        if matches.count == 1 {
            let match = matches[0]
            do {
                let chatId = try findDirectChatForHandle(match.handle)
                return .success(
                    SendResolution.ResolvedTarget(
                        target: .participant(handle: match.handle, chatId: chatId),
                        deliveredTo: [match.name]
                    )
                )
            } catch {
                return .failure("Database error: \(error.localizedDescription)")
            }
        }

        var candidates: [(handle: String, name: String, lastContact: Date?)] = []
        for match in matches {
            let lastTime = try? getLastContactTime(handle: match.handle)
            candidates.append((match.handle, match.name, lastTime))
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

    private func findDirectChatForHandle(_ handle: String) throws -> Int? {
        let oneOnOneChats: [Int64] = try db.query(
            """
            SELECT c.ROWID
            FROM chat c
            JOIN chat_handle_join chj ON c.ROWID = chj.chat_id
            JOIN handle h ON chj.handle_id = h.ROWID
            WHERE h.id = ?
            GROUP BY c.ROWID
            HAVING COUNT(DISTINCT chj.handle_id) = 1
            ORDER BY c.ROWID DESC
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.int(0)
        }

        return oneOnOneChats.first.map(Int.init)
    }

    private func getParticipants(chatId: Int) async throws -> [SendResolution.ParticipantInfo] {
        let handles: [String] = try db.query(
            """
            SELECT h.id
            FROM handle h
            JOIN chat_handle_join chj ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            ORDER BY h.id ASC
            """,
            params: [chatId]
        ) { row in
            row.string(0) ?? ""
        }

        var participants: [SendResolution.ParticipantInfo] = []
        for handle in handles {
            let name = await resolver.resolve(handle) ?? PhoneUtils.formatDisplay(handle)
            participants.append(.init(handle: handle, displayName: name))
        }

        return participants
    }

    private func getLastContactTime(handle: String) throws -> Date? {
        let dates: [Int64?] = try db.query(
            """
            SELECT m.date
            FROM message m
            JOIN handle h ON m.handle_id = h.ROWID
            WHERE h.id = ?
            ORDER BY m.date DESC
            LIMIT 1
            """,
            params: [handle]
        ) { row in
            row.optionalInt(0)
        }

        guard let timestamp = dates.first, let ts = timestamp else { return nil }
        return AppleTime.toDate(ts)
    }
}
