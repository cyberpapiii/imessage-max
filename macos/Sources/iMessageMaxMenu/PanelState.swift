import IMessageMaxContract
import MaxBrand
import MaxCore

enum Busy: Equatable {
  case starting, stopping, askingPermission, checkingSending

  var title: String {
    switch self {
    case .starting: "Getting ready…"
    case .stopping: "Taking a break…"
    case .askingPermission: "Waiting for permission…"
    case .checkingSending: "Checking sending…"
    }
  }

  var isPermissionRequest: Bool { self == .askingPermission || self == .checkingSending }
}

struct Notice: Equatable {
  enum Tone { case good, neutral }

  let text: String
  var tone = Tone.good

  static let resting = Notice(text: "Resting until you start it again.")
  static let connected = Notice(text: "Connected. You’re back in business.")
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
    case stopped(installed: Bool)
    case disconnected
  }

  enum Primary { case connect, start, recheck }

  let phase: Phase
  let busy: Busy?
  let troubled: Bool

  init(inspection: ServiceInspection?, busy: Busy?, problem: String?, checked: Bool) {
    self.busy = busy
    troubled = problem != nil
    if !checked && problem == nil {
      phase = .checking
    } else if let diagnosis = inspection?.diagnosis {
      phase = .connected(diagnosis.readiness, opensMessages: diagnosis.needsMessagesForSendingCheck)
    } else if let inspection, !inspection.loaded, !inspection.conflict {
      phase = .stopped(installed: inspection.configuration.isInstalled)
    } else {
      phase = .disconnected
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
    case .stopped(let installed): installed ? "Taking a break" : "Hello, iMessage Max"
    case .disconnected: "Let’s get connected"
    }
  }

  var subtitle: String {
    if busy != nil { return "We’ll check that everything worked." }
    return switch phase {
    case .connected(.messages, _): "Give iMessage Max access to Messages on this Mac."
    case .connected(.contacts, _): "Messages are available. Contacts make names familiar."
    case .connected(.sending, let opensMessages):
      opensMessages
        ? "Open Messages so we can check sending. Your assistants can already read messages."
        : "Your assistants can read messages. Let’s check sending access."
    case .connected(.ready, _): "Your messages. Your assistants. All on this Mac."
    case .stopped(let installed):
      installed
        ? "Start whenever you need your assistants again."
        : "A small helper connects your assistants to Messages."
    case .checking, .disconnected:
      "Your messages stay on this Mac. We’ll help with the connection."
    }
  }

  var primary: Primary? {
    switch phase {
    case .connected(.ready, _): .connect
    case .connected: nil
    case .stopped: .start
    case .checking, .disconnected: .recheck
    }
  }

  var primaryTitle: String {
    if busy != nil { return "Working…" }
    return switch phase {
    case .connected: "Connect an assistant"
    case .stopped(let installed): installed ? "Start iMessage Max" : "Set up iMessage Max"
    case .checking, .disconnected: "Check again"
    }
  }

  var primaryMark: ActionMark {
    if busy != nil { return .more }
    if case .stopped = phase { return .play }
    return .arrow
  }

  var primaryEnabled: Bool { busy == nil && phase != .checking }

  var mood: CompanionMood {
    if busy != nil || phase == .checking { return .working }
    if troubled { return .trouble }
    return switch phase {
    case .stopped: .resting
    case .connected(.ready, _): .ready
    case .connected: .needsYou
    case .checking, .disconnected: .trouble
    }
  }
}
