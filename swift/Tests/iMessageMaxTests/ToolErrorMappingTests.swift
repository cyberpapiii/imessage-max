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
        let mapped = ToolErrorMapping.map(.queryFailed("boom"), context: "test")
        XCTAssertEqual(mapped.code, "query_failed")
        XCTAssertEqual(mapped.message, "boom")
    }

    func testInvalidData() {
        let mapped = ToolErrorMapping.map(.invalidData("bad blob"), context: "test")
        XCTAssertEqual(mapped.code, "invalid_data")
        XCTAssertEqual(mapped.message, "bad blob")
    }
}
