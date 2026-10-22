import Foundation

public struct Diagnosis: Codable, Sendable, Equatable {
  public struct Database: Codable, Sendable, Equatable {
    public let accessible: Bool
    public let status: String
  }
  public struct Contacts: Codable, Sendable, Equatable {
    public let authorized: Bool
    public let status: String
  }
  public struct Capability: Codable, Sendable, Equatable {
    public let state: String
    public let detail: String?
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

  public var readiness: Readiness {
    if !database.accessible { return .messages }
    if !namesReady { return .contacts }
    if capabilities["perm_automation"]?.state != "supported"
      || capabilities["send_text_dm"]?.state != "supported"
    {
      return .sending
    }
    return .ready
  }

  public var namesReady: Bool {
    contacts.authorized && ["authorized", "limited"].contains(contacts.status)
  }

  public var needsMessagesForSendingCheck: Bool {
    readiness == .sending && capabilities["perm_automation"]?.detail == "messages_not_running"
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
