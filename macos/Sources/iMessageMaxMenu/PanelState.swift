import IMessageMaxContract
import MaxBrand
import MaxCore

enum Busy: Equatable {
  case starting, stopping, askingPermission, checkingSending, checkingAccess, moving

  var title: String {
    switch self {
    case .starting: "Getting ready…"
    case .stopping: "Taking a break…"
    case .askingPermission: "Waiting for permission…"
    case .checkingSending: "Checking sending…"
    case .checkingAccess: "Checking access…"
    case .moving: "Moving to Applications…"
    }
  }

  var isPermissionRequest: Bool { self == .askingPermission || self == .checkingSending }
}

struct Notice: Equatable {
  enum Tone { case good, neutral }

  let text: String
  var tone = Tone.good

  static let resting = Notice(text: "Resting until you start it again.")
  static let connected = Notice(text: "Connected. iMessage Max is running.")
  static let setupUnfinished = Notice(
    text: "That permission isn’t on yet. See Permissions below.", tone: .neutral)
  static let noLog = Notice(text: "No service log yet. Start iMessage Max first.")
  static let tried = Notice(text: "Your assistant just used iMessage Max. You’re all set.")

  static func linked(_ name: String) -> Notice { Notice(text: "\(name) is connected.") }

  static func granted(_ permission: SetupPermission) -> Notice {
    Notice(text: permission == .automation ? "Sending is ready." : "Contact names are ready.")
  }
}

/// One detected client on the Connections page.
struct ClientRow: Identifiable, Equatable {
  let id: ClientID
  let name: String
  var link: ClientLink
  var activity = ClientActivity.idle
}

enum ClientActivity: Equatable {
  case idle, connecting
  /// What the last Connect changed.
  case finished(String)
  /// The client shows its own Install step.
  case waiting(String)
  case failed(String)
}

/// What the home panel judges besides diagnose.
struct SetupFacts: Equatable {
  /// Detected clients whose config reaches the helper, in table order. nil
  /// until the first scan.
  var connected: [String]?
  /// The user chose Not now, or an assistant has connected or called a
  /// tool. Kept across launches, so the connect card does not come back.
  var connectSettled = false
}

enum Grant: Equatable {
  /// The word the row shows, such as Allowed.
  case granted(String)
  case missing(String)
  /// The helper is not running, so nothing can check.
  case unknown

  static let notChecked = "Not checked"
}

struct PermissionRow: Identifiable, Equatable {
  let step: SetupStep
  let grant: Grant
  var id: SetupStep { step }

  var word: String {
    switch grant {
    case .granted(let word), .missing(let word): word
    case .unknown: Grant.notChecked
    }
  }
}

extension SetupStep {
  var purpose: String {
    switch self {
    case .backgroundActivity: "Keeps running when this panel is closed."
    case .fullDiskAccess: "Lets your assistants read your messages."
    case .contacts: "Shows people’s names instead of phone numbers."
    case .automation: "Lets your assistants send messages when you ask."
    }
  }

  /// The permission as a running helper reports it. Answering diagnose is
  /// itself the check for background activity.
  func grant(_ diagnosis: DiagnoseResult) -> Grant {
    switch self {
    case .backgroundActivity:
      return .granted("On")
    case .fullDiskAccess:
      if diagnosis.database.accessible { return .granted("Allowed") }
      return .missing(diagnosis.database.status == .permissionDenied ? "Not allowed" : Grant.notChecked)
    case .contacts:
      if diagnosis.namesReady {
        return .granted(diagnosis.contacts.status == .limited ? "Some contacts" : "Allowed")
      }
      return .missing(diagnosis.contacts.authorized ? Grant.notChecked : "Not allowed")
    case .automation:
      if diagnosis.sendingReady { return .granted("Allowed") }
      return .missing(diagnosis[.permAutomation]?.isPermissionGated == true ? "Not allowed" : Grant.notChecked)
    }
  }
}

/// The four permissions, the same during first run and after. The first
/// missing one is the one the panel walks the user through.
struct Permissions: Equatable {
  let rows: [PermissionRow]

  /// nil for a helper no permission can fix, such as one that is stopped or
  /// misplaced.
  init?(service: ServiceState?) {
    switch service {
    case .notRegistered?, .blockedInLoginItems?:
      rows = SetupStep.allCases.map {
        PermissionRow(step: $0, grant: $0 == .backgroundActivity ? .missing("Off") : .unknown)
      }
    case .running(let diagnosis)?:
      rows = SetupStep.allCases.map { PermissionRow(step: $0, grant: $0.grant(diagnosis)) }
    default:
      return nil
    }
  }

  var current: SetupStep? {
    rows.first {
      if case .missing = $0.grant { true } else { false }
    }?.step
  }
}

