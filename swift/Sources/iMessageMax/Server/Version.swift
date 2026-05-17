import Foundation
import MCP

enum Version {
    static let current = "1.2.1"
    static let name = "iMessage Max"
    static let title = "iMessage Max"
    static let instructions = """
        iMessage Max exposes local iMessage history and send workflows for agent use. Use chat ids only as internal follow-up tool targets; when explaining results to the user, refer to chats by chat.name, group names, or participant names. Treat send as state-changing and confirm risky destinations before sending.
        """

    static var serverCapabilities: Server.Capabilities {
        .init(tools: .init(listChanged: false))
    }
}
