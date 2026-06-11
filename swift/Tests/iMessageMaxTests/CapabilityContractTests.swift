// Tests/iMessageMaxTests/CapabilityContractTests.swift
import XCTest
@testable import iMessageMax

/// Tests for the 15-key capability contract (design §2.2 / §2.4 / §3.2).
///
/// All three probes (DB, contacts, automation) are injected so tests are hermetic.
/// The real automation probe reads live macOS TCC; CI runners return "not_determined".
final class CapabilityContractTests: XCTestCase {

    // MARK: - Shared probe factories

    private static func dbProbe(ok: Bool) -> DatabaseProbe {
        if ok {
            return { (true, "accessible") }
        } else {
            return { (false, "permission_denied") }
        }
    }

    private static func contactsProbe(ok: Bool) -> ContactsProbe {
        if ok {
            return { (true, "authorized") }
        } else {
            return { (false, "denied") }
        }
    }

    private static let probeAutomationGranted: AutomationProbe = { (true, "authorized") }
    private static let probeAutomationDenied: AutomationProbe = { (false, "denied") }
    private static let probeAutomationNotDetermined: AutomationProbe = { (false, "not_determined") }

    // MARK: - Convenience execute helper

    private func run(
        dbOk: Bool = true,
        contactsOk: Bool = true,
        automation: AutomationProbe = CapabilityContractTests.probeAutomationGranted
    ) async throws -> DiagnoseResult {
        // Use a seeded resolver so initialize() is a no-op (already initialized)
        let resolver = ContactResolver(seedCache: [:])
        return try await DiagnoseTool.execute(
            resolver: resolver,
            dbProbe: CapabilityContractTests.dbProbe(ok: dbOk),
            contactsProbe: CapabilityContractTests.contactsProbe(ok: contactsOk),
            automationProbe: automation
        )
    }

    // MARK: - Test 1: All-healthy install

    func testAllHealthyCapabilities() async throws {
        let caps = try await run().capabilities

        // Send modes: automation granted → supported
        XCTAssertEqual(caps["send_text_dm"]?.state, "supported")
        XCTAssertNil(caps["send_text_dm"]?.fix)
        XCTAssertEqual(caps["send_text_group"]?.state, "supported")
        XCTAssertEqual(caps["send_file_dm"]?.state, "supported")

        // send_file_group: always risky-private when automation granted
        XCTAssertEqual(caps["send_file_group"]?.state, "risky-private")
        XCTAssertNotNil(caps["send_file_group"]?.note)

        // verified_send: db ok + automation ok → supported with db_reread detail
        XCTAssertEqual(caps["verified_send"]?.state, "supported")
        XCTAssertEqual(caps["verified_send"]?.detail, "db_reread")

        // Attachment handling
        XCTAssertEqual(caps["attachments_read"]?.state, "supported")
        XCTAssertEqual(caps["attachments_offloaded"]?.state, "supported")

        // Hardcoded unsupported features
        XCTAssertEqual(caps["reply_threading"]?.state, "unsupported")
        XCTAssertEqual(caps["tapbacks"]?.state, "unsupported")
        XCTAssertEqual(caps["edit_unsend"]?.state, "unsupported")

        // No-implementation features
        XCTAssertEqual(caps["live_inbox"]?.state, "unavailable")
        XCTAssertEqual(caps["rich_backend"]?.state, "unavailable")

        // Permissions: all probed as supported
        XCTAssertEqual(caps["perm_full_disk"]?.state, "supported")
        XCTAssertEqual(caps["perm_contacts"]?.state, "supported")
        XCTAssertEqual(caps["perm_automation"]?.state, "supported")
    }

    // MARK: - Test 2: Automation denied

    func testAutomationDeniedCapabilities() async throws {
        let caps = try await run(automation: CapabilityContractTests.probeAutomationDenied).capabilities

        // Four send modes: permission-gated with fix text
        for key in ["send_text_dm", "send_text_group", "send_file_dm", "send_file_group"] {
            XCTAssertEqual(caps[key]?.state, "permission-gated", "\(key) should be permission-gated")
            XCTAssertNotNil(caps[key]?.fix, "\(key) must include fix text")
        }

        // verified_send: db ok, automation denied → degraded
        XCTAssertEqual(caps["verified_send"]?.state, "degraded")

        // perm_automation: denied → permission-gated with fix
        XCTAssertEqual(caps["perm_automation"]?.state, "permission-gated")
        XCTAssertNotNil(caps["perm_automation"]?.fix)
    }

    // MARK: - Test 3: Automation not_determined → unverified (honest default)

    func testAutomationNotDeterminedCapabilities() async throws {
        let caps = try await run(automation: CapabilityContractTests.probeAutomationNotDetermined).capabilities

        XCTAssertEqual(caps["send_text_dm"]?.state, "unverified")
        XCTAssertEqual(caps["send_text_group"]?.state, "unverified")
        XCTAssertEqual(caps["send_file_dm"]?.state, "unverified")
        XCTAssertEqual(caps["send_file_group"]?.state, "unverified")
        XCTAssertEqual(caps["perm_automation"]?.state, "unverified")

        // verified_send: db ok, automation not_determined → degraded
        XCTAssertEqual(caps["verified_send"]?.state, "degraded")
    }

    // MARK: - Test 4: DB inaccessible

    func testDBInaccessibleCapabilities() async throws {
        let caps = try await run(dbOk: false).capabilities

        // verified_send: no DB → permission-gated
        XCTAssertEqual(caps["verified_send"]?.state, "permission-gated")
        XCTAssertNotNil(caps["verified_send"]?.fix)

        // attachments_read: no DB → permission-gated
        XCTAssertEqual(caps["attachments_read"]?.state, "permission-gated")
        XCTAssertNotNil(caps["attachments_read"]?.fix)

        // perm_full_disk: permission_denied status → permission-gated
        XCTAssertEqual(caps["perm_full_disk"]?.state, "permission-gated")

        // Send modes are driven only by automation, not DB
        XCTAssertEqual(caps["send_text_dm"]?.state, "supported")
        XCTAssertEqual(caps["send_file_group"]?.state, "risky-private")
    }

    // MARK: - Test 5: JSON contract — all 15 keys present with correct names

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
        XCTAssertEqual(Set(caps.keys), expectedKeys, "capabilities must contain exactly the 15 §2.2 keys")

        // Spot-check key names and state-object shape
        for key in ["send_text_dm", "verified_send", "perm_automation", "rich_backend"] {
            let entry = try XCTUnwrap(caps[key] as? [String: Any], "\(key) must be a JSON object")
            XCTAssertNotNil(entry["state"], "\(key).state must be present")
        }

        // Backward-compat health fields still present
        XCTAssertNotNil(decoded["database"])
        XCTAssertNotNil(decoded["contacts"])
        XCTAssertNotNil(decoded["version"])
        XCTAssertNotNil(decoded["process_id"])
        XCTAssertNotNil(decoded["status"])

        // verified_send detail key name (§3.2)
        let verifiedSend = try XCTUnwrap(caps["verified_send"] as? [String: Any])
        XCTAssertEqual(verifiedSend["state"] as? String, "supported")
        XCTAssertEqual(verifiedSend["detail"] as? String, "db_reread")
    }
}
