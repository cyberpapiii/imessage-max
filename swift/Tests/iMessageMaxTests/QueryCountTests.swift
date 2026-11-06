import MCP
import XCTest
@testable import iMessageMax

final class QueryCountTests: XCTestCase {
    func testQueryCounterIncrements() throws {
        let fixture = try ToolTestDatabase(name: "query-counter")
        try fixture.insertChat(rowId: 1, guid: "counter-chat")

        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        _ = try fixture.database().query("SELECT ROWID FROM chat", params: []) { row in
            row.int(0)
        }
        XCTAssertEqual(Database.queryCountForTesting, 1)
    }

    func testQueryCountIsExactUnderConcurrency() async throws {
        let fixture = try ToolTestDatabase(name: "query-count-concurrent")
        let db = fixture.database()
        Database.queryCountForTesting = 0
        defer { Database.queryCountForTesting = nil }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask { _ = try db.query("SELECT 1") { $0.int(0) } }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(Database.queryCountForTesting, 200)
    }

    /// get_messages with unanswered checks replies once per chunk, so its
    /// query count does not grow with the number of questions.
    func testUnansweredChecksRepliesPerChunkNotPerRow() async throws {
        func queries(questions: Int) async throws -> Int {
            let fixture = try directChatFixture(name: "unanswered-\(questions)")
            for row in 1...questions {
                try fixture.insertMessage(
                    rowId: row, guid: "g\(row)", text: "free at \(row)?",
                    date: 700_000_000_000_000_000 + Int64(row) * 120 * appleMinute, isFromMe: true
                )
                try fixture.joinChatMessage(chatId: 1, messageId: row)
            }
            let db = fixture.database()
            return try await countQueries {
                let json = try await callTool("get_messages", ["chat_id": "chat1", "unanswered": true, "unanswered_hours": 1], database: db)
                XCTAssertEqual(try itemIds(json, "messages").count, questions)
            }
        }
        let few = try await queries(questions: 5)
        let many = try await queries(questions: 40)
        XCTAssertEqual(few, many)
    }

    /// search counts hidden chats with a word match from one read, so its
    /// query count does not grow with the number of hidden chats.
    func testHiddenChatCountIsOneReadNotOnePerChat() async throws {
        func queries(hiddenChats: Int) async throws -> Int {
            let fixture = try ToolTestDatabase(name: "hidden-count-\(hiddenChats)")
            try fixture.insertHandle(rowId: 1, handle: "spam@example.com")
            for chat in 1...hiddenChats {
                try fixture.insertChat(rowId: chat, guid: "iMessage;-;spam\(chat)", isFiltered: 1)
                try fixture.joinChatHandle(chatId: chat, handleId: 1)
                try fixture.insertMessage(
                    rowId: chat, guid: "g\(chat)", text: "a zebra",
                    date: 700_000_000_000_000_000 + Int64(chat), isFromMe: false, handleId: 1
                )
                try fixture.joinChatMessage(chatId: chat, messageId: chat)
            }
            let db = fixture.database()
            return try await countQueries {
                let json = try await callTool("search", ["query": "zebra"], database: db)
                XCTAssertEqual(json["filtered_hidden"] as? Int, hiddenChats)
            }
        }
        let few = try await queries(hiddenChats: 2)
        let many = try await queries(hiddenChats: 12)
        XCTAssertEqual(few, many)
    }
}
