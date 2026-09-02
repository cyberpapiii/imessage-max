import XCTest
@testable import iMessageMax

final class SchemaCapabilitiesTests: XCTestCase {
    func testProbeReportsEveryFixtureColumnPresent() throws {
        let fixture = try ToolTestDatabase()
        let schema = try fixture.database().schema()
        XCTAssertTrue(schema.messageThreadOriginatorGuid)
        XCTAssertTrue(schema.messageDateEdited)
        XCTAssertTrue(schema.messageAssociatedMessageEmoji)
        XCTAssertTrue(schema.chatIsFiltered)
        XCTAssertFalse(schema.messageDateRead)
        XCTAssertFalse(schema.chatMessageJoinMessageDate)
    }

    func testProbeSeesDroppedColumn() throws {
        let fixture = try ToolTestDatabase()
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        let schema = try fixture.database().schema()
        XCTAssertFalse(schema.messageDateEdited)
        XCTAssertTrue(schema.messageThreadOriginatorGuid)
    }

    func testProbeIsCachedPerInstance() throws {
        let fixture = try ToolTestDatabase()
        let cached = fixture.database()
        XCTAssertTrue(try cached.schema().messageDateEdited)
        try fixture.execute("ALTER TABLE message DROP COLUMN date_edited")
        XCTAssertTrue(try cached.schema().messageDateEdited)
        XCTAssertFalse(try fixture.database().schema().messageDateEdited)
    }

    func testOverrideInitializerReplacesOnlyNamedFlags() {
        let overridden = SchemaCapabilities(base: .assumed, messageDateEdited: false)
        XCTAssertFalse(overridden.messageDateEdited)
        XCTAssertEqual(
            SchemaCapabilities(base: overridden, messageDateEdited: true).messageDateEdited,
            SchemaCapabilities.assumed.messageDateEdited
        )
        XCTAssertTrue(overridden.messageThreadOriginatorGuid)
        XCTAssertTrue(overridden.messageAssociatedMessageEmoji)
        XCTAssertTrue(overridden.chatIsFiltered)
        XCTAssertTrue(overridden.messageDateRead)
        XCTAssertEqual(overridden.messageThreadOriginatorPart, SchemaCapabilities.assumed.messageThreadOriginatorPart)
        XCTAssertEqual(overridden.messageIsDelivered, SchemaCapabilities.assumed.messageIsDelivered)
        XCTAssertEqual(overridden.attachmentHideAttachment, SchemaCapabilities.assumed.attachmentHideAttachment)
    }

    func testFeaturesDictionaryUsesTableDotColumnKeys() {
        XCTAssertEqual(SchemaCapabilities.assumed.features["message.date_edited"], true)
        XCTAssertEqual(SchemaCapabilities.assumed.features.count, 19)
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
