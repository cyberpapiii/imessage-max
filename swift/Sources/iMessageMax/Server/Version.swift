import Foundation
import MCP

enum Version {
    static let current = "1.5.0"
    static let name = "iMessage Max"
    static let title = name
    /// What `imessage-max --version` prints. The Homebrew Formula's `test do`
    /// matches the product name in this string; `make verify` strips the
    /// trailing number back out with `grep -o '[0-9.]*$'`.
    static let display = "\(name) \(current)"
    static let instructions = """
        iMessage Max reads the local iMessage database and sends messages through Messages.app. Use chat ids only as follow-up tool-call targets; when explaining results to the user, refer to chats by chat.name, group names, or participant names. Sending changes state. Confirm the destination with the user before sending anything consequential.
        """

    static var serverCapabilities: Server.Capabilities {
        .init(tools: .init(listChanged: false))
    }
}
