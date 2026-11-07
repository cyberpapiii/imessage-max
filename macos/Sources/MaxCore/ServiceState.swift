import Foundation
import IMessageMaxContract

/// Everything the companion knows about the helper, as one value. The
/// controller derives it from a `ServiceObservation`, so each case has one rule.
public enum ServiceState: Sendable, Equatable {
  /// The app runs from outside Applications. Registering from here would
  /// record a path that macOS keeps after the user moves or deletes the app.
  case misplaced(translocated: Bool)
  /// The pre-2.0 `local.imessage-max` agent or its copied helper is still
  /// installed. It holds the port, so it is replaced, with consent, first.
  case legacyInstall
  /// The user turned the helper off in Login Items. SMAppService reports this
  /// as `.requiresApproval`, the same status it gives before a first approval,
  /// and a Developer ID app is approved at registration, so this is the case
  /// a user meets. Both need the same step, Open Login Items.
  case blockedInLoginItems
  /// A process this app does not own listens on the helper's port.
  case portConflict
  case notRegistered
  case stopped
  /// launchd runs the helper but it does not answer yet.
  case unresponsive
  /// launchd runs the helper and it answers 401: the token file changed after
  /// the helper read it at launch. A restart makes both read the same token.
  case tokenRejected
  case running(DiagnoseResult)

  public init(_ observation: ServiceObservation) {
    switch observation.location {
    case .translocated: self = .misplaced(translocated: true)
    case .elsewhere: self = .misplaced(translocated: false)
    case .installed:
      if observation.legacy {
        self = .legacyInstall
      } else if observation.agent == .requiresApproval {
        self = .blockedInLoginItems
      } else if let diagnosis = observation.diagnosis, diagnosis.processID == observation.job?.pid,
        observation.agent == .enabled
      {
        self = .running(diagnosis)
      } else if observation.foreignListener {
        self = .portConflict
      } else if observation.agent == .notRegistered {
        self = .notRegistered
      } else {
        self =
          observation.job?.pid == nil
          ? .stopped : (observation.refused ? .tokenRejected : .unresponsive)
      }
    }
  }

  public var diagnosis: DiagnoseResult? {
    if case .running(let diagnosis) = self { diagnosis } else { nil }
  }

  /// The helper is registered and launchd may run it.
  public var isRegistered: Bool {
    switch self {
    case .stopped, .unresponsive, .tokenRejected, .running: true
    default: false
    }
  }

  public var isRunning: Bool {
    self == .unresponsive || self == .tokenRejected || diagnosis != nil
  }
}

/// The raw facts the state comes from. A test builds any case from a literal.
public struct ServiceObservation: Sendable, Equatable {
  public var location: AppLocation
  public var legacy: Bool
  public var agent: AgentStatus
  public var job: Job?
  public var diagnosis: DiagnoseResult?
  /// The endpoint answered 401 to this app's token.
  public var refused: Bool
  /// A listener on the port that is not launchd's process for the helper.
  public var foreignListener: Bool

  public init(
    location: AppLocation = .installed, legacy: Bool = false, agent: AgentStatus,
    job: Job? = nil, diagnosis: DiagnoseResult? = nil, refused: Bool = false,
    foreignListener: Bool = false
  ) {
    self.location = location
    self.legacy = legacy
    self.agent = agent
    self.job = job
    self.diagnosis = diagnosis
    self.refused = refused
    self.foreignListener = foreignListener
  }
}

/// SMAppService.Status without ServiceManagement. `.notFound` reads as not
/// registered, because a bundle without its plist fails to load before this.
public enum AgentStatus: Sendable, Equatable { case notRegistered, enabled, requiresApproval }

/// A job launchd has loaded, from `launchctl print`. `pid` is nil while it is
/// loaded but not running.
public struct Job: Sendable, Equatable {
  public var pid: Int32?

  public init(pid: Int32?) { self.pid = pid }

  public init(launchctlPrint output: String) {
    pid = output.components(separatedBy: .newlines).lazy
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix("pid = ") }
      .flatMap { Int32($0.dropFirst(6)) }
  }
}

public enum AppLocation: Sendable, Equatable {
  case installed, translocated, elsewhere

  /// Installed means under /Applications or ~/Applications. Gatekeeper runs a
  /// quarantined app from anywhere else at a random read-only path.
  public init(bundleURL: URL, home: URL) {
    let path = bundleURL.resolvingSymlinksInPath().path
    let roots = ["/Applications", home.appendingPathComponent("Applications").resolvingSymlinksInPath().path]
    if path.contains("/AppTranslocation/") {
      self = .translocated
    } else if roots.contains(where: { path.hasPrefix($0 + "/") }) {
      self = .installed
    } else {
      self = .elsewhere
    }
  }
}

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

public enum CoreError: Error, LocalizedError, Sendable, Equatable {
  case invalidResponse, invalidConfiguration, timeout
  case commandFailed(String)
  case conflict
  case notReady(ServiceState)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "iMessage Max returned an unreadable response. Try restarting it."
    case .invalidConfiguration:
      "This copy of iMessage Max is incomplete. Download it again and move it to Applications."
    case .timeout: "That took too long. Try again."
    case .conflict:
      "Another process is using this connection. iMessage Max has not changed or stopped it."
    case .commandFailed(let message): message
    case .notReady(let state):
      switch state {
      case .misplaced: "Move iMessage Max to Applications first."
      case .legacyInstall: "Finish replacing the older iMessage Max first."
      case .blockedInLoginItems: "Turn on iMessage Max in Login Items first."
      case .portConflict: CoreError.conflict.errorDescription
      default: "Start iMessage Max before finishing setup."
      }
    }
  }
}
