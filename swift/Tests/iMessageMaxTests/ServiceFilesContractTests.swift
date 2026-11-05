import XCTest
import HTTPTypes
import IMessageMaxContract
@testable import iMessageMax

/// The plist template, Makefile and companion build script cannot import the
/// contract, so they repeat its values. These tests fail when they drift. The
/// rest pins producers outside this refactor's reach to the contract's words.
final class ServiceFilesContractTests: XCTestCase {
    private var root: URL { get throws { try repoRoot() } }

    func testLaunchdTemplateMatchesContract() throws {
        let url = try root.appendingPathComponent("swift/launchd/\(ServiceDefaults.launchdLabel).plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, ServiceDefaults.launchdLabel)
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["__BIN__", ServerOption.http.flag, ServerOption.port.flag, String(ServiceDefaults.port)])
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
            "launchd/\(ServiceDefaults.launchdLabel).plist",
            "tail -f ~/\(ServiceDefaults.stderrLogPath)\n",
            "> ~/\(ServiceDefaults.stderrLogPath)",
            "> ~/\(ServiceDefaults.stdoutLogPath)",
        ] {
            XCTAssertTrue(makefile.contains(expected), "swift/Makefile lacks \(expected.debugDescription)")
        }
    }

    func testCompanionBuildScriptMatchesContract() throws {
        let script = try String(contentsOf: root.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let plist = "\(ServiceDefaults.launchdLabel).plist"
        XCTAssertTrue(script.contains("swift/launchd/\(plist)"), "script/build_and_run.sh template source")
        XCTAssertTrue(script.contains("Contents/Resources/\(plist)"), "script/build_and_run.sh bundled template")
        XCTAssertTrue(script.contains("Contents/Resources/\(ServiceDefaults.executableName)"), "bundled helper name")
        XCTAssertTrue(script.contains("BUNDLE_ID=\"\(ServiceDefaults.companionBundleID)\"\n"), "companion bundle id")
    }

    /// Every option the companion reads back out of the plist is one the
    /// server's own parser accepts, in both spellings the companion accepts.
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
            Database.checkAccess(path: "/nonexistent/chat.db").status, DatabaseStatus.databaseNotFound.rawValue)
    }
}

private func repoRoot() throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("contract/Package.swift").path) {
            return directory
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
