import Foundation

/// A string the server writes and the companion reads, with its known values
/// as static members. The type is open on purpose. A reader must still decode
/// a word that a newer server adds, so these are not closed enums.
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

/// `http.state` in the diagnose reply.
public struct HTTPEndpointState: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public static let starting: Self = "starting"
  public static let listening: Self = "listening"
  /// Another process holds the port. The helper retries the bind, and stdio
  /// bridges still reach it over the socket.
  public static let portInUse: Self = "port_in_use"
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
  /// Contacts: without an embedded Info.plist, macOS can neither prompt for
  /// the executable nor record a grant for it.
  public static let missingUsageDescription: Self = "missing_usage_description"
  /// Automation: Messages.app is not running, so TCC cannot be asked, and
  /// the helper has no remembered answer and could not start Messages
  /// hidden. Older helpers reported it whenever Messages was closed.
  public static let messagesNotRunning: Self = "messages_not_running"
  public static let messagesNotFound: Self = "messages_not_found"
  /// Automation: Messages.app is running but did not answer the Automation
  /// probe in time, so the helper cannot tell whether access is granted.
  /// Sends fail before anything reaches Messages until it answers again.
  public static let messagesNotResponding: Self = "messages_not_responding"
  /// Contacts: an authorization state newer than this server knows.
  public static let unknown: Self = "unknown"

  /// Contacts access is granted, but the store failed to load.
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

/// `imessage_account.detail` in the diagnose reply: what Messages says about
/// its iMessage account. Messages runs hidden on a headless Mac, so nobody
/// sees it sign out; diagnose reads the account instead.
public struct IMessageAccountStatus: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  /// An iMessage account is turned on and connected.
  public static let signedIn: Self = "signed_in"
  /// An iMessage account is turned on and still connecting.
  public static let connecting: Self = "connecting"
  /// An iMessage account is turned on but not connected: signed out, or
  /// offline.
  public static let signedOut: Self = "signed_out"
  /// Every iMessage account is turned off in Messages settings.
  public static let disabled: Self = "disabled"
  /// Messages has no iMessage account, and no SMS account that can send.
  public static let noAccount: Self = "no_account"
  /// No iMessage account is turned on, but an SMS account is turned on and
  /// connected (Text Message Forwarding), so sends to phone numbers go out
  /// as SMS.
  public static let smsOnly: Self = "sms_only"
  /// Diagnose did not read the account, because Automation for Messages is
  /// not granted.
  public static let notChecked: Self = "not_checked"
  /// Messages is not running, and diagnose does not start it again for this
  /// check once it has read the account.
  public static let messagesNotRunning: Self = "messages_not_running"
  /// Messages did not answer about its accounts in time.
  public static let messagesNotResponding: Self = "messages_not_responding"
  /// The account script failed.
  public static let checkFailed: Self = "check_failed"
}
