import XCTest
import IMessageMaxContract
@testable import iMessageMax

final class CapabilityContractTests: XCTestCase {

    private static func dbProbe(ok: Bool) -> DatabaseProbe {
        if ok {
            return { (true, "accessible") }
        } else {
            return { (false, "permission_denied") }
        }
    }

    private static let probeAutomationGranted: AutomationProbe = { (true, "authorized") }
    private static let probeAutomationDenied: AutomationProbe = { (false, "denied") }
    private static let probeAutomationNotDetermined: AutomationProbe = { (false, "not_determined") }

    private func run(
        dbOk: Bool = true,
        contactsOk: Bool = true,
        automation: AutomationProbe = CapabilityContractTests.probeAutomationGranted
    ) async throws -> DiagnoseResult {
        let resolver = ContactResolver(
            seedCache: [:],
            authorization: contactsOk ? (true, "authorized") : (false, "denied")
        )
        return try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: CapabilityContractTests.dbProbe(ok: dbOk),
            automationProbe: automation,
            liveInboxProbe: { false }
        )
    }

    func testAllHealthyCapabilities() async throws {
        let caps = try await run().capabilities

        XCTAssertEqual(caps["send_text_dm"]?.state, "supported")
        XCTAssertNil(caps["send_text_dm"]?.fix)
        XCTAssertEqual(caps["send_text_group"]?.state, "supported")
        XCTAssertEqual(caps["send_file_dm"]?.state, "supported")

        XCTAssertEqual(caps["send_file_group"]?.state, "supported")
        XCTAssertNotNil(caps["send_file_group"]?.note)

        XCTAssertEqual(caps["verified_send"]?.state, "supported")
        XCTAssertEqual(caps["verified_send"]?.detail, "db_reread")

        XCTAssertEqual(caps["attachments_read"]?.state, "supported")
        XCTAssertEqual(caps["attachments_offloaded"]?.state, "supported")

        XCTAssertEqual(caps["reply_threading"]?.state, "unsupported")
        XCTAssertEqual(caps["tapbacks"]?.state, "unsupported")
        XCTAssertEqual(caps["edit_unsend"]?.state, "unsupported")

        XCTAssertEqual(caps["live_inbox"]?.state, "unavailable")
        XCTAssertEqual(caps["rich_backend"]?.state, "unavailable")

        XCTAssertEqual(caps["perm_full_disk"]?.state, "supported")
        XCTAssertEqual(caps["perm_contacts"]?.state, "supported")
        XCTAssertEqual(caps["perm_automation"]?.state, "supported")
    }

    func testLiveInboxSupportedWhenProbeReportsRunning() async throws {
        let resolver = ContactResolver(seedCache: [:])
        let result = try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: CapabilityContractTests.dbProbe(ok: true),
            automationProbe: CapabilityContractTests.probeAutomationGranted,
            liveInboxProbe: { true }
        )
        XCTAssertEqual(result.capabilities["live_inbox"]?.state, "supported")
        XCTAssertEqual(
            result.capabilities["live_inbox"]?.detail,
            "notifications/imessage/new_messages over the legacy session SSE stream; stateless clients poll get_messages_since"
        )
    }

    func testAutomationDeniedCapabilities() async throws {
        let caps = try await run(automation: CapabilityContractTests.probeAutomationDenied).capabilities

        for key in ["send_text_dm", "send_text_group", "send_file_dm", "send_file_group"] {
            XCTAssertEqual(caps[key]?.state, "permission-gated", "\(key) should be permission-gated")
            XCTAssertNotNil(caps[key]?.fix, "\(key) must include fix text")
        }

        XCTAssertEqual(caps["verified_send"]?.state, "degraded")

        XCTAssertEqual(caps["perm_automation"]?.state, "permission-gated")
        XCTAssertNotNil(caps["perm_automation"]?.fix)
    }

    /// A send never asks for Automation (nobody may be at the screen), so
    /// "not determined" blocks sends just like "denied", with its own fix.
    func testAutomationNotDeterminedCapabilities() async throws {
        let caps = try await run(automation: CapabilityContractTests.probeAutomationNotDetermined).capabilities

        for key in ["send_text_dm", "send_text_group", "send_file_dm", "send_file_group", "perm_automation"] {
            XCTAssertEqual(caps[key]?.state, "permission-gated", "\(key) should be permission-gated")
            XCTAssertNotNil(caps[key]?.fix, "\(key) must include fix text")
        }
        XCTAssertEqual(caps["perm_automation"]?.detail, "not_determined")

        XCTAssertEqual(caps["verified_send"]?.state, "degraded")
    }

    func testDBInaccessibleCapabilities() async throws {
        let caps = try await run(dbOk: false).capabilities

        XCTAssertEqual(caps["verified_send"]?.state, "permission-gated")
        XCTAssertNotNil(caps["verified_send"]?.fix)

        XCTAssertEqual(caps["attachments_read"]?.state, "permission-gated")
        XCTAssertNotNil(caps["attachments_read"]?.fix)

        XCTAssertEqual(caps["perm_full_disk"]?.state, "permission-gated")

        XCTAssertEqual(caps["send_text_dm"]?.state, "supported")
        XCTAssertEqual(caps["send_file_group"]?.state, "supported")
    }

    func testJSONContractContainsAll15Keys() async throws {
        let result = try await run()
        let json = try FormatUtils.encodeJSON(result)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let caps = try XCTUnwrap(decoded["capabilities"] as? [String: Any])

        let expectedKeys: Set<String> = [
            "send_text_dm", "send_text_group", "send_file_dm", "send_file_group",
            "verified_send", "attachments_read", "attachments_offloaded",
            "reply_threading", "tapbacks", "edit_unsend",
            "live_inbox",
            "perm_full_disk", "perm_contacts", "perm_automation",
            "rich_backend",
        ]
        XCTAssertEqual(Set(caps.keys), expectedKeys, "capabilities must contain exactly the 15 contract keys")

        for key in ["send_text_dm", "verified_send", "perm_automation", "rich_backend"] {
            let entry = try XCTUnwrap(caps[key] as? [String: Any], "\(key) must be a JSON object")
            XCTAssertNotNil(entry["state"], "\(key).state must be present")
        }

        XCTAssertNotNil(decoded["database"])
        XCTAssertNotNil(decoded["contacts"])
        XCTAssertNotNil(decoded["version"])
        XCTAssertNotNil(decoded["process_id"])
        XCTAssertNotNil(decoded["status"])
        XCTAssertNil(decoded["database_accessible"])
        XCTAssertNil(decoded["contacts_authorized"])

        let verifiedSend = try XCTUnwrap(caps["verified_send"] as? [String: Any])
        XCTAssertEqual(verifiedSend["state"] as? String, "supported")
        XCTAssertEqual(verifiedSend["detail"] as? String, "db_reread")
    }
}
