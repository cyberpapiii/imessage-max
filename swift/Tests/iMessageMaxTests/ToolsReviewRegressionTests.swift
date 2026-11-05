import XCTest
import MCP
@testable import iMessageMax

/// Regressions for the read-tool review fixes.
final class ToolsReviewRegressionTests: XCTestCase {
    private let minute: Int64 = 60_000_000_000

    private func now() -> Int64 { Int64(Date().timeIntervalSinceReferenceDate) * 1_000_000_000 }

    private func call(
        _ name: String,
        _ args: [String: Value],
        db: ToolTestDatabase,
        contacts: [String: String] = [:]
    ) async throws -> [String: Any] {
        let catalog = ToolCatalog(database: db.database(), resolver: ContactResolver(seedCache: contacts))
        let handler = try XCTUnwrap(catalog.handler(named: name))
        return try decodeJSONDictionary(from: try await handler(args))
    }

    // MARK: - People keys never collide

    func testUnnamedKeySkipsAKeyAContactAlreadyHolds() {
        var people = PeopleMap(rules: .participants)
        people.addMe()
        XCTAssertEqual(people.add(handle: "+1", name: "Unknown A", position: 0), "unknown")
        XCTAssertEqual(people.add(handle: "+2", name: "Unknown B", position: 1), "unknown1")
        XCTAssertEqual(people.add(handle: "+3", name: nil, position: 2), "unknown2")
        XCTAssertEqual(Set(people.people.map(\.key)).count, people.people.count)
    }

    func testPositionSuffixSkipsAKeyAlreadyTaken() {
        var people = PeopleMap(rules: .participants)
        XCTAssertEqual(people.add(handle: "+1", name: nil, position: 0), "unknown1")
        XCTAssertEqual(people.add(handle: "+2", name: "Unknown A", position: 1), "unknown")
        XCTAssertEqual(people.add(handle: "+3", name: "Unknown B", position: 1), "unknown2")
    }

    func testSeenUnnamedKeySkipsAContactKey() {
        var people = PeopleMap(rules: .seen)
        XCTAssertEqual(people.add(handle: "+1", name: "P1 Pilot"), "p1")
        XCTAssertEqual(people.add(handle: "+2", name: nil), "p2")
    }

