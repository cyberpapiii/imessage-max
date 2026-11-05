import MCP
import XCTest
@testable import iMessageMax

/// A database error a tool lets escape reaches the client as a JSON error
/// with a stable code and fixed guidance, never the path or SQLite detail.
final class ToolErrorMappingTests: XCTestCase {

    func testDatabaseErrorsBecomeStableCodesWithoutInternalDetail() async throws {
        let cases: [(DatabaseError, String, String)] = [
            (.notFound("/Users/me/Library/Messages/chat.db"), "database_not_found", ClientErrorMessages.databaseNotFound),
            (.permissionDenied("/Users/me/Library/Messages/chat.db"), "permission_denied", ClientErrorMessages.permissionDenied),
            (.queryFailed("no such table: message"), "query_failed", ClientErrorMessages.internalError),
            (.invalidData("bad blob at /Users/me/x"), "invalid_data", ClientErrorMessages.internalError),
        ]
        for (error, code, message) in cases {
            let body = try await callFailing(throwing: error)
            XCTAssertEqual(body["error"] as? String, code)
            XCTAssertEqual(body["message"] as? String, message)
            XCTAssertEqual(body.count, 2)
        }
    }

    func testUnexpectedErrorsDoNotLeakTheirDescription() async throws {
        struct PathError: LocalizedError {
            var errorDescription: String? { "cannot open /Users/me/secret" }
        }
        let body = try await callFailing(throwing: PathError())
        XCTAssertEqual(body["error"] as? String, "internal_error")
        XCTAssertEqual(body["message"] as? String, ClientErrorMessages.internalError)
    }

    private func callFailing(throwing error: any Error) async throws -> [String: Any] {
        let catalog = ToolCatalog([
            ToolDefinition(name: "failing", description: "test", inputSchema: .object([:])) { _ in throw error }
        ])
        guard case .completed(let content, isError: true) = await ToolCallDispatch.execute(
            name: "failing", arguments: nil, lane: .legacyStdio, catalog: catalog
        ) else {
            XCTFail("expected an error result")
            return [:]
        }
        return try decodeJSONDictionary(from: content)
    }
}
