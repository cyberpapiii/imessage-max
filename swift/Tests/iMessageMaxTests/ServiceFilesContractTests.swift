import XCTest
import HTTPTypes
import IMessageMaxContract
@testable import iMessageMax

final class ServiceFilesContractTests: XCTestCase {
    private var root: URL { get throws { try findRepoRoot() } }

    private static let agentPlistSource =
        "macos/Resources/LaunchAgents/\(ServiceDefaults.launchdLabel).plist"

    func testAgentPlistMatchesContract() throws {
        let url = try root.appendingPathComponent(Self.agentPlistSource)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, ServiceDefaults.launchdLabel)
        XCTAssertEqual(plist["BundleProgram"] as? String, ServiceDefaults.helperBundlePath)
        XCTAssertNil(plist["Program"], "SMAppService resolves BundleProgram inside the app")
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [ServiceDefaults.companionBundleID])
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            [
                ServiceDefaults.executableName, ServerOption.http.flag,
                ServerOption.port.flag, String(ServiceDefaults.port),
                ServerOption.logFile.flag, "~/\(ServiceDefaults.logPath)",
            ])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        let keepAlive = try XCTUnwrap(plist["KeepAlive"] as? [String: Bool])
        XCTAssertEqual(keepAlive, ["Crashed": true, "SuccessfulExit": false])
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 10,
                       "kickstart -k waits out the throttle, and a restart must finish inside the companion's wait")
        XCTAssertNil(plist["StandardErrorPath"], "launchd does not expand ~; the helper opens its own log")
    }

    func testMakefileMatchesContract() throws {
        let makefile = try String(contentsOf: root.appendingPathComponent("swift/Makefile"), encoding: .utf8)
        for expected in [
            "LAUNCHD_LABEL := \(ServiceDefaults.launchdLabel)\n",
            "AGENT_PLIST  := ../\(Self.agentPlistSource.replacingOccurrences(of: ServiceDefaults.launchdLabel, with: "$(LAUNCHD_LABEL)"))\n",
            "LOG          := $(HOME)/\(ServiceDefaults.logPath)\n",
            "),\(ServiceDefaults.port))\n",
            "URL          := http://\(ServiceDefaults.host):$(PORT)\n",
            "TOKEN_FILE   := $(HOME)/\(ServiceDefaults.tokenPath)\n",
            "launchctl kickstart -k gui/$$(id -u)/$(LAUNCHD_LABEL)",
            "--args --register-helper",
            "tail -f \"$(LOG)\"\n",
        ] {
            XCTAssertTrue(makefile.contains(expected), "swift/Makefile lacks \(expected.debugDescription)")
        }
        XCTAssertFalse(makefile.contains("install-agent"), "the app registers the helper; no hand-rendered plist")
    }

    func testCompanionAssemblyScriptMatchesContract() throws {
        let script = try String(contentsOf: root.appendingPathComponent("script/assemble_app.sh"), encoding: .utf8)
        for (expected, what) in [
            (Self.agentPlistSource, "agent plist source"),
            ("$APP_BUNDLE/\(ServiceDefaults.agentPlistDirectory)/$HELPER_LABEL.plist", "bundled agent plist"),
            ("\"$APP_BUNDLE/\(ServiceDefaults.helperBundlePath)\"", "helper inside the bundle"),
            ("BUNDLE_ID=\"${APP_BUNDLE_ID:-\(ServiceDefaults.companionBundleID)}\"\n", "companion bundle id"),
            ("sign.sh\" \"$APP_BUNDLE\" --entitlements \"$ENTITLEMENTS\"", "app signed with entitlements"),
            ("rm -rf \"$APP_BUNDLE\"\n", "fresh bundle, never cp over a running binary"),
        ] {
            XCTAssertTrue(script.contains(expected), "script/assemble_app.sh: \(what)")
        }
    }

    func testReleaseScriptChecksTheBundledLayout() throws {
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/sign-notarize-app.sh"), encoding: .utf8)
        for expected in [
            "AGENT_LABEL=\"\(ServiceDefaults.launchdLabel)\"\n",
            "APP_ID=\"\(ServiceDefaults.companionBundleID)\"\n",
            "HELPER=\"$APP/\(ServiceDefaults.helperBundlePath)\"\n",
            "AGENT_PLIST=\"$APP/\(ServiceDefaults.agentPlistDirectory)/$AGENT_LABEL.plist\"\n",
            "== \"\(ServiceDefaults.helperBundlePath)\" ]]",
        ] {
            XCTAssertTrue(script.contains(expected), "scripts/sign-notarize-app.sh lacks \(expected.debugDescription)")
        }
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
            ServerOption.logFile.flag, "~/x.log",
        ])
        XCTAssertTrue(command.http)
        XCTAssertEqual(command.logFile, "~/x.log")
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
