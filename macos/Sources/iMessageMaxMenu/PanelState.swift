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
    text: "Setup isn’t finished yet. Check the step below.", tone: .neutral)
  static let noLog = Notice(text: "No service log yet. Start iMessage Max first.")
  static let tried = Notice(text: "Your assistant just used iMessage Max. You’re all set.")

  static func granted(_ permission: SetupPermission) -> Notice {
    Notice(text: permission == .automation ? "Sending is ready." : "Contact names are ready.")
  }
}

/// One detected client on the Connection page.
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

/// What the first-run steps are judged on besides diagnose.
struct SetupFacts: Equatable {
  /// Detected clients whose config reaches the helper, in table order.
  var connected: [String] = []
  var skippedConnect = false
  /// A client other than this app has called a tool. The app keeps it once
  /// seen, because the helper's count starts over at every launch.
  var tried = false
}

enum StepProgress: Equatable {
  /// The word the row shows, such as Ready.
  case done(String)
  case current
  case skipped
  case upcoming
}

struct StepRow: Identifiable, Equatable {
  let step: SetupStep
  let progress: StepProgress
  var id: SetupStep { step }
}

extension SetupStep {
  /// The step's done check against a running helper: nil while it is not
  /// done, else the word its row shows. Answering diagnose is itself the
  /// check for Allow in the background.
  func done(_ diagnosis: DiagnoseResult, _ facts: SetupFacts) -> String? {
    switch self {
    case .allowInBackground: "On"
    case .readMessages: diagnosis.database.accessible ? "Ready" : nil
    case .showNames:
      diagnosis.namesReady ? (diagnosis.contacts.status == .limited ? "Some names" : "Ready") : nil
    case .sendMessages: diagnosis.sendingReady ? "Ready" : nil
    case .connectAssistant:
      if let first = facts.connected.first {
        facts.connected.count == 1 ? first : "\(first) and \(facts.connected.count - 1) more"
      } else {
        facts.tried ? "Connected" : nil
      }
    case .tryIt: facts.tried ? "Worked" : nil
    }
  }
}

/// First run as one ordered list. Each row is judged on its own, so a revoked
/// grant turns its row back while later rows keep their state, and the first
/// row that is neither done nor skipped is the current step.
struct FirstRun: Equatable {
  let rows: [StepRow]

  /// nil for a helper no step can fix, such as one that is stopped or misplaced.
  init?(service: ServiceState?, facts: SetupFacts) {
    switch service {
    case .notRegistered?, .blockedInLoginItems?:
      rows = SetupStep.allCases.map {
        StepRow(step: $0, progress: $0 == .allowInBackground ? .current : .upcoming)
      }
    case .running(let diagnosis)?:
      var found = false
      rows = SetupStep.allCases.map { step in
        if let word = step.done(diagnosis, facts) { return StepRow(step: step, progress: .done(word)) }
        if step == .connectAssistant && facts.skippedConnect {
          return StepRow(step: step, progress: .skipped)
        }
        defer { found = true }
        return StepRow(step: step, progress: found ? .upcoming : .current)
      }
    default:
      return nil
    }
  }

  var current: SetupStep? { rows.first { $0.progress == .current }?.step }
}

struct PanelState: Equatable {
  enum Phase: Equatable {
    case checking
    /// Step one, before the helper was ever registered.
    case notSetUp
    /// Step one, after the user turned the helper off in Login Items.
    case blocked
    /// A running helper's first unfinished step.
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
  let firstRun: FirstRun?
  let busy: Busy?
  let troubled: Bool

  init(
    service: ServiceState?, facts: SetupFacts = SetupFacts(), busy: Busy?, problem: String?,
    checked: Bool
  ) {
    self.busy = busy
    troubled = problem != nil
    let firstRun = FirstRun(service: service, facts: facts)
    self.firstRun = firstRun
    phase =
      switch service {
      case nil: !checked && problem == nil ? .checking : .disconnected
      case .running: firstRun?.current.map(Phase.setup) ?? .ready
      case .misplaced: .misplaced
      case .legacyInstall: .olderInstall
      case .blockedInLoginItems: .blocked
      case .notRegistered: .notSetUp
      case .stopped: .stopped
      case .tokenRejected: .keyMismatch
      case .portConflict, .unresponsive: .disconnected
      }
  }

  /// The step the panel walks the user through now.
  var step: SetupStep? {
    switch phase {
    case .notSetUp, .blocked: .allowInBackground
    case .setup(let step): step
    default: nil
    }
  }

  /// Steps one to four. Until they are done no assistant can use Messages.
  var needsGrant: Bool {
    guard let step else { return false }
    return step != .connectAssistant && step != .tryIt
  }

  var title: String {
    if let busy { return busy.title }
    return switch phase {
    case .checking: "Checking in…"
    case .notSetUp: "Hello, iMessage Max"
    case .blocked: "Turned off in Login Items"
    case .setup(.allowInBackground), .setup(.readMessages): "A little setup first"
    case .setup(.showNames): "Let’s add names"
    case .setup(.sendMessages): "Ready to read"
    case .setup(.connectAssistant), .setup(.tryIt), .ready: "Ready to help"
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
    case .notSetUp: "A small helper connects your assistants to Messages. A few steps set it up."
    case .blocked:
      "macOS lets the helper run only when it’s on in Login Items. Turn on iMessage Max there."
    case .setup(.allowInBackground), .setup(.readMessages):
      "Give iMessage Max access to Messages on this Mac."
    case .setup(.showNames): "Messages are available. Allow Contacts to show names."
    case .setup(.sendMessages): "Your assistants can read messages. Let’s check sending access."
    case .setup(.connectAssistant): "Connect the assistant you use. It takes one click."
    case .setup(.tryIt): "Ask your assistant something, and this step turns green."
    case .ready: "Your assistants can now use Messages on this Mac."
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

  /// The big button, for states outside the steps. A step carries its own.
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
    case .ready, .setup(.connectAssistant), .setup(.tryIt): .ready
    case .setup, .blocked, .misplaced, .olderInstall: .needsYou
    case .checking, .disconnected, .keyMismatch: .trouble
    }
  }
}
