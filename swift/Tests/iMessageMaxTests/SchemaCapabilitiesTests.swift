import XCTest
@testable import iMessageMax

final class SchemaCapabilitiesTests: XCTestCase {
    func testProbeReportsEveryFixtureColumnPresent() throws {
        let fixture = try ToolTestDatabase()
        let schema = try fixture.database().schema()
        XCTAssertTrue(schema.has(.messageThreadOriginatorGuid))
        XCTAssertTrue(schema.has(.messageDateEdited))
        XCTAssertTrue(schema.has(.messageAssociatedMessageEmoji))
        XCTAssertTrue(schema.has(.chatIsFiltered))
        XCTAssertFalse(schema.has(.messageDateRead))
        XCTAssertFalse(schema.has(.chatMessageJoinMessageDate))
    }

    func testProbeSeesDroppedColumn() throws {
        let fixture = try ToolTestDatabase()
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        let schema = try fixture.database().schema()
        XCTAssertFalse(schema.has(.messageDateEdited))
        XCTAssertTrue(schema.has(.messageThreadOriginatorGuid))
    }

    func testProbeIsCachedPerInstance() throws {
        let fixture = try ToolTestDatabase()
        let cached = fixture.database()
        XCTAssertTrue(try cached.schema().has(.messageDateEdited))
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        XCTAssertTrue(try cached.schema().has(.messageDateEdited))
        XCTAssertFalse(try fixture.database().schema().has(.messageDateEdited))
    }

    func testFeaturesNameEveryOptionalColumnByTableDotColumn() {
        let features = SchemaCapabilities.assumed.without(.messageDateEdited).features
        XCTAssertEqual(features["message.date_edited"], false)
        XCTAssertEqual(features["attachment.hide_attachment"], true)
        XCTAssertTrue(features.keys.allSatisfy { $0.split(separator: ".").count == 2 }, "\(features.keys)")
    }

    func testProbeOnUnreadableFileThrowsPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        XCTAssertThrowsError(try Database(path: path).schema()) { error in
            guard case DatabaseError.permissionDenied = error else {
                XCTFail("expected permissionDenied, got \(error)")
                return
            }
        }
    }
}
