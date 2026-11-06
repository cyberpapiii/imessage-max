import Foundation
import IMessageMaxContract

enum ContactsAccessPolicy: Equatable, Sendable {
    case requestIfNeeded
    case skipIfNotDetermined

    typealias Override = ContactsPolicyOption

    static let environmentKey = "IMESSAGE_MAX_CONTACTS_POLICY"

    static func forStdin(isTTY: Bool) -> ContactsAccessPolicy {
        isTTY ? .requestIfNeeded : .skipIfNotDetermined
    }

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
