// Shared by MaxCoreTests and CompanionTests: CompanionTests/DiagnosisFixture.swift
// is a symlink to this file.
import Foundation
import IMessageMaxContract

/// A decoded `diagnose` reply. `automation` is the state of both
/// perm_automation and send_text_dm.
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
