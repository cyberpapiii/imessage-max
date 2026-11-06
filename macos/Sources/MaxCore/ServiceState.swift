import Foundation
import IMessageMaxContract

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
      "The installed service configuration is not valid. This app manages only a local iMessage Max service."
    case .timeout: "That took too long. Try again."
    case .conflict:
      "Another process is using this connection. iMessage Max has not changed or stopped it."
    case .commandFailed(let message): message
    }
  }
}
