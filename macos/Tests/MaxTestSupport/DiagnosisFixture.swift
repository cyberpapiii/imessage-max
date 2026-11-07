import Foundation
import IMessageMaxContract

public func diagnosis(
  database: Bool = true, contacts: Bool = true, automation: String = "supported",
  processID: Int32 = 123
) throws -> DiagnoseResult {
  let data = Data(
    """
    {"version":"1.8.0","process_id":\(processID),"status":"ready",
    "database":{"path":"~/Library/Messages/chat.db","accessible":\(database),"status":"\(database ? "accessible" : "permission_denied")"},
    "contacts":{"authorized":\(contacts),"status":"\(contacts ? "authorized" : "denied")"},
    "capabilities":{"perm_automation":{"state":"\(automation)"},"send_text_dm":{"state":"\(automation)"}}}
    """.utf8)
  return try JSONDecoder().decode(DiagnoseResult.self, from: data)
}
