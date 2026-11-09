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

/// `power.status` in the diagnose reply.
public struct PowerStatus: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  /// System sleep is off, or the helper holds its keep-awake assertion.
  public static let staysAwake: Self = "stays_awake"
  /// The Mac sleeps after `sleep_minutes` of inactivity.
  public static let idleSleep: Self = "idle_sleep"
  /// macOS did not report the sleep setting.
  public static let unknown: Self = "unknown"
}

/// `capabilities.live_inbox.detail` in the diagnose reply. The state is for
/// the connection that called diagnose; the detail also says whether the
/// helper's watcher runs at all.
public struct LiveInboxDetail: WireWord {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  /// This legacy HTTP session receives new-message notifications over SSE.
  public static let sessionSSE: Self = "session_sse"
  /// The watcher runs, but this connection (stdio, or the stateless modern
  /// lane) never receives notifications. Poll get_messages_since.
  public static let pollOnly: Self = "poll_only"
  /// No watcher runs in this process, so no connection gets notifications.
  public static let watcherNotRunning: Self = "watcher_not_running"
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
