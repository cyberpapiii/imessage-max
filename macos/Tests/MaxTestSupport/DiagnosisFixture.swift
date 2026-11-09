import Foundation
import IMessageMaxContract

public func diagnosis(
  database: Bool = true, contacts: Bool = true, automation: String = "supported",
  processID: Int32 = 123, contactsStatus: String? = nil, assistantCalls: Int? = nil,
  automationDetail: String? = nil
) throws -> DiagnoseResult {
  let calls = assistantCalls.map { ",\"assistant_calls\":\($0)" } ?? ""
  let detail = automationDetail.map { ",\"detail\":\"\($0)\"" } ?? ""
  let data = Data(
    """
    {"version":"1.8.0","process_id":\(processID),"status":"ready",
    "database":{"path":"~/Library/Messages/chat.db","accessible":\(database),"status":"\(database ? "accessible" : "permission_denied")"},
    "contacts":{"authorized":\(contacts),"status":"\(contactsStatus ?? (contacts ? "authorized" : "denied"))"},
    "capabilities":{"perm_automation":{"state":"\(automation)"\(detail)},"send_text_dm":{"state":"\(automation)"}}\(calls)}
    """.utf8)
  return try JSONDecoder().decode(DiagnoseResult.self, from: data)
}
