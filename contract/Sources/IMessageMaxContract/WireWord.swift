import Foundation

/// A string the server writes and the companion reads, with its known values
/// as static members. Open on purpose: a reader must still decode a word a
/// newer server adds, so these are not closed enums.
public protocol WireWord: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
  init(rawValue: String)
}

extension WireWord {
  public init(stringLiteral value: String) { self.init(rawValue: value) }
  public var description: String { rawValue }
}

/// `capabilities.<key>.state` in the diagnose reply.
public struct CapabilityState: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let supported: Self = "supported"
  public static let unsupported: Self = "unsupported"
  public static let permissionGated: Self = "permission-gated"
  public static let unverified: Self = "unverified"
  public static let unavailable: Self = "unavailable"
  public static let degraded: Self = "degraded"
}

/// Top-level `status` in the diagnose reply.
public struct DiagnoseStatus: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let ready: Self = "ready"
  public static let needsSetup: Self = "needs_setup"
}

/// `database.status` in the diagnose reply.
public struct DatabaseStatus: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let accessible: Self = "accessible"
  public static let permissionDenied: Self = "permission_denied"
  public static let databaseNotFound: Self = "database_not_found"
}

/// A macOS privacy permission's state as the server reports it: diagnose's
/// `contacts.status` and `perm_automation.detail`, and the setup reply's
/// `status`. Contacts and Automation share `authorized`, `denied` and
/// `not_determined`.
public struct PermissionStatus: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let authorized: Self = "authorized"
  public static let limited: Self = "limited"
  public static let denied: Self = "denied"
  public static let restricted: Self = "restricted"
  public static let notDetermined: Self = "not_determined"
  /// Contacts: a process with no terminal does not prompt.
  public static let notRequestedHeadless: Self = "not_requested_headless"
  /// Contacts: without an embedded Info.plist macOS can neither prompt for
  /// nor record a grant for the executable.
  public static let missingUsageDescription: Self = "missing_usage_description"
  /// Automation: Messages.app is not running, so TCC cannot be asked.
  public static let messagesNotRunning: Self = "messages_not_running"
  public static let messagesNotFound: Self = "messages_not_found"
  /// Contacts: an authorization state newer than this server knows.
  public static let unknown: Self = "unknown"

  /// Contacts is granted but the store failed to load.
  public static func loadFailed(_ authorization: Self) -> Self {
    Self(rawValue: "\(authorization.rawValue)_load_failed")
  }

  /// Automation: an OSStatus the server does not map.
  public static func checkFailed(_ code: Int32) -> Self {
    Self(rawValue: "check_failed_\(code)")
  }

  /// Contacts states in which names resolve.
  public static let namesAvailable: Set<Self> = [.authorized, .limited]
}
