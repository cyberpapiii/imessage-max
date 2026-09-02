import XCTest
@testable import iMessageMax

/// Plan 049: diagnose is the one tool whose response legitimately names the
/// database path, but the operator's username must not ride along with it.
/// All probes are injected so the test is hermetic on a CI runner without
/// Full Disk Access.
final class DiagnoseToolTests: XCTestCase {
    private static let dbAccessible: DatabaseProbe = { (true, "accessible") }
    private static let dbDenied: DatabaseProbe = { (false, "permission_denied") }
    private static let contactsAuthorized: ContactsProbe = { (true, "authorized") }
    private static let automationGranted: AutomationProbe = { (true, "authorized") }

    private func encodedResponse(dbProbe: DatabaseProbe) async throws -> (DiagnoseResult, String) {
        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: dbProbe,
            contactsProbe: DiagnoseToolTests.contactsAuthorized,
            automationProbe: DiagnoseToolTests.automationGranted
        )
        return (result, try FormatUtils.encodeJSON(result))
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

    /// CI=true makes ContactResolver.initialize skip contact loading. diagnose
    /// must say so instead of reporting an authorized, empty, "ready" store.
    func testCIGuardIsVisibleInDiagnose() async throws {
        let previous = ProcessInfo.processInfo.environment["CI"]
        setenv("CI", "true", 1)
        defer {
            if let previous { setenv("CI", previous, 1) } else { unsetenv("CI") }
        }

        let result = try await DiagnoseTool.execute(
            resolver: ContactResolver(),
            dbProbe: DiagnoseToolTests.dbAccessible,
            contactsProbe: DiagnoseToolTests.contactsAuthorized,
            automationProbe: DiagnoseToolTests.automationGranted
        )

        XCTAssertEqual(result.contacts.status, "skipped_ci")
        XCTAssertEqual(result.contacts.loaded, 0)
        XCTAssertNotNil(result.contacts.fix)
        XCTAssertEqual(result.status, "needs_setup",
                       "an empty contact store is not a ready server")
    }

    /// diagnose must probe on every call, never on first call only.
    func testDiagnoseReprobesOnEveryCall() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func next() -> (ok: Bool, status: String) {
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

    /// The fix must say which process to grant, what to do about a stale
    /// entry, that the grant only applies to newly launched processes, and
    /// how to bisect between "this user lacks FDA" and "this process lacks FDA".
    func testPermissionDeniedFixIsActionable() async throws {
        let (result, json) = try await encodedResponse(dbProbe: DiagnoseToolTests.dbDenied)
        let fix = try XCTUnwrap(result.database.fix)

        XCTAssertTrue(fix.contains("Full Disk Access"), fix)
        XCTAssertTrue(fix.contains("toggle it off and on"), fix)
        XCTAssertTrue(fix.contains("launchctl kickstart -k gui/$(id -u)/local.imessage-max"), fix)
        XCTAssertTrue(fix.contains("pragma quick_check"), fix)
        XCTAssertTrue(fix.contains("newly launched"), fix)
        XCTAssertEqual(result.capabilities["perm_full_disk"]?.fix, fix,
                       "perm_full_disk.fix must carry the same remediation")

        XCTAssertFalse(json.contains(NSHomeDirectory()), "fix must not leak the home directory: \(json)")
    }
}
