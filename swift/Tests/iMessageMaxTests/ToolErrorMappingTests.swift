import XCTest
@testable import iMessageMax

final class ToolErrorMappingTests: XCTestCase {

    func testNotFound() {
        let mapped = ToolErrorMapping.map(.notFound("/tmp/chat.db"), context: "test")
        XCTAssertEqual(mapped.code, "database_not_found")
        XCTAssertEqual(mapped.message, ClientErrorMessages.databaseNotFound)
    }

    func testPermissionDenied() {
        let mapped = ToolErrorMapping.map(.permissionDenied("/tmp/chat.db"), context: "test")
        XCTAssertEqual(mapped.code, "permission_denied")
        XCTAssertEqual(mapped.message, ClientErrorMessages.permissionDenied)
    }

    func testQueryFailed() {
        let mapped = ToolErrorMapping.map(.queryFailed("no such table: message"), context: "test")
        XCTAssertEqual(mapped.code, "query_failed")
        XCTAssertEqual(mapped.message, ClientErrorMessages.internalError)
        XCTAssertFalse(mapped.message.contains("message"), "sqlite detail must not reach the client")
    }

    func testInvalidData() {
        let mapped = ToolErrorMapping.map(.invalidData("bad blob at /Users/me/x"), context: "test")
        XCTAssertEqual(mapped.code, "invalid_data")
        XCTAssertEqual(mapped.message, ClientErrorMessages.internalError)
    }
}
