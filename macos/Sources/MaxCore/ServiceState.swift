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
  /// A process this app does not own listens on the helper's port. The
  /// helper may still run: it serves stdio bridges over its socket and
  /// retries the port.
  case portConflict
  case notRegistered
  case stopped
  /// launchd keeps starting the helper and it keeps stopping at launch, for
  /// the reason given, such as an unreadable token file.
  case failing(String)
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
      } else if observation.foreignListener || observation.portTaken {
        self = .portConflict
      } else if observation.agent == .notRegistered {
        self = .notRegistered
      } else if let job = observation.job, job.lastRunFailed {
        self = .failing(Self.failureReason(job, logged: observation.startupFailure))
      } else {
        self =
          observation.job?.pid == nil
          ? .stopped : (observation.refused ? .tokenRejected : .unresponsive)
      }
    }
  }

  static func failureReason(_ job: Job, logged: String?) -> String {
    if let logged { return logged }
    if let signal = job.lastSignal { return "It crashed (\(signal))." }
    return "It exited with code \(job.lastExitCode ?? -1)."
  }

  public var diagnosis: DiagnoseResult? {
    if case .running(let diagnosis) = self { diagnosis } else { nil }
  }

  /// The helper is registered and launchd may run it.
  public var isRegistered: Bool {
    switch self {
    case .stopped, .failing, .unresponsive, .tokenRejected, .running: true
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
  /// The helper runs but does not listen on its port, and something else
  /// answers there: another user's helper, whose listener lsof cannot show.
  public var portTaken: Bool
  /// The reason the helper's log gives for its last failed launch.
  public var startupFailure: String?

  public init(
    location: AppLocation = .installed, legacy: Bool = false, agent: AgentStatus,
    job: Job? = nil, diagnosis: DiagnoseResult? = nil, refused: Bool = false,
    foreignListener: Bool = false, portTaken: Bool = false, startupFailure: String? = nil
  ) {
    self.location = location
    self.legacy = legacy
    self.agent = agent
    self.job = job
    self.diagnosis = diagnosis
    self.refused = refused
    self.foreignListener = foreignListener
    self.portTaken = portTaken
    self.startupFailure = startupFailure
  }
}

/// SMAppService.Status without ServiceManagement. `.notFound` reads as not
/// registered, because a bundle without its plist fails to load before this.
public enum AgentStatus: Sendable, Equatable { case notRegistered, enabled, requiresApproval }

/// A job launchd has loaded, from `launchctl print`. `pid` is nil while it is
/// loaded but not running.
public struct Job: Sendable, Equatable {
  public var pid: Int32?
  /// `last exit code`, nil before the first exit and after a signal.
  public var lastExitCode: Int32?
  /// `last terminating signal`, such as "Segmentation fault: 11".
  public var lastSignal: String?

  public init(pid: Int32?, lastExitCode: Int32? = nil, lastSignal: String? = nil) {
    self.pid = pid
    self.lastExitCode = lastExitCode
    self.lastSignal = lastSignal
  }

  public init(launchctlPrint output: String) {
    // Only the job's own top-level lines: nested blocks such as
    // `resource coalition` carry their own `state` and similar keys.
    var fields: [String: String] = [:]
    for line in output.components(separatedBy: .newlines)
    where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
      let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
      guard parts.count == 2, fields[parts[0]] == nil else { continue }
      fields[parts[0]] = parts[1]
    }
    pid = fields["pid"].flatMap { Int32($0) }
    // launchd may name the code too: "75: EX_TEMPFAIL".
    lastExitCode = fields["last exit code"].flatMap {
      Int32($0.prefix { $0 != ":" }.trimmingCharacters(in: .whitespaces))
    }
    lastSignal = fields["last terminating signal"]
  }

  /// launchd will start it again, but its last run ended in failure: a
  /// non-zero exit other than the Keep running relaunch code, or a signal.
  /// While a helper stops at launch, launchd shows it between tries this way.
  public var lastRunFailed: Bool {
    guard pid == nil else { return false }
    if lastSignal != nil { return true }
    guard let lastExitCode else { return false }
    return lastExitCode != 0 && lastExitCode != ServiceDefaults.relaunchExitCode
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
  /// The first permission this helper still lacks, nil once it can read,
  /// show names and send. Background activity is on while it answers.
  public var missingGrant: SetupStep? {
    if !database.accessible { return .fullDiskAccess }
    if !namesReady { return .contacts }
    if !sendingReady { return .automation }
    return nil
  }

  public var namesReady: Bool {
    contacts.authorized && PermissionStatus.namesAvailable.contains(contacts.status)
  }

  public var sendingReady: Bool {
    self[.permAutomation]?.isSupported == true && self[.sendTextDM]?.isSupported == true
  }

  /// Automation is off and only System Settings can turn it on. A helper
  /// also reports `not_determined` as permission-gated, because a send never
  /// asks, but then the app's own request still shows the macOS prompt.
  public var automationRefused: Bool {
    guard let automation = self[.permAutomation], automation.isPermissionGated else { return false }
    return automation.detail != PermissionStatus.notDetermined.rawValue
  }

  public func grants(_ permission: SetupPermission) -> Bool {
    switch permission {
    case .automation: self[.permAutomation]?.isSupported == true
    case .contacts: namesReady
    }
  }

  /// The missing grant may already be on in System Settings. macOS gives Full
  /// Disk Access, and the helper reads Contacts access, only at launch, so
  /// checking it means starting a new helper.
  public var grantNeedsRestartToCheck: Bool {
    switch missingGrant {
    case .fullDiskAccess: database.status == .permissionDenied
    case .contacts:
      contacts.authorized || [.denied, .restricted].contains(contacts.status)
    default: false
    }
  }
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
      case .failing(let reason): "iMessage Max stops as soon as it starts. \(reason)"
      default: "Start iMessage Max before finishing setup."
      }
    }
  }
}
