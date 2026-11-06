import MCP
import XCTest
@testable import iMessageMax

final class ListAttachmentsQueryTests: XCTestCase {

    private func makeFixture() throws -> ToolTestDatabase {
        let fixture = try ToolTestDatabase(name: "attachment-query")

        try fixture.insertHandle(rowId: 1, handle: "+15550000001")
        try fixture.insertHandle(rowId: 2, handle: "+15550000002")
        try fixture.insertChat(rowId: 1, guid: "iMessage;-;+15550000001", displayName: "Alpha")
        try fixture.insertChat(rowId: 2, guid: "iMessage;-;+15550000002", displayName: "Beta")
        try fixture.joinChatHandle(chatId: 1, handleId: 1)
        try fixture.joinChatHandle(chatId: 2, handleId: 2)

        let messages: [(Int, Int, Int64, Bool, Int?)] = [
            (101, 1, fixtureDay(1), false, 1),
            (102, 1, fixtureDay(2), true, nil),
            (103, 2, fixtureDay(3), false, 2),
            (104, 2, fixtureDay(4), false, 2),
            (105, 1, fixtureDay(5), true, nil),
            (106, 1, fixtureDay(6), false, 1),
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
        try fixture.joinChatMessage(chatId: 2, messageId: 105)

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

        try fixture.insertMessage(rowId: 150, guid: "msg-150", text: "no attachment", date: fixtureDay(7), isFromMe: false, handleId: 1)
        try fixture.joinChatMessage(chatId: 1, messageId: 150)

        try fixture.insertMessage(
            rowId: 151,
            guid: "msg-151",
            text: "liked",
            date: fixtureDay(8),
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
        let result = try await tool.execute(
            chatId: chatId,
            fromPerson: fromPerson,
            type: type,
            since: since,
            before: before,
            limit: limit,
            sort: sort,
            cursor: cursor
        )
        return result
    }

    private func ids(_ response: ListAttachmentsResponse) -> [String] {
        response.messages.map(\.messageId)
    }

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
        let response = try await run(try makeFixture(), sort: "largest_first")
        XCTAssertEqual(ids(response), ["msg_102", "msg_103", "msg_104", "msg_106", "msg_105", "msg_101"])
    }

    func testChatFilterKeepsMessagesSharedIntoThatChat() async throws {
        let chatOne = try await run(try makeFixture(), chatId: "chat1")
        XCTAssertEqual(ids(chatOne), ["msg_106", "msg_105", "msg_102", "msg_101"])

        let chatTwo = try await run(try makeFixture(), chatId: "chat2")
        XCTAssertEqual(ids(chatTwo), ["msg_105", "msg_104", "msg_103"])
    }

    func testTypeFilterMatchesOnAttachmentsNotMessages() async throws {
        let images = try await run(try makeFixture(), type: "image")
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

        let byName = try await run(try makeFixture(), fromPerson: "Bob")
        XCTAssertEqual(ids(byName), ["msg_104", "msg_103"])
    }

    func testTimeBoundsAreInclusive() async throws {
        let fixture = try makeFixture()
        let since = try XCTUnwrap(AppleTime.toDate(fixtureDay(3))).ISO8601Format()
        let before = try XCTUnwrap(AppleTime.toDate(fixtureDay(5))).ISO8601Format()

        let windowed = try await run(fixture, since: since, before: before)
        XCTAssertEqual(ids(windowed), ["msg_105", "msg_104", "msg_103"])
    }

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
            } while cursor != nil && pages < 10
            XCTAssertNil(cursor, "\(sort) paging did not terminate")

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

    func testTypeFilterAgreesWithTheKindEachAttachmentIsLabelled() throws {
        let fixture = try ToolTestDatabase(name: "attachment-kinds")
        let samples: [(mime: String?, uti: String?, kind: String)] = [
            ("image/heic", "public.heic", "image"),
            (nil, "public.png", "image"),
            ("video/quicktime", "com.apple.quicktime-movie", "video"),
            ("audio/x-m4a", nil, "audio"),
            ("application/pdf", "com.adobe.pdf", "pdf"),
            ("application/msword", nil, "document"),
            ("text/plain", "public.plain-text", "other"),
        ]
        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(AttachmentType.from(mimeType: sample.mime, uti: sample.uti).rawValue, sample.kind, "\(sample)")
            try fixture.execute("""
                INSERT INTO attachment (ROWID, mime_type, uti) VALUES (\(index + 1), \(sample.mime.map { "'\($0)'" } ?? "NULL"), \(sample.uti.map { "'\($0)'" } ?? "NULL"))
                """)
        }
        for kind in ["image", "video", "audio", "pdf", "document"] {
            let predicate = try XCTUnwrap(AttachmentType.sqlPredicate(for: kind, alias: "a"))
            let matched: [Int64] = try fixture.database().query("SELECT a.ROWID FROM attachment a WHERE \(predicate) ORDER BY 1") { $0.int(0) }
            let expected = samples.enumerated().filter { $0.element.kind == kind }.map { Int64($0.offset + 1) }
            XCTAssertEqual(matched, expected, kind)
        }
        XCTAssertNil(AttachmentType.sqlPredicate(for: "any"))
        XCTAssertNil(AttachmentType.sqlPredicate(for: "other"))
    }
}
