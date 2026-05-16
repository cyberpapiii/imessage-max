import XCTest
@testable import iMessageMax

final class OverviewResponseTests: XCTestCase {
    func testListChatsUsesLeanOverviewShapeAndRecentParticipants() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let result = await ListChatsTool.execute(
            limit: 10,
            since: nil,
            isGroup: nil,
            minParticipants: nil,
            maxParticipants: nil,
            sort: "recent",
            cursor: nil,
            db: fixture.database(),
            resolver: resolver
        )

        switch result {
        case .failure(let error):
            XCTFail("Unexpected list_chats failure: \(error)")
        case .success(let response):
            let namedChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat100" }))
            XCTAssertEqual(namedChat.name, "Weekend Plans")
            XCTAssertEqual(namedChat.participantCount, 6)
            XCTAssertEqual(namedChat.participantsPreview, ["Dana Lee", "Alice Smith", "Evan Stone", "+3 more"])
            XCTAssertEqual(namedChat.lastMessage?.text, "Count me in")

            let unnamedChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat200" }))
            XCTAssertEqual(unnamedChat.participantsPreview, ["Bob Brown", "Casey Jones", "Faith Young", "+2 more"])
            XCTAssertEqual(unnamedChat.participantCount, 5)

            let selfLatestChat = try XCTUnwrap(response.chats.first(where: { $0.id == "chat700" }))
            XCTAssertEqual(selfLatestChat.lastMessage?.from, "Me")
        }
    }

    func testGetActiveConversationsUsesLeanOverviewShapeAndReadableLastMessage() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let result = try await GetActiveConversations.execute(
            hours: 48,
            minExchanges: 1,
            isGroup: nil,
            limit: 10,
            database: fixture.database(),
            resolver: resolver
        )

        let attachmentConversation = try XCTUnwrap(result.conversations.first(where: { $0.id == "chat600" }))
        let attachmentPreview = try XCTUnwrap(attachmentConversation.lastMessage)
        XCTAssertEqual(attachmentPreview.from, "Jules Hart")
        XCTAssertEqual(attachmentPreview.text, "[2 Photos]")
        XCTAssertNotNil(attachmentPreview.ago)
        XCTAssertGreaterThan(attachmentConversation.activity.exchanges, 0)
        XCTAssertEqual(attachmentConversation.participantsPreview, ["Jules Hart"])

        let urlOnlyConversation = try XCTUnwrap(result.conversations.first(where: { $0.id == "chat300" }))
        let urlOnlyPreview = try XCTUnwrap(urlOnlyConversation.lastMessage)
        XCTAssertEqual(urlOnlyPreview.text, "[Link: youtube.com]")

        let proseConversation = try XCTUnwrap(result.conversations.first(where: { $0.id == "chat400" }))
        let prosePreview = try XCTUnwrap(proseConversation.lastMessage)
        XCTAssertEqual(prosePreview.text, "Watch this [Link: youtube.com] please")
    }

    func testListAttachmentsGroupsSharedItemsByMessage() async throws {
        let fixture = try makeOverviewFixture()
        let resolver = makeOverviewResolver()

        let tool = ListAttachments(db: fixture.database(), resolver: resolver)
        let result = await tool.execute(
            chatId: nil,
            fromPerson: nil,
            type: "any",
            since: nil,
            before: nil,
            limit: 30,
            sort: "recent_first"
        )

        switch result {
        case .failure(let error):
            XCTFail("Unexpected list_attachments failure: \(error)")
        case .success(let response):
            let sameType = try XCTUnwrap(response.messages.first(where: { $0.messageId == "msg_503" }))
            XCTAssertEqual(sameType.chat.id, "chat100")
            XCTAssertEqual(sameType.chat.name, "Weekend Plans")
            XCTAssertNil(sameType.messagePreview)
            XCTAssertEqual(sameType.sharedSummary, "[2 Photos]")
            XCTAssertEqual(sameType.attachments.count, 2)

            let mixed = try XCTUnwrap(response.messages.first(where: { $0.messageId == "msg_552" }))
            XCTAssertEqual(mixed.chat.id, "chat200")
            XCTAssertNil(mixed.messagePreview)
            XCTAssertEqual(mixed.sharedSummary, "[Photo, PDF]")
            XCTAssertEqual(mixed.attachments.count, 2)

            let textWins = try XCTUnwrap(response.messages.first(where: { $0.messageId == "msg_553" }))
            XCTAssertEqual(textWins.messagePreview, "Deck attached for review")
            XCTAssertEqual(textWins.sharedSummary, "[PDF]")
            XCTAssertEqual(textWins.attachments.count, 1)

            let syntheticText = try XCTUnwrap(response.messages.first(where: { $0.messageId == "msg_554" }))
            XCTAssertNil(syntheticText.messagePreview)
            XCTAssertEqual(syntheticText.sharedSummary, "[2 Photos]")
            XCTAssertEqual(syntheticText.attachments.count, 2)
        }
    }

    func testGetUnreadUsesSharedChatIdentityNamingForUnnamedDirectChats() async throws {
        let fixture = try makeOverviewFixture()
        let tool = GetUnread(database: fixture.database(), contactResolver: makeOverviewResolver())

        let responseAny = try await tool.execute(params: GetUnread.Parameters(format: .summary))
        guard let response = responseAny as? UnreadSummaryResponse else {
            return XCTFail("Expected unread summary response")
        }

        let chat = try XCTUnwrap(response.chats.first(where: { $0.chat.id == "chat800" }))
        XCTAssertEqual(chat.chat.name, "Jules Hart")
        XCTAssertEqual(chat.chat.participantsPreview, ["Jules Hart"])
    }
}

