import Foundation
import IMessageMaxContract
import Testing
import MaxTestSupport

@testable import MaxCore

@Test func readingDoesNotPromiseUnverifiedSending() throws {
  #expect(try diagnosis(automation: "unverified").missingGrant == .automation)
}

@Test func missingMessagesTakesPriority() throws {
  #expect(try diagnosis(database: false, contacts: false).missingGrant == .fullDiskAccess)
}

@Test func missingNamesIsNotFullyReady() throws {
  #expect(try diagnosis(contacts: false).missingGrant == .contacts)
}

@Test func grantedContactsWithFailedLoadingAreNotReady() throws {
  let data = Data(
    """
    {"version":"1.8.0","process_id":123,"status":"ready","database":{"path":"~/Library/Messages/chat.db","accessible":true,"status":"accessible"},
    "contacts":{"authorized":true,"status":"authorized_load_failed"},"capabilities":{"perm_automation":{"state":"supported"}}}
    """.utf8)
  let value = try JSONDecoder().decode(DiagnoseResult.self, from: data)
  #expect(!value.namesReady)
  #expect(value.missingGrant == .contacts)
}

/// A signed-out iMessage account degrades the send capabilities, but no
/// permission fixes it, so it must not show as missing Automation.
@Test func signedOutIMessageIsNotAMissingGrant() throws {
  let data = Data(
    """
    {"version":"2.1.0","process_id":123,"status":"ready","database":{"path":"~/Library/Messages/chat.db","accessible":true,"status":"accessible"},
    "contacts":{"authorized":true,"status":"authorized"},
    "capabilities":{"perm_automation":{"state":"supported","detail":"authorized"},
    "send_text_dm":{"state":"degraded","detail":"imessage_account"},
    "imessage_account":{"state":"degraded","detail":"signed_out"}}}
    """.utf8)
  let value = try JSONDecoder().decode(DiagnoseResult.self, from: data)
  #expect(value.sendingReady)
  #expect(value.missingGrant == nil)
}
