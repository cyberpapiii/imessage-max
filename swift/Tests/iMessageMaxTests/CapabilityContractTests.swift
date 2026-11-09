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
        XCTAssertEqual(caps["attachments_offloaded"]?.state, "degraded")
        XCTAssertFalse(caps["attachments_offloaded"]?.note?.contains("Retry get_attachment") ?? true)
        XCTAssertNotNil(caps["attachments_offloaded"]?.fix)

        XCTAssertEqual(caps["reply_threading"]?.state, "unsupported")
        XCTAssertEqual(caps["tapbacks"]?.state, "unsupported")
        XCTAssertEqual(caps["edit_unsend"]?.state, "unsupported")

        XCTAssertEqual(caps["live_inbox"]?.state, "unsupported")
        XCTAssertEqual(caps["live_inbox"]?.detail, "watcher_not_running")
        XCTAssertEqual(caps["rich_backend"]?.state, "unavailable")

        XCTAssertEqual(caps["perm_full_disk"]?.state, "supported")
        XCTAssertEqual(caps["perm_contacts"]?.state, "supported")
        XCTAssertEqual(caps["perm_automation"]?.state, "supported")
    }

    private func liveInbox(lane: ToolCallDispatch.Lane?, watcherLive: Bool) async throws -> Capability? {
        try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: CapabilityContractTests.dbProbe(ok: true),
            automationProbe: CapabilityContractTests.probeAutomationGranted,
            liveInboxProbe: { watcherLive },
            lane: lane
        )[.liveInbox]
    }

    /// Only legacy HTTP sessions receive new_messages, so only they are told
    /// the live inbox works (088 finding #18).
    func testLiveInboxIsSupportedOnlyOnALegacyHTTPSession() async throws {
        let http = try await liveInbox(lane: .legacyHTTP(session: "abc"), watcherLive: true)
        XCTAssertEqual(http?.state, .supported)
        XCTAssertEqual(http?.detail, LiveInboxDetail.sessionSSE.rawValue)

        for lane: ToolCallDispatch.Lane in [.legacyStdio, .modern(transport: "http"), .modern(transport: "stdio")] {
            let other = try await liveInbox(lane: lane, watcherLive: true)
            XCTAssertEqual(other?.state, .unsupported, "\(lane.logFields)")
            XCTAssertEqual(other?.detail, LiveInboxDetail.pollOnly.rawValue)
            XCTAssertTrue(other?.note?.contains("get_messages_since") == true)
        }

        let stopped = try await liveInbox(lane: .legacyHTTP(session: "abc"), watcherLive: false)
        XCTAssertEqual(stopped?.state, .degraded)
        XCTAssertEqual(stopped?.detail, LiveInboxDetail.watcherNotRunning.rawValue)
        XCTAssertTrue(stopped?.note?.contains("get_messages_since") == true)
    }

    /// The lane reaches diagnose through the dispatch task local, so the
    /// same catalog answers differently per connection.
    func testDispatchHandsTheLaneToTheTool() async throws {
        let catalog = ToolCatalog([
            ToolDefinition(name: "lane", description: "", inputSchema: .object([:])) { _ in
                [.plainText(ToolCallDispatch.lane?.logFields ?? "none")]
            }
        ])
        for (lane, expected) in [
            (ToolCallDispatch.Lane.legacyHTTP(session: "abcdefghij"), "lane=legacy-http session=abcdefgh"),
            (.legacyStdio, "lane=legacy-stdio"),
            (.modern(transport: "http"), "lane=modern-http"),
        ] {
            guard case .completed(let content, false) = await ToolCallDispatch.execute(
                name: "lane", arguments: nil, lane: lane, catalog: catalog, fromCompanion: true)
            else { return XCTFail("lane tool failed") }
            guard case .text(let text, _, _) = content.first else { return XCTFail("no text") }
            XCTAssertEqual(text, expected)
        }
        XCTAssertNil(ToolCallDispatch.lane)
    }

    // MARK: - Power (088 finding #20)

    private func diagnosePower(
        _ sleep: SleepSettings, keepAwake: KeepAwake.State = .init(),
        holder: DiagnoseTool.GrantHolder = .app("/Applications/iMessage Max.app")
    ) async throws -> DiagnoseResult.Power? {
        try await DiagnoseTool.execute(
            resolver: ContactResolver(seedCache: [:]),
            dbProbe: CapabilityContractTests.dbProbe(ok: true),
            automationProbe: CapabilityContractTests.probeAutomationGranted,
            sleepProbe: { sleep },
            keepAwakeProbe: { keepAwake },
            holder: holder
        ).power
    }

    func testIdleSleepIsReportedWithAFix() async throws {
        let found = try await diagnosePower(SleepSettings(sleepMinutes: 10, sleepDisabled: false))
        let power = try XCTUnwrap(found)
        XCTAssertEqual(power.status, .idleSleep)
        XCTAssertEqual(power.sleepMinutes, 10)
        XCTAssertFalse(power.keepAwake)
        XCTAssertFalse(power.assertionHeld)
        let fix = try XCTUnwrap(power.fix)
        XCTAssertTrue(fix.contains("10 minutes"), fix)
        XCTAssertTrue(fix.contains("Open iMessage Max and turn on Keep this Mac awake"), fix)
        XCTAssertFalse(fix.contains("pmset") || fix.contains("Terminal"), fix)

        let bare = try await diagnosePower(SleepSettings(sleepMinutes: 10), holder: .executable("~/bin/imessage-max"))
        XCTAssertFalse(bare?.fix?.contains("Open iMessage Max") ?? true)
        XCTAssertTrue(bare?.fix?.contains("System Settings") == true)
    }

    func testAMacThatNeverSleepsNeedsNoFix() async throws {
        for settings in [SleepSettings(sleepMinutes: 0), SleepSettings(sleepMinutes: 10, sleepDisabled: true)] {
            let power = try await diagnosePower(settings)
            XCTAssertEqual(power?.status, .staysAwake)
            XCTAssertNil(power?.fix)
        }
        let held = try await diagnosePower(
            SleepSettings(sleepMinutes: 10), keepAwake: .init(requested: true, held: true))
        XCTAssertEqual(held?.status, .staysAwake)
        XCTAssertEqual(held?.keepAwake, true)
        XCTAssertEqual(held?.assertionHeld, true)
        XCTAssertNil(held?.fix)
    }

    func testARefusedAssertionSaysSo() async throws {
        let power = try await diagnosePower(SleepSettings(sleepMinutes: 5), keepAwake: .init(requested: true, held: false))
        XCTAssertEqual(power?.status, .idleSleep)
        XCTAssertTrue(power?.fix?.contains("refused") == true)
    }

    func testUnreadSleepSettingIsUnknown() async throws {
        let power = try await diagnosePower(SleepSettings())
        XCTAssertEqual(power?.status, .unknown)
        XCTAssertNil(power?.fix)
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