    /// Trapped in Dictionary(uniqueKeysWithValues:) before the fix.
    func testGetMessagesAndGetContextSurviveContactsNamedLikeUnnamedKeys() async throws {
        let db = try ToolTestDatabase(name: "people-collide")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertHandle(rowId: 2, handle: "+15550000002")
        try db.insertHandle(rowId: 3, handle: "+15550000003")
        try db.insertChat(rowId: 1, guid: "iMessage;+;chat-collide")
        for h in 1...3 { try db.joinChatHandle(chatId: 1, handleId: h) }
        let base = now() - 60 * minute
        for (i, h) in [1, 2, 3].enumerated() {
            try db.insertMessage(rowId: i + 1, guid: "C\(i)", text: "hi \(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: h)
            try db.joinChatMessage(chatId: 1, messageId: i + 1)
        }
        // +15550000003 has no contact, so it takes the unnamed key.
        let contacts = ["+15550000001": "Unknown A", "+15550000002": "Unknown B"]

        let messages = try await call("get_messages", ["chat_id": "chat1"], db: db, contacts: contacts)
        let people = try XCTUnwrap(messages["people"] as? [String: String])
        XCTAssertEqual(people.count, 4)

        let db2 = try ToolTestDatabase(name: "people-collide-seen")
        try db2.insertHandle(rowId: 1, handle: "+15550000001")
        try db2.insertHandle(rowId: 2, handle: "+15550000002")
        try db2.insertChat(rowId: 1, guid: "iMessage;+;chat-seen")
        for h in 1...2 { try db2.joinChatHandle(chatId: 1, handleId: h) }
        for (i, h) in [1, 2].enumerated() {
            try db2.insertMessage(rowId: i + 1, guid: "S\(i)", text: "yo \(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: h)
            try db2.joinChatMessage(chatId: 1, messageId: i + 1)
        }
        let context = try await call("get_context", ["message_id": "msg_1"], db: db2, contacts: ["+15550000001": "P1 Pilot"])
        let seen = try XCTUnwrap(context["people"] as? [String: Any])
        XCTAssertEqual(Set(seen.keys), ["p1", "p2"])
    }

    // MARK: - Paging past rows Swift drops

    /// Follows cursors until the tool stops returning one.
    private func pages(
        _ name: String,
        _ args: [String: Value],
        resultsKey: String,
        db: ToolTestDatabase
    ) async throws -> (ids: [String], pages: Int) {
        var ids: [String] = []
        var cursor: String?
        var count = 0
        repeat {
            var pageArgs = args
            if let cursor { pageArgs["cursor"] = .string(cursor) }
            let page = try await call(name, pageArgs, db: db)
            ids += try decodeJSONArray(page[resultsKey]).compactMap { $0["id"] as? String }
            cursor = page["cursor"] as? String
            XCTAssertEqual(page["more"] as? Bool, cursor != nil)
            count += 1
        } while cursor != nil && count < 20
        return (ids, count)
    }

    /// The blob holds the class name "NSString", so every attributedBody
    /// row passes the SQL prefilter for "string" and Swift drops them all.
    func testSearchReachesAMatchBehindAFullFetchOfPrefilterFalsePositives() async throws {
        let db = try ToolTestDatabase(name: "search-paging")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        let base = now() - 1_000 * minute
        try db.insertMessage(rowId: 1, guid: "M1", text: "tie the string here", date: base, isFromMe: false, handleId: 1)
        try db.joinChatMessage(chatId: 1, messageId: 1)
        try db.execute("BEGIN")
        for i in 2...601 {
            try db.insertMessage(
                rowId: i, guid: "M\(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array("filler \(i)".utf8))
            )
            try db.joinChatMessage(chatId: 1, messageId: i)
        }
        try db.execute("COMMIT")

        for args: [String: Value] in [["query": "string", "limit": 1], ["query": "strng", "fuzzy": true, "limit": 1]] {
            let found = try await pages("search", args, resultsKey: "results", db: db)
            XCTAssertEqual(found.ids, ["msg_1"], "\(args)")
            XCTAssertGreaterThan(found.pages, 1)
        }
    }

    func testUnansweredGetMessagesPagesPastNonQuestions() async throws {
        let db = try ToolTestDatabase(name: "unanswered-paging")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        let base = now() - 1_000 * minute
        try db.insertMessage(rowId: 1, guid: "Q", text: "are you coming?", date: base, isFromMe: true)
        try db.joinChatMessage(chatId: 1, messageId: 1)
        for i in 2...5 {
            try db.insertMessage(rowId: i, guid: "N\(i)", text: "note \(i)", date: base + Int64(i) * minute, isFromMe: true)
            try db.joinChatMessage(chatId: 1, messageId: i)
        }

        let found = try await pages(
            "get_messages", ["chat_id": "chat1", "unanswered": true, "limit": 1], resultsKey: "messages", db: db
        )
        XCTAssertEqual(found.ids, ["msg_1"])
    }

    // MARK: - One text-contains rule

    /// `fillerCount` attributedBody-only rows newer than one attributedBody
    /// row holding "Lisbon", in chat 1; chat 2 has nothing.
    private func blobFixture(fillerCount: Int) throws -> ToolTestDatabase {
        let db = try ToolTestDatabase(name: "blob-contains")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        let base = now() - Int64(fillerCount + 10) * minute
        try db.execute("BEGIN")
        try db.insertMessage(
            rowId: 1, guid: "HIT", date: base, isFromMe: false, handleId: 1,
            attributedBody: typedstreamBlob(payload: Array("off to Lisbon".utf8))
        )
        try db.joinChatMessage(chatId: 1, messageId: 1)
        for i in 2...(fillerCount + 1) {
            try db.insertMessage(
                rowId: i, guid: "F\(i)", date: base + Int64(i) * minute, isFromMe: false, handleId: 1,
                attributedBody: typedstreamBlob(payload: Array("filler \(i)".utf8))
            )
            try db.joinChatMessage(chatId: 1, messageId: i)
        }
        try db.execute("COMMIT")
        return db
    }

    func testGetContextFindsBlobTextBehindMoreThanTheScanCapOfBlobRows() async throws {
        let db = try blobFixture(fillerCount: 5_200)
        let context = try await call("get_context", ["chat_id": "chat1", "contains": "lisbon"], db: db)
        let message = try XCTUnwrap(context["message"] as? [String: Any])
        XCTAssertEqual(message["id"] as? String, "msg_1")
    }

    func testFindChatContainsRecentSeesPastTwoHundredBlobRows() async throws {
        let db = try blobFixture(fillerCount: 300)
        let found = try await call("find_chat", ["contains_recent": "Lisbon"], db: db)
        let chats = try decodeJSONArray(found["chats"])
        XCTAssertEqual(chats.compactMap { $0["id"] as? String }, ["chat1"])
    }

    // MARK: - One participant resolver

    /// Chats 1-12: DMs with Alice, newest last. Chat 20: Alice and Bob,
    /// older than all of them. Chat 30: a DM with an email handle.
    private func participantFixture() throws -> ToolTestDatabase {
        let db = try ToolTestDatabase(name: "participants")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertHandle(rowId: 2, handle: "+15550000002")
        try db.insertHandle(rowId: 3, handle: "pat@example.com")
        let base = now() - 100 * minute
        var id = 0
        func say(_ chat: Int, _ at: Int64, handle: Int) throws {
            id += 1
            try db.insertMessage(rowId: id, guid: "P\(id)", text: "hello \(id)", date: base + at * minute, isFromMe: false, handleId: handle)
            try db.joinChatMessage(chatId: chat, messageId: id)
        }
        try db.insertChat(rowId: 20, guid: "iMessage;+;alice-bob")
        try db.joinChatHandle(chatId: 20, handleId: 1)
        try db.joinChatHandle(chatId: 20, handleId: 2)
        try say(20, 0, handle: 2)
        for chat in 1...12 {
            try db.insertChat(rowId: chat, guid: "iMessage;-;alice\(chat)")
            try db.joinChatHandle(chatId: chat, handleId: 1)
            try say(chat, Int64(chat), handle: 1)
        }
        try db.insertChat(rowId: 30, guid: "iMessage;-;pat@example.com")
        try db.joinChatHandle(chatId: 30, handleId: 3)
        try say(30, 50, handle: 3)
        return db
    }

    private let aliceAndBob = ["+15550000001": "Alice Smith", "+15550000002": "Bob Brown"]

    func testGetMessagesFindsTheOnlyChatWithEveryParticipantPastTenNewerCandidates() async throws {
        let db = try participantFixture()
        let page = try await call("get_messages", ["participants": ["Alice", "Bob"]], db: db, contacts: aliceAndBob)
        XCTAssertEqual((page["chat"] as? [String: Any])?["id"] as? String, "chat20")
    }

    func testAnUnresolvedParticipantIsNeverDropped() async throws {
        let db = try participantFixture()
        let catalog = ToolCatalog(database: db.database(), resolver: ContactResolver(seedCache: aliceAndBob))
        let getMessages = try XCTUnwrap(catalog.handler(named: "get_messages"))
        let body = try await toolFailureBody { try await getMessages(["participants": ["Alice", "Bob", "Nobody Known"]]) }
        XCTAssertEqual(body["error"] as? String, "invalid_participants")
        XCTAssertTrue((body["message"] as? String ?? "").contains("Nobody Known"))

        let found = try await call("find_chat", ["participants": ["Alice", "Bob", "Nobody Known"]], db: db, contacts: aliceAndBob)
        XCTAssertEqual(try decodeJSONArray(found["chats"]).count, 0)
    }

    func testParticipantsAcceptAnEmail() async throws {
        let db = try participantFixture()
        let page = try await call("get_messages", ["participants": ["Pat@Example.com"]], db: db)
        XCTAssertEqual((page["chat"] as? [String: Any])?["id"] as? String, "chat30")
        let found = try await call("find_chat", ["participants": ["pat@example.com"]], db: db)
        XCTAssertEqual(try decodeJSONArray(found["chats"]).compactMap { $0["id"] as? String }, ["chat30"])
    }

    func testFindChatRanksTheExactParticipantSetFirst() async throws {
        let db = try participantFixture()
        let found = try await call("find_chat", ["participants": ["Bob"]], db: db, contacts: aliceAndBob)
        XCTAssertEqual(try decodeJSONArray(found["chats"]).compactMap { $0["id"] as? String }, ["chat20"])
        let alice = try await call("find_chat", ["participants": ["Alice"], "limit": 3], db: db, contacts: aliceAndBob)
        XCTAssertEqual(try decodeJSONArray(alice["chats"]).compactMap { $0["id"] as? String }, ["chat12", "chat11", "chat10"])
    }

    // MARK: - get_active_conversations

    func testActiveConversationsFindsQualifyingChatsBehindNewerThinOnes() async throws {
        let db = try ToolTestDatabase(name: "active")
        let base = now() - 120 * minute
        var id = 0
        func exchange(_ chat: Int, at: Int64, rounds: Int) throws {
            for r in 0..<rounds {
                for me in [true, false] {
                    id += 1
                    try db.insertMessage(rowId: id, guid: "A\(id)", text: "t\(id)", date: base + (at + Int64(r)) * minute,
                                         isFromMe: me, handleId: me ? nil : chat)
                    try db.joinChatMessage(chatId: chat, messageId: id)
                }
            }
        }
        for chat in 1...6 {
            try db.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try db.insertChat(rowId: chat, guid: "iMessage;-;\(chat)")
            try db.joinChatHandle(chatId: chat, handleId: chat)
        }
        try exchange(1, at: 0, rounds: 2)
        try exchange(2, at: 5, rounds: 2)
        for chat in 3...6 { try exchange(chat, at: Int64(20 + chat), rounds: 1) }

        let one = try await call("get_active_conversations", ["limit": 1, "min_exchanges": 2], db: db)
        XCTAssertEqual(try decodeJSONArray(one["conversations"]).compactMap { $0["id"] as? String }, ["chat2"])
        XCTAssertEqual(one["more"] as? Bool, true)
        let all = try await call("get_active_conversations", ["limit": 2, "min_exchanges": 2], db: db)
        XCTAssertEqual(try decodeJSONArray(all["conversations"]).compactMap { $0["id"] as? String }, ["chat2", "chat1"])
        XCTAssertEqual(all["more"] as? Bool, false)
    }

    // MARK: - get_unread

    func testUnreadSummaryTotalsCountEveryChatNotJustThePage() async throws {
        let db = try ToolTestDatabase(name: "unread-totals")
        let base = now() - 60 * minute
        var id = 0
        for (chat, unread) in [(1, 3), (2, 2), (3, 1)] {
            try db.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try db.insertChat(rowId: chat, guid: "iMessage;-;\(chat)")
            try db.joinChatHandle(chatId: chat, handleId: chat)
            for _ in 0..<unread {
                id += 1
                try db.insertMessage(rowId: id, guid: "U\(id)", text: "u\(id)", date: base + Int64(id) * minute,
                                     isFromMe: false, isRead: false, handleId: chat)
                try db.joinChatMessage(chatId: chat, messageId: id)
            }
        }

        let summary = try await call("get_unread", ["format": "summary", "limit": 1], db: db)
        let messages = try await call("get_unread", ["format": "messages", "limit": 1], db: db)
        XCTAssertEqual(try decodeJSONArray(summary["chats"]).count, 1)
        for page in [summary, messages] {
            XCTAssertEqual(page["total_unread"] as? Int, 6)
            XCTAssertEqual(page["chats_with_unread"] as? Int, 3)
            XCTAssertEqual(page["more"] as? Bool, true)
        }
    }

    // MARK: - filtered_hidden counts chats with a real match

    /// Chat 1 shown, chat 2 hidden with a match, chat 3 hidden without one.
    private func hiddenFixture() throws -> ToolTestDatabase {
        let db = try ToolTestDatabase(name: "hidden")
        let base = now() - 60 * minute
        let texts = [1: ["volcano trip"], 2: ["volcano photos", "volcano again?"], 3: ["nothing here", "still nothing"]]
        var id = 0
        for chat in 1...3 {
            try db.insertHandle(rowId: chat, handle: "+1555000000\(chat)")
            try db.insertChat(rowId: chat, guid: "iMessage;-;\(chat)", isFiltered: chat == 1 ? 0 : 1)
            try db.joinChatHandle(chatId: chat, handleId: chat)
            for text in texts[chat] ?? [] {
                id += 1
                try db.insertMessage(rowId: id, guid: "H\(id)", text: text, date: base + Int64(id) * minute,
                                     isFromMe: true)
                try db.joinChatMessage(chatId: chat, messageId: id)
            }
        }
        return db
    }

    func testSearchFilteredHiddenCountsOnlyHiddenChatsWithARealMatch() async throws {
        let db = try hiddenFixture()
        for args: [String: Value] in [
            ["query": "volcano"],
            ["query": "volcno", "fuzzy": true],
            ["query": "volcano", "format": "grouped_by_chat"],
            ["unanswered": true],
        ] {
            let page = try await call("search", args, db: db)
            XCTAssertEqual(page["filtered_hidden"] as? Int, 1, "\(args)")
        }
    }

    func testGetMessagesSinceFilteredHiddenCountsChats() async throws {
        let db = try hiddenFixture()
        let page = try await call("get_messages_since", ["since_rowid": 0], db: db)
        XCTAssertEqual(page["filtered_hidden"] as? Int, 2)
        XCTAssertEqual(try decodeJSONArray(page["messages"]).count, 1)
    }

    // MARK: - Deterministic picks

    func testGuidSubstringResolvesToTheMostRecentlyActiveChat() async throws {
        let db = try ToolTestDatabase(name: "guid-pick")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        let base = now() - 60 * minute
        for chat in 1...3 {
            try db.insertChat(rowId: chat, guid: "iMessage;+;shared-guid-\(chat)")
            try db.joinChatHandle(chatId: chat, handleId: 1)
            try db.insertMessage(rowId: chat, guid: "D\(chat)", text: "m\(chat)", date: base + Int64([3: 1, 1: 2, 2: 3][chat]!) * minute,
                                 isFromMe: true)
            try db.joinChatMessage(chatId: chat, messageId: chat)
        }
        let page = try await call("get_messages", ["chat_id": "shared-guid"], db: db)
        XCTAssertEqual((page["chat"] as? [String: Any])?["id"] as? String, "chat2")
    }

    func testFindChatByNameListsTheMostRecentlyActiveFirst() async throws {
        let db = try ToolTestDatabase(name: "name-order")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertHandle(rowId: 2, handle: "+15550000002")
        let base = now() - 60 * minute
        for chat in 1...3 {
            try db.insertChat(rowId: chat, guid: "iMessage;+;team\(chat)", displayName: "Team \(chat)")
            try db.joinChatHandle(chatId: chat, handleId: 1)
            try db.joinChatHandle(chatId: chat, handleId: 2)
            try db.insertMessage(rowId: chat, guid: "T\(chat)", text: "m\(chat)", date: base + Int64([1: 2, 2: 3, 3: 1][chat]!) * minute,
                                 isFromMe: true)
            try db.joinChatMessage(chatId: chat, messageId: chat)
        }
        let found = try await call("find_chat", ["name": "Team", "limit": 2], db: db)
        XCTAssertEqual(try decodeJSONArray(found["chats"]).compactMap { $0["id"] as? String }, ["chat2", "chat1"])
    }

    // MARK: - Attachments

    func testPreviewsSkipHiddenAttachments() async throws {
        let db = try ToolTestDatabase(name: "hidden-attachment")
        try db.insertHandle(rowId: 1, handle: "+15550000001")
        try db.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try db.joinChatHandle(chatId: 1, handleId: 1)
        try db.insertMessage(rowId: 1, guid: "IMG", text: "\u{FFFC}", date: now() - minute, isFromMe: false, handleId: 1)
        try db.joinChatMessage(chatId: 1, messageId: 1)
        for id in 1...2 {
            try db.insertAttachment(rowId: id, filename: "~/Library/Messages/Attachments/\(id).jpeg", mimeType: "image/jpeg",
                                    uti: "public.jpeg", totalBytes: 10, transferName: "\(id).jpeg")
            try db.joinMessageAttachment(messageId: 1, attachmentId: id)
        }
        try db.execute("UPDATE attachment SET hide_attachment = 1 WHERE ROWID = 2")

        let page = try await call("list_chats", [:], db: db)
        let chat = try XCTUnwrap(try decodeJSONArray(page["chats"]).first)
        XCTAssertEqual((chat["last_message"] as? [String: Any])?["text"] as? String, "[Photo]")
    }

    func testAttachmentKindsAgreeBetweenSwiftAndSQL() throws {
        let db = try ToolTestDatabase(name: "attachment-kinds")
        let samples: [(String?, String?)] = [
            ("image/heic", "public.heic"), (nil, "public.png"), ("video/quicktime", "com.apple.quicktime-movie"),
            ("audio/x-m4a", nil), ("application/pdf", "com.adobe.pdf"), ("application/msword", nil),
            ("text/plain", "public.plain-text"),
        ]
        for (id, sample) in samples.enumerated() {
            try db.execute("""
                INSERT INTO attachment (ROWID, mime_type, uti) VALUES (\(id + 1), \(sample.0.map { "'\($0)'" } ?? "NULL"), \(sample.1.map { "'\($0)'" } ?? "NULL"))
                """)
        }
        for kind in ["image", "video", "audio", "pdf", "document"] {
            let predicate = try XCTUnwrap(AttachmentType.sqlPredicate(for: kind, alias: "a"))
            let matched: [Int64] = try db.database().query("SELECT a.ROWID FROM attachment a WHERE \(predicate) ORDER BY 1", params: []) { $0.int(0) }
            let expected = samples.enumerated().filter { AttachmentType.from(mimeType: $0.element.0, uti: $0.element.1).rawValue == kind }
                .map { Int64($0.offset + 1) }
            XCTAssertEqual(matched, expected, kind)
        }
        XCTAssertNil(AttachmentType.sqlPredicate(for: "any"))
        XCTAssertNil(AttachmentType.sqlPredicate(for: "other"))
    }
}
