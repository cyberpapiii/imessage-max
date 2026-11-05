import IMessageMaxContract
import XCTest
@testable import iMessageMax

/// Regressions for the database/contacts review: contract status words,
/// race-free query counting, call-scoped interrupts, schema guard truth.
final class DatabaseContactsReviewRegressionTests: XCTestCase {

    // MARK: - 5. Database status words

    func testCheckAccessSpeaksTheContractWords() throws {
        let fixture = try ToolTestDatabase(name: "review-access")
        XCTAssertEqual(Database.checkAccess(path: fixture.path).status, .accessible)
        XCTAssertTrue(Database.checkAccess(path: fixture.path).ok)
        XCTAssertEqual(Database.checkAccess(path: "/nonexistent/review/chat.db").status, .databaseNotFound)
    }

    // MARK: - 6. Contacts authorization is a PermissionStatus

    /// The resolver hands diagnose and setup the contract word itself; the
    /// wire text is unchanged, including the `unknown` fallback.
    func testContactsAuthorizationReachesDiagnoseUnchanged() async throws {
        for word: PermissionStatus in [.authorized, .limited, .denied, .restricted, .notDetermined, .unknown] {
            let authorized = PermissionStatus.namesAvailable.contains(word)
            let resolver = ContactResolver(seedCache: [:], authorization: (authorized, word))
            let status = await resolver.status()
            XCTAssertEqual(status.authorization, word)

            let result = try await DiagnoseTool.execute(
                resolver: resolver,
                dbProbe: { (true, .accessible) },
                automationProbe: { (true, .authorized) },
                usageDescriptionProbe: { true }
            )
            if word != .notDetermined {   // not_determined may become not_requested_headless
                XCTAssertEqual(result.contacts.status.rawValue, word.rawValue)
            }
        }
        XCTAssertEqual(PermissionStatus.unknown.rawValue, "unknown")
    }

    // MARK: - 7. Query counting

    /// The counter was a nonisolated(unsafe) read-modify-write and lost
    /// increments under concurrent queries.
    func testQueryCountIsExactUnderConcurrency() async throws {
        let fixture = try ToolTestDatabase(name: "review-count")
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

    // MARK: - 10. Which optional columns SQL actually guards

    /// Each guarded column has a fragment that falls back when it is missing;
    /// the set names exactly those, so nobody assumes protection elsewhere.
    func testGuardedColumnsAreExactlyTheOnesWithFallbackFragments() {
        typealias Column = SchemaCapabilities.Column
        XCTAssertEqual(Column.guardedInSQL, [.messageThreadOriginatorGuid, .messageDateEdited, .messageAssociatedMessageEmoji])
        let fragments: [Column: KeyPath<SchemaCapabilities, String>] = [
            .messageThreadOriginatorGuid: \.threadOriginatorGuidSQL,
            .messageDateEdited: \.dateEditedSQL,
            .messageAssociatedMessageEmoji: \.associatedMessageEmojiSQL,
        ]
        XCTAssertEqual(Set(fragments.keys), Column.guardedInSQL)
        for (column, fragment) in fragments {
            XCTAssertEqual(SchemaCapabilities.assumed[keyPath: fragment], "m.\(column.name)")
            XCTAssertTrue(SchemaCapabilities.assumed.without(column)[keyPath: fragment].hasSuffix("AS \(column.name)"))
        }
    }

    func testSetupReplyCarriesTheResolverWord() async throws {
        let service = SetupPermissionService(
            resolver: ContactResolver(seedCache: [:], authorization: (false, .denied))
        )
        let reply = try await service.request(.contacts)
        XCTAssertEqual(reply.status, .denied)
        XCTAssertFalse(reply.authorized)
    }
}
