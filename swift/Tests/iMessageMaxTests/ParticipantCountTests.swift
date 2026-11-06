import XCTest
@testable import iMessageMax

/// One person can appear in chat_handle_join twice: a duplicated join row, or an
/// SMS and an iMessage handle row for the same number. They are one participant.
final class ParticipantCountTests: XCTestCase {
    private func fixture() throws -> ToolTestDatabase {
        let f = try ToolTestDatabase(name: "participant-count")
        try f.insertHandle(rowId: 1, handle: "+15550000001", service: "iMessage")
        try f.insertHandle(rowId: 2, handle: "+15550000001", service: "SMS")
        try f.insertChat(rowId: 1, guid: "iMessage;-;+15550000001")
        try f.joinChatHandle(chatId: 1, handleId: 1)
        try f.joinChatHandle(chatId: 1, handleId: 1)
        try f.joinChatHandle(chatId: 1, handleId: 2)
        let date = AppleTime.fromDate(Date())
        try f.insertMessage(rowId: 1, guid: "m1", text: "hi", date: date, isFromMe: false, handleId: 1)
        try f.joinChatMessage(chatId: 1, messageId: 1)
        return f
    }

    func testDuplicateHandleRowsCountAsOneParticipant() async throws {
        let f = try fixture()
        let listed = try await ListChatsTool.execute(db: f.database(), resolver: makeSeededResolver())
        let chat = try XCTUnwrap(listed.chats.first)
        XCTAssertEqual(chat.participantCount, 1)
        XCTAssertNil(chat.group)

        let dms = try await ListChatsTool.execute(isGroup: false, db: f.database(), resolver: makeSeededResolver())
        XCTAssertEqual(dms.chats.map(\.id), ["chat1"], "a DM stays a DM in the is_group filter")
    }
}
