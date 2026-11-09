import Foundation
import IMessageMaxContract
import Testing

@Test func setupReplyWireShape() throws {
  let reply = SetupPermissionReply(
    permission: .automation, authorized: true, status: .authorized, processID: 42)
  let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? NSDictionary
  #expect(object == ["permission": "automation", "authorized": true, "status": "authorized", "process_id": 42])
}

@Test func largestSetupReplyFitsTheCompanionCap() throws {
  let reply = SetupPermissionReply(
    permission: .automation, authorized: false, status: .checkFailed(Int32.min),
    processID: Int32.max)
  #expect(try JSONEncoder().encode(reply).count < SetupPermissionRoute.maxReplyBytes)
}

@Test func capabilityOmitsNilFields() throws {
  let json = String(decoding: try JSONEncoder().encode(Capability(state: .supported)), as: UTF8.self)
  #expect(json == #"{"state":"supported"}"#)
}

@Test func wireWordsAreBareStringsAndStayOpen() throws {
  #expect(String(decoding: try JSONEncoder().encode(CapabilityState.permissionGated), as: UTF8.self)
    == #""permission-gated""#)
  let unknown = try JSONDecoder().decode(CapabilityState.self, from: Data(#""brand-new""#.utf8))
  #expect(unknown.rawValue == "brand-new")
  #expect("\(PermissionStatus.loadFailed(.limited))" == "limited_load_failed")
  #expect(PermissionStatus.checkFailed(-1).rawValue == "check_failed_-1")
}

@Test func diagnoseDecodesWithoutOptionalFields() throws {
  let json = """
    {"version":"1.8.0","process_id":7,"status":"ready",
     "database":{"accessible":true,"status":"accessible","path":"~/Library/Messages/chat.db"},
     "contacts":{"authorized":true,"status":"limited"},
     "capabilities":{"perm_automation":{"state":"supported","detail":"authorized"},"future_key":{"state":"new"}}}
    """
  let result = try JSONDecoder().decode(DiagnoseResult.self, from: Data(json.utf8))
  #expect(result.processID == 7)
  #expect(PermissionStatus.namesAvailable.contains(result.contacts.status))
  #expect(result[.permAutomation]?.isSupported == true)
  #expect(result[.permAutomation]?.detail == PermissionStatus.authorized.rawValue)
  #expect(result.capabilities["future_key"]?.state == "new")
  #expect(result.assistantCalls == nil)
  #expect(result.http == nil)
}

@Test func httpListenerStateTravelsWithItsFix() throws {
  let json = """
    {"version":"2.1.0","process_id":7,"status":"ready",
     "database":{"accessible":true,"status":"accessible","path":"~/Library/Messages/chat.db"},
     "contacts":{"authorized":true,"status":"authorized"},
     "capabilities":{},"http":{"port":47821,"state":"port_in_use","fix":"Quit it."}}
    """
  let result = try JSONDecoder().decode(DiagnoseResult.self, from: Data(json.utf8))
  #expect(result.http == DiagnoseResult.HTTPEndpoint(port: 47821, state: .portInUse, fix: "Quit it."))
  let listening = try JSONEncoder().encode(DiagnoseResult.HTTPEndpoint(port: 1, state: .listening))
  #expect(String(decoding: listening, as: UTF8.self).contains(#""state":"listening""#))
  #expect(!String(decoding: listening, as: UTF8.self).contains("fix"))
}

@Test func startupFailureIsReadFromTheLastLaunchOnly() {
  let log = """
    2026-11-08T10:00:00.000Z [imessage-max] INFO \(StartupFailure.startedMarker)2.1.0 pid=1
    2026-11-08T10:01:00.000Z [imessage-max] ERROR \(StartupFailure.marker)Cannot create /x: Permission denied
    Error: Cannot create /x: Permission denied
    """
  #expect(StartupFailure.reason(inLog: log) == "Cannot create /x: Permission denied")
  #expect(StartupFailure.reason(inLog: log + "\nlater \(StartupFailure.startedMarker)2.1.0") == nil)
  #expect(StartupFailure.reason(inLog: "no launch lines") == nil)
}

@Test func assistantCallsTravelAsASnakeCaseKey() throws {
  let json = """
    {"version":"2.0.0","process_id":7,"status":"ready",
     "database":{"accessible":true,"status":"accessible","path":"~/Library/Messages/chat.db"},
     "contacts":{"authorized":true,"status":"authorized"},
     "capabilities":{},"assistant_calls":2}
    """
  let result = try JSONDecoder().decode(DiagnoseResult.self, from: Data(json.utf8))
  #expect(result.assistantCalls == 2)
  let encoded = try JSONEncoder().encode(result)
  #expect(String(decoding: encoded, as: UTF8.self).contains(#""assistant_calls":2"#))
}

@Test func serverOptionsParseFlags() {
  #expect(ServerOption.allCases.map(\.flag)
    == ["--http", "--host", "--port", "--contacts-policy", "--allow-external-bind", "--log-file",
       "--socket-path", "--token-file"])
  #expect(ServerOption(flag: "--contacts-policy") == .contactsPolicy)
  #expect(ServerOption(flag: "contacts-policy") == nil)
  #expect(SetupPermissionRoute.path == "/setup/permissions")
}

/// Diagnose fixes and the companion's rows both use these titles, which are
/// the names System Settings shows.
@Test func permissionTitlesAreTheSystemSettingsNamesInPanelOrder() {
  #expect(SetupStep.allCases.map(\.title) == [
    "Background activity", "Full Disk Access", "Contacts", "Automation",
  ])
}
