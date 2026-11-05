import Foundation
import IMessageMaxContract

/// The companion's reading of the server's `diagnose` reply. Its "ready"
/// includes sending, which the server's top-level status does not.
extension DiagnoseResult {
  public var readiness: Readiness {
    if !database.accessible { return .messages }
    if !namesReady { return .contacts }
    if self[.permAutomation]?.isSupported != true || self[.sendTextDM]?.isSupported != true {
      return .sending
    }
    return .ready
  }

  public var namesReady: Bool {
    contacts.authorized && PermissionStatus.namesAvailable.contains(contacts.status)
  }

  /// Whether the service already holds `permission`, so asking again is moot.
  public func grants(_ permission: SetupPermission) -> Bool {
    switch permission {
    case .automation: self[.permAutomation]?.isSupported == true
    case .contacts: namesReady
    }
  }

  public var needsMessagesForSendingCheck: Bool {
    readiness == .sending
      && self[.permAutomation]?.detail == PermissionStatus.messagesNotRunning.rawValue
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
