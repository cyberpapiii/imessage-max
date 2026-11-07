import Foundation
import IMessageMaxContract

public struct ServiceClient: Sendable {
  /// The helper writes this file on first start. It is read on every call, so
  /// a token created after the app launched is picked up.
  let tokenFile: URL

  public init(
    tokenFile: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(ServiceDefaults.tokenPath)
  ) {
    self.tokenFile = tokenFile
  }

  static let unauthorized = CoreError.commandFailed(
    "iMessage Max refused this app's access token. Restart the service so it reads the token again.")

  static func readToken(_ file: URL) -> String? {
    guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return token.isEmpty ? nil : token
  }

  static func authorize(_ request: inout URLRequest, token: String?) {
    guard let token else { return }
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }

  public static func permissionRequest(endpoint: URL, permission: SetupPermission, token: String?)
    throws -> URLRequest
  {
    let url = SetupPermissionRoute.pathComponents.reduce(endpoint) {
      $0.appendingPathComponent($1)
    }
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      SetupPermissionRoute.headerValue, forHTTPHeaderField: SetupPermissionRoute.header)
    request.httpBody = try JSONEncoder().encode([SetupPermissionRoute.bodyKey: permission.rawValue])
    authorize(&request, token: token)
    return request
  }

  public func requestPermission(endpoint: URL, permission: SetupPermission, expectedProcessID: Int32)
    async throws -> SetupPermissionReply
  {
    let (data, response) = try await URLSession.shared.data(
      for: Self.permissionRequest(
        endpoint: endpoint, permission: permission, token: Self.readToken(tokenFile)))
    guard let response = response as? HTTPURLResponse else { throw CoreError.invalidResponse }
    if response.statusCode == 401 { throw Self.unauthorized }
    if response.statusCode == SetupPermissionRoute.notOfferedStatus {
      throw CoreError.commandFailed("Update iMessage Max to finish permission setup.")
    }
    if response.statusCode == SetupPermissionRoute.busyStatus {
      throw CoreError.commandFailed(
        "A permission request is already open. Finish the macOS prompt, then check again.")
    }
    guard response.statusCode == 200, data.count <= SetupPermissionRoute.maxReplyBytes else {
      throw CoreError.invalidResponse
    }
    return try Self.decodePermissionReply(
      data, permission: permission, expectedProcessID: expectedProcessID)
  }

  public static func decodePermissionReply(
    _ data: Data, permission: SetupPermission, expectedProcessID: Int32
  ) throws -> SetupPermissionReply {
    let reply = try JSONDecoder().decode(SetupPermissionReply.self, from: data)
    guard reply.permission == permission, reply.processID == expectedProcessID else {
      throw CoreError.conflict
    }
    return reply
  }

  public static func request(endpoint: URL, token: String?) throws -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(ModernMCP.protocolVersion, forHTTPHeaderField: MCPHeader.protocolVersion)
    request.setValue("tools/call", forHTTPHeaderField: MCPHeader.method)
    request.setValue(DiagnoseResult.toolName, forHTTPHeaderField: MCPHeader.name)
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": [
        "name": DiagnoseResult.toolName, "arguments": [:],
        "_meta": [
          ModernMetaKey.protocolVersion: ModernMCP.protocolVersion,
          ModernMetaKey.clientCapabilities: [:],
          ModernMetaKey.clientInfo: ["name": "iMessage Max Menu", "version": "1.0"],
        ],
      ],
    ])
    authorize(&request, token: token)
    return request
  }

  public func diagnose(endpoint: URL) async throws -> DiagnoseResult {
    let (data, response) = try await URLSession.shared.data(
      for: Self.request(endpoint: endpoint, token: Self.readToken(tokenFile)))
    if (response as? HTTPURLResponse)?.statusCode == 401 { throw Self.unauthorized }
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      data.count <= DiagnoseResult.maxReplyBytes
    else { throw CoreError.invalidResponse }
    return try Self.decode(data)
  }

  public static func decode(_ data: Data) throws -> DiagnoseResult {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["jsonrpc"] as? String == "2.0", envelope["id"] as? Int == 1,
      envelope["error"] == nil, let result = envelope["result"] as? [String: Any],
      result["isError"] as? Bool != true
    else { throw CoreError.invalidResponse }
    let payload: Data
    if let structured = result["structuredContent"] as? [String: Any] {
      payload = try JSONSerialization.data(withJSONObject: structured)
    } else if let blocks = result["content"] as? [[String: Any]],
      let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
    {
      payload = Data(text.utf8)
    } else {
      throw CoreError.invalidResponse
    }
    let diagnosis = try JSONDecoder().decode(DiagnoseResult.self, from: payload)
    guard diagnosis.processID > 0, !diagnosis.version.isEmpty,
      diagnosis[.permAutomation] != nil
    else { throw CoreError.invalidResponse }
    return diagnosis
  }
}
