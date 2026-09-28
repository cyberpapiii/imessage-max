import XCTest
import MCP
@testable import iMessageMax

/// Every `tools/call` leaves one stderr line with the tool, lane, outcome and
/// duration, and never its arguments. Before this there was no record of how
/// long a call took or how it ended, only an era line saying one arrived.
final class CallLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ToolHandlerRegistry.shared.resetForTesting()
        ToolCallDispatch.lastCallLogForTesting = nil
    }

    override func tearDown() {
        ToolHandlerRegistry.shared.resetForTesting()
        super.tearDown()
    }

    func testSuccessfulCallLogsToolLaneOutcomeAndDuration() async throws {
        register("ok_tool") { _ in [.plainText("{}")] }
        _ = await ToolCallDispatch.execute(
            name: "ok_tool",
            arguments: ["query": .string("hunter2")],
            lane: .legacyHTTP(session: "abcdef1234567890")
        )
        let line = try XCTUnwrap(ToolCallDispatch.lastCallLogForTesting)
        XCTAssertTrue(
            line.hasPrefix("call tool=ok_tool lane=legacy-http session=abcdef12 outcome=ok ms="),
            line
        )
        XCTAssertFalse(line.contains("hunter2"), "arguments must never reach the log")
    }

    func testOutcomesAreClassified() async throws {
        register("tool_fails") { _ in throw ToolError(content: [.plainText("bad")]) }
        register("tool_throws") { _ in throw DatabaseError.queryFailed("boom") }
        register("tool_cancelled") { _ in throw DatabaseError.cancelled }

        let expected = [
            "tool_fails": "tool_error",
            "tool_throws": "internal_error",
            "tool_cancelled": "cancelled",
            "missing_tool": "unknown_tool",
        ]
        for (name, outcome) in expected {
            _ = await ToolCallDispatch.execute(name: name, arguments: nil, lane: .modern(transport: "http"))
            let line = try XCTUnwrap(ToolCallDispatch.lastCallLogForTesting)
            XCTAssertTrue(line.contains(" lane=modern-http outcome=\(outcome) "), line)
        }
    }

    func testToolNameIsSanitized() async throws {
        _ = await ToolCallDispatch.execute(
            name: "evil\nINFO forged",
            arguments: nil,
            lane: .legacyStdio
        )
        let line = try XCTUnwrap(ToolCallDispatch.lastCallLogForTesting)
        XCTAssertFalse(line.contains("\n"), line)
        XCTAssertTrue(line.contains(" lane=legacy-stdio outcome=unknown_tool "), line)
    }

    func testLogLinesCarryAUTCTimestamp() {
        XCTAssertEqual(
            Log.format(.info, "Database: ok", at: Date(timeIntervalSince1970: 1_790_000_000.25)),
            "2026-09-21T14:13:20.250Z [imessage-max] INFO Database: ok\n"
        )
    }

    private func register(
        _ name: String,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) {
        ToolHandlerRegistry.shared.register(
            tool: Tool(name: name, description: "test", inputSchema: InputSchema.object(properties: [:])),
            handler: handler
        )
    }
}
