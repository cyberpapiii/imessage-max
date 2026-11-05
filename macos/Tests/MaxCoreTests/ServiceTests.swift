import Foundation
import IMessageMaxContract
import Testing

@testable import MaxCore

func diagnosis(database: Bool = true, contacts: Bool = true, automation: String = "supported")
  throws -> DiagnoseResult
{
  let data = Data(
    """
    {"version":"1.8.0","process_id":123,"status":"ready",
    "database":{"path":"~/Library/Messages/chat.db","accessible":\(database),"status":"\(database ? "accessible" : "permission_denied")"},
    "contacts":{"authorized":\(contacts),"status":"\(contacts ? "authorized" : "denied")"},
    "capabilities":{"perm_automation":{"state":"\(automation)"},"send_text_dm":{"state":"\(automation)"}}}
    """.utf8)
  return try JSONDecoder().decode(DiagnoseResult.self, from: data)
}

@Test func readingDoesNotPromiseUnverifiedSending() throws {
  #expect(try diagnosis(automation: "unverified").readiness == .sending)
}

@Test func missingMessagesTakesPriority() throws {
  #expect(try diagnosis(database: false, contacts: false).readiness == .messages)
}

@Test func missingNamesIsNotFullyReady() throws {
  #expect(try diagnosis(contacts: false).readiness == .contacts)
}

@Test func grantedContactsWithFailedLoadingAreNotReady() throws {
  let data = Data(
    """
    {"version":"1.8.0","process_id":123,"status":"ready","database":{"path":"~/Library/Messages/chat.db","accessible":true,"status":"accessible"},
    "contacts":{"authorized":true,"status":"authorized_load_failed"},"capabilities":{"perm_automation":{"state":"supported"}}}
    """.utf8)
  let value = try JSONDecoder().decode(DiagnoseResult.self, from: data)
  #expect(!value.namesReady)
  #expect(value.readiness == .contacts)
}
