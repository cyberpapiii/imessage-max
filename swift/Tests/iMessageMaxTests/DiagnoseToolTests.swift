import XCTest
import IMessageMaxContract
@testable import iMessageMax

final class DiagnoseToolTests: XCTestCase {
    private static let dbAccessible: DatabaseProbe = { (true, "accessible") }
    private static let dbDenied: DatabaseProbe = { (false, "permission_denied") }
    private static let automationGranted: AutomationProbe = { (true, "authorized") }

    private func encodedResponse(dbProbe: DatabaseProbe) async throws -> (DiagnoseResult, String) {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: dbProbe,
            automationProbe: DiagnoseToolTests.automationGranted
        )
        return (result, try FormatUtils.encodeJSON(result))
    }

    func testContactsAuthorizationReachesDiagnoseUnchanged() async throws {
        let words: [(PermissionStatus, String)] = [
            (.authorized, "authorized"), (.limited, "limited"), (.denied, "denied"),
            (.restricted, "restricted"), (.unknown, "unknown"),
        ]
        for (word, wire) in words {
            let authorized = PermissionStatus.namesAvailable.contains(word)
            let result = try await DiagnoseTool.execute(
                resolver: ContactResolver(seedCache: [:], authorization: (authorized, word)),
                dbProbe: { (true, .accessible) },
                automationProbe: { (true, .authorized) },
                usageDescriptionProbe: { true }
            )
            XCTAssertEqual(result.contacts.status.rawValue, wire)
        }
    }

    func testResponseDoesNotContainHomeDirectory() async throws {
        let home = NSHomeDirectory()
        XCTAssertFalse(home.isEmpty)

        for probe in [DiagnoseToolTests.dbAccessible, DiagnoseToolTests.dbDenied] {
            let (result, json) = try await encodedResponse(dbProbe: probe)
            XCTAssertFalse(
                json.contains(home),
                "diagnose output must not contain the home directory: \(json)"
            )
            XCTAssertTrue(
                result.database.path.hasPrefix("~/"),
                "database path should be tilde-abbreviated, got \(result.database.path)"
            )
            XCTAssertTrue(result.database.path.hasSuffix("/Library/Messages/chat.db"))
        }
    }

    func testDiagnoseReprobesOnEveryCall() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func next() -> (ok: Bool, status: DatabaseStatus) {
                lock.lock(); defer { lock.unlock() }
                calls += 1
                return calls == 1 ? (false, "permission_denied") : (true, "accessible")
            }
        }
        let counter = Counter()
        let probe: DatabaseProbe = { counter.next() }

        let (first, _) = try await encodedResponse(dbProbe: probe)
        XCTAssertFalse(first.database.accessible)
        XCTAssertEqual(first.database.status, "permission_denied")
        XCTAssertEqual(first.capabilities["perm_full_disk"]?.state, "permission-gated")

        let (second, _) = try await encodedResponse(dbProbe: probe)
        XCTAssertTrue(second.database.accessible)
        XCTAssertEqual(second.database.status, "accessible")
        XCTAssertNil(second.database.fix)
        XCTAssertEqual(second.capabilities["perm_full_disk"]?.state, "supported")
        XCTAssertEqual(counter.calls, 2)
    }

    func testPermissionDeniedFixIsActionable() async throws {
        let (result, json) = try await encodedResponse(dbProbe: DiagnoseToolTests.dbDenied)
        let fix = try XCTUnwrap(result.database.fix)

        XCTAssertTrue(fix.contains("Full Disk Access"), fix)
        XCTAssertTrue(fix.contains("toggle it off and on"), fix)
        XCTAssertTrue(fix.contains("make restart"), fix)
        XCTAssertTrue(fix.contains("kickstart -k gui/<uid>/\(ServiceDefaults.launchdLabel)"), fix)
        XCTAssertTrue(fix.contains("pragma quick_check"), fix)
        XCTAssertTrue(fix.contains("newly launched"), fix)
        XCTAssertEqual(result.capabilities["perm_full_disk"]?.fix, fix,
                       "perm_full_disk.fix must carry the same remediation")

        XCTAssertFalse(json.contains(NSHomeDirectory()), "fix must not leak the home directory: \(json)")
    }

    func testGrantTargetIsTheAppForAnInBundleHelper() {
        XCTAssertEqual(
            DiagnoseTool.grantTarget(executable: "/Applications/iMessage Max.app/Contents/MacOS/imessage-max"),
            "/Applications/iMessage Max.app")
        XCTAssertEqual(
            DiagnoseTool.grantTarget(executable: "/opt/bin/imessage-max"), "/opt/bin/imessage-max")
        XCTAssertEqual(
            DiagnoseTool.grantTarget(executable: "/tmp/Contents/MacOS/imessage-max"),
            "/tmp/Contents/MacOS/imessage-max")
    }

    func testFeaturesReportedWhenDatabaseAccessible() async throws {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: DiagnoseToolTests.dbAccessible,
            automationProbe: DiagnoseToolTests.automationGranted,
            schemaProbe: { SchemaCapabilities.assumed.without(.messageDateEdited) }
        )
        XCTAssertEqual(result.database.features?["message.date_edited"], false)
        XCTAssertEqual(result.database.features?["message.thread_originator_guid"], true)
        let json = try FormatUtils.encodeJSON(result)
        XCTAssertTrue(json.contains("\"features\""))
    }

    func testFeaturesOmittedWhenDatabaseDenied() async throws {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: DiagnoseToolTests.dbDenied,
            automationProbe: DiagnoseToolTests.automationGranted,
            schemaProbe: {
                XCTFail("must not probe a denied database")
                return nil
            }
        )
        XCTAssertNil(result.database.features)
        let json = try FormatUtils.encodeJSON(result)
        XCTAssertFalse(json.contains("\"features\""))
    }

    func testHeadlessSkipIsVisibleInDiagnose() async throws {
        let resolver = ContactResolver(
            source: ContactResolver.Source(
                authorization: { (false, "not_determined") },
                load: { [:] },
                requestAccess: { XCTFail("must not prompt"); return false }
            ),
            refreshInterval: 30,
            now: { 0 }
        )
        await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)

        let result = try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: DiagnoseToolTests.dbAccessible,
            automationProbe: DiagnoseToolTests.automationGranted,
            usageDescriptionProbe: { true }
        )

        XCTAssertEqual(result.contacts.status, "not_requested_headless")
        XCTAssertFalse(result.contacts.authorized)
        XCTAssertTrue(result.contacts.fix?.contains("--request-contacts-access") == true)
        XCTAssertEqual(result.status, "needs_setup")
        XCTAssertEqual(result.capabilities["perm_contacts"]?.state, "permission-gated")
        XCTAssertNotNil(result.capabilities["perm_contacts"]?.fix)
    }

    func testNotDeterminedWithoutSkipIsUnchanged() async throws {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:], authorization: (false, "not_determined")),
            dbProbe: DiagnoseToolTests.dbAccessible,
            automationProbe: DiagnoseToolTests.automationGranted,
            usageDescriptionProbe: { true }
        )
        XCTAssertEqual(result.contacts.status, "not_determined")
        XCTAssertEqual(result.capabilities["perm_contacts"]?.state, "unverified")
    }

    func testMissingUsageDescriptionIsReportedBeforeHeadlessSkip() async throws {
        let resolver = ContactResolver(
            source: ContactResolver.Source(
                authorization: { (false, "not_determined") },
                load: { [:] },
                requestAccess: { XCTFail("must not prompt"); return false }
            ),
            refreshInterval: 30,
            now: { 0 }
        )
        await resolver.requestAccessIfAllowed(policy: .skipIfNotDetermined)

        let result = try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: DiagnoseToolTests.dbAccessible,
            automationProbe: DiagnoseToolTests.automationGranted,
            usageDescriptionProbe: { false }
        )

        XCTAssertEqual(result.contacts.status, "missing_usage_description")
        XCTAssertTrue(result.contacts.fix?.contains("make build") == true)
        XCTAssertEqual(result.capabilities["perm_contacts"]?.state, "permission-gated")
    }
}