struct PanelState: Equatable {
  enum Phase: Equatable {
    case checking
    /// Background activity is off, before the helper was ever registered.
    case notSetUp
    /// Background activity is off, because the user turned it off in Login Items.
    case blocked
    /// A running helper's first missing permission.
    case setup(SetupStep)
    case ready
    case misplaced
    case olderInstall
    case stopped
    /// The helper answered 401: it holds another token than this app reads.
    case keyMismatch
    case disconnected
  }

  enum Primary { case start, restart, migrate, move, recheck }

  let phase: Phase
  let permissions: Permissions?
  /// Every permission is on, and no assistant has connected yet.
  let offersConnect: Bool
  /// The Connections row's value: who is connected, or None. nil until the
  /// first scan.
  let connections: String?
  let busy: Busy?
  let troubled: Bool

  init(
    service: ServiceState?, facts: SetupFacts = SetupFacts(), busy: Busy?, problem: String?,
    checked: Bool
  ) {
    self.busy = busy
    troubled = problem != nil
    let permissions = Permissions(service: service)
    self.permissions = permissions
    phase =
      switch service {
      case nil: !checked && problem == nil ? .checking : .disconnected
      case .running: permissions?.current.map(Phase.setup) ?? .ready
      case .misplaced: .misplaced
      case .legacyInstall: .olderInstall
      case .blockedInLoginItems: .blocked
      case .notRegistered: .notSetUp
      case .stopped: .stopped
      case .tokenRejected: .keyMismatch
      case .portConflict, .unresponsive: .disconnected
      }
    offersConnect = phase == .ready && facts.connected == [] && !facts.connectSettled
    connections = facts.connected.map { names in
      switch names.count {
      case 0: "None"
      case 1: names[0]
      default: "\(names[0]) and \(names.count - 1) more"
      }
    }
  }

  /// The permission the panel walks the user through now.
  var step: SetupStep? {
    switch phase {
    case .notSetUp, .blocked: .backgroundActivity
    case .setup(let step): step
    default: nil
    }
  }

  var title: String {
    if let busy { return busy.title }
    return switch phase {
    case .checking: "Checking in…"
    case .notSetUp: "Hello, iMessage Max"
    case .blocked: "Turned off in Login Items"
    case .setup(.contacts), .setup(.automation): "Almost ready"
    case .setup: "A little setup first"
    case .ready: "Ready to help"
    case .misplaced: "Move me to Applications"
    case .olderInstall: "Finish the update"
    case .stopped: "Taking a break"
    case .keyMismatch: "Access key doesn’t match"
    case .disconnected: "Let’s get connected"
    }
  }

  var subtitle: String {
    if busy != nil { return "We’ll check that everything worked." }
    return switch phase {
    case .notSetUp: "A small helper connects your assistants to Messages. Allow what it needs below."
    case .blocked: "Background activity is off, so your assistants can’t reach Messages."
    case .setup(.contacts): "Your assistants can read messages. Allow Contacts to show names."
    case .setup(.automation): "Your assistants can read messages. Allow Automation so they can send."
    case .setup: "Give iMessage Max access to Messages on this Mac."
    case .ready: "Your assistants can use Messages on this Mac."
    case .misplaced:
      "Move iMessage Max to Applications so it can register its helper and start at login."
    case .olderInstall:
      "An older iMessage Max helper is still installed. We’ll replace it with the one in this app. Then you’ll allow access once more, for the app."
    case .stopped: "Start whenever you need your assistants again."
    case .keyMismatch:
      "iMessage Max is running but turned this app away, because its access key changed. Restart it so both use the same key."
    case .checking, .disconnected:
      "Your messages stay on this Mac. Let’s check the connection."
    }
  }

  /// The big button, for states outside the permissions. A missing
  /// permission carries its own.
  var primary: Primary? {
    switch phase {
    case .misplaced: .move
    case .olderInstall: .migrate
    case .stopped: .start
    case .keyMismatch: .restart
    case .checking, .disconnected: .recheck
    case .notSetUp, .blocked, .setup, .ready: nil
    }
  }

  var primaryTitle: String {
    if busy != nil { return "Working…" }
    return switch phase {
    case .misplaced: "Move to Applications"
    case .olderInstall: "Replace the older helper"
    case .stopped: "Start iMessage Max"
    case .keyMismatch: "Restart iMessage Max"
    default: "Check again"
    }
  }

  var primaryMark: ActionMark {
    if busy != nil { return .more }
    return switch phase {
    case .stopped, .olderInstall, .keyMismatch: .play
    default: .arrow
    }
  }

  var primaryEnabled: Bool { busy == nil && phase != .checking }

  var mood: CompanionMood {
    if busy != nil || phase == .checking { return .working }
    if troubled { return .trouble }
    return switch phase {
    case .stopped, .notSetUp: .resting
    case .ready: .ready
    case .setup, .blocked, .misplaced, .olderInstall: .needsYou
    case .checking, .disconnected, .keyMismatch: .trouble
    }
  }
}
