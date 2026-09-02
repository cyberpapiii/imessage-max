import XCTest
@testable import iMessageMax

/// Characterization tests for the `list_attachments` message query.
///
/// The query has to satisfy several constraints at once: one row per message
/// even when a message carries several attachments or belongs to several
/// chats, a type filter that applies to the attachments rather than the
/// message, three sort orders, and cursor paging on the two date sorts. These
/// tests pin that behavior so the SQL underneath can be reshaped safely.
final class ListAttachmentsQueryTests: XCTestCase {

    // MARK: - Fixture

    /// Apple epoch nanoseconds for midnight, `offset` days after 2020-01-01.
    private static func day(_ offset: Int) -> Int64 {
        let base: Int64 = 600_000_000  // 2020-01-05T00:00:00Z in Apple seconds
        return (base + Int64(offset) * 86_400) * 1_000_000_000
    }

    /// Chats 1 and 2 hold the bulk of the data. Message 105 is deliberately
    /// joined to both chats, which is rare in a real chat.db but does occur.
    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "attachment-query")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", displayName: "Alpha")
        try fixture.insertChat(rowId: 2, guid: "iMessage;-;+15550000002", displayName: "Beta")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        // Dates are whole seconds in Apple epoch nanoseconds, one hour apart.
        // Whole seconds matter: the `since`/`before` bounds travel through an
        // ISO-8601 string, which has no sub-second precision.
        // (messageId, chatId, date, isFromMe, handleId)
        let messages: [(Int, Int, Int64, Bool, Int?)] = [
            (101, 1, Self.day(1), false, 1),
            (102, 1, Self.day(2), true, nil),
            (103, 2, Self.day(3), false, 2),
            (104, 2, Self.day(4), false, 2),
            (105, 1, Self.day(5), true, nil),
            (106, 1, Self.day(6), false, 1),
        ]
        for (id, chat, date, fromMe, handle) in messages {
            try fixture.insertMessage(
                rowId: id,
                guid: "msg-\(id)",
                text: "message \(id)",
                date: date,
                isFromMe: fromMe,
                handleId: handle
            )
            try fixture.joinChatMessage(chatId: chat, messageId: id)
        }
        // Message 105 lives in both chats.
        try fixture.joinChatMessage(chatId: 2, messageId: 105)

        // (attachmentId, messageId, mime, uti, bytes)
        let attachments: [(Int, Int, String, String, Int)] = [
            (201, 101, "image/jpeg", "public.jpeg", 100),
            (202, 102, "application/pdf", "com.adobe.pdf", 900),
            (203, 103, "image/png", "public.png", 300),
            (204, 103, "video/mp4", "public.mpeg-4", 700),
            (205, 104, "image/heic", "public.heic", 500),
            (206, 105, "image/jpeg", "public.jpeg", 200),
            (207, 106, "application/pdf", "com.adobe.pdf", 400),
        ]
        for (attachmentId, messageId, mime, uti, bytes) in attachments {
            try fixture.insertAttachment(
                rowId: attachmentId,
                filename: "/tmp/attachment-\(attachmentId)",
                mimeType: mime,
                uti: uti,
                totalBytes: bytes
            )
            try fixture.joinMessageAttachment(messageId: messageId, attachmentId: attachmentId)
        }

        // A message with no attachment must never appear in the results.
        try fixture.insertMessage(rowId: 150, guid: "msg-150", text: "no attachment", date: Self.day(7), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 150)

        // A reaction carrying an attachment must never appear either.
        try fixture.insertMessage(
            rowId: 151,
            guid: "msg-151",
            text: "liked",
            date: Self.day(8),
            isFromMe: false,
            handleId: 1,
            associatedMessageType: 2000
        )
        try fixture.joinChatMessage(chatId: 1, messageId: 151)
        try fixture.insertAttachment(rowId: 208, filename: "/tmp/attachment-208", mimeType: "image/jpeg", uti: "public.jpeg", totalBytes: 50)
        try fixture.joinMessageAttachment(messageId: 151, attachmentId: 208)

        return fixture
    }

    private func run(
        _ fixture: ToolTestDatabase,
        chatId: String? = nil,
        fromPerson: String? = nil,
        type: String? = nil,
        since: String? = nil,
        before: String? = nil,
        limit: Int = 50,
        sort: String = "recent_first",
        cursor: String? = nil
    ) async throws -> ListAttachmentsResponse {
        let tool = ListAttachments(db: fixture.database(), resolver: makeSeededResolver())
        let result = await tool.execute(
            chatId: chatId,
            fromPerson: fromPerson,
            type: type,
            since: since,
            before: before,
            limit: limit,
            sort: sort,
            cursor: cursor
        )
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }

    private func ids(_ response: ListAttachmentsResponse) -> [String] {
        response.messages.map(\.messageId)
    }

    // MARK: - Sorts

    func testRecentFirstReturnsEveryAttachmentMessageOnceNewestFirst() async throws {
        let response = try await run(try makeFixture())
        XCTAssertEqual(ids(response), ["msg_106", "msg_105", "msg_104", "msg_103", "msg_102", "msg_101"])
        XCTAssertEqual(response.total, 6)
    }

    func testOldestFirstReversesTheDateOrder() async throws {
        let response = try await run(try makeFixture(), sort: "oldest_first")
        XCTAssertEqual(ids(response), ["msg_101", "msg_102", "msg_103", "msg_104", "msg_105", "msg_106"])
    }

    func testLargestFirstRanksByTheMessagesBiggestAttachment() async throws {
        // msg_103 carries a 300-byte and a 700-byte attachment, so it ranks on
        // 700, above the 900-byte msg_102? No: 900 > 700, so msg_102 leads.
        let response = try await run(try makeFixture(), sort: "largest_first")
        XCTAssertEqual(ids(response), ["msg_102", "msg_103", "msg_104", "msg_106", "msg_105", "msg_101"])
    }

    // MARK: - Filters

    func testChatFilterKeepsMessagesSharedIntoThatChat() async throws {
        let chatOne = try await run(try makeFixture(), chatId: "chat1")
        XCTAssertEqual(ids(chatOne), ["msg_106", "msg_105", "msg_102", "msg_101"])

        // msg_105 is joined to both chats and must appear under either filter.
        let chatTwo = try await run(try makeFixture(), chatId: "chat2")
        XCTAssertEqual(ids(chatTwo), ["msg_105", "msg_104", "msg_103"])
    }

    func testTypeFilterMatchesOnAttachmentsNotMessages() async throws {
        let images = try await run(try makeFixture(), type: "image")
        // msg_103 qualifies through its PNG even though it also holds a video.
        XCTAssertEqual(ids(images), ["msg_105", "msg_104", "msg_103", "msg_101"])

        let pdfs = try await run(try makeFixture(), type: "pdf")
        XCTAssertEqual(ids(pdfs), ["msg_106", "msg_102"])

        let videos = try await run(try makeFixture(), type: "video")
        XCTAssertEqual(ids(videos), ["msg_103"])
    }

    func testFromPersonFiltersBySenderAndByMe() async throws {
        let mine = try await run(try makeFixture(), fromPerson: "me")
        XCTAssertEqual(ids(mine), ["msg_105", "msg_102"])

        let theirs = try await run(try makeFixture(), fromPerson: "+15550000002")
        XCTAssertEqual(ids(theirs), ["msg_104", "msg_103"])
    }

    func testTimeBoundsAreInclusive() async throws {
        let fixture = try makeFixture()
        let since = try XCTUnwrap(AppleTime.toDate(Self.day(3))).ISO8601Format()
        let before = try XCTUnwrap(AppleTime.toDate(Self.day(5))).ISO8601Format()

        let windowed = try await run(fixture, since: since, before: before)
        XCTAssertEqual(ids(windowed), ["msg_105", "msg_104", "msg_103"])
    }

    // MARK: - Paging

    func testCursorPagingWalksBothDateSortsWithoutOverlap() async throws {
        for sort in ["recent_first", "oldest_first"] {
            let fixture = try makeFixture()
            var seen: [String] = []
            var cursor: String? = nil
            var pages = 0

            repeat {
                let page = try await run(fixture, limit: 2, sort: sort, cursor: cursor)
                seen.append(contentsOf: ids(page))
                cursor = page.more ? page.cursor : nil
                pages += 1
                XCTAssertLessThan(pages, 10, "\(sort) paging did not terminate")
            } while cursor != nil

            let expected = sort == "recent_first"
                ? ["msg_106", "msg_105", "msg_104", "msg_103", "msg_102", "msg_101"]
                : ["msg_101", "msg_102", "msg_103", "msg_104", "msg_105", "msg_106"]
            XCTAssertEqual(seen, expected, "\(sort) paging lost or repeated rows")
        }
    }

    func testLimitReportsMoreWithoutOverrunningThePage() async throws {
        let response = try await run(try makeFixture(), limit: 3)
        XCTAssertEqual(ids(response), ["msg_106", "msg_105", "msg_104"])
        XCTAssertTrue(response.more)
        XCTAssertNotNil(response.cursor)
    }
}
