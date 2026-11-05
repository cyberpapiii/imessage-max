import Foundation

/// A permission the companion may ask the running service to request.
/// The request has to come from the service process: TCC records the grant
/// for whichever process asks.
public enum SetupPermission: String, Codable, Sendable, CaseIterable {
  case contacts, automation
}

/// `POST /setup/permissions`: the native-only route through which the
/// companion asks the service to put up a macOS permission prompt.
public enum SetupPermissionRoute {
  public static let pathComponents = ["setup", "permissions"]
  public static let path = "/" + pathComponents.joined(separator: "/")
  /// Required request header. A custom header forces a browser preflight,
  /// which the server never answers, so a web page cannot trigger a prompt.
  public static let header = "X-iMessage-Max-Setup"
  public static let headerValue = "permission-request-v1"
  /// The request body is exactly `{"permission": "<SetupPermission>"}`.
  public static let bodyKey = "permission"
  /// The server rejects a larger request body with 413.
  public static let maxRequestBytes = 256
  /// The companion refuses a larger reply.
  public static let maxReplyBytes = 4096
  /// No such route: an older server, or one bound to a non-loopback host.
  public static let notOfferedStatus = 404
  /// Another permission request is still open.
  public static let busyStatus = 409
}

public struct SetupPermissionReply: Codable, Sendable, Equatable {
  public let permission: SetupPermission
  public let authorized: Bool
  public let status: PermissionStatus
  /// The service's pid, so the companion can tell the reply came from the
  /// launchd job it manages.
  public let processID: Int32

  public init(permission: SetupPermission, authorized: Bool, status: PermissionStatus, processID: Int32) {
    self.permission = permission
    self.authorized = authorized
    self.status = status
    self.processID = processID
  }

  enum CodingKeys: String, CodingKey {
    case permission, authorized, status
    case processID = "process_id"
  }
}
