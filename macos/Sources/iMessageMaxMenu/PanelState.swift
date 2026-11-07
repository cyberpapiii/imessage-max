import IMessageMaxContract
import MaxBrand
import MaxCore

enum Busy: Equatable {
  case starting, stopping, askingPermission, checkingSending, moving

  var title: String {
    switch self {
    case .starting: "Getting ready…"
    case .stopping: "Taking a break…"
    case .askingPermission: "Waiting for permission…"
    case .checkingSending: "Checking sending…"
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

  static func granted(_ permission: SetupPermission) -> Notice {
    Notice(text: permission == .automation ? "Sending is ready." : "Contact names are ready.")
  }
}

struct PanelState: Equatable {
  enum Phase: Equatable {
    case checking
    case connected(Readiness, opensMessages: Bool)
    case misplaced
    case olderInstall
    case blocked
    case notSetUp
    case stopped
    case disconnected
  }

  enum Primary { case connect, start, migrate, move, openLoginItems, recheck }

  let phase: Phase
  let busy: Busy?
  let troubled: Bool

  init(service: ServiceState?, busy: Busy?, problem: String?, checked: Bool) {
    self.busy = busy
    troubled = problem != nil
    phase =
      switch service {
      case nil: !checked && problem == nil ? .checking : .disconnected
      case .running(let diagnosis):
        .connected(diagnosis.readiness, opensMessages: diagnosis.needsMessagesForSendingCheck)
      case .misplaced: .misplaced
      case .legacyInstall: .olderInstall
      case .blockedInLoginItems: .blocked
      case .notRegistered: .notSetUp
      case .stopped: .stopped
      case .portConflict, .unresponsive: .disconnected
      }
  }

  var title: String {
    if let busy { return busy.title }
    return switch phase {
    case .checking: "Checking in…"
    case .connected(.messages, _): "A little setup first"
    case .connected(.contacts, _): "Let’s add names"
    case .connected(.sending, _): "Ready to read"
    case .connected(.ready, _): "Ready to help"
    case .misplaced: "Move me to Applications"
    case .olderInstall: "Finish the update"
    case .blocked: "Turned off in Login Items"
    case .notSetUp: "Hello, iMessage Max"
    case .stopped: "Taking a break"
    case .disconnected: "Let’s get connected"
    }
  }

  var subtitle: String {
    if busy != nil { return "We’ll check that everything worked." }
    return switch phase {
    case .connected(.messages, _): "Give iMessage Max access to Messages on this Mac."
    case .connected(.contacts, _): "Messages are available. Allow Contacts to show names."
    case .connected(.sending, let opensMessages):
      opensMessages
        ? "Open Messages so we can check sending. Your assistants can already read messages."
        : "Your assistants can read messages. Let’s check sending access."
    case .connected(.ready, _): "Your assistants can now use Messages on this Mac."
    case .misplaced:
      "iMessage Max runs from your Applications folder, so its helper keeps working after this window closes."
    case .olderInstall:
      "An older iMessage Max helper is still installed. We’ll replace it with the one in this app. Your settings stay."
    case .blocked:
      "macOS lets the helper run only when it’s on in Login Items. Turn on iMessage Max there."
    case .notSetUp: "A small helper connects your assistants to Messages."
    case .stopped: "Start whenever you need your assistants again."
    case .checking, .disconnected:
      "Your messages stay on this Mac. Let’s check the connection."
    }
  }

  var primary: Primary? {
    switch phase {
    case .connected(.ready, _): .connect
    case .connected: nil
    case .misplaced: .move
    case .olderInstall: .migrate
    case .blocked: .openLoginItems
    case .notSetUp, .stopped: .start
    case .checking, .disconnected: .recheck
    }
  }

  var primaryTitle: String {
    if busy != nil { return "Working…" }
    return switch phase {
    case .connected: "Connect an assistant"
    case .misplaced: "Move to Applications"
    case .olderInstall: "Replace the older helper"
    case .blocked: "Open Login Items"
    case .notSetUp: "Set up iMessage Max"
    case .stopped: "Start iMessage Max"
    case .checking, .disconnected: "Check again"
    }
  }

  var primaryMark: ActionMark {
    if busy != nil { return .more }
    return switch phase {
    case .notSetUp, .stopped, .olderInstall: .play
    default: .arrow
    }
  }

  var primaryEnabled: Bool { busy == nil && phase != .checking }

  var mood: CompanionMood {
    if busy != nil || phase == .checking { return .working }
    if troubled { return .trouble }
    return switch phase {
    case .stopped, .notSetUp: .resting
    case .connected(.ready, _): .ready
    case .connected, .misplaced, .olderInstall, .blocked: .needsYou
    case .checking, .disconnected: .trouble
    }
  }
}