func makeOverviewFixture() throws -> ToolTestDatabase {
    let fixture = try ToolTestDatabase(name: "overview")
    let imageURL = try makeFixtureImage(name: "overview-image.jpg")
    let pdfURL = imageURL.deletingPathExtension().appendingPathExtension("pdf")
    FileManager.default.createFile(atPath: pdfURL.path, contents: Data("pdf".utf8))

    let handles = [
        (1, "+15550000001"),
        (2, "+15550000002"),
        (3, "+15550000003"),
        (4, "+15550000004"),
        (5, "+15550000005"),
        (6, "+15550000006"),
        (7, "+15550000007"),
        (8, "+15550000008"),
        (9, "+15550000009"),
        (10, "+15550000010"),
        (11, "+15550000011"),
    ]

    for (id, handle) in handles {
        try fixture.insertHandle(rowId: id, handle: handle)
    }

    try fixture.insertChat(rowId: 100, guid: "chat-overview-guid", displayName: "Weekend Plans")
    for id in 1...6 {
        try fixture.joinChatHandle(chatId: 100, handleId: id)
    }

    try fixture.insertChat(rowId: 200, guid: "chat-unnamed-guid", displayName: nil)
    for handleId in [7, 2, 8, 3, 6] {
        try fixture.joinChatHandle(chatId: 200, handleId: handleId)
    }

    try fixture.insertChat(rowId: 300, guid: "chat-url-guid", displayName: "Links")
    try fixture.joinChatHandle(chatId: 300, handleId: 9)

    try fixture.insertChat(rowId: 400, guid: "chat-prose-guid", displayName: "Prose Links")
    try fixture.joinChatHandle(chatId: 400, handleId: 10)

    try fixture.insertChat(rowId: 600, guid: "chat-photos-guid", displayName: "Photo Updates")
    try fixture.joinChatHandle(chatId: 600, handleId: 11)

    try fixture.insertChat(rowId: 700, guid: "chat-self-latest-guid", displayName: "Self Latest")
    try fixture.joinChatHandle(chatId: 700, handleId: 1)

    try fixture.insertChat(rowId: 800, guid: "chat-unread-dm-guid", displayName: nil)
    try fixture.joinChatHandle(chatId: 800, handleId: 11)

    let base = AppleTime.fromDate(Date().addingTimeInterval(-6 * 3600))
    let minute: Int64 = 60 * 1_000_000_000

    try fixture.insertMessage(
        rowId: 500,
        guid: "chat100-me",
        text: "Working on plans",
        date: base,
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 100, messageId: 500)

    try fixture.insertMessage(
        rowId: 501,
        guid: "chat100-bob",
        text: "I can bring snacks",
        date: base + minute,
        isFromMe: false,
        handleId: 2
    )
    try fixture.joinChatMessage(chatId: 100, messageId: 501)

    try fixture.insertMessage(
        rowId: 502,
        guid: "chat100-evan",
        text: "I have the grill tools",
        date: base + (2 * minute),
        isFromMe: false,
        handleId: 5
    )
    try fixture.joinChatMessage(chatId: 100, messageId: 502)

    try fixture.insertMessage(
        rowId: 503,
        guid: "chat100-photo",
        text: nil,
        date: base + (3 * minute),
        isFromMe: false,
        handleId: 1
    )
    try fixture.joinChatMessage(chatId: 100, messageId: 503)

    try fixture.insertMessage(
        rowId: 504,
        guid: "chat100-dana",
        text: "Count me in",
        date: base + (4 * minute),
        isFromMe: false,
        handleId: 4
    )
    try fixture.joinChatMessage(chatId: 100, messageId: 504)

    let imageSize = (try? FileManager.default.attributesOfItem(atPath: imageURL.path)[.size] as? Int) ?? 0
    try fixture.insertAttachment(
        rowId: 900,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: imageURL.lastPathComponent
    )
    try fixture.joinMessageAttachment(messageId: 503, attachmentId: 900)

    try fixture.insertAttachment(
        rowId: 901,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "overview-image-2.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 503, attachmentId: 901)

    try fixture.insertMessage(
        rowId: 550,
        guid: "chat200-bob",
        text: "Status update",
        date: base + (5 * minute),
        isFromMe: false,
        handleId: 2
    )
    try fixture.joinChatMessage(chatId: 200, messageId: 550)

    try fixture.insertMessage(
        rowId: 551,
        guid: "chat200-me",
        text: "Got it",
        date: base + (6 * minute),
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 200, messageId: 551)

    try fixture.insertMessage(
        rowId: 552,
        guid: "chat200-mixed",
        text: nil,
        date: base + (7 * minute),
        isFromMe: false,
        handleId: 3
    )
    try fixture.joinChatMessage(chatId: 200, messageId: 552)

    try fixture.insertAttachment(
        rowId: 910,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "mixed-image.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 552, attachmentId: 910)

    try fixture.insertAttachment(
        rowId: 911,
        filename: pdfURL.path,
        mimeType: "application/pdf",
        uti: "com.adobe.pdf",
        totalBytes: 3,
        transferName: "deck.pdf"
    )
    try fixture.joinMessageAttachment(messageId: 552, attachmentId: 911)

    try fixture.insertMessage(
        rowId: 553,
        guid: "chat200-text",
        text: "Deck attached for review",
        date: base + (8 * minute),
        isFromMe: false,
        handleId: 6
    )
    try fixture.joinChatMessage(chatId: 200, messageId: 553)

    try fixture.insertAttachment(
        rowId: 912,
        filename: pdfURL.path,
        mimeType: "application/pdf",
        uti: "com.adobe.pdf",
        totalBytes: 3,
        transferName: "review-deck.pdf"
    )
    try fixture.joinMessageAttachment(messageId: 553, attachmentId: 912)

    try fixture.insertMessage(
        rowId: 600,
        guid: "chat300-me",
        text: "What link was that?",
        date: base + (9 * minute),
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 300, messageId: 600)

    try fixture.insertMessage(
        rowId: 601,
        guid: "chat300-url",
        text: "https://www.youtube.com/watch?v=123",
        date: base + (10 * minute),
        isFromMe: false,
        handleId: 9
    )
    try fixture.joinChatMessage(chatId: 300, messageId: 601)

    try fixture.insertMessage(
        rowId: 700,
        guid: "chat400-me",
        text: "Send it over",
        date: base + (11 * minute),
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 400, messageId: 700)

    try fixture.insertMessage(
        rowId: 701,
        guid: "chat400-url",
        text: "Watch this https://www.youtube.com/watch?v=abc please",
        date: base + (12 * minute),
        isFromMe: false,
        handleId: 10
    )
    try fixture.joinChatMessage(chatId: 400, messageId: 701)

    try fixture.insertMessage(
        rowId: 800,
        guid: "chat600-me",
        text: "Send the latest photos",
        date: base + (13 * minute),
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 600, messageId: 800)

    try fixture.insertMessage(
        rowId: 801,
        guid: "chat600-photos",
        text: "[Photo][Photo]",
        date: base + (14 * minute),
        isFromMe: false,
        handleId: 11
    )
    try fixture.joinChatMessage(chatId: 600, messageId: 801)

    try fixture.insertAttachment(
        rowId: 920,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "photo-1.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 801, attachmentId: 920)

    try fixture.insertAttachment(
        rowId: 921,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "photo-2.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 801, attachmentId: 921)

    try fixture.insertMessage(
        rowId: 850,
        guid: "chat700-from-other",
        text: "Can you confirm timing?",
        date: base + (15 * minute),
        isFromMe: false,
        handleId: 1
    )
    try fixture.joinChatMessage(chatId: 700, messageId: 850)

    try fixture.insertMessage(
        rowId: 851,
        guid: "chat700-from-me",
        text: "Confirmed",
        date: base + (16 * minute),
        isFromMe: true
    )
    try fixture.joinChatMessage(chatId: 700, messageId: 851)

    try fixture.insertMessage(
        rowId: 860,
        guid: "chat800-unread",
        text: "Need your answer",
        date: base + (18 * minute),
        isFromMe: false,
        isRead: false,
        handleId: 11
    )
    try fixture.joinChatMessage(chatId: 800, messageId: 860)

    try fixture.insertMessage(
        rowId: 554,
        guid: "chat200-synthetic-text",
        text: "[Photo][Photo]",
        date: base + (17 * minute),
        isFromMe: false,
        handleId: 2
    )
    try fixture.joinChatMessage(chatId: 200, messageId: 554)

    try fixture.insertAttachment(
        rowId: 913,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "synthetic-1.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 554, attachmentId: 913)

    try fixture.insertAttachment(
        rowId: 914,
        filename: imageURL.path,
        mimeType: "image/jpeg",
        uti: "public.jpeg",
        totalBytes: imageSize,
        transferName: "synthetic-2.jpg"
    )
    try fixture.joinMessageAttachment(messageId: 554, attachmentId: 914)

    return fixture
}

func makeOverviewResolver() -> ContactResolver {
    ContactResolver(seedCache: [
        "+15550000001": "Alice Smith",
        "+15550000002": "Bob Brown",
        "+15550000003": "Casey Jones",
        "+15550000004": "Dana Lee",
        "+15550000005": "Evan Stone",
        "+15550000006": "Faith Young",
        "+15550000009": "Garry West",
        "+15550000010": "Iris Lane",
        "+15550000011": "Jules Hart",
    ])
}
