import Foundation

/// The companion's reading of the server's `diagnose` reply.
public struct Diagnosis: Codable, Sendable, Equatable {
  public struct Database: Codable, Sendable, Equatable {
    public let accessible: Bool
    public let status: String
  }
  public struct Contacts: Codable, Sendable, Equatable {
    public let authorized: Bool
    public let status: String
  }
  /// One entry of the server's capability contract (see CONCEPTS.md).
  public struct Capability: Codable, Sendable, Equatable {
    public enum Key: String, Sendable {
      case automation = "perm_automation"
      case sendText = "send_text_dm"
      case liveInbox = "live_inbox"
    }
    public static let supported = "supported"
    public static let permissionGated = "permission-gated"

    public let state: String
    public let detail: String?

    public var isSupported: Bool { state == Self.supported }
    public var isPermissionGated: Bool { state == Self.permissionGated }
  }
  public let version: String
  public let processID: Int32
  public let status: String
  public let database: Database
  public let contacts: Contacts
  public let capabilities: [String: Capability]

  enum CodingKeys: String, CodingKey {
    case version, status, database, contacts, capabilities
    case processID = "process_id"
  }

  public subscript(key: Capability.Key) -> Capability? { capabilities[key.rawValue] }

  public var readiness: Readiness {
    if !database.accessible { return .messages }
    if !namesReady { return .contacts }
    if self[.automation]?.isSupported != true || self[.sendText]?.isSupported != true {
      return .sending
    }
    return .ready
  }

  public var namesReady: Bool {
    contacts.authorized && ["authorized", "limited"].contains(contacts.status)
  }

  /// Whether the service already holds `permission`, so asking again is moot.
  public func grants(_ permission: PermissionKind) -> Bool {
    switch permission {
    case .automation: self[.automation]?.isSupported == true
    case .contacts: namesReady
    }
  }

  public var needsMessagesForSendingCheck: Bool {
    readiness == .sending && self[.automation]?.detail == "messages_not_running"
  }
}

public enum Readiness: String, Sendable {
  case messages, contacts, sending, ready
}

public enum CoreError: Error, LocalizedError, Sendable {
  case invalidResponse, invalidConfiguration, timeout
  case commandFailed(String)
  case conflict

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "iMessage Max returned an unreadable response. Try restarting it."
    case .invalidConfiguration:
      "The installed service configuration needs attention. Only a local iMessage Max service can be managed."
    case .timeout: "That took too long. Try again."
    case .conflict:
      "Another process is using this connection. iMessage Max has not changed or stopped it."
    case .commandFailed(let message): message
    }
  }
}
