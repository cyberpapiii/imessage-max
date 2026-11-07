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

struct PanelState: Equatable {
  enum Phase: Equatable {
    case checking
    case connected(Readiness, opensMessages: Bool)
    case misplaced
    case olderInstall
    case blocked
    case notSetUp
    case stopped
    /// The helper answered 401: it holds another token than this app reads.
    case keyMismatch
    case disconnected
  }

  enum Primary { case connect, start, restart, migrate, move, openLoginItems, recheck }

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
      case .tokenRejected: .keyMismatch
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
    case .keyMismatch: "Access key doesn’t match"
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
      "Move iMessage Max to Applications so it can register its helper and start at login."
    case .olderInstall:
      "An older iMessage Max helper is still installed. We’ll replace it with the one in this app. Then you’ll allow access once more, for the app."
    case .blocked:
      "macOS lets the helper run only when it’s on in Login Items. Turn on iMessage Max there."
    case .notSetUp: "A small helper connects your assistants to Messages."
    case .stopped: "Start whenever you need your assistants again."
    case .keyMismatch:
      "iMessage Max is running but turned this app away, because its access key changed. Restart it so both use the same key."
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
    case .keyMismatch: .restart
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
    case .keyMismatch: "Restart iMessage Max"
    case .checking, .disconnected: "Check again"
    }
  }

  var primaryMark: ActionMark {
    if busy != nil { return .more }
    return switch phase {
    case .notSetUp, .stopped, .olderInstall, .keyMismatch: .play
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
    case .checking, .disconnected, .keyMismatch: .trouble
    }
  }
}
