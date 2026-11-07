import Foundation
import IMessageMaxContract
import Testing

@testable import MaxCore

@Test func permissionRequestsTargetTheLiveServiceNotASpawnedHelper() throws {
  let request = try ServiceClient.permissionRequest(
    endpoint: URL(string: "http://127.0.0.1:9191/")!, permission: .automation, token: "secret")
  #expect(request.url?.absoluteString == "http://127.0.0.1:9191/setup/permissions")
  #expect(request.value(forHTTPHeaderField: "X-iMessage-Max-Setup") == "permission-request-v1")
  #expect(request.value(forHTTPHeaderField: "Origin") == nil)
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
}

@Test func permissionReceiptMustMatchTheActualDaemonAndRequestedPermission() throws {
  let data = Data(
    "{\"permission\":\"automation\",\"authorized\":true,\"status\":\"authorized\",\"process_id\":123}"
      .utf8)
  #expect(
    try ServiceClient.decodePermissionReply(data, permission: .automation, expectedProcessID: 123)
      .authorized)
  #expect(throws: CoreError.self) {
    try ServiceClient.decodePermissionReply(data, permission: .automation, expectedProcessID: 456)
  }
  #expect(throws: CoreError.self) {
    try ServiceClient.decodePermissionReply(data, permission: .contacts, expectedProcessID: 123)
  }
}

@Test func deniedPermissionIsNotASuccessfulSetupReceipt() throws {
  let data = Data(
    "{\"permission\":\"automation\",\"authorized\":false,\"status\":\"denied\",\"process_id\":123}"
      .utf8)
  #expect(
    try !ServiceClient.decodePermissionReply(data, permission: .automation, expectedProcessID: 123)
      .authorized)
}

@Test func sendingCheckNeverSkipsMessagesOrContactsSetup() throws {
  for (messages, contacts) in [(false, false), (true, false), (true, true)] {
    let data = Data(
      """
      {"version":"1.8.0","process_id":123,"status":"ready",
      "database":{"path":"~/Library/Messages/chat.db","accessible":\(messages),"status":"accessible"},
      "contacts":{"authorized":\(contacts),"status":"\(contacts ? "authorized" : "denied")"},
      "capabilities":{"perm_automation":{"state":"unverified","detail":"messages_not_running"}}}
      """.utf8)
    let diagnosis = try JSONDecoder().decode(DiagnoseResult.self, from: data)
    #expect(diagnosis.needsMessagesForSendingCheck == (messages && contacts))
  }
}
