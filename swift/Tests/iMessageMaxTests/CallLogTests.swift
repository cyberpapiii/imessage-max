import XCTest
import MCP
@testable import iMessageMax

/// Every `tools/call` leaves one stderr line with the tool, lane, outcome and
/// duration, and never its arguments.
final class CallLogTests: XCTestCase {
    private var definitions: [ToolDefinition] = []

    func testSuccessfulCallLogsToolLaneOutcomeAndDuration() async throws {
        register("ok_tool") { _ in [.plainText("{}")] }
        let line = try await callLine(
            name: "ok_tool",
            arguments: ["query": .string("hunter2")],
            lane: .legacyHTTP(session: "abcdef1234567890")
        )
        XCTAssertTrue(
            line.hasPrefix("call tool=ok_tool lane=legacy-http session=abcdef12 outcome=ok ms="),
            line
        )
        XCTAssertFalse(line.contains("hunter2"), "arguments must never reach the log")
    }

    func testOutcomesAreClassified() async throws {
        register("tool_fails") { _ in throw ToolFailure("bad", "bad") }
        register("tool_throws") { _ in throw DatabaseError.queryFailed("boom") }
        register("tool_cancelled") { _ in throw DatabaseError.cancelled }

        let expected = [
            "tool_fails": "tool_error",
            "tool_throws": "internal_error",
            "tool_cancelled": "cancelled",
            "missing_tool": "unknown_tool",
        ]
        for (name, outcome) in expected {
            let line = try await callLine(name: name, lane: .modern(transport: "http"))
            XCTAssertTrue(line.contains(" lane=modern-http outcome=\(outcome) "), line)
        }
    }

    func testToolNameIsSanitized() async throws {
        let line = try await callLine(name: "evil\nINFO forged", lane: .legacyStdio)
        XCTAssertFalse(line.contains("\n"), line)
        XCTAssertTrue(line.contains(" lane=legacy-stdio outcome=unknown_tool "), line)
    }

    /// Runs one call and returns the single line it logged.
    private func callLine(
        name: String,
        arguments: [String: Value]? = nil,
        lane: ToolCallDispatch.Lane
    ) async throws -> String {
        let capture = Log.Capture()
        let catalog = ToolCatalog(definitions)
        await Log.$capture.withValue(capture) {
            _ = await ToolCallDispatch.execute(name: name, arguments: arguments, lane: lane, catalog: catalog)
        }
        let calls = capture.lines.filter { $0.hasPrefix("call ") }
        XCTAssertEqual(calls.count, 1, "\(capture.lines)")
        return try XCTUnwrap(calls.first)
    }

    private func register(
        _ name: String,
        handler: @escaping @Sendable ([String: Value]?) async throws -> [Tool.Content]
    ) {
        definitions.append(ToolDefinition(name: name, description: "test", inputSchema: InputSchema.object(properties: [:]), handler: handler))
    }
}
