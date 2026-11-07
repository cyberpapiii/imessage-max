import XCTest
import HTTPTypes
import IMessageMaxContract
@testable import iMessageMax

final class ServiceFilesContractTests: XCTestCase {
    private var root: URL { get throws { try findRepoRoot() } }

    func testLaunchdTemplateMatchesContract() throws {
        let url = try root.appendingPathComponent("swift/launchd/\(ServiceDefaults.launchdLabel).plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, ServiceDefaults.launchdLabel)
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.dropLast(), ["__BIN__", ServerOption.http.flag, ServerOption.port.flag])
        // Plan 087 P3 owns this template and moves its port. The expectation
        // is strict, so the test fails once the port matches: then remove it.
        XCTExpectFailure("swift/launchd still pins port 8080 until plan 087 P3 lands", strict: true) {
            XCTAssertEqual(arguments.last, String(ServiceDefaults.port))
        }
        XCTAssertEqual(plist["StandardOutPath"] as? String, "~/\(ServiceDefaults.stdoutLogPath)")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, "~/\(ServiceDefaults.stderrLogPath)")
    }

    func testMakefileMatchesContract() throws {
        let makefile = try String(contentsOf: root.appendingPathComponent("swift/Makefile"), encoding: .utf8)
        for expected in [
            "LAUNCHD_LABEL := \(ServiceDefaults.launchdLabel)\n",
            "PLIST        := $(HOME)/\(ServiceDefaults.launchAgentPath.replacingOccurrences(of: ServiceDefaults.launchdLabel, with: "$(LAUNCHD_LABEL)"))\n",
            "),\(ServiceDefaults.port))\n",
            "URL          := http://\(ServiceDefaults.host):$(PORT)\n",
            "TOKEN_FILE   := $(HOME)/\(ServiceDefaults.tokenPath)\n",
            "launchd/\(ServiceDefaults.launchdLabel).plist",
            "tail -f ~/\(ServiceDefaults.stderrLogPath)\n",
            "> ~/\(ServiceDefaults.stderrLogPath)",
            "> ~/\(ServiceDefaults.stdoutLogPath)",
        ] {
            XCTAssertTrue(makefile.contains(expected), "swift/Makefile lacks \(expected.debugDescription)")
        }
    }

    func testCompanionAssemblyScriptMatchesContract() throws {
        let script = try String(contentsOf: root.appendingPathComponent("script/assemble_app.sh"), encoding: .utf8)
        let plist = "\(ServiceDefaults.launchdLabel).plist"
        XCTAssertTrue(script.contains("swift/launchd/\(plist)"), "script/assemble_app.sh template source")
        XCTAssertTrue(script.contains("Contents/Resources/\(plist)"), "script/assemble_app.sh bundled template")
        XCTAssertTrue(script.contains("Contents/Resources/\(ServiceDefaults.executableName)"), "bundled helper name")
        XCTAssertTrue(script.contains("BUNDLE_ID=\"\(ServiceDefaults.companionBundleID)\"\n"), "companion bundle id")
    }

    func testHelperEntitlementsGrantContactsAndAutomation() throws {
        let url = try root.appendingPathComponent("swift/iMessageMax.entitlements")
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(entitlements["com.apple.security.automation.apple-events"] as? Bool, true)
        XCTAssertEqual(entitlements["com.apple.security.personal-information.addressbook"] as? Bool, true)
        let makefile = try String(contentsOf: root.appendingPathComponent("swift/Makefile"), encoding: .utf8)
        XCTAssertTrue(makefile.contains("--entitlements iMessageMax.entitlements"), "make sign applies the entitlements")
    }

    func testServerParsesEveryCompanionOption() throws {
        let command = try iMessageMax.parse([
            ServerOption.http.flag,
            ServerOption.host.flag, "::1",
            "\(ServerOption.port.flag)=9191",
            ServerOption.contactsPolicy.flag, ContactsPolicyOption.skip.rawValue,
            ServerOption.allowExternalBind.flag,
        ])
        XCTAssertTrue(command.http)
        XCTAssertEqual(command.host, "::1")
        XCTAssertEqual(command.port, 9191)
        XCTAssertEqual(command.contactsPolicy, .skip)
        XCTAssertTrue(command.allowExternalBind)

        let defaults = try iMessageMax.parse([])
        XCTAssertEqual(defaults.host, ServiceDefaults.host)
        XCTAssertEqual(defaults.port, ServiceDefaults.port)
    }

    func testSetupRouteStatusCodes() {
        XCTAssertEqual(HTTPResponse.Status.notFound.code, SetupPermissionRoute.notOfferedStatus)
        XCTAssertEqual(HTTPResponse.Status.conflict.code, SetupPermissionRoute.busyStatus)
    }

    func testDatabaseStatusWords() {
        XCTAssertEqual(DatabaseError.permissionDenied("").clientCode, DatabaseStatus.permissionDenied.rawValue)
        XCTAssertEqual(DatabaseError.notFound("").clientCode, DatabaseStatus.databaseNotFound.rawValue)
        XCTAssertEqual(
            Database.checkAccess(path: "/nonexistent/chat.db").status, DatabaseStatus.databaseNotFound)
    }
}
