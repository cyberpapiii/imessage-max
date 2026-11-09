import IMessageMaxContract
import MaxBrand
import MaxCore

enum Busy: Equatable {
  case starting, stopping, askingPermission, checkingAccess, moving

  var title: String {
    switch self {
    case .starting: "Getting ready…"
    case .stopping: "Taking a break…"
    case .askingPermission: "Waiting for permission…"
    case .checkingAccess: "Checking access…"
    case .moving: "Moving to Applications…"
    }
  }

  var isPermissionRequest: Bool { self == .askingPermission }
}

/// A short line that answers an action. The window shows it where the
/// action was, and VoiceOver reads it out.
struct Notice: Equatable {
  let text: String

  static let resting = Notice(text: "Stopped. iMessage Max rests until you start it again.")
  static let connected = Notice(text: "iMessage Max is running.")
  static let setupUnfinished = Notice(text: "That permission isn’t on yet.")
  static let noLog = Notice(text: "No log yet. Start iMessage Max first.")

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

/// What the companion judges besides diagnose.
struct SetupFacts: Equatable {
  /// Detected clients whose config reaches the helper, in table order. nil
  /// until the first scan.
  var connected: [String]?
  /// The user chose Not now, or an assistant has connected or called a
  /// tool. Kept across launches, so the connect prompt does not come back.
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
    case .backgroundActivity: "Keeps iMessage Max running, even after you quit this app."
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
/// missing one opens with what to do.
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

/// The pages of the Settings window, in sidebar order. General sits under
/// the identity row at the top of the sidebar.
enum SettingsPage: String, CaseIterable, Identifiable {
  case general, permissions, connections, about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "iMessage Max"
    case .permissions: "Permissions"
    case .connections: "Connections"
    case .about: "About & Help"
    }
  }
}

/// The pages the Settings window has shown, for its back and forward buttons.
struct PageHistory: Equatable {
  private(set) var pages: [SettingsPage]
  private(set) var index = 0

  init(_ start: SettingsPage = .general) { pages = [start] }

  var current: SettingsPage { pages[index] }
  var canGoBack: Bool { index > 0 }
  var canGoForward: Bool { index < pages.count - 1 }

  mutating func go(_ page: SettingsPage) {
    guard page != current else { return }
    pages = Array(pages[...index]) + [page]
    index += 1
  }

  mutating func back() { if canGoBack { index -= 1 } }
  mutating func forward() { if canGoForward { index += 1 } }
}

/// What the status menu and the sidebar say beside the face.
enum Status: Equatable {
  case running, attention, stopped, settingUp
  /// A check or a change is under way, with what it is doing.
  case working(String)

  var word: String {
    switch self {
    case .running: "Running"
    case .attention: "Needs attention"
    case .stopped: "Stopped"
    case .settingUp: "Setting up"
    case .working(let title): title
    }
  }
}

/// The one thing to do next, as a line in the status menu. Choosing it opens
/// Settings on `page`.
struct Attention: Equatable {
  let text: String
  let page: SettingsPage
  /// false for a suggestion, such as connecting the first assistant.
  var urgent = true
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
  /// Who is connected, or None. nil until the first scan.
  let connections: String?
  let busy: Busy?
  let troubled: Bool
  /// Setup was finished once: an assistant connected or called a tool, or
  /// the user chose Not now. A permission missing after that needs attention.
  let settled: Bool

  init(
    service: ServiceState?, facts: SetupFacts = SetupFacts(), busy: Busy?, problem: String?,
    checked: Bool
  ) {
    self.busy = busy
    troubled = problem != nil
    settled = facts.connectSettled
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

  /// The permission to turn on now.
  var step: SetupStep? {
    switch phase {
    case .notSetUp, .blocked: .backgroundActivity
    case .setup(let step): step
    default: nil
    }
  }

  var status: Status {
    if let busy { return .working(busy.title) }
    return switch phase {
    case .checking: .working("Checking…")
    case .ready, .stopped: troubled ? .attention : phase == .ready ? .running : .stopped
    case .notSetUp: .settingUp
    case .setup: settled ? .attention : .settingUp
    case .blocked, .misplaced, .olderInstall, .keyMismatch, .disconnected: .attention
    }
  }

  var attention: Attention? {
    if busy != nil { return nil }
    if troubled && (phase == .ready || phase == .stopped) {
      return Attention(text: "Something went wrong", page: .general)
    }
    return switch phase {
    case .notSetUp: Attention(text: "Finish setting up", page: .permissions)
    case .blocked: Attention(text: "Turn on iMessage Max in Login Items", page: .permissions)
    case .setup(.backgroundActivity): Attention(text: "Turn on Background activity", page: .permissions)
    case .setup(.fullDiskAccess): Attention(text: "Turn on Full Disk Access", page: .permissions)
    case .setup(.contacts): Attention(text: "Allow Contacts to show names", page: .permissions)
    case .setup(.automation): Attention(text: "Allow Automation to send messages", page: .permissions)
    case .misplaced: Attention(text: "Move iMessage Max to Applications", page: .general)
    case .olderInstall: Attention(text: "Finish the update", page: .general)
    case .keyMismatch: Attention(text: "Restart iMessage Max", page: .general)
    case .disconnected: Attention(text: "iMessage Max isn’t answering", page: .general)
    case .ready where offersConnect:
      Attention(text: "Connect your assistant", page: .connections, urgent: false)
    case .checking, .ready, .stopped: nil
    }
  }

  var subtitle: String {
    if busy != nil { return "We’ll check that everything worked." }
    return switch phase {
    case .notSetUp:
      "A small helper connects your assistants to Messages. Allow what it needs in Permissions."
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
    case .checking: "Checking the connection…"
    case .disconnected: "Your messages stay on this Mac. Let’s check the connection."
    }
  }

  /// The service row's button, for states outside the permissions. A missing
  /// permission carries its own on the Permissions page.
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
    switch phase {
    case .misplaced: "Move to Applications"
    case .olderInstall: "Replace Older Helper"
    case .stopped: "Start iMessage Max"
    case .keyMismatch: "Restart iMessage Max"
    default: "Check Again"
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
