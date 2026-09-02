import Foundation

/// Whether this process may put up the macOS Contacts permission dialog.
/// A process with no terminal (launchd, an MCP client's stdio pipe) cannot
/// answer the prompt; asking from there leaves the request hanging and the
/// dialog attributed to whatever launched us. Ported from openclaw/imsg.
enum ContactsAccessPolicy: Equatable, Sendable {
    case requestIfNeeded
    case skipIfNotDetermined

    /// CLI / environment override. `auto` follows stdin.
    enum Override: String, CaseIterable, Sendable {
        case auto, request, skip
    }

    static let environmentKey = "IMESSAGE_MAX_CONTACTS_POLICY"

    static func forStdin(isTTY: Bool) -> ContactsAccessPolicy {
        isTTY ? .requestIfNeeded : .skipIfNotDetermined
    }

    /// Precedence: explicit flag, then the environment variable, then stdin.
    /// Unknown environment values are ignored (the flag is validated by
    /// ArgumentParser before it gets here).
    static func resolve(flag: Override, environment: [String: String], isTTY: Bool) -> ContactsAccessPolicy {
        switch flag {
        case .request: return .requestIfNeeded
        case .skip: return .skipIfNotDetermined
        case .auto:
            switch environment[environmentKey].flatMap(Override.init(rawValue:)) {
            case .request?: return .requestIfNeeded
            case .skip?: return .skipIfNotDetermined
            default: return forStdin(isTTY: isTTY)
            }
        }
    }

    static var stdinIsTTY: Bool { isatty(STDIN_FILENO) != 0 }
}
