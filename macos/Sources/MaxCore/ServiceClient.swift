import Foundation

public struct ServiceClient: Sendable {
  public init() {}

  public static func permissionRequest(endpoint: URL, permission: PermissionKind) throws
    -> URLRequest
  {
    var request = URLRequest(
      url: endpoint.appendingPathComponent("setup").appendingPathComponent("permissions"),
      timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("permission-request-v1", forHTTPHeaderField: "X-iMessage-Max-Setup")
    request.httpBody = try JSONEncoder().encode(["permission": permission.rawValue])
    return request
  }

  public func requestPermission(endpoint: URL, permission: PermissionKind, expectedProcessID: Int32)
    async throws -> SetupPermissionReply
  {
    let (data, response) = try await URLSession.shared.data(
      for: Self.permissionRequest(endpoint: endpoint, permission: permission))
    guard let response = response as? HTTPURLResponse else { throw CoreError.invalidResponse }
    if response.statusCode == 404 {
      throw CoreError.commandFailed("Update iMessage Max to finish permission setup.")
    }
    if response.statusCode == 409 {
      throw CoreError.commandFailed(
        "A permission request is already open. Finish the macOS prompt, then check again.")
    }
    guard response.statusCode == 200, data.count <= 4096 else { throw CoreError.invalidResponse }
    return try Self.decodePermissionReply(
      data, permission: permission, expectedProcessID: expectedProcessID)
  }

  public static func decodePermissionReply(
    _ data: Data, permission: PermissionKind, expectedProcessID: Int32
  ) throws -> SetupPermissionReply {
    let reply = try JSONDecoder().decode(SetupPermissionReply.self, from: data)
    guard reply.permission == permission, reply.processID == expectedProcessID else {
      throw CoreError.conflict
    }
    return reply
  }

  public static func request(endpoint: URL) throws -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("2026-07-28", forHTTPHeaderField: "MCP-Protocol-Version")
    request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
    request.setValue("diagnose", forHTTPHeaderField: "Mcp-Name")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": [
        "name": "diagnose", "arguments": [:],
        "_meta": [
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": [:],
          "io.modelcontextprotocol/clientInfo": ["name": "iMessage Max Menu", "version": "1.0"],
        ],
      ],
    ])
    return request
  }

  public func diagnose(endpoint: URL) async throws -> Diagnosis {
    let (data, response) = try await URLSession.shared.data(for: Self.request(endpoint: endpoint))
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      data.count <= 1_048_576
    else { throw CoreError.invalidResponse }
    return try Self.decode(data)
  }

  public static func decode(_ data: Data) throws -> Diagnosis {
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
    let diagnosis = try JSONDecoder().decode(Diagnosis.self, from: payload)
    guard diagnosis.processID > 0, !diagnosis.version.isEmpty,
      diagnosis.capabilities["perm_automation"] != nil
    else { throw CoreError.invalidResponse }
    return diagnosis
  }
}

public struct SetupPermissionReply: Codable, Sendable {
  public let permission: PermissionKind
  public let authorized: Bool
  public let status: String
  public let processID: Int32

  enum CodingKeys: String, CodingKey {
    case permission, authorized, status
    case processID = "process_id"
  }
}
