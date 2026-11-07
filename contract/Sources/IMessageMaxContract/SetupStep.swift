import Foundation

/// The companion's first-run steps, in order. Diagnose fixes name a step by
/// its title, so the server and the app must spell it the same way.
public enum SetupStep: String, Sendable, CaseIterable {
  case allowInBackground, readMessages, showNames, sendMessages, connectAssistant, tryIt

  public var title: String {
    switch self {
    case .allowInBackground: "Allow in the background"
    case .readMessages: "Read messages"
    case .showNames: "Show names"
    case .sendMessages: "Send messages"
    case .connectAssistant: "Connect an assistant"
    case .tryIt: "Try it"
    }
  }
}
