import Foundation

/// The `diagnose` tool's reply. The server encodes it and the companion
/// decodes it. The JSON leaves out optional fields that are nil.
public struct DiagnoseResult: Codable, Sendable, Equatable {
  public static let toolName = "diagnose"
  /// The companion refuses a larger diagnose reply.
  public static let maxReplyBytes = 1_048_576

  public struct DatabaseAccess: Codable, Sendable, Equatable {
    public let accessible: Bool
    public let status: DatabaseStatus
    public let path: String
    public let fix: String?
    public let features: [String: Bool]?

    public init(
      accessible: Bool, status: DatabaseStatus, path: String, fix: String?,
      features: [String: Bool]? = nil
    ) {
      self.accessible = accessible
      self.status = status
      self.path = path
      self.fix = fix
      self.features = features
    }
  }

  public struct ContactsAccess: Codable, Sendable, Equatable {
    public let authorized: Bool
    public let status: PermissionStatus
    public let loaded: Int?
    public let fix: String?

    public init(authorized: Bool, status: PermissionStatus, loaded: Int?, fix: String?) {
      self.authorized = authorized
      self.status = status
      self.loaded = loaded
      self.fix = fix
    }
  }

  public let version: String
  public let processID: Int32
  public let status: DiagnoseStatus
  public let database: DatabaseAccess
  public let contacts: ContactsAccess
  /// The keys are `CapabilityKey` raw values. The map is keyed by String so a
  /// reader still decodes keys that a newer server adds.
  public let capabilities: [String: Capability]
  /// The tools/call requests this helper process has received from clients
  /// other than the companion. The companion's Try it step turns green once it
  /// is above zero. nil from a helper older than the field.
  public let assistantCalls: Int?

  public init(
    version: String, processID: Int32, status: DiagnoseStatus, database: DatabaseAccess,
    contacts: ContactsAccess, capabilities: [String: Capability], assistantCalls: Int? = nil
  ) {
    self.version = version
    self.processID = processID
    self.status = status
    self.database = database
    self.contacts = contacts
    self.capabilities = capabilities
    self.assistantCalls = assistantCalls
  }

  enum CodingKeys: String, CodingKey {
    case version
    case processID = "process_id"
    case status
    case database
    case contacts
    case capabilities
    case assistantCalls = "assistant_calls"
  }

  public subscript(key: CapabilityKey) -> Capability? { capabilities[key.rawValue] }
}

/// One entry of the capability contract (see CONCEPTS.md).
public struct Capability: Codable, Sendable, Equatable {
  public let state: CapabilityState
  public let note: String?
  public let fix: String?
  public let detail: String?

  public init(state: CapabilityState, note: String? = nil, fix: String? = nil, detail: String? = nil) {
    self.state = state
    self.note = note
    self.fix = fix
    self.detail = detail
  }

  public var isSupported: Bool { state == .supported }
  public var isPermissionGated: Bool { state == .permissionGated }
}

public enum CapabilityKey: String, CaseIterable, Sendable {
  case sendTextDM = "send_text_dm"
  case sendTextGroup = "send_text_group"
  case sendFileDM = "send_file_dm"
  case sendFileGroup = "send_file_group"
  case verifiedSend = "verified_send"
  case attachmentsRead = "attachments_read"
  case attachmentsOffloaded = "attachments_offloaded"
  case replyThreading = "reply_threading"
  case tapbacks = "tapbacks"
  case editUnsend = "edit_unsend"
  case liveInbox = "live_inbox"
  case permFullDisk = "perm_full_disk"
  case permContacts = "perm_contacts"
  /// `detail` carries the raw `PermissionStatus`.
  case permAutomation = "perm_automation"
  case richBackend = "rich_backend"
}
